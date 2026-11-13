import XCTest
@testable import NativeMonitor

final class SystemReaderTests: XCTestCase {
    func testCounterRatesRejectResetAndInvalidIntervals() throws {
        let old = Counters(first: 100, second: 200)
        let current = Counters(first: 300, second: 500)
        let rates = try XCTUnwrap(current.rates(since: old, seconds: 2))
        XCTAssertEqual(rates.0, 100)
        XCTAssertEqual(rates.1, 150)
        XCTAssertNil(old.rates(since: current, seconds: 2))
        XCTAssertNil(current.rates(since: old, seconds: 0))
    }
    func testCPUPercentages() throws {
        let old = CPUCounters(user: 10, system: 20, idle: 30, nice: 10)
        let current = CPUCounters(user: 20, system: 30, idle: 100, nice: 20)
        let values = try XCTUnwrap(current.percentages(since: old))
        XCTAssertEqual(values.0, 20, accuracy: 0.001)
        XCTAssertEqual(values.1, 10, accuracy: 0.001)
        XCTAssertEqual(values.2, 70, accuracy: 0.001)
        XCTAssertNil(old.percentages(since: current))
        XCTAssertNil(old.percentages(since: old))
    }
    func testLocalSystemSources() throws {
        XCTAssertNotNil(SystemReader.cpu())
        let memory = try XCTUnwrap(SystemReader.memory())
        XCTAssertGreaterThan(memory.total, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        let volume = try XCTUnwrap(SystemReader.volume())
        XCTAssertGreaterThan(volume.total, 0)
        XCTAssertLessThanOrEqual(volume.available, volume.total)
        XCTAssertNotNil(SystemReader.network())
        XCTAssertNotNil(SystemReader.disk())
    }
    func testCollectorProducesRealValuesAfterBaseline() throws {
        let collector = MonitorCollector()
        let first = collector.read()
        XCTAssertNil(first[.cpu]?.value)
        XCTAssertNil(first[.disk]?.value)
        XCTAssertNil(first[.network]?.value)
        Thread.sleep(forTimeInterval: 0.15)
        let second = collector.read()
        let cpu = try XCTUnwrap(second[.cpu]?.value)
        XCTAssertTrue((0...100).contains(cpu))
        XCTAssertGreaterThan(try XCTUnwrap(second[.memory]?.value), 0)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second[.disk]?.value), 0)
        if let interfaces = SystemReader.network(), !interfaces.isEmpty {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(second[.network]?.value), 0)
        }
        XCTAssertFalse(MonitorCollector.readGPU().status.isEmpty)
    }
    func testNetworkCountersMatchNetstatWithoutTruncation() throws {
        let before = try XCTUnwrap(SystemReader.network())
        guard let candidate = before.first(where: { $0.counters.first > 0 || $0.counters.second > 0 }) else {
            throw XCTSkip("没有可用于对照的活动网络接口")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let line = try XCTUnwrap(String(data: output, encoding: .utf8)?.split(separator: "\n").first {
            let fields = $0.split(whereSeparator: \.isWhitespace)
            return fields.count >= 10 && fields[0] == Substring(candidate.name) && fields[2].hasPrefix("<Link#")
        })
        let fields = line.split(whereSeparator: \.isWhitespace)
        let received = try XCTUnwrap(UInt64(fields[fields.count - 5]))
        let sent = try XCTUnwrap(UInt64(fields[fields.count - 2]))
        let after = try XCTUnwrap(SystemReader.network()?.first(where: { $0.name == candidate.name }))
        XCTAssertGreaterThanOrEqual(received, candidate.counters.first)
        XCTAssertLessThanOrEqual(received, after.counters.first)
        XCTAssertGreaterThanOrEqual(sent, candidate.counters.second)
        XCTAssertLessThanOrEqual(sent, after.counters.second)
    }
}
