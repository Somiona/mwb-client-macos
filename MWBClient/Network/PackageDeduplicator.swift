import Foundation

/// Circular buffer of recently seen packet IDs for duplicate detection.
/// Matches PowerToys Receiver.cs dedup behavior with a 50-entry window.
///
/// PowerToys keeps both a client (outbound) and a server (inbound) socket per
/// machine pair and sends input on every connected socket to the target, so
/// the same packet routinely arrives through more than one session. The dedup
/// window must therefore be shared across all sessions — use `shared`.
final class PackageDeduplicator: @unchecked Sendable {
    // All mutable state is guarded by `lock`, hence @unchecked Sendable.
    private let lock = NSLock()
    private var seenIDs: [UInt32] = []
    private var seenSet: Set<UInt32> = []
    private var index: Int = 0
    private static let capacity = 50

    static let shared = PackageDeduplicator()

    /// Returns true if the ID was already seen (duplicate).
    /// If new, inserts it into the buffer and returns false.
    func isDuplicate(_ id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if seenSet.contains(id) {
            return true
        }
        if seenIDs.count < Self.capacity {
            seenIDs.append(id)
        } else {
            let evicted = seenIDs[index]
            seenSet.remove(evicted)
            seenIDs[index] = id
            index = (index + 1) % Self.capacity
        }
        seenSet.insert(id)
        return false
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        seenIDs.removeAll()
        seenSet.removeAll()
        index = 0
    }
}
