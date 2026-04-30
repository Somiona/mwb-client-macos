import XCTest
import CoreGraphics
@testable import MWBClient

@MainActor
final class CoordinateMappingTests: XCTestCase {

    var injection: InputInjection!

    override func setUp() {
        super.setUp()
        injection = InputInjection()
    }

    func testMapVirtualToScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        injection.screenBoundsProvider = { bounds }
        
        // 0, 0 -> 0, 0
        let p1 = injection.mapVirtualToScreen(x: 0, y: 0)
        XCTAssertEqual(p1.x, 0)
        XCTAssertEqual(p1.y, 0)
        
        // 65535, 65535 -> 1000, 1000
        let p2 = injection.mapVirtualToScreen(x: 65535, y: 65535)
        XCTAssertEqual(p2.x, 1000)
        XCTAssertEqual(p2.y, 1000)
        
        // Middle
        let p3 = injection.mapVirtualToScreen(x: 32767, y: 32767)
        XCTAssertEqual(p3.x, 32767.0 / 65535.0 * 1000.0, accuracy: 0.1)
        XCTAssertEqual(p3.y, 32767.0 / 65535.0 * 1000.0, accuracy: 0.1)
    }
    
    func testRelativeMoveExtractionMath() {
        let threshold: Int32 = 100_000
        
        func extract(_ val: Int32) -> Int32 {
            return val >= 0 ? val - threshold : val + threshold
        }
        
        XCTAssertEqual(extract(100005), 5)
        XCTAssertEqual(extract(-100005), -5)
        XCTAssertEqual(extract(100000), 0)
        XCTAssertEqual(extract(-100000), 0)
    }
}
