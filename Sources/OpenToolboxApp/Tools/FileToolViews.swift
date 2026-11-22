import AppKit
import Observation
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

struct BatchRenameView: View {
    let tool: ToolDescriptor

    @Environment(AppModel.self) private var model
    @State private var files: [URL] = []
    @State private var rules: [RenameRuleEditor] = [.init(kind: .template)]
    @State private var mode: Mode = .copy
    @State private var selectingFiles = false
    @State private var confirmingRename = false
    @State private var selectedFile: URL?
    @State private var preview: [RenamePlanItem] = []
    @State private var previewRequest: PreviewRequest?
    @State private var previewError: String?
    @State private var operationError: String?
    @State private var result: RenameResult?
    @State private var resultTitle = ""
    @State private var revision = 0

    private let session = FileToolSession.shared

    private enum Mode: Hashable { case copy, inPlace }

    private struct PreviewRequest: Equatable, Sendable {
        let files: [URL]
        let rules: [RenameRule]
        let copyDirectory: URL?
        let revision: Int
    }

    private var request: PreviewRequest {
        PreviewRequest(
            files: files,
            rules: rules.map(\.rule),
            copyDirectory: mode == .copy ? model.outputDirectory.batchRenameDirectory() : nil,
            revision: revision
        )
    }

    private var applicableCount: Int {
        preview.count(where: { $0.conflict == nil && (mode == .copy || $0.changesName) })
    }

    private var canApply: Bool {
        !session.isRenaming && !session.isRecycling && previewRequest == request && applicableCount > 0
    }

