import OpenToolboxCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @State private var window = WindowModel()

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .frame(minWidth: 820, minHeight: 520)
        .overlay {
            if window.isCommandPaletteVisible {
                CommandPaletteView()
            }
        }
        .environment(window)
        .focusedSceneValue(\.windowModel, window)
        .background(
            WindowReader { nsWindow in
                window.window = nsWindow
                if nsWindow?.isKeyWindow == true { model.windowBecameKey(window) }
            })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let key = note.object as? NSWindow, key === window.window { model.windowBecameKey(window) }
        }
        .alert(
            L("Engine error"),
            isPresented: Binding(
                get: { model.engines.errorMessage != nil },
                set: { if !$0 { model.engines.errorMessage = nil } }
            ),
            presenting: model.engines.errorMessage
        ) { _ in
            Button(L("OK")) { model.engines.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onChange(of: updates.windowRequest) {
            if updates.takeWindowRequest() { openWindow(id: SoftwareUpdateWindow.id) }
        }
        .onAppear {
            model.register(window) { [openWindow] in openWindow(id: MainWindow.id) }
            let notice = updates.takeLaunchNotice()
            if updates.takeWindowRequest() || notice { openWindow(id: SoftwareUpdateWindow.id) }
        }
        .onDisappear { model.unregister(window) }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window

    var body: some View {
        List(selection: Binding(get: { window.selection }, set: { window.select($0) })) {
            Section {
                Label(L("Tool Catalog"), systemImage: "square.grid.2x2")
                    .tag(SidebarItem.catalog)
                Label(L("Engines"), systemImage: "shippingbox")
                    .tag(SidebarItem.engines)
            }
            ForEach(model.sidebarSections) { section in
                Section(section.category.localizedTitle) {
                    ForEach(section.tools) { tool in
                        SidebarToolRow(tool: tool)
                            .tag(SidebarItem.tool(tool.id))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        .sidebarBottomBar {
            Button {
                window.isCommandPaletteVisible = true
            } label: {
                HStack {
                    Image(systemName: "magnifyingglass")
                    Text(L("Quick Open"))
                    Spacer()
                    Text(verbatim: "⌘K").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }
}

private extension View {
    @ViewBuilder
    func sidebarBottomBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // safeAreaBar first ships in the macOS 26 SDK (Swift 6.2); Xcode 16 must still build this file.
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.hard, for: .bottom)
                .safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom, content: content)
        }
        #else
        safeAreaInset(edge: .bottom, content: content)
        #endif
    }
}

struct SidebarToolRow: View {
    @Environment(WindowModel.self) private var window
    let tool: ToolDescriptor

    var body: some View {
        HStack {
            Label(tool.localizedTitle, systemImage: tool.symbolName)
            Spacer(minLength: 4)
            if window.busyTools.contains(tool.id) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel(L("Working"))
            } else if window.finishedTools.contains(tool.id) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(L("Finished"))
            }
        }
    }
}

/// Shows the selected page. Tools opened in this window stay alive behind it, so switching
/// back finds them as they were left, with any running work still going.
struct DetailView: View {
    @Environment(WindowModel.self) private var window

    var body: some View {
        ZStack {
            ForEach(window.openedTools, id: \.self) { id in
                if let tool = ToolCatalog.tool(id) {
                    let isShown = window.selection == .tool(id)
                    ToolHostView(tool: tool)
                        .environment(\.toolActivity, ToolActivity(tool: tool, window: window))
                        .opacity(isShown ? 1 : 0)
                        .allowsHitTesting(isShown)
                        .disabled(!isShown)
                        .accessibilityHidden(!isShown)
                        .zIndex(isShown ? 1 : 0)
                }
            }
            page
        }
        .navigationTitle(title)
    }

    @ViewBuilder private var page: some View {
        switch window.selection {
        case .catalog:
            ToolCatalogView()
        case .engines:
            EngineManagerView()
        case .tool(let id):
            if ToolCatalog.tool(id) == nil {
                ContentUnavailableView(L("Tool not found"), systemImage: "questionmark.square.dashed")
            }
        case nil:
            ContentUnavailableView(
                L("Choose a tool"),
                systemImage: "wrench.and.screwdriver",
                description: Text(L("Pick a tool in the sidebar or press ⌘K to search."))
            )
        }
    }

    private var title: String {
        switch window.selection {
        case .catalog: L("Tool Catalog")
        case .engines: L("Engines")
        case .tool(let id): ToolCatalog.tool(id)?.localizedTitle ?? L("OpenToolbox")
        case nil: L("OpenToolbox")
        }
    }
}

/// Shows a tool's view, or explains what it still needs.
struct ToolHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let tool: ToolDescriptor

    var body: some View {
        let missing = model.engines.missingEngines(for: tool)
        if tool.availability == .planned {
            ContentUnavailableView(
                tool.localizedTitle,
                systemImage: tool.symbolName,
                description: Text(L("This tool is planned for a later OpenToolbox release."))
            )
        } else if !missing.isEmpty {
            ContentUnavailableView {
                Label(tool.localizedTitle, systemImage: tool.symbolName)
            } description: {
                Text(L("This tool needs \(missing.map(\.displayName).formatted(.list(type: .and))), which is downloaded on demand."))
            } actions: {
                Button(L("Open Engine Manager")) { window.open(.engines) }
            }
        } else {
            ToolViewRegistry.view(for: tool)
        }
    }
}

enum ToolViewRegistry {
    @MainActor @ViewBuilder
    static func view(for tool: ToolDescriptor) -> some View {
        switch tool.id {
        case "dev.json-formatter": JSONFormatterView(tool: tool)
        case "dev.base64-hex": Base64HexView(tool: tool)
        case "dev.hash": HashGeneratorView(tool: tool)
        case "dev.uuid": UUIDGeneratorView(tool: tool)
        case "dev.jwt": JWTDecoderView(tool: tool)
        case "dev.timestamp": TimestampConverterView(tool: tool)
        case "dev.diff": DiffCheckerView(tool: tool)
        case "dev.regex": RegexTesterView(tool: tool)
        case "dev.clean-links": CleanLinksView(tool: tool)
        case "dev.unicode": UnicodeInspectorView(tool: tool)
        case "dev.lorem": LoremIpsumView(tool: tool)
        case "dev.password": PasswordGeneratorView(tool: tool)
        case "dev.csv-json": CSVJSONView(tool: tool)
        case "text.word-counter": WordCounterView(tool: tool)
        case "text.case-converter": CaseConverterView(tool: tool)
        case "text.qr-code": QRCodeView(tool: tool)
        case "image.convert": ImageConvertView(tool: tool)
        case "image.strip-metadata": StripMetadataView(tool: tool)
        case "image.remove-background": RemoveBackgroundView(tool: tool)
        case "image.blur-faces": BlurFacesView(tool: tool)
        case "image.ocr": OCRView(tool: tool)
        case "pdf.organize": PDFOrganizeView(tool: tool)
        case "pdf.images": ImagesPDFView(tool: tool)
        case "image.watermark": WatermarkView(tool: tool)
        case "files.batch-rename": BatchRenameView(tool: tool)
        case "files.duplicates": FindDuplicatesView(tool: tool)
        case "mac.keep-awake": KeepAwakeView(tool: tool)
        case "mac.battery": BatteryHealthView(tool: tool)
        case "mac.network-speed": NetworkSpeedTestView(tool: tool)
        case "mac.disk-speed": DiskSpeedTestView(tool: tool)
        case "mac.eject": EjectDisksView(tool: tool)
        case "mac.quarantine": QuarantineHelperView(tool: tool)
        case "mac.hidden-settings": HiddenSettingsView(tool: tool)
        default:
            ContentUnavailableView(
                tool.localizedTitle,
                systemImage: tool.symbolName,
                description: Text(L("This tool is planned for a later OpenToolbox release."))
            )
        }
    }
}
