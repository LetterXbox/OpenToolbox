import OpenToolboxCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateCenter.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @State private var window = WindowModel()

    private struct PresentedEngineError {
        let ids: Set<UUID>
        let message: String
    }

    private var presentedError: PresentedEngineError? {
        guard let message = model.engines.errorMessage else { return nil }
        return PresentedEngineError(ids: model.engines.activeErrorIDs, message: message)
    }

    var body: some View {
        let currentAlert = presentedError
        NavigationSplitView {
            SidebarView()
        } detail: {
            DetailView()
        }
        .toolbar {
            ToolbarItem {
                Button {
                    window.isCommandPaletteVisible = true
                } label: {
                    Label(L("Quick Open"), systemImage: "magnifyingglass")
                }
                .help(L("Quick Open…"))
            }
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
                get: { currentAlert != nil },
                set: {
                    if !$0, let ids = currentAlert?.ids {
                        model.engines.dismissErrors(ids: ids)
                    }
                }
            ),
            presenting: currentAlert
        ) { presented in
            Button(L("OK")) { model.engines.dismissErrors(ids: presented.ids) }
        } message: { presented in
            Text(presented.message)
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

    private var hasActiveTool: Bool {
        if case .tool(let id) = window.selection {
            return ToolCatalog.tool(id) != nil && window.openedTools.contains(id)
        }
        return false
    }

    var body: some View {
        DetailDeckLayout {
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
                        .layoutValue(key: DetailPageActiveKey.self, value: isShown)
                        .layoutValue(key: DetailPageIDKey.self, value: .tool(id))
                }
            }
            if !hasActiveTool {
                page
                    .zIndex(1)
                    .layoutValue(key: DetailPageActiveKey.self, value: true)
                    .layoutValue(key: DetailPageIDKey.self, value: window.selection)
            }
        }
        .clipped()
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

private struct DetailPageActiveKey: LayoutValueKey {
    static let defaultValue = false
}

private struct DetailPageIDKey: LayoutValueKey {
    static let defaultValue: SidebarItem? = nil
}

private struct DetailDeckLayout: Layout {
    struct Cache {
        var frozenSizes: [SidebarItem: CGSize] = [:]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        let liveIDs = Set(subviews.compactMap { $0[DetailPageIDKey.self] })
        cache.frozenSizes = cache.frozenSizes.filter { liveIDs.contains($0.key) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if let width = proposal.width, let height = proposal.height,
            width > 0, height > 0, width.isFinite, height.isFinite
        {
            return CGSize(width: width, height: height)
        }
        if let active = subviews.first(where: { $0[DetailPageActiveKey.self] }) {
            return active.sizeThatFits(proposal)
        }
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let activeSize = bounds.size
        let hasValidSize = activeSize.width > 0 && activeSize.height > 0
        for subview in subviews {
            let id = subview[DetailPageIDKey.self]
            if subview[DetailPageActiveKey.self] {
                if let id, hasValidSize { cache.frozenSizes[id] = activeSize }
                subview.place(at: bounds.origin, proposal: ProposedViewSize(activeSize))
            } else {
                let frozen = id.flatMap { cache.frozenSizes[$0] } ?? activeSize
                if let id, cache.frozenSizes[id] == nil, hasValidSize {
                    cache.frozenSizes[id] = frozen
                }
                subview.place(at: bounds.origin, proposal: ProposedViewSize(frozen))
            }
        }
    }
}

struct ToolHostView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let tool: ToolDescriptor

