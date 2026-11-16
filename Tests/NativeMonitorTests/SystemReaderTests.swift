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
        XCTAssertFalse(try XCTUnwrap(SystemReader.cpuCores()).isEmpty)
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
        let cores = try XCTUnwrap(second[.cpu]?.cores)
        XCTAssertFalse(cores.isEmpty)
        XCTAssertTrue(cores.allSatisfy { $0.map { (0...100).contains($0) } ?? false })
        XCTAssertEqual(cpu, cores.compactMap { $0 }.reduce(0, +), accuracy: 0.001)
        XCTAssertLessThanOrEqual(cpu, Double(cores.count) * 100)
        let memory = try XCTUnwrap(second[.memory])
        XCTAssertGreaterThan(try XCTUnwrap(memory.value), 0)
        XCTAssertEqual(ValueFormat.memoryGigabytes(38_654_705_664), 36)
        let physicalMemory = try XCTUnwrap(memory.facts.first { $0.label == "物理内存" })
        let expectedMemory = ValueFormat.memoryGigabytes(ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(physicalMemory.value, "\(expectedMemory.formatted(.number.precision(.fractionLength(0...2)))) GB")
        XCTAssertEqual(Set(memory.series.keys), Set(["活跃", "非活跃", "不可换出", "压缩", "空闲"]))
        XCTAssertTrue(memory.series.values.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertEqual(try XCTUnwrap(memory.value), try XCTUnwrap(memory.series["活跃"]) + XCTUnwrap(memory.series["不可换出"]) + XCTUnwrap(memory.series["压缩"]), accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(second[.disk]?.value), 0)
        if let interfaces = SystemReader.network(), !interfaces.isEmpty {
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(second[.network]?.value), 0)
        }
        XCTAssertFalse(collector.readGPU().status.isEmpty)
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
    func testCoreTopologyOnlyMapsUnambiguousGroups() {
        let types = [0: "M", 1: "M", 2: "P"]
        let labels = CoreTopology.match(types: types, levels: [("Super", 1), ("Performance", 2)], count: 3)
        XCTAssertEqual(labels, ["性能核", "性能核", "超能核"])
        XCTAssertNil(CoreTopology.match(types: [0: "M", 1: "P"], levels: [("Super", 1), ("Performance", 1)], count: 2))
        XCTAssertNil(CoreTopology.match(types: [1: "M"], levels: [("Super", 1)], count: 1))
        XCTAssertNil(CoreTopology.match(types: [0: "M", 1: "M", 2: "P", 3: "P"], levels: [("Super", 2), ("Performance", 3)], count: 4))
    }
    func testClusterGroupingAndMissingCoreSamples() throws {
        let groups = try XCTUnwrap(CoreTopology.clusters(ids: [0: 2, 1: 1, 2: 1, 3: 2], count: 4))
        XCTAssertEqual(groups, [CPUCluster(id: 1, indices: [1, 2]), CPUCluster(id: 2, indices: [0, 3])])
        XCTAssertEqual(groups[0].total([1, 20, 30, 4]), 50)
        XCTAssertNil(groups[0].total([1, nil, 30, 4]))
        XCTAssertNil(groups[0].total([1]))
        XCTAssertNil(CoreTopology.clusters(ids: [0: 0], count: 2))
        XCTAssertNil(CoreTopology.clusters(ids: [0: -1], count: 1))
        let local = try XCTUnwrap(SystemReader.cpuCores())
        if let clusters = SystemReader.coreTopology(count: local.count).clusters {
            XCTAssertEqual(clusters.flatMap(\.indices).sorted(), Array(local.indices))
        }
    }
    func testGPUCoreCountMatchesSystemProfiler() throws {
        let capabilities = GPUCapabilities.detect()
        guard let count = capabilities.coreCount, let name = capabilities.name else {
            throw XCTSkip("驱动未提供可验证的 GPU 核心掩码")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try XCTUnwrap(document["SPDisplaysDataType"] as? [[String: Any]])
        guard let device = devices.first(where: { $0["sppci_model"] as? String == name }),
              let reported = device["sppci_cores"] as? String, let officialCount = Int(reported) else {
            throw XCTSkip("系统报告未提供可匹配的 GPU 核心数")
        }
        XCTAssertEqual(count, officialCount)
    }
}
