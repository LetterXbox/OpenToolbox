import OpenToolboxCore
import SwiftUI

struct Base64HexView: View {
    enum Codec: Hashable { case base64, base64URL, hex }
    enum Direction: Hashable { case encode, decode }

    let tool: ToolDescriptor
    @State private var input = ""
    @State private var codec: Codec = .base64
    @State private var direction: Direction = .encode
    @State private var uppercaseHex = false

    private struct Output {
        var text: String
        var note: String?
    }

    private var output: Result<Output, Error> {
        Result {
            guard !input.isEmpty else { return Output(text: "") }
            switch direction {
            case .encode:
                let data = Data(input.utf8)
                let text: String =
                    switch codec {
                    case .base64: ByteEncoding.base64Encode(data)
                    case .base64URL: ByteEncoding.base64Encode(data, urlSafe: true, padded: false)
                    case .hex: ByteEncoding.hexEncode(data, uppercase: uppercaseHex)
                    }
                return Output(text: text)
            case .decode:
                let data: Data
                if codec == .hex {
                    data = try ByteEncoding.hexDecode(input)
                } else {
                    data = try ByteEncoding.base64Decode(input)
                }
                if let text = String(data: data, encoding: .utf8) {
                    return Output(text: text)
                }
                return Output(
                    text: ByteEncoding.hexEncode(data, uppercase: uppercaseHex, separator: " "),
                    note: L("The decoded bytes are not UTF-8 text, so they are shown as hexadecimal (\(data.count) bytes)."))
            }
        }
    }

    var body: some View {
        let output = self.output
        let text = (try? output.get().text) ?? ""
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Picker(L("Format"), selection: $codec) {
                    Text(verbatim: "Base64").tag(Codec.base64)
                    Text(verbatim: "Base64URL").tag(Codec.base64URL)
                    Text(L("Hex")).tag(Codec.hex)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Picker(L("Direction"), selection: $direction) {
                    Text(L("Encode")).tag(Direction.encode)
                    Text(L("Decode")).tag(Direction.decode)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                Toggle(L("Uppercase hex"), isOn: $uppercaseHex)
                Spacer()
            }

            HStack(alignment: .top, spacing: 16) {
                Pane(direction == .encode ? L("Text") : L("Encoded")) {
                    Button(L("Clear")) { input = "" }
                } content: {
                    CodeEditor(text: $input)
                }
                Pane(direction == .encode ? L("Encoded") : L("Decoded")) {
                    HStack {
                        Button(L("Swap")) {
                            input = text
                            direction = direction == .encode ? .decode : .encode
                        }
                        .disabled(text.isEmpty)
                        CopyButton(text: text)
                    }
                } content: {
                    CodeOutput(text: text)
                }
            }

            switch output {
            case .failure(let error):
                ErrorMessage(text: error.localizedDescription)
            case .success(let value):
                if let note = value.note {
                    Label(note, systemImage: "info.circle").foregroundStyle(.secondary)
                }
            }
        }
    }
}
