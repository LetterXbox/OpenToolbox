import OpenToolboxCore
import SwiftUI

// MARK: - Word Counter

struct WordCounterView: View {
    let tool: ToolDescriptor
    @State private var text = ""

    var body: some View {
        let stats = TextStatistics(text)
        ToolPage(tool: tool) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                StatTile(title: L("Words"), value: stats.words.formatted())
                StatTile(title: L("Characters"), value: stats.characters.formatted())
                StatTile(title: L("Without spaces"), value: stats.charactersExcludingWhitespace.formatted())
                StatTile(title: L("Sentences"), value: stats.sentences.formatted())
                StatTile(title: L("Lines"), value: stats.lines.formatted())
                StatTile(title: L("Paragraphs"), value: stats.paragraphs.formatted())
                StatTile(title: L("Reading time"), value: Self.duration(stats.readingTime))
                StatTile(title: L("Speaking time"), value: Self.duration(stats.speakingTime))
                StatTile(title: L("UTF-8 bytes"), value: stats.utf8Bytes.formatted())
            }
            Pane(L("Text")) {
                HStack {
                    Button(L("Paste")) { text = Clipboard.string() ?? text }
                    Button(L("Clear")) { text = "" }
                }
            } content: {
                CodeEditor(text: $text)
            }
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Case Converter

struct CaseConverterView: View {
    let tool: ToolDescriptor
    @State private var text = ""

    var body: some View {
        ToolPage(tool: tool) {
            Pane(L("Text")) {
                Button(L("Clear")) { text = "" }
            } content: {
                CodeEditor(text: $text)
                    .frame(minHeight: 90, maxHeight: 180)
            }
            Pane(L("Conversions")) {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(TextCase.allCases) { textCase in
                            let converted = CaseConverter.convert(text, to: textCase)
                            GridRow {
                                Text(verbatim: textCase.example)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                Text(converted.isEmpty ? " " : converted)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                InlineCopyButton(text: converted)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Lorem Ipsum

struct LoremIpsumView: View {
    let tool: ToolDescriptor
    @State private var count = 3
    @State private var unit: LoremIpsum.Unit = .paragraphs
    @State private var startWithClassic = true
    @State private var output = ""

    var body: some View {
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Stepper(value: $count, in: 1...200) {
                    Text(count.formatted()).monospacedDigit()
                }
                .fixedSize()
                Picker(L("Unit"), selection: $unit) {
                    Text(L("Words")).tag(LoremIpsum.Unit.words)
                    Text(L("Sentences")).tag(LoremIpsum.Unit.sentences)
                    Text(L("Paragraphs")).tag(LoremIpsum.Unit.paragraphs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle(L("Start with “Lorem ipsum”"), isOn: $startWithClassic)
                Spacer()
            }
            Pane(L("Output")) {
                HStack {
                    Button(L("Generate"), action: generate)
                        .buttonStyle(.borderedProminent)
                    CopyButton(text: output)
                }
            } content: {
                CodeOutput(text: output)
            }
        }
        .onAppear(perform: generate)
        .onChange(of: count) { generate() }
        .onChange(of: unit) { generate() }
        .onChange(of: startWithClassic) { generate() }
    }

    private func generate() {
        output = LoremIpsum.generate(count, unit: unit, startWithClassic: startWithClassic)
    }
}

// MARK: - Password Generator

struct PasswordGeneratorView: View {
    let tool: ToolDescriptor
    @State private var options = PasswordGenerator.Options()
    @State private var count = 5
    @State private var passwords: [String] = []

    var body: some View {
        let entropy = PasswordGenerator.entropyBits(for: options)
        let strength = PasswordGenerator.Strength(entropyBits: entropy)
        ToolPage(tool: tool) {
            HStack(spacing: 12) {
                Text(L("Length"))
                Slider(
                    value: Binding(get: { Double(options.length) }, set: { options.length = Int($0) }),
                    in: 4...128, step: 1
                )
                .frame(maxWidth: 320)
                Text(options.length.formatted())
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
                Stepper(value: $count, in: 1...50) {
                    Text(L("Count: \(count)"))
                }
                .fixedSize()
                Spacer()
            }
            HStack(spacing: 16) {
                Toggle(L("a–z"), isOn: $options.lowercase)
                Toggle(L("A–Z"), isOn: $options.uppercase)
                Toggle(L("0–9"), isOn: $options.digits)
                Toggle(L("Symbols"), isOn: $options.symbols)
                Toggle(L("Avoid look-alikes"), isOn: $options.excludeAmbiguous)
                Spacer()
            }
            HStack(spacing: 8) {
                Badge(text: strength.localizedName, tint: Self.color(for: strength))
                Text(L("About \(Int(entropy)) bits of entropy"))
                    .foregroundStyle(.secondary)
            }
            Pane(L("Passwords")) {
                HStack {
                    Button(L("Generate"), action: generate)
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                    CopyButton(text: passwords.joined(separator: "\n"), label: L("Copy All"))
                }
            } content: {
                List(passwords, id: \.self) { password in
                    HStack {
                        Text(password)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        InlineCopyButton(text: password)
                    }
                }
                .listStyle(.bordered)
            }
            Text(L("Passwords are generated on this Mac with the system's secure random number generator and are never stored."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: generate)
        .onChange(of: options) { generate() }
        .onChange(of: count) { generate() }
    }

    private func generate() {
        passwords = (0..<count).map { _ in PasswordGenerator.generate(options) }.filter { !$0.isEmpty }
    }

    static func color(for strength: PasswordGenerator.Strength) -> Color {
        switch strength {
        case .veryWeak: .red
        case .weak: .orange
        case .fair: .yellow
        case .strong: .green
        case .veryStrong: .mint
        }
    }
}