    var body: some View {
        let missing = model.engines.missingEngines(for: tool)
        let installing = missing.filter { model.engines.isInstalling($0.id) }
        let downloadable = model.engines.downloadableMissingEngines(for: [tool])
        if tool.availability == .planned {
            ContentUnavailableView(
                tool.localizedTitle,
                systemImage: tool.symbolName,
                description: Text(L("This tool is planned for a later OpenToolbox release."))
            )
        } else if !model.engines.allEnginesInstalled(for: tool) {
            let names = (missing.isEmpty ? tool.requiredEngines : missing.map(\.displayName)).formatted(.list(type: .and))
            ContentUnavailableView {
                Label(tool.localizedTitle, systemImage: tool.symbolName)
            } description: {
                VStack(spacing: 10) {
                    if let storeError = model.engines.storeErrorMessage {
                        Text(storeError)
                    } else if !installing.isEmpty {
                        let installingNames = installing.map(\.displayName).formatted(.list(type: .and))
                        Text(L("Downloading \(installingNames)…"))
                        if let fraction = model.engines.downloadProgress(for: tool) {
                            ProgressView(value: fraction)
                                .frame(maxWidth: 260)
                        }
                    } else {
                        Text(L("This tool needs \(names), which is downloaded on demand."))
                    }
                }
            } actions: {
                if !downloadable.isEmpty {
                    let size = model.engines.downloadSize(of: downloadable).formatted(.byteCount(style: .file))
                    let downloadNames = downloadable.map(\.displayName).formatted(.list(type: .and))
                    Button(L("Download \(downloadNames) (\(size))")) {
                        model.engines.install(downloadable)
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !installing.isEmpty {
                    Button(L("Cancel")) {
                        for manifest in installing {
                            model.engines.cancelInstall(manifest.id)
                        }
                    }
                }
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
        case "image.compress": CompressImagesView(tool: tool)
        case "pdf.password": PDFPasswordView(tool: tool)
        case "pdf.crop": CropPDFView(tool: tool)
        case "dev.color-picker": ColorPickerView(tool: tool)
        case "dev.coordinates": CoordinatePickerView(tool: tool)
        case "mac.wifi": WiFiPasswordView(tool: tool)
        case "mac.permissions": ResetPermissionsView(tool: tool)
        case "text.translate": TranslateView(tool: tool)
        case "text.speech": TextToSpeechView(tool: tool)
        case "text.transcribe": TranscribeView(tool: tool)
        case "text.summarize": SummarizeView(tool: tool)
        case "media.record-screen": RecordScreenView(tool: tool)
        case "media.record-audio": RecordAudioView(tool: tool)
        case "media.trim-audio": TrimAudioView(tool: tool)
        case "media.frames": ExtractFramesView(tool: tool)
        case "pdf.forms": PDFFormsView(tool: tool)
        case "pdf.scan": ScanDocumentView(tool: tool)
        case "pdf.web": WebPageToPDFView(tool: tool)
        case "pdf.compress": CompressPDFView(tool: tool)
        case "pdf.markdown": MarkdownToPDFView(tool: tool)
        case "pdf.word": OfficeToPDFView(tool: tool, kind: .word)
        case "pdf.powerpoint": OfficeToPDFView(tool: tool, kind: .powerpoint)
        case "pdf.excel": OfficeToPDFView(tool: tool, kind: .excel)
        case "docs.convert": ConvertDocumentsView(tool: tool)
        case "files.archive": ArchiveToolView(tool: tool)
        case "files.batch-rename": BatchRenameView(tool: tool)
        case "files.duplicates": FindDuplicatesView(tool: tool)
        case "media.compress-video": CompressVideoView(tool: tool)
        case "media.convert": ConvertVideoView(tool: tool)
        case "media.resize-video": ResizeVideoView(tool: tool)
        case "media.crop-rotate-video": CropRotateVideoView(tool: tool)
        case "media.trim-video": TrimVideoView(tool: tool)
        case "media.merge-videos": MergeVideosView(tool: tool)
        case "media.mute-video": MuteVideoView(tool: tool)
        case "media.replace-audio": ReplaceAudioView(tool: tool)
        case "media.change-speed": ChangeVideoSpeedView(tool: tool)
        case "media.video-to-gif": VideoToGIFView(tool: tool)
        case "media.burn-subtitles": BurnSubtitlesView(tool: tool)
        case "media.info": MediaInfoView(tool: tool)
        case "media.convert-audio": ConvertAudioView(tool: tool)
        case "media.extract-audio": ExtractAudioView(tool: tool)
        case "media.clean-audio": CleanAudioView(tool: tool)
        case "media.download": DownloadVideoView(tool: tool)
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
