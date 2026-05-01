import Foundation
import os.log


// MARK: - Logger categories

extension Logger {
    static let network   = Logger(subsystem: "com.mwb.client", category: "Network")
    static let input     = Logger(subsystem: "com.mwb.client", category: "Input")
    static let clipboard = Logger(subsystem: "com.mwb.client", category: "Clipboard")
    static let coordinator = Logger(subsystem: "com.mwb.client", category: "Coordinator")
    static let crypto    = Logger(subsystem: "com.mwb.client", category: "Crypto")
}

// MARK: - Runtime debug-log gate

/// Emits a debug-level os_log message **only when Debug Logging is enabled** in Settings.
///
/// Call this in place of `Logger.<category>.debug(…)` everywhere in the codebase.
/// Because `SettingsStore` is `@MainActor`, we read the UserDefaults backing store
/// directly so this function is safe to call from any actor context without `await`.
///
/// - Parameters:
///   - logger: The category logger (e.g. `Logger.network`).
///   - message: Autoclosure producing the log string (not evaluated when logging is off).
@inlinable
func mwbDebug(_ logger: Logger, _ message: @autoclosure () -> String) {
    guard UserDefaults.standard.bool(forKey: "settings.debugLogging") else { return }
    let msg = message()
    logger.debug("\(msg, privacy: .public)")
}
