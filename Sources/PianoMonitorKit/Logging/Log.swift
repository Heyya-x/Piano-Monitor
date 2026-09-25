import Foundation
import OSLog

/// A log payload that carries its own privacy annotation.
///
/// Why this exists: `os.Logger` (with its `"\(value, privacy: .public)"` interpolation) requires
/// macOS 11, but PianoMonitor ships to Catalina. `OSLog`/`os_log` itself goes back to 10.12, so
/// the facade below wraps it and keeps structured, privacy-annotated logging available on every
/// supported OS.
///
/// Usage mirrors the modern API so call sites stay readable:
/// ```swift
/// Log.audio.notice("started in=\(inputDevice.name, privacy: .public) rate=\(rate)")
/// ```
public struct LogValue: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, CustomStringConvertible {
    public let text: String
    public let isPublic: Bool

    public var description: String { text }

    public enum Privacy: Sendable {
        case `public`
        case `private`
    }

    /// Unannotated values are private, matching Apple's default recommendation.
    public init(stringLiteral value: String) {
        self.text = value
        self.isPublic = false
    }

    public init(_ text: String, _ privacy: Privacy = .private) {
        self.text = text
        self.isPublic = privacy == .public
    }

    public init(stringInterpolation: StringInterpolation) {
        self.text = stringInterpolation.output
        self.isPublic = stringInterpolation.isPublic
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        public var output = ""
        /// A message is public only when *every* interpolated value asked to be public.
        /// This fails closed: forgetting an annotation cannot leak content.
        public var isPublic = true

        public init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        public mutating func appendLiteral(_ literal: String) {
            output += literal
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> String) {
            output += value()
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Int) {
            output += String(value())
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Double) {
            output += String(value())
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Float) {
            output += String(value())
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(_ value: @autoclosure () -> T) {
            output += value().description
        }

        public mutating func appendInterpolation<T: CustomStringConvertible>(
            _ value: @autoclosure () -> T,
            privacy: Privacy
        ) {
            output += value().description
            if privacy == .private { isPublic = false }
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> String, privacy: Privacy) {
            output += value()
            if privacy == .private { isPublic = false }
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Int, privacy: Privacy) {
            output += String(value())
            if privacy == .private { isPublic = false }
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Double, privacy: Privacy) {
            output += String(value())
            if privacy == .private { isPublic = false }
        }

        public mutating func appendInterpolation(_ value: @autoclosure () -> Float, privacy: Privacy) {
            output += String(value())
            if privacy == .private { isPublic = false }
        }
    }
}

/// A category-scoped logger. Thin wrapper over `OSLog` so `log stream --predicate` filtering
/// works: `subsystem == "com.pianomonitor.app" && category == "Audio"`.
public struct LogChannel: Sendable {
    private let log: OSLog

    public init(subsystem: String, category: String) {
        self.log = OSLog(subsystem: subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> LogValue) {
        emit(type: .debug, message())
    }

    public func info(_ message: @autoclosure () -> LogValue) {
        emit(type: .info, message())
    }

    public func notice(_ message: @autoclosure () -> LogValue) {
        emit(type: .default, message())
    }

    public func error(_ message: @autoclosure () -> LogValue) {
        emit(type: .error, message())
    }

    public func fault(_ message: @autoclosure () -> LogValue) {
        emit(type: .fault, message())
    }

    private func emit(type: OSLogType, _ value: LogValue) {
        // `os_log` accepts a Swift String for `%{public}@` / `%{private}@`, so the privacy
        // decision stays at runtime without giving up unified-log masking.
        if value.isPublic {
            os_log("%{public}@", log: log, type: type, value.text)
        } else {
            os_log("%{private}@", log: log, type: type, value.text)
        }
    }
}

/// Central logging facade.
///
/// Design goals:
/// - Separate categories so `log stream` predicates can filter precisely.
/// - **Silent by default.** PianoMonitor runs for days in the background and must not spam the
///   unified log. Per-buffer logging is behind `Log.isVerbose`.
/// - Verbose can be toggled from Settings or at launch with `PIANOMONITOR_VERBOSE=1`.
public enum Log {
    public static let subsystem = "com.pianomonitor.app"

    public static let audio = LogChannel(subsystem: subsystem, category: "Audio")
    public static let analyzer = LogChannel(subsystem: subsystem, category: "Analyzer")
    public static let session = LogChannel(subsystem: subsystem, category: "Session")
    public static let network = LogChannel(subsystem: subsystem, category: "Network")
    public static let store = LogChannel(subsystem: subsystem, category: "Store")
    public static let ui = LogChannel(subsystem: subsystem, category: "UI")

    /// Guards high-frequency diagnostics (per-buffer RMS, noise floor, detector state).
    /// Never leave this on for long: it costs power and floods the log.
    public nonisolated(unsafe) static var isVerbose = ProcessInfo.processInfo.environment["PIANOMONITOR_VERBOSE"] == "1"

    /// Verbose-only log line. The autoclosure means the message is not even built unless enabled.
    @inline(__always)
    public static func verbose(_ channel: LogChannel, _ message: @autoclosure () -> LogValue) {
        guard isVerbose else { return }
        channel.debug(message())
    }
}

/// Named filter targets, handy in the Settings UI and in log-stream documentation.
public enum LogCategory: String, CaseIterable, Sendable {
    case all
    case audio
    case analyzer
    case session
    case network
    case store
    case ui

    public var channel: LogChannel {
        switch self {
        case .all, .ui: return Log.ui
        case .audio: return Log.audio
        case .analyzer: return Log.analyzer
        case .session: return Log.session
        case .network: return Log.network
        case .store: return Log.store
        }
    }

    /// Ready-to-paste `log stream` predicate for this category.
    public var streamPredicate: String {
        self == .all
            ? "subsystem == \"\(Log.subsystem)\""
            : "subsystem == \"\(Log.subsystem)\" && category == \"\(rawValue.capitalized)\""
    }
}