    var body: some View {
        let request = self.request
        ToolPage(tool: tool) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Pane(L("Files"), accessory: {
                        Button(L("Choose Files…")) { selectingFiles = true }
                    }) {
                        filePreview
                        if !files.isEmpty {
                            fileControls
                        }
                    }

                    Pane(L("Rules"), accessory: {
                        Menu(L("Add Rule")) {
                            ForEach(RenameRuleEditor.Kind.allCases) { kind in
                                Button(kind.title) { rules.append(.init(kind: kind)) }
                            }
                        }
                        .fixedSize()
                    }) {
                        ruleRows
                    }

                    Pane(L("Apply")) {
                        applyControls
                        if let directory = request.copyDirectory {
                            Text(directory.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let previewError { ErrorMessage(text: previewError) }
                        if let operationError { ErrorMessage(text: operationError) }
                        if let result { resultSummary(result) }
                    }
                }
            }
        }
        .fileImporter(isPresented: $selectingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            switch $0 {
            case .success(let urls): addFiles(urls)
            case .failure(let error): operationError = error.localizedDescription
            }
        }
        .task(id: request) { await updatePreview(request) }
        .confirmationDialog(L("Rename files in place?"), isPresented: $confirmingRename) {
            Button(L("Rename \(applicableCount) Files")) { apply() }
                .disabled(!canApply)
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This changes the names of the original files in their current folders."))
        }
    }

    private var filePreview: some View {
        Group {
            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc").font(.title)
                    Text(L("Drop files here"))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                Table(preview, selection: $selectedFile) {
                    TableColumn(L("Current name")) { (item: RenamePlanItem) in
                        Text(item.source.lastPathComponent)
                            .truncationMode(.middle)
                            .help(item.source.path)
                    }
                    TableColumn(L("New name")) { (item: RenamePlanItem) in
                        Text(item.newName)
                            .truncationMode(.middle)
                            .help(item.newName)
                    }
                    TableColumn(L("Status")) { (item: RenamePlanItem) in
                        if let conflict = item.conflict {
                            Badge(text: conflict.localizedDescription, tint: .orange)
                                .help(conflict.localizedDescription)
                        } else if mode == .inPlace, !item.changesName {
                            Badge(text: L("Same name"), tint: .secondary)
                        }
                    }
                }
                .frame(height: 220)
                .opacity(previewRequest == request ? 1 : 0.55)
                .overlay(alignment: .bottomTrailing) {
                    if previewRequest != request, previewError == nil {
                        ProgressView().controlSize(.small).padding(8)
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter { $0.isFileURL }
            guard !fileURLs.isEmpty else { return false }
            addFiles(fileURLs)
            return true
        }
    }

    private var fileControls: some View {
        HStack {
            Text(L("\(files.count) files"))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                moveSelectedFile(by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .help(L("Move File Up"))
            .accessibilityLabel(L("Move File Up"))
            .disabled(selectedFileIndex.map { $0 == 0 } ?? true)
            Button {
                moveSelectedFile(by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .help(L("Move File Down"))
            .accessibilityLabel(L("Move File Down"))
            .disabled(selectedFileIndex.map { $0 + 1 == files.count } ?? true)
            Button(L("Remove")) {
                if let index = selectedFileIndex { files.remove(at: index) }
                selectedFile = nil
            }
            .disabled(selectedFileIndex == nil)
            Button(L("Clear")) {
                files.removeAll()
                selectedFile = nil
            }
        }
    }

    private var selectedFileIndex: Int? {
        guard let selectedFile else { return nil }
        return files.firstIndex(of: selectedFile)
    }

    private func moveSelectedFile(by offset: Int) {
        guard let index = selectedFileIndex, files.indices.contains(index + offset) else { return }
        files.swapAt(index, index + offset)
    }

    private var ruleRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rules.isEmpty {
                Text(L("Add a rule to change the file names."))
                    .foregroundStyle(.secondary)
            }
            ForEach($rules) { $rule in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(rule.kind.title).fontWeight(.medium)
                        Spacer()
                        ruleButton("arrow.up", label: L("Move Rule Up"), id: rule.id, offset: -1)
                        ruleButton("arrow.down", label: L("Move Rule Down"), id: rule.id, offset: 1)
                        Button {
                            rules.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .help(L("Remove Rule"))
                        .accessibilityLabel(L("Remove Rule"))
                    }
                    ruleEditor($rule)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func ruleButton(_ symbol: String, label: String, id: UUID, offset: Int) -> some View {
        let index = rules.firstIndex { $0.id == id }
        return Button {
            if let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) {
                rules.swapAt(index, index + offset)
            }
        } label: {
            Image(systemName: symbol)
        }
        .help(label)
        .accessibilityLabel(label)
        .disabled(index.map { !rules.indices.contains($0 + offset) } ?? true)
    }

    @ViewBuilder
    private func ruleEditor(_ rule: Binding<RenameRuleEditor>) -> some View {
        switch rule.wrappedValue.kind {
        case .template:
            TextField(L("Name template"), text: rule.pattern)
                .textFieldStyle(.roundedBorder)
            Text(L("{name}, {ext}, {n}, {n:3}, {date}, {parent}. Use .{ext} to insert the original suffix explicitly."))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(L("Start"), value: rule.start, format: .number)
                TextField(L("Step"), value: rule.step, format: .number)
            }
            .textFieldStyle(.roundedBorder)
        case .replace:
            HStack {
                TextField(L("Find"), text: rule.pattern)
                TextField(L("Replace with"), text: rule.replacement)
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Toggle(L("Regular expression"), isOn: rule.regex)
                Toggle(L("Ignore case"), isOn: rule.caseInsensitive)
            }
        case .letterCase:
            Picker(L("Case"), selection: rule.letterCase) {
                Text(L("Lowercase")).tag(RenameCase.lower)
                Text(L("Uppercase")).tag(RenameCase.upper)
                Text(L("Title Case")).tag(RenameCase.title)
            }
            .pickerStyle(.segmented)
        case .trim:
            EmptyView()
        case .extensionChange:
            TextField(L("New extension, or blank to remove it"), text: rule.pattern)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var applyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Mode"), selection: $mode) {
                Text(L("Copy with new names")).tag(Mode.copy)
                Text(L("Rename in place")).tag(Mode.inPlace)
            }
            .pickerStyle(.segmented)
            HStack {
                Button(mode == .copy ? L("Copy with New Names") : L("Rename in Place…")) {
                    if mode == .copy { apply() }
                    else { confirmingRename = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)
                Button(L("Undo Last Rename")) { undo() }
                    .disabled(session.undoJournal == nil || session.isRenaming || session.isRecycling)
                if session.isRenaming { ProgressView().controlSize(.small) }
            }
        }
    }

    private func resultSummary(_ result: RenameResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(resultTitle)
                .font(.headline)
            if result.skipped > 0 {
                Text(L("\(result.skipped) skipped")).foregroundStyle(.secondary)
            }
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                ErrorMessage(text: L("\(issue.file.lastPathComponent): \(issue.message)"))
            }
            if !result.completed.isEmpty {
                CopyButton(text: result.completed.map(\.path).joined(separator: "\n"), label: L("Copy Result Paths"))
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        var known = Set(files.map { $0.standardizedFileURL })
        files += urls.filter { $0.isFileURL && known.insert($0.standardizedFileURL).inserted }
    }

    private func updatePreview(_ request: PreviewRequest) async {
        previewError = nil
        let worker = Task.detached(priority: .userInitiated) {
            try await Task.sleep(for: .milliseconds(120))
            return try withFileToolAccess(request.files) {
                try BatchRename.plan(sources: request.files, rules: request.rules, copyDirectory: request.copyDirectory)
            }
        }

        do {
            let preview = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, self.request == request else { return }
            self.preview = preview
            previewRequest = request
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.request == request else { return }
            preview = []
            previewRequest = nil
            previewError = error.localizedDescription
        }
    }

    private func apply() {
        guard canApply else { return }
        let request = self.request
        let plan = self.preview
        let copying = request.copyDirectory != nil
        session.isRenaming = true
        result = nil
        operationError = nil
        Task {
            defer {
                session.isRenaming = false
                revision += 1
            }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try withFileToolAccess(request.files) {
                        if let directory = request.copyDirectory {
                            return try BatchRename.copy(plan, to: directory)
                        }
                        return BatchRename.renameInPlace(plan)
                    }
                }.value

                if let journal = result.undoJournal {
                    session.undoJournal = journal
                    session.undoScopes = request.files
                }
                if !copying {
                    let finished = Set(result.completed)
                    let previous = Set(plan.filter { $0.destination.map { finished.contains($0) } ?? false }.map(\.source))
                    files.removeAll { previous.contains($0) }
                    if let selectedFile, previous.contains(selectedFile) { self.selectedFile = nil }
                }
                resultTitle = copying ? L("Copied \(result.completed.count) files") : L("Renamed \(result.completed.count) files")
                self.result = result
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    private func undo() {
        guard let journal = session.undoJournal, !session.isRenaming, !session.isRecycling else { return }
        let scopes = session.undoScopes
        session.isRenaming = true
        result = nil
        operationError = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                withFileToolAccess(scopes) { BatchRename.undo(journal) }
            }.value
            session.undoJournal = result.undoJournal
            if result.undoJournal == nil { session.undoScopes = [] }
            resultTitle = L("Restored \(result.completed.count) names")
            self.result = result
            revision += 1
            session.isRenaming = false
        }
    }
}

private struct RenameRuleEditor: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case template, replace, letterCase, trim, extensionChange

        var id: String { rawValue }
        var title: String {
            switch self {
            case .template: L("Name Template")
            case .replace: L("Find & Replace")
            case .letterCase: L("Change Case")
            case .trim: L("Trim Whitespace")
            case .extensionChange: L("Change Extension")
            }
        }
    }

    let id = UUID()
    let kind: Kind
    var pattern = ""
    var replacement = ""
    var start = 1
    var step = 1
    var regex = false
    var caseInsensitive = false
    var letterCase: RenameCase = .lower

    init(kind: Kind) {
        self.kind = kind
        if kind == .template { pattern = "{name}" }
    }

    var rule: RenameRule {
        switch kind {
        case .template: .template(pattern, start: start, step: step)
        case .replace: .replace(pattern, with: replacement, regex: regex, caseInsensitive: caseInsensitive)
        case .letterCase: .changeCase(letterCase)
        case .trim: .trimWhitespace
        case .extensionChange: .setExtension(pattern)
        }
    }
}

