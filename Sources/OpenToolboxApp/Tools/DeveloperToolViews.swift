import OpenToolboxCore
import SwiftUI

// MARK: - Diff Checker

struct DiffCheckerView: View {
    let tool: ToolDescriptor
    @State private var original = ""
    @State private var changed = ""
    @State private var options = TextDiff.Options()

    var body: some View {
        let lines = TextDiff.diff(original, changed, options: options)
        let summary = TextDiff.summary(of: lines)
        ToolPage(tool: tool) {
            HStack(alignment: .top, spacing: 16) {
                Pane(L("Original")) {
                    CodeEditor(text: $original)
                }
                Pane(L("Changed")) {
                    CodeEditor(text: $changed)
                }
            }
            .frame(minHeight: 140, maxHeight: 260)

            HStack(spacing: 16) {
                Toggle(L("Ignore case"), isOn: $options.ignoreCase)
                Toggle(L("Ignore whitespace"), isOn: $options.ignoreWhitespace)
                Spacer()
                if !lines.isEmpty {
                    if summary.isIdentical {
                        Label(L("No differences"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Text(L("+\(summary.added) added, −\(summary.removed) removed"))
                            .foregroundStyle(.secondary)
                    }
                }
                CopyButton(text: TextDiff.unifiedText(lines), label: L("Copy Diff"))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DiffLineRow(line: line)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct DiffLineRow: View {
    let line: TextDiff.Line

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(.tertiary)
            Text(verbatim: marker)
                .frame(width: 22)
                .foregroundStyle(tint)
            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.body, design: .monospaced))
        .padding(.vertical, 1)
        .background(tint.opacity(line.kind == .unchanged ? 0 : 0.14))
    }

    private var marker: String {
        switch line.kind {
        case .unchanged: " "
        case .added: "+"
        case .removed: "−"
        }
    }

    private var tint: Color {
        switch line.kind {
        case .unchanged: .clear
        case .added: .green
        case .removed: .red
        }
    }
}

// MARK: - Regex Tester

struct RegexTesterView: View {
    let tool: ToolDescriptor
    @State private var pattern = ""
    @State private var text = ""
    @State private var replacement = ""
    @State private var options: RegexTester.Options = []

    var body: some View {
        let pattern = self.pattern, text = self.text, options = self.options
        let result = Swift.Result { try RegexTester.matches(pattern, in: text, options: options) }
        let matches = (try? result.get()) ?? []
        ToolPage(tool: tool) {
            TextField(L("Regular expression"), text: $pattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.title3, design: .monospaced))
            HStack(spacing: 16) {
                optionToggle(L("Ignore case"), .caseInsensitive)
                optionToggle(L("Multiline anchors"), .multiline)
                optionToggle(L("Dot matches newline"), .dotMatchesNewlines)
                optionToggle(L("Extended"), .extended)
                Spacer()
                if !pattern.isEmpty, case .success = result {
                    Text(L("\(matches.count) matches")).foregroundStyle(.secondary)
                }
            }
            if !pattern.isEmpty, case .failure(let error) = result {
                ErrorMessage(text: error.localizedDescription)
            }

            HStack(alignment: .top, spacing: 16) {
                Pane(L("Test text")) {
                    CodeEditor(text: $text)
                }
                Pane(L("Matches")) {
                    ScrollView {
                        Text(Self.highlighted(text, matches: matches))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(10)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }

            if !matches.isEmpty {
                Pane(L("Groups")) {
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            ForEach(matches.prefix(200)) { match in
                                GridRow {
                                    Text(verbatim: "#\(match.index + 1)").foregroundStyle(.secondary)
                                    Text(match.value).font(.system(.body, design: .monospaced))
                                    Text(
                                        match.groups.map { group in
                                            "\(group.name ?? "$\(group.index)")=\(group.value ?? "∅")"
                                        }.joined(separator: "  ")
                                    )
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
            }

            Pane(L("Replace")) {
                TextField(L("Replacement ($1, ${name})"), text: $replacement)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if !pattern.isEmpty, !replacement.isEmpty,
                    let replaced = try? RegexTester.replace(pattern, in: text, with: replacement, options: options)
                {
                    HStack(alignment: .top) {
                        CodeOutput(text: replaced).frame(maxHeight: 120)
                        CopyButton(text: replaced)
                    }
                }
            }
        }
    }

    private func optionToggle(_ title: String, _ option: RegexTester.Options) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { options.contains(option) },
                set: { enabled in
                    if enabled { options.insert(option) } else { options.remove(option) }
                }))
    }

    static func highlighted(_ text: String, matches: [RegexTester.Match]) -> AttributedString {
        var result = AttributedString()
        var cursor = text.startIndex
        for match in matches where match.range.lowerBound >= cursor {
            result += AttributedString(String(text[cursor..<match.range.lowerBound]))
            var highlighted = AttributedString(String(text[match.range]))
            highlighted.swiftUI.backgroundColor = Color.accentColor.opacity(0.3)
            result += highlighted
            cursor = match.range.upperBound
        }
        result += AttributedString(String(text[cursor...]))
        return result
    }
}

// MARK: - Clean Links

struct CleanLinksView: View {
    let tool: ToolDescriptor
    @State private var input = ""

    var body: some View {
        let cleanup = CleanLinks.cleanAll(in: input)
        let cleaned = cleanup.text, results = cleanup.results
        let changes = results.filter(\.changed)
        ToolPage(tool: tool) {
            HStack(alignment: .top, spacing: 16) {
                Pane(L("Links or text")) {
                    HStack {
                        Button(L("Paste")) { input = Clipboard.string() ?? input }
                        Button(L("Clear")) { input = "" }
                    }
                } content: {
                    CodeEditor(text: $input)
                }
                Pane(L("Cleaned")) {
                    CopyButton(text: cleaned)
                } content: {
                    CodeOutput(text: input.isEmpty ? "" : cleaned)
                }
            }
            if !input.isEmpty {
                if changes.isEmpty {
                    Label(
                        results.isEmpty ? L("No web links found.") : L("No tracking parameters found."),
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Pane(L("Removed")) {
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                            HStack(alignment: .firstTextBaseline) {
                                if change.unwrapped {
                                    Badge(text: L("Unwrapped redirect"), tint: .blue)
                                }
                                Text(change.removedParameters.joined(separator: ", "))
                                    .font(.system(.callout, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Unicode Inspector

struct UnicodeInspectorView: View {
    let tool: ToolDescriptor
    @State private var text = "Héllo 👋🏽\u{200B}!"

    var body: some View {
        let scalars = UnicodeInspector.inspect(text).flatMap(\.scalars)
        ToolPage(tool: tool) {
            TextField(L("Text to inspect"), text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Table(scalars) {
                TableColumn(L("Char")) { info in
                    Text(info.isInvisible ? "·" : String(info.scalar))
                        .foregroundStyle(info.isInvisible ? Color.orange : Color.primary)
                }
                .width(44)
                TableColumn(L("Code point")) { info in
                    Text(info.codePoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                .width(90)
                TableColumn(L("Name")) { info in
                    Text(info.name).textSelection(.enabled)
                }
                TableColumn(L("Category")) { info in
                    Text(info.category).foregroundStyle(.secondary)
                }
                TableColumn(L("UTF-8")) { info in
                    Text(info.utf8).font(.system(.body, design: .monospaced))
                }
                .width(110)
                TableColumn(L("UTF-16")) { info in
                    Text(info.utf16).font(.system(.body, design: .monospaced))
                }
                .width(90)
            }
            HStack(spacing: 16) {
                Text(L("\(text.count) characters · \(text.unicodeScalars.count) code points · \(text.utf8.count) UTF-8 bytes · \(text.utf16.count) UTF-16 units"))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu(L("Copy Normalized")) {
                    ForEach(UnicodeInspector.normalizations(of: text), id: \.name) { form in
                        Button(form.name) { Clipboard.copy(form.value) }
                    }
                }
                .fixedSize()
            }
        }
    }
}

// MARK: - CSV ↔ JSON

struct CSVJSONView: View {
    enum Direction: Hashable { case csvToJSON, jsonToCSV }
    enum Delimiter: Hashable { case auto, comma, semicolon, tab }

    let tool: ToolDescriptor
    @State private var direction: Direction = .csvToJSON
    @State private var delimiter: Delimiter = .auto
    @State private var firstRowIsHeader = true
    @State private var inferTypes = true
    @State private var input = ""

    private var delimiterCharacter: Character? {
        switch delimiter {
        case .auto: nil
        case .comma: ","
        case .semicolon: ";"
        case .tab: "\t"
        }
    }

    var body: some View {
        let input = self.input, direction = self.direction, delimiter = self.delimiterCharacter
        let options = CSV.ToJSONOptions(firstRowIsHeader: firstRowIsHeader, inferTypes: inferTypes)
        let result = Swift.Result { () throws -> String in
            guard !input.isEmpty else { return "" }
            switch direction {
            case .csvToJSON: return try CSV.toJSON(input, delimiter: delimiter, options: options)
            case .jsonToCSV: return try CSV.fromJSON(input, delimiter: delimiter ?? ",")
            }
        }
        let output = (try? result.get()) ?? ""
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Picker(L("Direction"), selection: $direction) {
                    Text(L("CSV → JSON")).tag(Direction.csvToJSON)
                    Text(L("JSON → CSV")).tag(Direction.jsonToCSV)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker(L("Delimiter"), selection: $delimiter) {
                    Text(L("Auto")).tag(Delimiter.auto)
                    Text(L("Comma")).tag(Delimiter.comma)
                    Text(L("Semicolon")).tag(Delimiter.semicolon)
                    Text(L("Tab")).tag(Delimiter.tab)
                }
                .fixedSize()
                if direction == .csvToJSON {
                    Toggle(L("First row is header"), isOn: $firstRowIsHeader)
                    Toggle(L("Detect numbers and booleans"), isOn: $inferTypes)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 16) {
                Pane(direction == .csvToJSON ? L("CSV") : L("JSON")) {
                    Button(L("Clear")) { self.input = "" }
                } content: {
                    CodeEditor(text: $input)
                }
                Pane(direction == .csvToJSON ? L("JSON") : L("CSV")) {
                    HStack {
                        Button(L("Swap")) {
                            self.input = output
                            self.direction = direction == .csvToJSON ? .jsonToCSV : .csvToJSON
                        }
                        .disabled(output.isEmpty)
                        CopyButton(text: output)
                    }
                } content: {
                    CodeOutput(text: output)
                }
            }
            if case .failure(let error) = result {
                ErrorMessage(text: error.localizedDescription)
            }
        }
    }
}
