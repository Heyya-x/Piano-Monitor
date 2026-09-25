import Foundation

/// A parsed HTTP request. Minimal on purpose: the API is read-only, so there is no body handling to
/// get wrong.
public struct HTTPRequest: Sendable {
    public let method: String
    /// Path without the query string, e.g. `/api/status`.
    public let path: String
    public let query: [String: String]
    public let httpVersion: String
    public let headers: [String: String]

    /// Parses the request head. Returns `nil` when the bytes are not a well-formed HTTP request,
    /// which the server answers with 400 rather than crashing.
    public init?(data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        // Requests are header-only for GET; tolerate a body by ignoring everything after the headers.
        let head = text.components(separatedBy: "\r\n\r\n").first ?? text
        let lines = head.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        self.method = String(parts[0]).uppercased()
        let target = String(parts[1])
        self.httpVersion = parts.count > 2 ? String(parts[2]) : "HTTP/1.1"

        if let questionMark = target.firstIndex(of: "?") {
            self.path = String(target[target.startIndex..<questionMark])
            self.query = Self.parseQuery(String(target[target.index(after: questionMark)...]))
        } else {
            self.path = target
            self.query = [:]
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        self.headers = headers
    }

    private static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            result[String(name).removingPercentEncoding ?? String(name)] =
                value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return result
    }

    /// Parses an ISO-8601 date query parameter, e.g. `?from=2026-09-19T00:00:00Z`.
    public func date(_ key: String) -> Date? {
        guard let raw = query[key], !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        // Tolerate a plain `yyyy-MM-dd` too — much easier to type by hand.
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: raw)
    }

    public func int(_ key: String) -> Int? {
        guard let raw = query[key] else { return nil }
        return Int(raw)
    }
}

/// A minimal HTTP response.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var contentType: String
    public var body: Data
    public var additionalHeaders: [String: String]

    public init(
        status: Int,
        reason: String,
        contentType: String = "application/json; charset=utf-8",
        body: Data = Data(),
        additionalHeaders: [String: String] = [:]
    ) {
        self.status = status
        self.reason = reason
        self.contentType = contentType
        self.body = body
        self.additionalHeaders = additionalHeaders
    }

    /// Serialises the head and body. `Content-Length` and `Connection: close` are always set:
    /// closing per request keeps the server stateless and trivially robust.
    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-PianoMonitor-Version: \(APIConstants.apiVersion)\r\n"
        for (name, value) in additionalHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func json(status: Int = 200, reason: String = "OK", body: Data) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, body: body)
    }

    public static func error(status: Int, reason: String, code: String, message: String) -> HTTPResponse {
        let payload = APIErrorResponse(error: code, message: message)
        let data = (try? APICoding.makeEncoder().encode(payload)) ?? Data(#"{"error":"internal"}"#.utf8)
        return HTTPResponse(status: status, reason: reason, body: data)
    }
}