struct FindDuplicatesView: View {
    let tool: ToolDescriptor

    @State private var folders: [URL] = []
    @State private var selectingFolders = false
    @State private var includeHidden = false
    @State private var minimumSize: Int64 = 1
    @State private var progress = DuplicateScanProgress()
    @State private var scanTask: Task<Void, Never>?
    @State private var groups: [DuplicateGroup] = []
    @State private var selected: Set<URL> = []
    @State private var confirmingTrash = false
    @State private var trashOutcomes: [DuplicateTrashOutcome] = []
    @State private var filesNeedingRescan: Set<URL> = []
    @State private var status: String?
    @State private var errorMessage: String?

    private let session = FileToolSession.shared

    var body: some View {
        ToolPage(tool: tool) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Pane(L("Folders"), accessory: {
                        Button(L("Choose Folders…")) { selectingFolders = true }
                            .disabled(scanTask != nil || session.isRecycling)
                    }) {
                        folderList
                    }
                    scanControls
                    if let status { Text(status).foregroundStyle(.secondary) }
                    if let errorMessage { ErrorMessage(text: errorMessage) }
                    if !groups.isEmpty { results }
                    if !trashOutcomes.isEmpty { trashReport }
                }
            }
        }
        .fileImporter(isPresented: $selectingFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) {
            switch $0 {
            case .success(let urls):
                var known = Set(folders.map { $0.standardizedFileURL })
                folders += urls.filter { known.insert($0.standardizedFileURL).inserted }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(L("Move selected files to Trash?"), isPresented: $confirmingTrash) {
            Button(L("Move \(selected.count) Files to Trash"), role: .destructive) { moveToTrash() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Before each move, OpenToolbox checks that an unselected copy is unchanged."))
        }
        .onChange(of: folders) { clearScan() }
        .onChange(of: includeHidden) { clearScan() }
        .onChange(of: minimumSize) { clearScan() }
        .onDisappear { scanTask?.cancel() }
    }

    private var folderList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if folders.isEmpty {
                Text(L("Choose one or more folders to scan.")).foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                HStack {
                    Label(folder.path, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(folder.path)
                    Spacer()
                    Button {
                        folders.removeAll { $0 == folder }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Remove Folder"))
                    .accessibilityLabel(L("Remove Folder"))
                    .disabled(scanTask != nil || session.isRecycling)
                }
            }
        }
    }

    private var scanControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(L("Include hidden files"), isOn: $includeHidden)
                Spacer()
                TextField(L("Minimum size (bytes)"), value: $minimumSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 230)
            }
            .disabled(scanTask != nil || session.isRecycling)
            HStack(spacing: 10) {
                if let scanTask {
                    Button(L("Cancel")) { scanTask.cancel() }
                    ProgressView().controlSize(.small)
                    Text(L("\(progress.filesScanned) files scanned · \(progress.bytesHashed.formatted(.byteCount(style: .file))) hashed"))
                        .foregroundStyle(.secondary)
                } else {
                    Button(L("Scan")) { scan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(folders.isEmpty || session.isRecycling)
                    if progress.unreadableEntries > 0 {
                        Text(L("\(progress.unreadableEntries) items could not be read"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var results: some View {
        let reclaimable = groups.reduce(Int64(0)) { total, group in
            let count = group.files.count(where: { !filesNeedingRescan.contains($0.url) })
            return total + Int64(max(0, count - 1)) * (group.files.first?.size ?? 0)
        }
        return Pane(L("Duplicate Groups"), accessory: {
            Button(L("Move to Trash…")) { confirmingTrash = true }
                .disabled(selected.isEmpty || session.isRecycling || session.isRenaming)
        }) {
            Text(L("\(reclaimable.formatted(.byteCount(style: .file))) reclaimable"))
                .foregroundStyle(.secondary)
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(groups) { group in
                    groupCard(group)
                }
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        let selectedCount = group.files.count(where: { selected.contains($0.url) })
        let eligibleCount = group.files.count(where: { !filesNeedingRescan.contains($0.url) })
        return VStack(alignment: .leading, spacing: 8) {
            Text(eligibleCount == group.files.count
                ? L("\(group.files.count) copies · \(group.wastedBytes.formatted(.byteCount(style: .file))) reclaimable")
                : L("Scan again to update this group."))
                .font(.headline)
            ForEach(group.files) { file in
                let isSelected = selected.contains(file.url)
                let needsRescan = filesNeedingRescan.contains(file.url)
                HStack(spacing: 8) {
                    Toggle(isOn: Binding(
                        get: { selected.contains(file.url) },
                        set: { value in
                            if value {
                                let remaining = group.files.count {
                                    !selected.contains($0.url) && !filesNeedingRescan.contains($0.url)
                                }
                                if !filesNeedingRescan.contains(file.url) && remaining > 1 {
                                    selected.insert(file.url)
                                }
                            } else {
                                selected.remove(file.url)
                            }
                        }
                    )) {
                        Text(file.url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(file.url.path)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(session.isRecycling || needsRescan || (!isSelected && eligibleCount - selectedCount <= 1))
                    Spacer(minLength: 8)
                    Text(needsRescan ? L("Scan again") : file.modificationDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    InlineCopyButton(text: file.url.path)
                    Button {
                        reveal(file)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .disabled(needsRescan)
                    .help(L("Reveal in Finder"))
                    .accessibilityLabel(L("Reveal in Finder"))
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    private var trashReport: some View {
        Pane(L("Last Trash Results")) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(trashOutcomes) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.original.path)
                        Text(trashMessage(outcome.disposition))
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func trashMessage(_ disposition: DuplicateTrashOutcome.Disposition) -> String {
        switch disposition {
        case .trashed(let destination):
            L("Moved to Trash at “\(destination.path)”.")
        case .restored(let destination, let reason):
            L("Restored to “\(destination.path)”. \(reason)")
        case .uncertain(let reason):
            reason
        case .skipped(let reason):
            L("Skipped. \(reason)")
        }
    }

    private func scan() {
        guard scanTask == nil, !session.isRecycling else { return }
        let folders = self.folders
        let options = DuplicateScanOptions(includeHidden: includeHidden, minimumSize: minimumSize)
        let (updates, continuation) = AsyncStream<DuplicateScanProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        clearScan()
        scanTask = Task {
            let scopes = beginFileToolAccess(folders)
            let displayProgress = Task {
                for await update in updates {
                    progress = update
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer {
                continuation.finish()
                endFileToolAccess(scopes)
                scanTask = nil
            }
            do {
                groups = try await DuplicateScanner.scan(folders: folders, options: options) {
                    continuation.yield($0)
                }
                if groups.isEmpty { status = L("No duplicates found.") }
            } catch is CancellationError {
                status = L("Scan canceled.")
            } catch {
                errorMessage = error.localizedDescription
            }
            continuation.finish()
            await displayProgress.value
        }
    }

    private func clearScan() {
        progress = DuplicateScanProgress()
        groups = []
        selected = []
        filesNeedingRescan = []
        status = nil
        errorMessage = nil
    }

    private func reveal(_ file: DuplicateFile) {
        withFileToolAccess(folders) {
            if file.isUnchanged() {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } else {
                errorMessage = L("This file changed after the scan.")
            }
        }
    }

    private func moveToTrash() {
        guard !session.isRecycling, !session.isRenaming, scanTask == nil, !selected.isEmpty else { return }
        session.isRecycling = true
        errorMessage = nil
        status = nil
        trashOutcomes = []
        let requested = selected
        let groups = self.groups
        let folders = self.folders
        Task {
            defer { session.isRecycling = false }
            let result = await Task.detached(priority: .userInitiated) {
                withFileToolAccess(folders) { DuplicateScanner.trashSelected(requested, in: groups) }
            }.value
            let removed = result.removedFromResults
            self.groups = groups.compactMap { $0.removingFiles(at: removed) }
            selected.subtract(requested)
            trashOutcomes = result.outcomes
            for outcome in result.outcomes where !removed.contains(outcome.original) {
                switch outcome.disposition {
                case .restored, .uncertain:
                    filesNeedingRescan.insert(outcome.original)
                case .trashed, .skipped:
                    break
                }
            }
        }
    }
}

@MainActor
@Observable
private final class FileToolSession {
    static let shared = FileToolSession()

    var isRenaming = false
    var undoJournal: RenameUndoJournal?
    var undoScopes: [URL] = []
    var isRecycling = false
}

private func beginFileToolAccess(_ urls: [URL]) -> [URL] {
    urls.filter { $0.startAccessingSecurityScopedResource() }
}

private func endFileToolAccess(_ accessed: [URL]) {
    for url in accessed { url.stopAccessingSecurityScopedResource() }
}

private func withFileToolAccess<T>(_ urls: [URL], _ work: () throws -> T) rethrows -> T {
    let accessed = beginFileToolAccess(urls)
    defer { endFileToolAccess(accessed) }
    return try work()
}
