import XCTest
@testable import MWBClient

final class InputLayerTests: XCTestCase {
    func testMouseRelativeOffsetDecoding() {
        let threshold: Int32 = 100_000
        
        func extract(_ val: Int32) -> Int32 {
            return val >= 0 ? val - threshold : val + threshold
        }
        
        XCTAssertEqual(extract(100005), 5)
        XCTAssertEqual(extract(-99995), 5)
        XCTAssertEqual(extract(100000), 0)
        XCTAssertEqual(extract(-100000), 0)
    }
    
    func testAbsoluteCoordinateScaling() {
        let injection = InputInjection()
        injection.screenBoundsProvider = { CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        
        let p = injection.mapVirtualToScreen(x: 32767, y: 32767)
        XCTAssertEqual(p.x, 960, accuracy: 1.0, "Absolute coordinates must be scaled from 65535 space.")
    }
}
