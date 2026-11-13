import Foundation

enum ValueFormat {
    static func number(_ value: Double, precision: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...max(0, min(2, precision)))))
    }
    static func display(_ value: Double, metric: Metric, precision: Int) -> (String, String) {
        guard metric == .disk || metric == .network else { return (number(value, precision: precision), metric.unit) }
        let bytes = value * 1_000_000
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var scaled = bytes, index = 0
        while scaled >= 1000 && index < units.count - 1 { scaled /= 1000; index += 1 }
        return (number(scaled, precision: precision), units[index])
    }
    static func reading(_ value: Double, metric: Metric, precision: Int) -> String {
        let result = display(value, metric: metric, precision: precision)
        return "\(result.0) \(result.1)"
    }
    static func rate(_ bytes: Double, precision: Int) -> String { reading(bytes / 1_000_000, metric: .network, precision: precision) }
}
