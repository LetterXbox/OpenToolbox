import OpenToolboxCore
import SwiftUI

private struct PendingEngineEnable: Identifiable {
    let id = UUID()
    let tools: [ToolDescriptor]
    let engines: [EngineManifest]
}

struct ToolCatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""
    @State private var pendingEnable: PendingEngineEnable?

    private var visibleTools: [ToolDescriptor] {
        CommandSearch.rank(searchText, in: ToolCatalog.all)
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let tools = visibleTools
        let availableVisible = tools.filter { $0.availability == .available }
        let disabledVisible = availableVisible.filter { !model.isEnabled($0) }
        let enabledVisible = availableVisible.filter(model.isEnabled)

        List {
            ForEach(ToolCategory.allCases) { category in
                let categoryTools = ToolCatalog.tools(in: category, from: tools)
                if !categoryTools.isEmpty {
                    let availableInCategory = categoryTools.filter { $0.availability == .available }
                    let allEnabled = !availableInCategory.isEmpty && availableInCategory.allSatisfy(model.isEnabled)
                    Section {
                        ForEach(categoryTools) { tool in
                            ToolCatalogRow(tool: tool) {
                                requestEnable([tool])
                            }
                        }
                    } header: {
                        HStack {
                            Label(category.localizedTitle, systemImage: category.symbolName)
                            Spacer()
                            if !availableInCategory.isEmpty {
                                Button(allEnabled ? L("Disable All") : L("Enable All")) {
                                    if allEnabled {
                                        model.setEnabled(false, for: availableInCategory)
                                    } else {
                                        requestEnable(availableInCategory)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: L("Filter tools"))
        .navigationTitle(L("Tool Catalog"))
        .toolbar {
            ToolbarItemGroup {
                Button(isFiltering ? L("Enable Shown") : L("Enable All")) {
                    requestEnable(disabledVisible)
                }
                .disabled(disabledVisible.isEmpty)

                Button(isFiltering ? L("Disable Shown") : L("Disable All")) {
                    model.setEnabled(false, for: enabledVisible)
                }
                .disabled(enabledVisible.isEmpty)
            }
        }
        .overlay {
            if tools.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .onAppear { model.engines.refresh() }
        .alert(
            alertTitle(for: pendingEnable),
            isPresented: Binding(
                get: { pendingEnable != nil },
                set: { if !$0 { pendingEnable = nil } }
            ),
            presenting: pendingEnable
        ) { pending in
            Button(L("Enable & Download")) {
                model.setEnabled(true, for: pending.tools)
                model.engines.install(pending.engines)
                pendingEnable = nil
            }
            Button(L("Enable Only")) {
                model.setEnabled(true, for: pending.tools)
                pendingEnable = nil
            }
            Button(L("Cancel"), role: .cancel) {
                pendingEnable = nil
            }
        } message: { pending in
            Text(alertMessage(for: pending))
        }
    }

    private func requestEnable(_ tools: [ToolDescriptor]) {
        let toEnable = tools.filter { $0.availability == .available && !model.isEnabled($0) }
        guard !toEnable.isEmpty else { return }
        let missing = model.engines.downloadableMissingEngines(for: toEnable)
        if missing.isEmpty {
            model.setEnabled(true, for: toEnable)
        } else {
            pendingEnable = PendingEngineEnable(tools: toEnable, engines: missing)
        }
    }

    private func alertTitle(for pending: PendingEngineEnable?) -> String {
        guard let pending else { return L("Download required engines?") }
        if pending.tools.count == 1 {
            let names = pending.engines.map(\.displayName).formatted(.list(type: .and))
            return L("Download \(names)?")
        }
        return L("Download required engines?")
    }

    private func alertMessage(for pending: PendingEngineEnable) -> String {
        let names = pending.engines.map(\.displayName).formatted(.list(type: .and))
        let size = model.engines.downloadSize(of: pending.engines).formatted(.byteCount(style: .file))
        if pending.tools.count == 1, let tool = pending.tools.first {
            return L("\(tool.localizedTitle) needs \(names) (\(size) download). Engines are verified with SHA-256 and shared across tools.")
        }
        return L("Enabling \(pending.tools.count) tools needs \(names) (\(size) download). Engines are verified with SHA-256 and shared across tools.")
    }
}

private struct ToolCatalogRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let tool: ToolDescriptor
    let onRequestEnable: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.symbolName)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(tool.availability == .available ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.localizedTitle)
                Text(tool.localizedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            footprint
            Toggle(
                L("Enabled"),
                isOn: Binding(
                    get: { model.isEnabled(tool) },
                    set: { enabled in
                        if enabled {
                            onRequestEnable()
                        } else {
                            model.setEnabled(false, for: tool)
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(tool.availability == .planned)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if tool.availability == .available, model.isEnabled(tool) {
                window.open(.tool(tool.id))
            }
        }
    }

    private var requiredEngineNames: String {
        tool.requiredEngines
            .compactMap { EngineCatalog.manifest($0)?.displayName }
            .formatted(.list(type: .and))
    }

    @ViewBuilder private var footprint: some View {
        if tool.availability == .planned {
            Badge(text: L("Planned"), tint: .secondary)
        } else if tool.isBuiltIn {
            Badge(text: L("Built-in · 0 MB"), tint: .green)
        } else if let fraction = model.engines.downloadProgress(for: tool) {
            let percent = min(max(Int((fraction * 100).rounded()), 0), 100)
            Badge(text: L("Downloading… \(percent)%"), tint: .blue)
                .help(requiredEngineNames)
        } else if model.engines.allEnginesInstalled(for: tool) {
            let bytes = model.engines.installedDiskUsage(for: tool)
            Badge(text: L("Installed · \(bytes.formatted(.byteCount(style: .file)))"), tint: .green)
                .help(requiredEngineNames)
        } else {
            let missing = model.engines.missingEngines(for: tool)
            let damaged = missing.filter {
                if case .damaged = model.engines.status(of: $0.id) { return true }
                return false
            }
            let allUpdates = !missing.isEmpty && missing.allSatisfy {
                if case .updateAvailable = model.engines.status(of: $0.id) { return true }
                return false
            }
            if !damaged.isEmpty {
                let names = damaged.map(\.displayName).formatted(.list(type: .and))
                Badge(text: L("Repair \(names)"), tint: .red)
            } else if allUpdates {
                let names = missing.map(\.displayName).formatted(.list(type: .and))
                Badge(text: L("Update \(names)"), tint: .orange)
            } else {
                let names = missing.isEmpty
                    ? requiredEngineNames
                    : missing.map(\.displayName).formatted(.list(type: .and))
                Badge(text: L("Needs \(names)"), tint: .orange)
            }
        }
    }
}

struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
