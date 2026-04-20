import Foundation

typealias MouseCallback = @Sendable (MouseData) -> Void
typealias KeyboardCallback = @Sendable (KeyboardData) -> Void
typealias ClipboardCallback = @Sendable (MWBPacket) -> Void
