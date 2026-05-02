import Foundation
import os.log

// MARK: - Categorized Logger

struct MWBLog: Sendable {
    let logger: Logger
    let category: String
}

extension MWBLog {
    static let network    = MWBLog(logger: Logger(subsystem: "com.mwb.client", category: "Network"), category: "Network")
    static let input      = MWBLog(logger: Logger(subsystem: "com.mwb.client", category: "Input"), category: "Input")
    static let clipboard  = MWBLog(logger: Logger(subsystem: "com.mwb.client", category: "Clipboard"), category: "Clipboard")
    static let coordinator = MWBLog(logger: Logger(subsystem: "com.mwb.client", category: "Coordinator"), category: "Coordinator")
    static let crypto     = MWBLog(logger: Logger(subsystem: "com.mwb.client", category: "Crypto"), category: "Crypto")
}

// MARK: - Log Entry Model

enum LogLevel: String, Sendable {
    case debug
    case info
    case warning
    case error
}

struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let level: LogLevel
    let message: String
}

// MARK: - In-Memory Log Store

@MainActor
@Observable
final class InMemoryLogStore {
    static let shared = InMemoryLogStore()

    private static let maxEntries = 500

    private(set) var entries: [LogEntry] = []

    private init() {}

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

// MARK: - Wrapper logging functions

func mwbDebug(_ log: MWBLog, _ message: @autoclosure () -> String) {
    guard CachedSettings.debugLogging else { return }
    let msg = message()
    log.logger.debug("\(msg, privacy: .public)")
    Task { @MainActor in
        InMemoryLogStore.shared.append(LogEntry(
            timestamp: Date(),
            category: log.category,
            level: .debug,
            message: msg
        ))
    }
}

func mwbInfo(_ log: MWBLog, _ message: @autoclosure () -> String) {
    let msg = message()
    log.logger.info("\(msg, privacy: .public)")
    Task { @MainActor in
        InMemoryLogStore.shared.append(LogEntry(
            timestamp: Date(),
            category: log.category,
            level: .info,
            message: msg
        ))
    }
}

func mwbWarning(_ log: MWBLog, _ message: @autoclosure () -> String) {
    let msg = message()
    log.logger.warning("\(msg, privacy: .public)")
    Task { @MainActor in
        InMemoryLogStore.shared.append(LogEntry(
            timestamp: Date(),
            category: log.category,
            level: .warning,
            message: msg
        ))
    }
}

func mwbError(_ log: MWBLog, _ message: @autoclosure () -> String) {
    let msg = message()
    log.logger.error("\(msg, privacy: .public)")
    Task { @MainActor in
        InMemoryLogStore.shared.append(LogEntry(
            timestamp: Date(),
            category: log.category,
            level: .error,
            message: msg
        ))
    }
}
