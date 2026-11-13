import XCTest
@testable import NativeMonitor

final class ANEPowerTests: XCTestCase {
    func testPublishedEnergyUsesPublicationIntervalAndRejectsStaleSamples() throws {
        var window = ANEPowerWindow()
        XCTAssertNil(window.update(energy: 1_000, time: 100, now: 100, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 1_000, time: 100, now: 101, joulesPerUnit: 0.001))
        XCTAssertEqual(try XCTUnwrap(window.update(energy: 2_500, time: 102, now: 102.2, joulesPerUnit: 0.001)), 0.75, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(window.update(energy: 2_500, time: 102, now: 103, joulesPerUnit: 0.001)), 0.75, accuracy: 0.0001)
        XCTAssertNil(window.update(energy: 2_500, time: 102, now: 113, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 3_000, time: 114, now: 114, joulesPerUnit: 0.001))
        XCTAssertEqual(try XCTUnwrap(window.update(energy: 3_000, time: 116, now: 116, joulesPerUnit: 0.001)), 0)
    }

    func testCounterResetAndShortPublicationDoNotCreateSpikes() throws {
        var window = ANEPowerWindow()
        XCTAssertNil(window.update(energy: 1_000, time: 100, now: 100, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 1_010, time: 100.01, now: 100.01, joulesPerUnit: 0.001))
        XCTAssertEqual(try XCTUnwrap(window.update(energy: 2_000, time: 102, now: 102, joulesPerUnit: 0.001)), 0.5, accuracy: 0.0001)
        XCTAssertNil(window.update(energy: 5, time: 104, now: 104, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 6, time: 104, now: 105, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 7, time: 200, now: 190, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 7, time: 201, now: 201, joulesPerUnit: 0.001))
        XCTAssertNil(window.update(energy: 8, time: 202, now: 202, joulesPerUnit: 0.000001))
    }
}
