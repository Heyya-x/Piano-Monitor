import Foundation
import Network

// macOS-only: the iOS viewer never serves an API.
#if os(macOS)

/// Read-only HTTP/JSON server published over Bonjour as `_pianomonitor._tcp`.
///
/// Security posture (see the spec's network-safety section):
/// - **Read-only.** Only `GET` is routed; everything else is `405`. No endpoint mutates practice
///   data, settings, or the machine, and no endpoint can execute anything.
/// - **Local network only.** `NWListener` binds local interfaces and Bonjour does not route, so the
///   service is not reachable from outside the LAN.
/// - **Minimal payloads.** Only aggregate practice data and device names leave the machine. No audio,
///   no file paths, no logs.
/// - **Optional token.** When `AppSettings.apiToken` is set, every request must carry it
///   (`?token=` or `X-PianoMonitor-Token`). Without a token the API is open on the LAN, which is the
///   documented MVP posture.
/// - **Never fatal.** A bind failure is reported to the UI; practice recording keeps working.
public final class PianoAPIServer: @unchecked Sendable {

    /// Supplies live status. Boxed because the closure crosses from the main actor onto the network
    /// queue and must be `Sendable`.
    public struct StatusProvider: @unchecked Sendable {
        private let provider: @Sendable () async -> APIStatusResponse

        public init(_ provider: @escaping @Sendable () async -> APIStatusResponse) {
            self.provider = provider
        }

        public func callAsFunction() async -> APIStatusResponse {
            await provider()
        }
    }

    private let store: PianoDataStore
    private let queue = DispatchQueue(label: "com.pianomonitor.network.http", qos: .utility)
    private var listener: NWListener?
    private let token = TokenBox()

    /// Live status source, assigned by `PianoMonitorService`.
    public var statusProvider: StatusProvider?
    /// Live tempo measurement source. Returns `nil` when the analyzer is not running, which is the
    /// normal case: it only runs while its window is open.
    public var tempoProvider: (@Sendable () async -> TempoSnapshot?)?
    /// Supplies the payload for `GET /api/diagnostics`.
    public var diagnosticsProvider: (@Sendable () async -> APIDiagnosticsResponse?)?

    /// Port the listener is bound to, or `nil` when it is down.
    public private(set) var port: UInt16?
    /// `true` when the requested port was taken and the system assigned another one.
    public private(set) var didFallBackToEphemeralPort = false
    /// Whether `_pianomonitor._tcp` was *verified* to resolve on this host. Not the same as the
    /// socket being bound; see `scheduleAdvertisementChecks`.
    public private(set) var isAdvertising = false
    /// Last advertisement failure, surfaced in diagnostics.
    public private(set) var advertisementError: String?

    /// Requests served and the most recent path, for diagnostics.
    private let requestCount = AtomicInt(0)
    private var lastRequestPath: String?
    /// The port requested at `start`, so `restart()` can ask for the same one.
    private var preferredPort: Int?

