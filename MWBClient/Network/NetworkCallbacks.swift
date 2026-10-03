import Foundation

typealias MouseCallback = @Sendable (MouseData) -> Void
typealias KeyboardCallback = @Sendable (KeyboardData) -> Void
typealias ClipboardCallback = @Sendable (MWBPacket) -> Void

/// Machine-level events (machine switching, drag & drop choreography,
/// cursor visibility) routed to the coordinator for orchestration.
typealias MachineEventCallback = @Sendable (MWBPacket) -> Void
