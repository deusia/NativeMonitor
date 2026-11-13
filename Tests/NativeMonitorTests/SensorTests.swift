import XCTest
@testable import NativeMonitor

final class SensorTests: XCTestCase {
    func testM5TemperatureMappingAndAverage() {
        let readings = [
            SensorReading(id: "Tp00", value: 40, unit: "°C"),
            SensorReading(id: "Tp0O", value: 60, unit: "°C"),
            SensorReading(id: "Tp04", value: 0, unit: "°C"),
            SensorReading(id: "Tp08", value: 111, unit: "°C"),
            SensorReading(id: "Tg0U", value: 70, unit: "°C"),
            SensorReading(id: "Tp99", value: 100, unit: "°C")
        ]
        let cpu = SensorReading.temperatureAverage(readings, chip: "Apple M5 Max", gpu: false)
        XCTAssertEqual(cpu?.value, 50)
        XCTAssertEqual(cpu?.count, 2)
        XCTAssertEqual(SensorReading.temperatureAverage(readings, chip: "Apple M5 Max", gpu: true)?.value, 70)
        XCTAssertNil(SensorReading.temperatureAverage(readings, chip: "Apple M4 Max", gpu: false))
        XCTAssertNil(SensorReading.temperatureAverage([], chip: "Apple M5 Max", gpu: false))
        XCTAssertEqual(SensorReading.m5SensorName("Tp0O", chip: "Apple M5 Max"), "CPU 性能核心测点 1")
        XCTAssertNil(SensorReading.m5SensorName("Tp0O", chip: "Apple M4 Max"))
    }
    func testDecodeSensorValues() {
        XCTAssertEqual(SensorReader.decode([0x2a, 0x80], type: "sp78"), 42.5)
        XCTAssertEqual(SensorReader.decode([0xff, 0x00], type: "sp78"), -1)
        XCTAssertEqual(SensorReader.decode([0x1f, 0x40], type: "fpe2"), 2000)
        XCTAssertEqual(SensorReader.decode([0, 0, 0x48, 0x42], type: "flt "), 50)
        XCTAssertNil(SensorReader.decode([0, 0, 0xc0, 0x7f], type: "flt "))
        XCTAssertNil(SensorReader.decode([0], type: "sp78"))
    }
    func testTemperatureGroupsAreSortedAndExcludeFans() {
        let readings = [
            SensorReading(id: "TB1T", value: 35, unit: "°C"),
            SensorReading(id: "F0Ac", value: 2000, unit: "rpm"),
            SensorReading(id: "TA0T", value: 30, unit: "°C"),
            SensorReading(id: "TB0T", value: 34, unit: "°C")
        ]
        let groups = SensorReading.temperatureGroups(readings)
        XCTAssertEqual(groups.map(\.key), ["TA", "TB"])
        XCTAssertEqual(groups[1].readings.map(\.id), ["TB0T", "TB1T"])
        XCTAssertTrue(SensorReading.temperatureGroups([]).isEmpty)
        XCTAssertEqual(readings[1].displayName, "风扇 1（F0Ac）")
        XCTAssertEqual(readings[0].displayName, "TB1T")
        XCTAssertEqual(SensorReading(id: "FZAc", value: 0, unit: "rpm").displayName, "FZAc")
    }
}
