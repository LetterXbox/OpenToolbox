import OpenToolboxCore
import SwiftUI

/// Every tool, grouped by category, with an enable switch and its download footprint.
struct ToolCatalogView: View {
    @Environment(AppModel.self) private var model
    @State private var searchText = ""

    private var visibleTools: [ToolDescriptor] {
        CommandSearch.rank(searchText, in: ToolCatalog.all)
    }

    var body: some View {
        let tools = visibleTools
        List {
            ForEach(ToolCategory.allCases) { category in
                let categoryTools = ToolCatalog.tools(in: category, from: tools)
                if !categoryTools.isEmpty {
                    Section {
                        ForEach(categoryTools) { tool in
                            ToolCatalogRow(tool: tool)
                        }
                    } header: {
                        Label(category.localizedTitle, systemImage: category.symbolName)
                    }
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: L("Filter tools"))
        .navigationTitle(L("Tool Catalog"))
        .overlay {
            if tools.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

private struct ToolCatalogRow: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

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
                    set: { model.setEnabled($0, for: tool) }
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
                model.open(.tool(tool.id))
            }
        }
    }

    @ViewBuilder private var footprint: some View {
        if tool.availability == .planned {
            Badge(text: L("Planned"), tint: .secondary)
        } else if tool.isBuiltIn {
            Badge(text: L("Built-in · 0 MB"), tint: .green)
        } else {
            let names = tool.requiredEngines
                .compactMap { EngineCatalog.manifest($0)?.displayName }
                .formatted(.list(type: .and))
            Badge(text: L("Needs \(names)"), tint: .orange)
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
