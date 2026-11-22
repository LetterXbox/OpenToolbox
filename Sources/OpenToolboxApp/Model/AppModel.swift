import AppKit
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
    private(set) var preferences: ToolPreferences
    private(set) var outputBaseDirectory: URL
    let engines: EngineCenter

    private let defaults: UserDefaults
    private static let preferencesKey = "ToolPreferences"
    private static let outputDirectoryKey = "OutputBaseDirectory"
    private static let menuBarKey = "ShowsMenuBarExtra"
    private static let hotKeyKey = "QuickOpenHotKey"

    /// Shows the OpenToolbox menu in the menu bar. While it is on, closing the last window
    /// keeps OpenToolbox running there.
    var showsMenuBarExtra: Bool {
        didSet {
            defaults.set(showsMenuBarExtra, forKey: Self.menuBarKey)
            updateActivationPolicy()
        }
    }

    /// Opens Quick Open from any app with ⌃⌥K.
    var usesQuickOpenHotKey: Bool {
        didSet {
            defaults.set(usesQuickOpenHotKey, forKey: Self.hotKeyKey)
            applyHotKey()
        }
    }

    private(set) var hotKeyUnavailable = false
    let loginItem = LoginItem()

    @ObservationIgnored private var windows: [ObjectIdentifier: WindowModel] = [:]
    @ObservationIgnored private weak var activeWindow: WindowModel?
    @ObservationIgnored private var pendingItem: SidebarItem?
    @ObservationIgnored private var pendingPalette = false
    @ObservationIgnored private var openMainWindow: (() -> Void)?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private let notifier = ToolNotifier()

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
        showsMenuBarExtra = defaults.bool(forKey: Self.menuBarKey)
        usesQuickOpenHotKey = defaults.bool(forKey: Self.hotKeyKey)
    }

    /// Starts the parts that talk to the system once the app has finished launching.
    func start() {
        notifier.onOpen = { [weak self] id in self?.show(.tool(id)) }
        notifier.start()
        loginItem.refresh()
        applyHotKey()
        updateActivationPolicy()
    }

    // MARK: Windows

    func register(_ window: WindowModel, openWindow: @escaping () -> Void) {
        openMainWindow = openWindow
        window.onFinish = { [weak self] tool in self?.notifier.announce(tool) }
        windows[ObjectIdentifier(window)] = window
        if activeWindow == nil { activeWindow = window }
        if let item = pendingItem {
            window.open(item)
            pendingItem = nil
        }
        if pendingPalette {
            window.isCommandPaletteVisible = true
            pendingPalette = false
        }
        updateActivationPolicy()
    }

    func unregister(_ window: WindowModel) {
        windows[ObjectIdentifier(window)] = nil
        if activeWindow === window { activeWindow = windows.values.first }
        updateActivationPolicy()
    }

    func windowBecameKey(_ window: WindowModel) {
        activeWindow = window
    }

    var hasOpenWindow: Bool { !windows.isEmpty }

    /// The window that was last in front, or `nil` when every window is closed.
    private var frontWindow: WindowModel? {
        if let activeWindow, windows[ObjectIdentifier(activeWindow)] != nil { return activeWindow }
        return windows.values.first
    }

    /// Brings a window forward, opening one if none is open.
    func showWindow() {
        NSApp.activate()
        if let window = frontWindow?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    /// Shows a tool or page in the front window, opening one if none is open.
    func show(_ item: SidebarItem) {
        if let window = frontWindow {
            window.open(item)
        } else {
            pendingItem = item
        }
        showWindow()
    }

    func showQuickOpen() {
        if let window = frontWindow {
            window.isCommandPaletteVisible = true
        } else {
            pendingPalette = true
        }
        showWindow()
    }

    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = windows.isEmpty && showsMenuBarExtra ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func applyHotKey() {
        if usesQuickOpenHotKey {
            let hotKey = hotKey ?? GlobalHotKey { [weak self] in self?.showQuickOpen() }
            self.hotKey = hotKey
            hotKeyUnavailable = !hotKey.register()
        } else {
            hotKey?.unregister()
            hotKeyUnavailable = false
        }
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
        if !enabled {
            for window in windows.values { window.close(tool.id) }
        }
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
