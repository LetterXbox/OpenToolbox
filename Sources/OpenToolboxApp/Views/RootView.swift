import OpenToolboxCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView(item: model.selection)
        }
        .frame(minWidth: 820, minHeight: 520)
        .overlay {
            if model.isCommandPaletteVisible {
                CommandPaletteView()
            }
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
            openWindow(id: SoftwareUpdateWindow.id)
        }
        .onAppear {
            if updates.takeLaunchNotice() { openWindow(id: SoftwareUpdateWindow.id) }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section {
                Label(L("Tool Catalog"), systemImage: "square.grid.2x2")
                    .tag(SidebarItem.catalog)
                Label(L("Engines"), systemImage: "shippingbox")
                    .tag(SidebarItem.engines)
            }
            ForEach(model.sidebarSections) { section in
                Section(section.category.localizedTitle) {
                    ForEach(section.tools) { tool in
                        Label(tool.localizedTitle, systemImage: tool.symbolName)
                            .tag(SidebarItem.tool(tool.id))
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        .sidebarBottomBar {
            Button {
                model.isCommandPaletteVisible = true
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

struct DetailView: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem?

    var body: some View {
        switch item {
        case .catalog:
            ToolCatalogView()
        case .engines:
            EngineManagerView()
        case .tool(let id):
            if let tool = ToolCatalog.tool(id) {
                ToolHostView(tool: tool)
                    .navigationTitle(tool.localizedTitle)
            } else {
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
}

/// Shows a tool's view, or explains what it still needs.
struct ToolHostView: View {
    @Environment(AppModel.self) private var model
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
                Button(L("Open Engine Manager")) { model.selection = .engines }
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
        case "files.batch-rename": BatchRenameView(tool: tool)
        case "files.duplicates": FindDuplicatesView(tool: tool)
        case "mac.keep-awake": KeepAwakeView(tool: tool)
        case "mac.battery": BatteryHealthView(tool: tool)
        case "mac.network-speed": NetworkSpeedTestView(tool: tool)
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