    public init(store: PianoDataStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// Starts listening and publishing the Bonjour service.
    ///
    /// Tries `preferredPort` first and falls back to a system-assigned port if it is taken. A clash
    /// must degrade to "the API is on a different port" (Bonjour always advertises the real one)
    /// rather than "the API is unavailable" — port 8787 was already in use by unrelated software on
    /// the development machine, which is exactly this case.
    ///
    /// - Throws: only if no port at all could be opened.
    @discardableResult
    public func start(preferredPort: Int?, token: String?) throws -> UInt16 {
        stop()
        self.token.value = token
        self.preferredPort = preferredPort

        var requested: NWEndpoint.Port = .any
        if let preferredPort,
           let candidate = NWEndpoint.Port(rawValue: UInt16(clamping: preferredPort)),
           candidate != .any {
            requested = candidate
        }

        if requested != .any,
           let listener = makeListener(on: requested),
           let assigned = waitUntilReady(listener) {
            didFallBackToEphemeralPort = false
            port = assigned
            scheduleAdvertisementChecks()
            return assigned
        }

        // Either nothing was requested, or the requested port was unavailable.
        stop()
        guard let fallback = makeListener(on: .any), let assigned = waitUntilReady(fallback) else {
            stop()
            throw PianoAPIServerError.portUnavailable
        }
        didFallBackToEphemeralPort = requested != .any
        port = assigned
        if didFallBackToEphemeralPort {
            Log.network.notice("Preferred port was unavailable; API is on system-assigned port \(assigned, privacy: .public)")
        }
        scheduleAdvertisementChecks()
        return assigned
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        isAdvertising = false
    }

    /// Tears the listener down and brings it back up on the same terms.
    ///
    /// Exposed because the Bonjour registration is established asynchronously by the system daemon,
    /// and a registration that never lands leaves the app reachable by IP but invisible to the
    /// iPhone. Restarting is the recovery path, and it is cheap.
    @discardableResult
    public func restart() throws -> UInt16 {
        try start(preferredPort: preferredPort, token: token.value)
    }

    // MARK: - Listener

    /// Builds and starts a listener on `port`, wiring the Bonjour service and connection handler.
    private func makeListener(on port: NWEndpoint.Port) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        guard let listener = try? NWListener(using: parameters, on: port) else { return nil }
        listener.service = NWListener.Service(
            name: "PianoMonitor on \(APIConstants.localHostName)",
            type: APIConstants.bonjourServiceType
        )
        let advertisedName = "PianoMonitor on \(APIConstants.localHostName)"
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // `.ready` only means the socket is bound; it is *not* proof that the Bonjour
                // registration reached the daemon, which is why `isAdvertising` is confirmed by an
                // actual browse instead of being set here.
                Log.network.notice("HTTP listener ready on port \(listener.port?.rawValue ?? 0, privacy: .public), advertising \(advertisedName, privacy: .public)")
            case .failed(let error):
                Log.network.error("HTTP listener failed: \(error.localizedDescription, privacy: .public)")
                self?.advertisementError = error.localizedDescription
                self?.isAdvertising = false
                self?.port = nil
            case .cancelled:
                self?.isAdvertising = false
                self?.port = nil
            case .waiting(let error):
                // Covers both "port in use" and a withheld Bonjour registration.
                self?.advertisementError = error.localizedDescription
                Log.network.error("HTTP listener waiting: \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        return listener
    }

    /// Blocks the caller's thread (never the network queue) until the listener is `ready`.
    ///
    /// `NWListener` reports `ready` asynchronously and `listener.port` can still be nil at that
    /// instant, so the port is polled briefly afterwards. A taken port never reaches `ready` — it
    /// sits in `.waiting` — which is why the timeout is the failure signal.
    private func waitUntilReady(_ listener: NWListener, timeout: TimeInterval = 2.0) -> UInt16? {
        let semaphore = DispatchSemaphore(value: 0)
        let readyFlag = AtomicInt(0)
        let previous = listener.stateUpdateHandler
        listener.stateUpdateHandler = { state in
            previous?(state)
            switch state {
            case .ready:
                readyFlag.store(1)
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout + 0.5)

        guard readyFlag.value == 1 else { return nil }
        for _ in 0..<25 {
            if let assigned = listener.port?.rawValue, assigned != 0 { return assigned }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    // MARK: - Advertisement verification

    /// Runs a bounded sequence of Bonjour visibility checks.
    ///
    /// **Why browse rather than trust `.ready`:** `.ready` only means the socket is bound. On modern
    /// macOS a Bonjour *registration* can be withheld until the app has local-network consent, so the
    /// app can hold a perfectly good listening socket while staying invisible to Bonjour — exactly
    /// the failure an iPhone user would see. Browsing exercises (and on first run triggers the
    /// consent prompt for) local-network access, so it is both the verification mechanism and the
    /// thing that gets the registration unstuck.
    ///
    /// Written as an explicit retry schedule rather than a recursive closure: a recursive version
    /// made the Swift type checker explode and the build never completed.
    private func scheduleAdvertisementChecks(attempt: Int = 0) {
        let maximumAttempts = 5
        guard attempt < maximumAttempts else {
            if !isAdvertising {
                advertisementError = "Bonjour did not resolve \(APIConstants.bonjourServiceType) after \(maximumAttempts) attempts. Check System Settings → Privacy & Security → Local Network for “Piano Monitor”, then use Restart in Settings."
                Log.network.error("\(self.advertisementError ?? "", privacy: .public)")
            }
            return
        }
        let delay = attempt == 0 ? 0.5 : pow(2.0, Double(attempt)) * 1.5
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkAdvertisementOnce(attempt: attempt)
        }
    }

    /// One bounded browse for `_pianomonitor._tcp`.
    private func checkAdvertisementOnce(attempt: Int) {
        let browser = NWBrowser(
            for: .bonjour(type: APIConstants.bonjourServiceType, domain: nil),
            using: .tcp
        )
        let settled = AtomicInt(0)

        func conclude(_ success: Bool) {
            guard settled.compareExchange(expected: 0, desired: 1) else { return }
            browser.cancel()
            if success {
                isAdvertising = true
                advertisementError = nil
                Log.network.notice("Bonjour advertisement confirmed for \(APIConstants.bonjourServiceType, privacy: .public)")
            } else {
                scheduleAdvertisementChecks(attempt: attempt + 1)
            }
        }

        browser.browseResultsChangedHandler = { results, _ in
            if !results.isEmpty { conclude(true) }
        }
        browser.stateUpdateHandler = { state in
            // Only `.failed` is a real problem. `.cancelled` fires when this attempt is being torn
            // down (including by `conclude` itself); treating it as a failure produced a spurious
            // "Address already in use" and hid the real outcome.
            if case .failed(let error) = state {
                Log.network.error("Bonjour browse failed: \(error.localizedDescription, privacy: .public)")
                conclude(false)
            }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { conclude(false) }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(on: connection, accumulated: Data())
    }

    /// Reads until the end of the request headers. Bounded so a broken or hostile client cannot make
    /// the app allocate without limit.
    private func receiveHead(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data { buffer.append(data) }

            if error != nil {
                connection.cancel()
                return
            }
            if buffer.count > 32 * 1024 {
                self.send(
                    HTTPResponse.error(status: 431, reason: "Request Header Fields Too Large", code: "too_large", message: "Request head too large"),
                    on: connection
                )
                return
            }
            // A complete head ends with a blank line. GET requests carry no body.
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") || isComplete {
                self.handle(buffer, on: connection)
                return
            }
            self.receiveHead(on: connection, accumulated: buffer)
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        guard let request = HTTPRequest(data: data) else {
            send(HTTPResponse.error(status: 400, reason: "Bad Request", code: "bad_request", message: "Malformed HTTP request"), on: connection)
            return
        }

        // Authentication first: an unauthenticated request learns nothing about the data.
        if let expected = token.value, !expected.isEmpty {
            let provided = request.query["token"] ?? request.headers["x-pianomonitor-token"]
            guard provided == expected else {
                send(HTTPResponse.error(status: 401, reason: "Unauthorized", code: "unauthorized", message: "Missing or invalid token"), on: connection)
                return
            }
        }

        guard request.method == "GET" else {
            send(
                HTTPResponse.error(status: 405, reason: "Method Not Allowed", code: "read_only", message: "PianoMonitor's API is read-only")
                    .withExtraHeaders(["Allow": "GET"]),
                on: connection
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let response = await self.route(request)
            self.send(response, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest) async -> HTTPResponse {
        requestCount.increment()
        lastRequestPath = request.path
        Log.verbose(Log.network, "GET \(request.path)\(request.query.isEmpty ? "" : "?\(request.query)")")

        switch request.path {
        case "/", "/api":
            return index()
        case "/api/status":
            return await status()
        case "/api/sessions":
            return await sessions(request)
        case "/api/statistics":
            return await statistics(request)
        case "/api/tempo":
            return await tempo(request)
        case "/api/diagnostics":
            return await diagnostics()
        default:
            return HTTPResponse.error(status: 404, reason: "Not Found", code: "not_found", message: "Unknown endpoint \(request.path)")
        }
    }

    /// Requests served and the most recent path.
    public func requestStatistics() -> (count: Int, lastPath: String?) {
        (requestCount.value, lastRequestPath)
    }

    private func index() -> HTTPResponse {
        let payload: [String: Any] = [
            "name": "PianoMonitor",
            "version": APIConstants.apiVersion,
            "readOnly": true,
            "bonjourService": APIConstants.bonjourServiceType,
            "endpoints": [
                "/api/status",
                "/api/sessions?from=&to=&limit=",
                "/api/statistics?period=day|week|month|year|all",
                "/api/tempo?limit=",
                "/api/diagnostics",
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            ?? Data(#"{"name":"PianoMonitor"}"#.utf8)
        return .json(body: data)
    }

    private func diagnostics() async -> HTTPResponse {
        guard let diagnosticsProvider, let payload = await diagnosticsProvider() else {
            return .error(status: 503, reason: "Service Unavailable", code: "not_ready", message: "Diagnostics are not available yet")
        }
        return encode(payload)
    }

    private func status() async -> HTTPResponse {
        let payload: APIStatusResponse
        if let statusProvider {
            payload = await statusProvider()
        } else {
            payload = APIStatusResponse.disconnected
        }
        return encode(payload)
    }

    private func sessions(_ request: HTTPRequest) async -> HTTPResponse {
        let from = request.date("from")
        let to = request.date("to")
        let limit = min(max(request.int("limit") ?? 200, 1), 2_000)
        do {
            let sessions = try await store.sessions(from: from, to: to, limit: limit, includeSegments: true)
            return encode(APISessionsResponse(sessions: sessions))
        } catch {
            return failure(error, context: "load sessions")
        }
    }

    private func statistics(_ request: HTTPRequest) async -> HTTPResponse {
        let raw = request.query["period"] ?? StatisticsPeriod.week.rawValue
        guard let period = StatisticsPeriod(rawValue: raw.lowercased()) else {
            return HTTPResponse.error(
                status: 400,
                reason: "Bad Request",
                code: "bad_period",
                message: "period must be one of \(StatisticsPeriod.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        let reference = request.date("reference") ?? Date()
        do {
            let statistics = try await store.statistics(period: period, reference: reference)
            let days: Int
            switch period {
            case .day: days = 1
            case .week: days = 7
            case .month: days = 31
            case .year: days = 365
            case .all: days = 90
            }
            let daily = try await store.dailySummaries(days: days, endingOn: reference)
            let summaries = daily.map {
                DailyPracticeSummary(
                    date: $0.day,
                    totalActiveDuration: $0.activeDuration,
                    sessionCount: $0.sessionCount,
                    longestSession: 0
                )
            }
            return encode(APIStatisticsResponse(period: period.rawValue, statistics: statistics, days: summaries))
        } catch {
            return failure(error, context: "compute statistics")
        }
    }

    private func tempo(_ request: HTTPRequest) async -> HTTPResponse {
        let limit = min(max(request.int("limit") ?? 20, 1), 200)
        do {
            let history = try await store.tempoSessions(from: nil, to: nil, limit: limit)
            var live: TempoLiveMeasurement?
            if let tempoProvider, let snapshot = await tempoProvider(), snapshot.hasMeasurement {
                live = TempoLiveMeasurement(snapshot: snapshot)
            }
            return encode(APITempoResponse(live: live, history: history))
        } catch {
            return failure(error, context: "load tempo sessions")
        }
    }

    // MARK: - Helpers

    private func encode<T: Encodable>(_ value: T) -> HTTPResponse {
        do {
            return .json(body: try APICoding.makeEncoder().encode(value))
        } catch {
            Log.network.error("JSON encoding failed: \(error.localizedDescription, privacy: .public)")
            return .error(status: 500, reason: "Internal Server Error", code: "encoding_failed", message: "Could not encode response")
        }
    }

    private func failure(_ error: Error, context: String) -> HTTPResponse {
        Log.network.error("API failed to \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return .error(status: 500, reason: "Internal Server Error", code: "store_failed", message: "Could not \(context)")
    }
}

/// Thread-safe holder so the token can be read from the network queue without capturing a mutable
/// `var` in a `@Sendable` closure.
final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}

extension HTTPResponse {
    func withExtraHeaders(_ headers: [String: String]) -> HTTPResponse {
        var copy = self
        copy.additionalHeaders.merge(headers) { _, new in new }
        return copy
    }
}

#endif
