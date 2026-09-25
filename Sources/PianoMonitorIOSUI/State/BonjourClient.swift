import Foundation
import Network
import PianoMonitorKit

/// A Mac discovered on the local network.
public struct DiscoveredMac: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    /// Resolved connection details, once available.
    public var host: String?
    public var port: UInt16?

    public init(id: String, name: String, endpoint: NWEndpoint, host: String? = nil, port: UInt16? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.host = host
        self.port = port
    }

    /// Base URL for the HTTP API, or `nil` until the address resolves.
    public var baseURL: URL? {
        guard let host, let port, port != 0 else { return nil }
        // Bonjour hostnames end in a dot; URL(string:) tolerates it but the trailing dot can confuse
        // some resolvers, so trim it.
        let cleaned = host.hasSuffix(".") ? String(host.dropLast()) : host
        return URL(string: "http://\(cleaned):\(port)")
    }
}

/// Discovers PianoMonitor instances with `NWBrowser`, then resolves them to host/port.
///
/// The iOS app is a viewer: it never sends anything but `GET`, and it holds no authoritative data.
public final class BonjourMacBrowser: @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case idle
        case searching
        case found([DiscoveredMac])
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.pianomonitor.ios.browser", qos: .utility)
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private var discovered: [String: DiscoveredMac] = [:]

    /// Called on the main queue whenever the set of discovered Macs changes.
    public var onUpdate: (@Sendable (State) -> Void)?

    public init() {}

    public func start() {
        stop()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: APIConstants.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.publish(.failed(error.localizedDescription))
            case .ready:
                self.publish(.searching)
            case .cancelled:
                self.publish(.idle)
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
        publish(discovered.isEmpty ? .searching : .found(Array(discovered.values)))
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for connection in resolvers.values { connection.cancel() }
        resolvers.removeAll()
        discovered.removeAll()
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var seen: Set<String> = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            seen.insert(name)
            if discovered[name] == nil {
                discovered[name] = DiscoveredMac(
                    id: name,
                    name: name,
                    endpoint: result.endpoint
                )
                resolve(name: name, endpoint: result.endpoint)
            }
        }
        // Drop entries whose service disappeared.
        for key in discovered.keys where !seen.contains(key) {
            discovered.removeValue(forKey: key)
            resolvers[key]?.cancel()
            resolvers.removeValue(forKey: key)
        }
        publish(.found(Array(discovered.values)))
    }

    /// Resolves a Bonjour service to a concrete host and port by opening a short-lived connection
    /// and reading the resolved endpoint back out of it.
    private func resolve(name: String, endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            guard case .ready = state else { return }
            defer { connection.cancel() }
            guard case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint else { return }
            let hostString: String
            switch host {
            case .name(let value, _): hostString = value
            case .ipv4(let address): hostString = "\(address)"
            case .ipv6(let address): hostString = "\(address)"
            @unknown default: return
            }
            self.queue.async {
                guard var entry = self.discovered[name] else { return }
                entry.host = hostString
                entry.port = port.rawValue
                self.discovered[name] = entry
                self.resolvers.removeValue(forKey: name)
                self.publish(.found(Array(self.discovered.values)))
            }
        }
        connection.start(queue: queue)
    }

    private func publish(_ state: State) {
        let handler = onUpdate
        DispatchQueue.main.async { handler?(state) }
    }
}

/// Errors surfaced to the user. The spec requires clear "Mac Not Found" / "Disconnected" handling.
public enum PianoClientError: LocalizedError {
    case noMacFound
    case notConnected
    case badResponse(Int)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .noMacFound: return "Mac Not Found"
        case .notConnected: return "Disconnected"
        case .badResponse(let status): return "The Mac returned HTTP \(status)"
        case .transport(let message): return message
        case .decoding(let message): return "Unexpected response: \(message)"
        }
    }
}

/// Read-only HTTP client for the Mac's JSON API.
///
/// Only `GET` is implemented, which is the client-side half of the read-only guarantee.
public final class PianoAPIClient: @unchecked Sendable {

    private let session: URLSession
    private let token: String?

    public init(token: String? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        // Short timeouts: a stale Mac should surface as "Disconnected" quickly rather than hanging
        // the UI.
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.token = token
    }

    private func makeURL(_ base: URL, _ path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = query
        if let token, !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    private func get<T: Decodable>(_ type: T.Type, from base: URL, path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let url = makeURL(base, path, query: query) else {
            throw PianoClientError.transport("Could not build a request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-PianoMonitor-Token")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PianoClientError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PianoClientError.transport("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PianoClientError.badResponse(http.statusCode)
        }
        do {
            return try APICoding.makeDecoder().decode(type, from: data)
        } catch {
            throw PianoClientError.decoding(error.localizedDescription)
        }
    }

    public func status(from base: URL) async throws -> APIStatusResponse {
        try await get(APIStatusResponse.self, from: base, path: "api/status")
    }

    public func sessions(from base: URL, limit: Int = 200) async throws -> APISessionsResponse {
        try await get(APISessionsResponse.self, from: base, path: "api/sessions", query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    public func statistics(from base: URL, period: StatisticsPeriod) async throws -> APIStatisticsResponse {
        try await get(APIStatisticsResponse.self, from: base, path: "api/statistics", query: [
            URLQueryItem(name: "period", value: period.rawValue),
        ])
    }

    public func tempo(from base: URL, limit: Int = 20) async throws -> APITempoResponse {
        try await get(APITempoResponse.self, from: base, path: "api/tempo", query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }
}
