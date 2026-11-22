import AppKit
import OpenToolboxCore
import SwiftUI

/// ⌘K quick-open palette over tools and app destinations.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isSearchFocused: Bool

    private struct Entry: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbolName: String
        let destination: SidebarItem
    }

    private var entries: [Entry] {
        let tools = CommandSearch.rank(query, in: model.activeTools).map { tool in
            Entry(
                id: tool.id, title: tool.localizedTitle, subtitle: tool.category.localizedTitle,
                symbolName: tool.symbolName, destination: .tool(tool.id))
        }
        let destinations = [
            Entry(
                id: "app.catalog", title: L("Tool Catalog"), subtitle: L("Enable or disable tools"),
                symbolName: "square.grid.2x2", destination: .catalog),
            Entry(
                id: "app.engines", title: L("Engines"), subtitle: L("Download and remove on-demand engines"),
                symbolName: "shippingbox", destination: .engines),
        ]
        let needle = query.trimmingCharacters(in: .whitespaces)
        let matchingDestinations = needle.isEmpty
            ? destinations
            : destinations.filter { $0.title.localizedStandardContains(needle) }
        return tools + matchingDestinations
    }

    var body: some View {
        let entries = self.entries
        ZStack(alignment: .top) {
            Color.black.opacity(0.15)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L("Search tools…"), text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($isSearchFocused)
                        .onSubmit { activate(entries, at: highlighted) }
                        .onKeyPress(.downArrow) {
                            highlighted = min(highlighted + 1, max(entries.count - 1, 0))
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            highlighted = max(highlighted - 1, 0)
                            return .handled
                        }
                    Button(action: close) {
                        Text(verbatim: "esc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help(L("Close"))
                }
                .padding(14)

                Divider()

                if entries.isEmpty {
                    Text(L("No matching tools"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(24)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                    row(entry, isHighlighted: index == highlighted)
                                        .id(entry.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture { activate(entries, at: index) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 340)
                        .onChange(of: highlighted) { _, newValue in
                            if entries.indices.contains(newValue) {
                                proxy.scrollTo(entries[newValue].id)
                            }
                        }
                    }
                }
            }
            .frame(width: 540)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(.top, 72)
        }
        .onChange(of: query) { highlighted = 0 }
        .task {
            // A text field in the tool view keeps first responder unless it resigns first.
            NSApp.keyWindow?.makeFirstResponder(nil)
            await Task.yield()
            isSearchFocused = true
        }
    }

    private func row(_ entry: Entry, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbolName)
                .frame(width: 22)
                .foregroundStyle(isHighlighted ? Color.white : Color.accentColor)
            Text(entry.title)
            Spacer()
            Text(entry.subtitle)
                .font(.callout)
                .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isHighlighted ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 7))
    }

    private func activate(_ entries: [Entry], at index: Int) {
        guard entries.indices.contains(index) else { return }
        model.open(entries[index].destination)
    }

    private func close() {
        model.isCommandPaletteVisible = false
    }
}
