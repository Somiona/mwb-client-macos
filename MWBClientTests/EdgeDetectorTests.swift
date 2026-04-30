import XCTest
import CoreGraphics
@testable import MWBClient

@MainActor
final class EdgeDetectorTests: XCTestCase {
    
    var detector: EdgeDetector!
    let mockBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    
    override func setUp() {
        super.setUp()
        detector = EdgeDetector()
    }
    
    func testCornerBlocking() {
        detector.screenBoundsProvider = { self.mockBounds }
        // Update detector with a dummy position to refresh displayBounds
        detector.updateCursorPosition(MouseData(), screenPoint: .zero)
        
        detector.cornerBlockMargin = 100.0
        
        // Top-left corner (0,0) -> blocked
        XCTAssertTrue(detector.isInCornerZone(CGPoint(x: 5, y: 5)))
        
        // Near top edge but not corner (200, 5) -> not blocked
        XCTAssertFalse(detector.isInCornerZone(CGPoint(x: 200, y: 5)))
        
        // Bottom-right corner (1915, 1075) -> blocked
        XCTAssertTrue(detector.isInCornerZone(CGPoint(x: 1915, y: 1075)))
        
        // Just outside corner (105, 105) -> not blocked
        XCTAssertFalse(detector.isInCornerZone(CGPoint(x: 105, y: 105)))
    }
    
    func testEdgeDetection() {
        detector.screenBoundsProvider = { self.mockBounds }
        detector.crossingEdge = .right
        detector.threshold = 2.0
        detector.updateCursorPosition(MouseData(), screenPoint: CGPoint(x: 1000, y: 500))
        
        // Not at edge
        XCTAssertFalse(detector.isAtEdge(CGPoint(x: 1000, y: 500)))
        
        // At right edge
        XCTAssertTrue(detector.isAtEdge(CGPoint(x: 1919, y: 500)))
        
        // Change edge to left
        detector.crossingEdge = .left
        XCTAssertTrue(detector.isAtEdge(CGPoint(x: 1, y: 500)))
    }
    
    func testDebounceLogic() {
        detector.screenBoundsProvider = { self.mockBounds }
        detector.crossingEdge = .right
        detector.debounceInterval = 0.05
        
        let expectation = self.expectation(description: "Crossing triggered")
        detector.crossingStart = { _ in
            expectation.fulfill()
        }
        
        // Move to edge
        detector.updateCursorPosition(MouseData(), screenPoint: CGPoint(x: 1919, y: 500))
        
        waitForExpectations(timeout: 0.2)
    }
}
