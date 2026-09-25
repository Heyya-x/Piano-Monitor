import Network
import XCTest
@testable import PianoMonitorKit

/// End-to-end tests against a real HTTP listener on a loopback port.
///
/// These verify the properties the spec cares about for the network layer: the documented JSON
/// shapes actually come out, the API is strictly read-only, and a bind failure never takes the app
/// down.
final class APIServerTests: XCTestCase {

    private var directory: URL!
    private var store: JSONDataStore!
    private var server: PianoAPIServer!
    private var port: UInt16!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PianoMonitorAPI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = JSONDataStore(directory: directory)
        await store.load()

        // Seed one session: 20:31–21:13 with 42m17s of actual playing.
        let start = Date(timeIntervalSince1970: 1_758_313_882) // 2025-09-19T20:31:22Z
        let sessionID = UUID()
        let segmentID = UUID()
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionOpened(sessionID: sessionID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentOpened(sessionID: sessionID, segmentID: segmentID, at: start)))
        _ = try await store.recordActivity(ActivityRecord(kind: .segmentClosed(
            sessionID: sessionID, segmentID: segmentID,
            at: start.addingTimeInterval(2_537), confidence: 0.85
        )))
        _ = try await store.recordActivity(ActivityRecord(kind: .sessionClosed(sessionID: sessionID, at: start.addingTimeInterval(2_537))))

        server = PianoAPIServer(store: store)
        server.statusProvider = PianoAPIServer.StatusProvider {
            APIStatusResponse(
                isPlaying: true,
                state: "playing",
                todayActiveDuration: 5_547,
                todaySessionCount: 1,
                currentSession: CurrentSessionResponse(start: start, activeDuration: 1_200, duration: 1_300),
                inputDevice: "TOP1",
                outputDeviceName: "MacBook Speakers",
                audioState: "Running",
                sampleRate: 44_100,
                server: .pianoMonitor
            )
        }
        server.tempoProvider = { nil }
        _ = try server.start(preferredPort: nil, token: nil)

        // NWListener reports the system-assigned port asynchronously; wait briefly for it.
        let deadline = Date().addingTimeInterval(3)
        while server.port == nil || server.port == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        port = try XCTUnwrap(server.port, "server did not report a port")
        XCTAssertNotEqual(port, 0)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func get(_ path: String) async throws -> (status: Int, body: Data) {
        let url = URL(string: "http://127.0.0.1:\(port!)\(path)")!
        let (data, response) = try await session.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try APICoding.makeDecoder().decode(type, from: data)
    }

    // MARK: - Tests

    func testStatusEndpointReturnsTheDocumentedShape() async throws {
        let (status, body) = try await get("/api/status")
        XCTAssertEqual(status, 200)
        let payload = try decode(APIStatusResponse.self, from: body)
        XCTAssertTrue(payload.isPlaying)
        XCTAssertEqual(payload.state, "playing")
        XCTAssertEqual(payload.todayActiveDuration, 5_547)
        XCTAssertEqual(payload.inputDevice, "TOP1")
        XCTAssertNotNil(payload.currentSession)
        XCTAssertEqual(payload.server.version, APIConstants.apiVersion)
    }

    func testSessionsEndpointReturnsSessionsWithSegments() async throws {
        let (status, body) = try await get("/api/sessions")
        XCTAssertEqual(status, 200)
        let payload = try decode(APISessionsResponse.self, from: body)
        XCTAssertEqual(payload.count, 1)
        let session = try XCTUnwrap(payload.sessions.first)
        XCTAssertEqual(session.activeDuration, 2_537, accuracy: 0.01)
        XCTAssertEqual(session.segments.count, 1)
        XCTAssertEqual(session.segments.first?.duration ?? 0, 2_537, accuracy: 0.01)
    }

    func testSessionsEndpointHonoursDateRange() async throws {
        // A range that excludes the seeded session must return nothing.
        let (_, body) = try await get("/api/sessions?from=2026-01-01T00:00:00Z")
        let payload = try decode(APISessionsResponse.self, from: body)
        XCTAssertEqual(payload.count, 0)

        // A range that includes it must return it.
        let (_, included) = try await get("/api/sessions?from=2025-01-01T00:00:00Z&to=2025-12-31T00:00:00Z")
        let includedPayload = try decode(APISessionsResponse.self, from: included)
        XCTAssertEqual(includedPayload.count, 1)
    }

    func testStatisticsEndpointReturnsAggregatesAndDailyBreakdown() async throws {
        let (status, body) = try await get("/api/statistics?period=all")
        XCTAssertEqual(status, 200)
        let payload = try decode(APIStatisticsResponse.self, from: body)
        XCTAssertEqual(payload.period, "all")
        XCTAssertEqual(payload.statistics.totalActiveDuration, 2_537, accuracy: 0.01)
        XCTAssertEqual(payload.statistics.sessionCount, 1)
        XCTAssertFalse(payload.days.isEmpty, "the chart needs a per-day breakdown")
    }

    func testStatisticsRejectsUnknownPeriod() async throws {
        let (status, body) = try await get("/api/statistics?period=fortnight")
        XCTAssertEqual(status, 400)
        let error = try decode(APIErrorResponse.self, from: body)
        XCTAssertEqual(error.error, "bad_period")
    }

    func testTempoEndpointReturnsHistory() async throws {
        let (status, body) = try await get("/api/tempo")
        XCTAssertEqual(status, 200)
        let payload = try decode(APITempoResponse.self, from: body)
        XCTAssertTrue(payload.history.isEmpty)
        XCTAssertNil(payload.live, "no analyzer running should mean no live measurement, not an error")
    }

    func testIndexListsEndpoints() async throws {
        let (status, body) = try await get("/")
        XCTAssertEqual(status, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["readOnly"] as? Bool, true)
        XCTAssertEqual(json["bonjourService"] as? String, APIConstants.bonjourServiceType)
    }

    func testUnknownEndpointReturns404() async throws {
        let (status, body) = try await get("/api/does-not-exist")
        XCTAssertEqual(status, 404)
        let error = try decode(APIErrorResponse.self, from: body)
        XCTAssertEqual(error.error, "not_found")
    }

    /// The API must be read-only: no verb other than GET may be routed to anything.
    func testWriteMethodsAreRejected() async throws {
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/api/status")!)
            request.httpMethod = method
            request.httpBody = Data(#"{"evil":true}"#.utf8)
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 405, "\(method) must be rejected")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Allow"), "GET")
            let error = try decode(APIErrorResponse.self, from: data)
            XCTAssertEqual(error.error, "read_only")
        }
    }

    /// The configured port must never be fatal.
    ///
    /// This is not hypothetical: port 8787 (the configured default) was already in use by unrelated
    /// software on the development machine, which is how the failure mode was found. Whatever
    /// happens to the preferred port, `start` must return a port the API actually answers on.
    func testStartAlwaysYieldsAWorkingPort() async throws {
        let squatterPort: UInt16 = 45_678
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let squatterPortValue = NWEndpoint.Port(rawValue: squatterPort),
              let squatter = try? NWListener(using: parameters, on: squatterPortValue) else {
            throw XCTSkip("could not occupy the test port")
        }
        squatter.start(queue: .global(qos: .utility))
        defer { squatter.cancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PianoMonitorPort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONDataStore(directory: directory)
        await store.load()

        let server = PianoAPIServer(store: store)
        server.statusProvider = PianoAPIServer.StatusProvider { .disconnected }
        defer { server.stop() }

        // Request the port that is already in use. Either the kernel lets us share it (SO_REUSEADDR)
        // or we fall back — both are fine; what is not fine is reporting a port that does not work.
        let assigned = try server.start(preferredPort: Int(squatterPort), token: nil)
        XCTAssertNotEqual(assigned, 0, "start must always report a usable port")
        XCTAssertEqual(server.port, assigned, "the published diagnostics must agree with the return value")

        let url = URL(string: "http://127.0.0.1:\(assigned)/api/status")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "the API must answer on the reported port")
        XCTAssertFalse(data.isEmpty)
    }

    func testMalformedRequestDoesNotCrashServer() async throws {
        // Speak garbage at the port, then confirm the server still answers correctly.
        let connection = try makeRawConnection()
        connection.write(Data("not-http-at-all\r\n\r\n".utf8))
        connection.close()

        let (status, _) = try await get("/api/status")
        XCTAssertEqual(status, 200, "the server must survive a malformed request")
    }

    private func makeRawConnection() throws -> RawConnection {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, "127.0.0.1" as CFString, UInt32(port), &readStream, &writeStream)
        let output = try XCTUnwrap(writeStream?.takeRetainedValue())
        CFWriteStreamOpen(output)
        return RawConnection(stream: output)
    }

    struct RawConnection {
        let stream: CFWriteStream
        func write(_ data: Data) {
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                CFWriteStreamWrite(stream, base, CFIndex(data.count))
            }
        }
        func close() {
            CFWriteStreamClose(stream)
        }
    }
}

/// Authentication is opt-in; when a token is configured every request must present it.
final class APIServerAuthTests: XCTestCase {

    private var directory: URL!
    private var server: PianoAPIServer!
    private var port: UInt16!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PianoMonitorAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = JSONDataStore(directory: directory)
        await store.load()
        server = PianoAPIServer(store: store)
        server.statusProvider = PianoAPIServer.StatusProvider { .disconnected }
        _ = try server.start(preferredPort: nil, token: "s3cret")
        let deadline = Date().addingTimeInterval(3)
        while server.port == nil || server.port == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        port = try XCTUnwrap(server.port)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testRequestsWithoutTokenAreUnauthorized() async throws {
        let url = URL(string: "http://127.0.0.1:\(port!)/api/status")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 401)
        let error = try APICoding.makeDecoder().decode(APIErrorResponse.self, from: data)
        XCTAssertEqual(error.error, "unauthorized")
    }

    func testRequestsWithTokenSucceed() async throws {
        let url = URL(string: "http://127.0.0.1:\(port!)/api/status?token=s3cret")!
        let (_, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
    }

    func testTokenCanBeSuppliedAsAHeader() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/api/status")!)
        request.setValue("s3cret", forHTTPHeaderField: "X-PianoMonitor-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
    }
}
