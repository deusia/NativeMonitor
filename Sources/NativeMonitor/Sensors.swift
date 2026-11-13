import Foundation
import IOKit

struct SensorReading: Identifiable {
    let id: String
    let value: Double
    let unit: String
}

// AppleSMC 是私有接口；只展示类型和数值均可识别的实际读数。
final class SensorReader {
    private struct Version { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct Limits { var version: UInt16 = 0; var length: UInt16 = 0; var cpu: UInt32 = 0; var gpu: UInt32 = 0; var memory: UInt32 = 0 }
    private struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0; var padding: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    private struct SMCData {
        var key: UInt32 = 0
        var version = Version()
        var limits = Limits()
        var info = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
    private var connection: io_connect_t = 0
    private var keys: [(UInt32, String, KeyInfo)]?

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
    }
    deinit { IOServiceClose(connection) }
    private func call(_ input: SMCData) -> SMCData? {
        var input = input, output = SMCData(), size = MemoryLayout<SMCData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 && size == MemoryLayout<SMCData>.stride ? output : nil
    }
    private func info(_ key: UInt32) -> KeyInfo? {
        var input = SMCData(); input.key = key; input.command = 9
        guard let info = call(input)?.info, info.size > 0, info.size <= 32 else { return nil }
        return info
    }
    private func read(_ key: UInt32, _ info: KeyInfo) -> [UInt8]? {
        var input = SMCData(); input.key = key; input.info.size = info.size; input.command = 5
        guard var output = call(input) else { return nil }
        return withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(info.size))) }
    }
    private static func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    private static func string(_ code: UInt32) -> String {
        String(bytes: (0..<4).map { UInt8(truncatingIfNeeded: code >> (24 - $0 * 8)) }, encoding: .ascii) ?? ""
    }
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt " where bytes.count == 4:
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        default: return nil
        }
    }
    func read() -> [SensorReading]? {
        if keys == nil {
            let countKey = Self.code("#KEY")
            guard let info = info(countKey), let bytes = read(countKey, info), bytes.count == 4 else { return nil }
            let count = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= 16384 else { return nil }
            var found: [(UInt32, String, KeyInfo)] = []
            for index in 0..<count {
                var input = SMCData(); input.command = 8; input.index = index
                guard let key = call(input)?.key else { continue }
                let name = Self.string(key)
                guard name.hasPrefix("T") || (name.hasPrefix("F") && name.hasSuffix("Ac")), let info = self.info(key) else { continue }
                let type = Self.string(info.type)
                if (name.hasPrefix("T") && ["sp78", "flt "].contains(type)) || (name.hasPrefix("F") && ["fpe2", "flt "].contains(type)) {
                    found.append((key, name, info))
                }
            }
            keys = found
        }
        return keys!.compactMap { key, name, info in
            guard let bytes = read(key, info), let value = Self.decode(bytes, type: Self.string(info.type)), name.hasPrefix("T") || value >= 0 else { return nil }
            return SensorReading(id: name, value: value, unit: name.hasPrefix("T") ? "°C" : "rpm")
        }.sorted { $0.id < $1.id }
    }
}
