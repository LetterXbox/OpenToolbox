import Foundation
import Observation
import OpenToolboxCore

enum SidebarItem: Hashable {
    case catalog
    case engines
    case tool(ToolID)
}

struct SidebarSection: Identifiable {
    let category: ToolCategory
    let tools: [ToolDescriptor]
    var id: ToolCategory { category }
}

@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? = .tool("dev.json-formatter")
    var isCommandPaletteVisible = false
    private(set) var preferences: ToolPreferences
    private(set) var outputBaseDirectory: URL
    let engines: EngineCenter

    private let defaults: UserDefaults
    private static let preferencesKey = "ToolPreferences"
    private static let outputDirectoryKey = "OutputBaseDirectory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.preferencesKey),
            let stored = try? JSONDecoder().decode(ToolPreferences.self, from: data)
        {
            preferences = stored
        } else {
            preferences = ToolPreferences()
        }
        if let path = defaults.string(forKey: Self.outputDirectoryKey) {
            outputBaseDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            outputBaseDirectory = OutputDirectory.defaultBaseDirectory()
        }
        engines = EngineCenter()
    }

    // MARK: Tools

    /// Tools shown in the sidebar and palette: implemented and enabled.
    var activeTools: [ToolDescriptor] {
        ToolCatalog.all.filter { $0.availability == .available && preferences.isEnabled($0) }
    }

    var sidebarSections: [SidebarSection] {
        let active = activeTools
        return ToolCategory.allCases.compactMap { category in
            let tools = ToolCatalog.tools(in: category, from: active)
            return tools.isEmpty ? nil : SidebarSection(category: category, tools: tools)
        }
    }

    func isEnabled(_ tool: ToolDescriptor) -> Bool {
        preferences.isEnabled(tool)
    }

    func setEnabled(_ enabled: Bool, for tool: ToolDescriptor) {
        preferences.setEnabled(enabled, for: tool)
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: Self.preferencesKey)
        }
        if !enabled, selection == .tool(tool.id) {
            selection = .catalog
        }
    }

    func open(_ item: SidebarItem) {
        selection = item
        isCommandPaletteVisible = false
    }

    // MARK: Output

    var outputDirectory: OutputDirectory {
        OutputDirectory(baseDirectory: outputBaseDirectory)
    }

    func setOutputBaseDirectory(_ url: URL?) {
        if let url {
            outputBaseDirectory = url
            defaults.set(url.path, forKey: Self.outputDirectoryKey)
        } else {
            outputBaseDirectory = OutputDirectory.defaultBaseDirectory()
            defaults.removeObject(forKey: Self.outputDirectoryKey)
        }
    }
}
