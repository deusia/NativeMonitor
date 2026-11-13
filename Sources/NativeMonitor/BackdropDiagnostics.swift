import SwiftUI

@MainActor final class BackdropDiagnostics: ObservableObject {
    @Published private(set) var reports: [UUID: String] = [:]
    func update(_ id: UUID, _ text: String) { reports[id] = text }
    func remove(_ id: UUID) { reports.removeValue(forKey: id) }
    var summary: String { Set(reports.values).sorted().joined(separator: "\n") }
}

struct BackdropStatus: View {
    @ObservedObject var diagnostics: BackdropDiagnostics
    var body: some View {
        Text(diagnostics.summary.isEmpty ? "背景模糊准备中" : diagnostics.summary)
            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
    }
}
