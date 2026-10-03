import XCTest
@testable import MWBClient

/// Verifies ``SharedPackageDeduplicator``: one dedup window across all
/// receive paths. PowerToys `Common.SkSend` writes every packet to all
/// connected sockets of the destination machine, so the same packet ID can
/// arrive once via NetworkManager (Mac's outbound connection) and once via
/// ServerListener (Windows' inbound client connection). Without a shared
/// window every input event is dispatched — and injected — twice.
final class SharedPackageDeduplicatorTests: XCTestCase {

    func testCrossPathDuplicateIsDropped() {
        let store = SharedPackageDeduplicator()

        // First delivery (e.g. via NetworkManager).
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 42))
        // Same packet delivered again via ServerListener.
        XCTAssertTrue(store.isDuplicate(type: .mouse, id: 42))
    }

    func testKeyboardDuplicatesDroppedAcrossPaths() {
        let store = SharedPackageDeduplicator()
        XCTAssertFalse(store.isDuplicate(type: .keyboard, id: 1000))
        XCTAssertTrue(store.isDuplicate(type: .keyboard, id: 1000))
    }

    func testDistinctIdsAreNotDuplicates() {
        let store = SharedPackageDeduplicator()
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 1))
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 2))
        XCTAssertTrue(store.isDuplicate(type: .mouse, id: 1))
    }

    func testExemptTypesAreNeverDroppedAndDoNotPoisonTheWindow() {
        let store = SharedPackageDeduplicator()

        // Handshake packets legitimately repeat with the same ID.
        XCTAssertFalse(store.isDuplicate(type: .handshake, id: 7))
        XCTAssertFalse(store.isDuplicate(type: .handshake, id: 7))
        XCTAssertFalse(store.isDuplicate(type: .handshakeAck, id: 7))

        // Exempt deliveries must not mark the ID as seen for other types.
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 7))
    }

    func testResetClearsTheWindow() {
        let store = SharedPackageDeduplicator()
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 5))
        store.reset()
        XCTAssertFalse(store.isDuplicate(type: .mouse, id: 5))
    }
}
