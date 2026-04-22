/// Reference-type flag for guarding against double-continuation-resume in async callbacks.
/// NWConnection.stateUpdateHandler fires multiple times as the state machine transitions,
/// so we need a flag to ensure the continuation is resumed only once.
final class ResumeOnce: @unchecked Sendable {
    private var _fired = false
    var fired: Bool {
        get { _fired }
        set { _fired = newValue }
    }
}
