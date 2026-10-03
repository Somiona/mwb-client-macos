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

/// Thread-safe dedup store shared by every receive path (``NetworkManager``
/// and ``ServerListener``).
///
/// PowerToys sends each packet over *all* connected sockets to the
/// destination machine (`Common.SkSend` iterates `TcpSockets`), so the same
/// packet ID can arrive over different connections — one accepted by
/// NetworkManager (the Mac's outbound connection) and one accepted by
/// ServerListener (Windows' inbound client connection). Windows dedups in a
/// single global `Receiver` window; the Mac must do the same or every input
/// event is dispatched (and injected) twice.
final class SharedPackageDeduplicator: @unchecked Sendable {
    /// Packet types that may legitimately repeat with the same ID
    /// (per PowerToys Receiver.cs).
    private static let exemptFromDedup: Set<PackageType> = [
        .handshake, .handshakeAck, .clipboardText, .clipboardImage,
    ]

    private let lock = NSLock()
    private var dedup = PackageDeduplicator()

    /// Returns true if this type/id was already seen (duplicate delivery).
    func isDuplicate(type: PackageType, id: UInt32) -> Bool {
        if Self.exemptFromDedup.contains(type) { return false }
        return lock.withLock { dedup.isDuplicate(id) }
    }

    func reset() {
        lock.withLock { dedup.reset() }
    }
}
