import XCTest
@testable import NativeMonitor

final class SensorTests: XCTestCase {
    func testDecodeSensorValues() {
        XCTAssertEqual(SensorReader.decode([0x2a, 0x80], type: "sp78"), 42.5)
        XCTAssertEqual(SensorReader.decode([0xff, 0x00], type: "sp78"), -1)
        XCTAssertEqual(SensorReader.decode([0x1f, 0x40], type: "fpe2"), 2000)
        XCTAssertEqual(SensorReader.decode([0, 0, 0x48, 0x42], type: "flt "), 50)
        XCTAssertNil(SensorReader.decode([0, 0, 0xc0, 0x7f], type: "flt "))
        XCTAssertNil(SensorReader.decode([0], type: "sp78"))
    }
}
