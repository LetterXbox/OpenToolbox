import OpenToolboxCore
import SwiftUI

struct HiddenSettingsView: View {
    let tool: ToolDescriptor

    private struct Change {
        let setting: HiddenSetting
        let value: HiddenSettingValue?
    }

    @State private var selectedID = HiddenSetting.all[0].id
    @State private var reading: HiddenSetting.Reading?
    @State private var draftBoolean = false
    @State private var draftText = ""
    @State private var pendingChange: Change?
    @State private var confirmChange = false
    @State private var isApplying = false
    @State private var message: String?
    @State private var error: String?

    private var setting: HiddenSetting {
        HiddenSetting.all.first { $0.id == selectedID } ?? HiddenSetting.all[0]
    }

    private var draft: HiddenSettingValue? {
        switch setting.kind {
        case .boolean:
            return .boolean(draftBoolean)
        case .seconds:
            let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let seconds = try? Double(text, format: .number, lenient: false) else { return nil }
            return .seconds(seconds)
        case .choice, .directory:
            return .text(draftText)
        }
    }

    var body: some View {
        ToolPage(tool: tool) {
            Picker(L("Setting"), selection: $selectedID) {
                ForEach(HiddenSetting.all) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .disabled(isApplying)

            Pane(setting.title, accessory: {
                Button(L("Refresh"), systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isApplying)
            }) {
                Text(setting.explanation).foregroundStyle(.secondary)
                MacUtilityMetrics(rows: [
                    (L("Preference"), setting.id),
                    (L("Current value"), currentValue),
                    (L("Default value"), setting.defaultValue.map(describe) ?? L("System default")),
                ])
                editor.disabled(isApplying)

                HStack {
                    Button(L("Apply…")) {
                        if let draft { prepareChange(draft) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || draft.map { setting.defaultsArguments(for: $0) == nil } != false)
                    Button(L("Reset to Default…")) { prepareChange(nil) }
                        .disabled(isApplying || reading?.hasUserOverride != true)
                    if isApplying {
                        ProgressView().controlSize(.small).accessibilityLabel(L("Applying the setting"))
                    }
                }
            }
            if let message {
                Label(message, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if let error {
                ErrorMessage(text: error)
            }
        }
        .onAppear { refresh() }
        .onChange(of: selectedID) { refresh() }
        .confirmationDialog(L("Change this macOS setting?"), isPresented: $confirmChange, titleVisibility: .visible,
                            presenting: pendingChange) { change in
            let name = change.setting.relaunchTarget.rawValue
            Button(L("Apply and Relaunch \(name)")) { apply(change, relaunch: true) }
            Button(L("Apply Only")) { apply(change, relaunch: false) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { change in
            let name = change.setting.relaunchTarget.rawValue
            if let value = change.value {
                Text(L("Set \(change.setting.title) to \(describe(value)). Relaunching \(name) applies the change immediately."))
            } else {
                Text(L("Reset \(change.setting.title) to the macOS default. Relaunching \(name) applies the change immediately."))
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch setting.kind {
        case .boolean:
            Toggle(L("Enabled"), isOn: $draftBoolean)
        case .seconds:
            TextField(L("Seconds"), text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 180)
        case .choice(let options):
            Picker(L("Format"), selection: $draftText) {
                ForEach(options, id: \.self) { option in Text(option.uppercased()).tag(option) }
            }
            .fixedSize()
        case .directory:
            TextField(L("Folder path"), text: $draftText, prompt: Text(L("~/Desktop")))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var currentValue: String {
        if reading?.hasUnrecognizedValue == true { return L("Unrecognized value") }
        return reading?.value.map(describe) ?? setting.defaultValue.map(describe) ?? L("System default")
    }

    private func describe(_ value: HiddenSettingValue) -> String {
        switch value {
        case .boolean(let enabled): enabled ? L("On") : L("Off")
        case .seconds(let seconds): L("\(seconds.formatted()) seconds")
        case .text(let text): text
        }
    }

    private func refresh() {
        let current = setting.read()
        reading = current
        draftBoolean = false
        draftText = ""
        switch current.value ?? setting.defaultValue {
        case .boolean(let flag)?: draftBoolean = flag
        case .seconds(let seconds)?: draftText = seconds.formatted(.number.grouping(.never))
        case .text(let text)?: draftText = text
        case nil: break
        }
        message = nil
        error = nil
    }

    private func prepareChange(_ value: HiddenSettingValue?) {
        pendingChange = Change(setting: setting, value: value)
        confirmChange = true
    }

    private func apply(_ change: Change, relaunch: Bool) {
        guard !isApplying else { return }
        isApplying = true
        message = nil
        error = nil
        Task {
            defer { isApplying = false }
            do {
                try await change.setting.apply(change.value)
            } catch {
                self.error = error.localizedDescription
                return
            }

            refresh()
            if relaunch {
                let name = change.setting.relaunchTarget.rawValue
                do {
                    try await change.setting.relaunch()
                    message = L("Setting saved. Relaunched \(name).")
                } catch {
                    self.error = L("Setting saved, but \(name) could not be relaunched: \(error.localizedDescription)")
                }
            } else {
                message = L("Setting saved.")
            }
        }
    }
}
