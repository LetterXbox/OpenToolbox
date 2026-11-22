import OpenToolboxCore
import SwiftUI

struct TimestampConverterView: View {
    enum Zone: Hashable { case local, utc }

    let tool: ToolDescriptor
    @State private var input = String(Int(Date().timeIntervalSince1970))
    @State private var unit: TimestampUnit?
    @State private var zone: Zone = .local

    private var timeZone: TimeZone {
        zone == .utc ? TimeZone(identifier: "UTC")! : .current
    }

    private var parsed: Result<ParsedTimestamp, Error> {
        let input = self.input, unit = self.unit, timeZone = self.timeZone
        return Result { try TimestampConverter.parse(input, unit: unit, timeZone: timeZone) }
    }

    var body: some View {
        let parsed = self.parsed
        ToolPage(tool: tool) {
            HStack(spacing: 12) {
                TextField(L("Unix timestamp or date"), text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                Button(L("Now")) { input = String(Int(Date().timeIntervalSince1970)) }
            }

            HStack(spacing: 16) {
                Picker(L("Unit"), selection: $unit) {
                    Text(L("Auto")).tag(TimestampUnit?.none)
                    ForEach(TimestampUnit.allCases) { unit in
                        Text(unit.localizedName).tag(Optional(unit))
                    }
                }
                .fixedSize()

                Picker(L("Time zone"), selection: $zone) {
                    Text(L("Local (\(TimeZone.current.identifier))")).tag(Zone.local)
                    Text(verbatim: "UTC").tag(Zone.utc)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
            }

            switch parsed {
            case .failure(let error):
                ErrorMessage(text: error.localizedDescription)
            case .success(let value):
                if let detected = value.unit, unit == nil {
                    Text(L("Read as \(detected.localizedName.lowercased())."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    ForEach(TimestampConverter.representations(of: value.date, timeZone: timeZone)) { item in
                        GridRow {
                            Text(item.kind.localizedName)
                                .foregroundStyle(.secondary)
                            Text(item.value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            InlineCopyButton(text: item.value)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
