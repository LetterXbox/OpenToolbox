import AppKit
import Observation
import OpenToolboxCore
import SwiftUI

/// State that belongs to one OpenToolbox window: what it shows, its Quick Open palette,
/// and the tools it keeps open in the background.
@MainActor
@Observable
final class WindowModel {
    let id = UUID()
    private(set) var selection: SidebarItem?
    var isCommandPaletteVisible = false
    /// Tools opened in this window, kept alive in that order so switching away keeps their state.
    private(set) var openedTools: [ToolID] = []
    private(set) var busyTools: Set<ToolID> = []
    /// Tools whose work finished while they weren't in front of the user.
    private(set) var finishedTools: Set<ToolID> = []
    /// The last Batch Rename in this window that can be undone, and the files it needs access to.
    var renameUndo: (journal: RenameUndoJournal, scopes: [URL])?
    @ObservationIgnored weak var window: NSWindow?
    /// Called when a tool finishes work while it isn't in front of the user.
    @ObservationIgnored var onFinish: (ToolDescriptor, WindowModel) -> Void = { _, _ in }

    init(selection: SidebarItem? = .tool("dev.json-formatter")) {
        select(selection)
    }

    func select(_ item: SidebarItem?) {
        selection = item
        if case .tool(let id) = item {
            if !openedTools.contains(id) { openedTools.append(id) }
            finishedTools.remove(id)
        }
    }

    func open(_ item: SidebarItem) {
        select(item)
        isCommandPaletteVisible = false
    }

    /// Stops keeping a tool alive, for example after it is disabled.
    func close(_ id: ToolID) {
        openedTools.removeAll { $0 == id }
        busyTools.remove(id)
        finishedTools.remove(id)
        if selection == .tool(id) { selection = .catalog }
    }

    var isInFront: Bool {
        NSApp.isActive && (window?.isKeyWindow ?? false)
    }

    func setBusy(_ busy: Bool, for tool: ToolDescriptor) {
        if busy {
            busyTools.insert(tool.id)
            return
        }
        guard busyTools.remove(tool.id) != nil else { return }
        guard !(selection == .tool(tool.id) && isInFront) else { return }
        finishedTools.insert(tool.id)
        onFinish(tool, self)
    }

    func cameToFront() {
        if case .tool(let id) = selection { finishedTools.remove(id) }
    }
}

/// Lets a tool view tell its window when it starts and stops long-running work.
struct ToolActivity: Sendable {
    let tool: ToolDescriptor
    let window: WindowModel

    @MainActor func report(_ busy: Bool) {
        window.setBusy(busy, for: tool)
    }
}

extension EnvironmentValues {
    @Entry var toolActivity: ToolActivity? = nil
}

struct WindowModelKey: FocusedValueKey {
    typealias Value = WindowModel
}

extension FocusedValues {
    var windowModel: WindowModel? {
        get { self[WindowModelKey.self] }
        set { self[WindowModelKey.self] = newValue }
    }
}

extension View {
    /// Shows the tool as working in the sidebar while `busy` is true, and announces when it finishes
    /// if the tool is no longer in front.
    func reportsActivity(_ busy: Bool) -> some View {
        modifier(ActivityReporter(busy: busy))
    }
}

private struct ActivityReporter: ViewModifier {
    @Environment(\.toolActivity) private var activity
    let busy: Bool

    func body(content: Content) -> some View {
        content.onChange(of: busy, initial: true) { _, isBusy in
            activity?.report(isBusy)
        }
    }
}

/// Gives a SwiftUI view its hosting `NSWindow`.
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange?(window)
        }
    }
}
