import Foundation

/// Circular buffer of recently seen packet IDs for duplicate detection.
/// Matches PowerToys Receiver.cs dedup behavior with a 50-entry window.
struct PackageDeduplicator {
    private var seenIDs: [UInt32] = []
    private var seenSet: Set<UInt32> = []
    private var index: Int = 0
    private static let capacity = 50

    /// Returns true if the ID was already seen (duplicate).
    /// If new, inserts it into the buffer and returns false.
    mutating func isDuplicate(_ id: UInt32) -> Bool {
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

    mutating func reset() {
        seenIDs.removeAll()
        seenSet.removeAll()
        index = 0
    }
}
