import SMCKit
import SwiftUI

/// Debug view: every SMC key with type, raw bytes and decoded value (same data as `smcprobe dump`).
struct RawSMCView: View {
    @Environment(Monitor.self) private var monitor
    @State private var values: [SMCValue] = []
    @State private var filter = ""
    @State private var loading = false

    private var shown: [SMCValue] {
        guard !filter.isEmpty else { return values }
        return values.filter { $0.key.localizedCaseInsensitiveContains(filter) || $0.type.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Filter keys (e.g. F0, TB, CH)", text: $filter).textFieldStyle(.roundedBorder)
                Button(loading ? "Reading…" : "Reload") { Task { await load() } }.disabled(loading)
                Text("\(shown.count) / \(values.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Table(shown) {
                TableColumn("Key", value: \.key).width(60)
                TableColumn("Type", value: \.type).width(50)
                TableColumn("Hex") { Text($0.hex).font(.system(.caption, design: .monospaced)) }
                TableColumn("Decoded") { Text($0.decoded).monospacedDigit() }.width(120)
            }
        }
        .padding(12)
        .task { if values.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        values = await monitor.reader.dumpAllKeys()
        loading = false
    }
}

extension SMCValue: Identifiable {
    public var id: String { key }
}
