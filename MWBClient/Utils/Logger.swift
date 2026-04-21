import os.log

extension Logger {
    static let network = Logger(subsystem: "com.mwb.client", category: "Network")
    static let input = Logger(subsystem: "com.mwb.client", category: "Input")
    static let clipboard = Logger(subsystem: "com.mwb.client", category: "Clipboard")
    static let coordinator = Logger(subsystem: "com.mwb.client", category: "Coordinator")
    static let crypto = Logger(subsystem: "com.mwb.client", category: "Crypto")
}
