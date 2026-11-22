import OpenToolboxCore
import SwiftUI

struct UUIDGeneratorView: View {
    let tool: ToolDescriptor
    @State private var version: UUIDVersion = .v7
    @State private var count = 5
    @State private var format = UUIDFormat()
    @State private var generated: [UUID] = []
    @State private var inspectInput = ""

    private var outputText: String {
        generated.map { UUIDTools.format($0, format) }.joined(separator: "\n")
    }

    var body: some View {
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Picker(L("Version"), selection: $version) {
                    Text(L("v4 (random)")).tag(UUIDVersion.v4)
                    Text(L("v7 (time-ordered)")).tag(UUIDVersion.v7)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Stepper(value: $count, in: 1...1000) {
                    Text(L("Count: \(count)"))
                }
                .fixedSize()

                Toggle(L("Uppercase"), isOn: $format.uppercase)
                Toggle(L("Hyphens"), isOn: $format.hyphens)
                Toggle(L("Braces"), isOn: $format.braces)
                Spacer()
            }

            Pane(L("Generated")) {
                HStack {
                    Button(L("Generate"), action: generate)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    CopyButton(text: outputText)
                }
            } content: {
                CodeOutput(text: outputText)
            }

            Pane(L("Inspect")) {
                TextField(L("Paste a UUID"), text: $inspectInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                inspection
            }
        }
        .onAppear { if generated.isEmpty { generate() } }
        .onChange(of: version) { generate() }
        .onChange(of: count) { generate() }
    }

    @ViewBuilder private var inspection: some View {
        let trimmed = inspectInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let info = UUIDTools.inspect(trimmed) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text(L("Version")).foregroundStyle(.secondary)
                        Text(info.isNil ? L("Nil UUID") : info.isMax ? L("Max UUID") : String(info.version))
                    }
                    GridRow {
                        Text(L("Variant")).foregroundStyle(.secondary)
                        Text(info.variant.localizedName)
                    }
                    if let timestamp = info.timestamp {
                        GridRow {
                            Text(L("Created")).foregroundStyle(.secondary)
                            Text(timestamp.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)))
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                ErrorMessage(text: L("Not a valid UUID."))
            }
        }
    }

    private func generate() {
        if version == .v7 {
            // Generate in order so a batch is sorted even within one millisecond.
            let now = Date()
            generated = (0..<count).map { _ in UUIDTools.v7(date: now) }.sorted { $0.uuidString < $1.uuidString }
        } else {
            generated = (0..<count).map { _ in UUIDTools.generate(.v4) }
        }
    }
}
