import OpenToolboxCore
import SwiftUI

struct JSONFormatterView: View {
    let tool: ToolDescriptor
    @State private var input = ""
    @State private var indent: JSONIndent = .twoSpaces
    @State private var sortKeys = false
    @State private var minify = false

    private var result: Result<String, Error>? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let input = self.input, minify = self.minify, indent = self.indent, sortKeys = self.sortKeys
        return Result { () throws -> String in
            if minify {
                return try JSONFormatter.minified(input, sortKeys: sortKeys)
            }
            return try JSONFormatter.prettyPrinted(input, indent: indent, sortKeys: sortKeys)
        }
    }

    var body: some View {
        let result = self.result
        let output = (try? result?.get()) ?? ""
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Picker(L("Style"), selection: $minify) {
                    Text(L("Pretty")).tag(false)
                    Text(L("Minified")).tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Picker(L("Indent"), selection: $indent) {
                    Text(L("2 spaces")).tag(JSONIndent.twoSpaces)
                    Text(L("4 spaces")).tag(JSONIndent.fourSpaces)
                    Text(L("Tabs")).tag(JSONIndent.tab)
                }
                .fixedSize()
                .disabled(minify)

                Toggle(L("Sort keys"), isOn: $sortKeys)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                Pane(L("Input")) {
                    HStack {
                        Button(L("Paste")) { input = Clipboard.string() ?? input }
                        Button(L("Clear")) { input = "" }
                    }
                } content: {
                    CodeEditor(text: $input)
                }
                Pane(L("Output")) {
                    HStack {
                        Button(L("Use as Input")) { input = output }
                            .disabled(output.isEmpty)
                        CopyButton(text: output)
                    }
                } content: {
                    CodeOutput(text: output, placeholder: L("Formatted JSON appears here."))
                }
            }

            if case .failure(let error)? = result {
                ErrorMessage(text: error.localizedDescription)
            } else if result != nil {
                Label(L("Valid JSON"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
