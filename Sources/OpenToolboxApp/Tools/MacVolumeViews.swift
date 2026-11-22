import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

struct EjectDisksView: View {
    let tool: ToolDescriptor

    private struct Failure: Identifiable, Sendable {
        let volume: MountedVolume
        let reason: String
        var id: URL { volume.id }
    }

    @State private var volumes: [MountedVolume] = []
    @State private var pendingVolumes: [MountedVolume] = []
    @State private var failures: [Failure] = []
    @State private var confirmEject = false
    @State private var isEjecting = false
    @State private var didEject = false

    var body: some View {
        ToolPage(tool: tool) {
            Pane(L("Ejectable volumes"), accessory: {
                Button(L("Refresh"), systemImage: "arrow.clockwise") { refresh() }
                    .disabled(isEjecting)
            }) {
                if volumes.isEmpty {
                    Text(L("No ejectable or external volumes are mounted.")).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(volumes) { volume in
                                HStack {
                                    Image(systemName: "externaldrive")
                                    VStack(alignment: .leading) {
                                        Text(volume.name)
                                        Text(volume.url.path).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let bytes = volume.capacityBytes {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if isEjecting {
                ProgressView(L("Ejecting volumes…"))
            } else if !volumes.isEmpty {
                Button(L("Eject All"), systemImage: "eject") {
                    pendingVolumes = volumes
                    confirmEject = true
                }
                .buttonStyle(.borderedProminent)
            }

            if didEject, failures.isEmpty {
                Label(L("Selected volumes are no longer mounted."), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else if !failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failures) { failure in
                            ErrorMessage(text: L("Could not eject \(failure.volume.name): \(failure.reason)"))
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .onAppear { refresh() }
        .confirmationDialog(L("Eject the listed volumes?"), isPresented: $confirmEject, titleVisibility: .visible) {
            Button(L("Eject All"), role: .destructive) { eject(pendingVolumes) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Close files on these volumes before continuing."))
        }
    }

    private func refresh() {
        volumes = MountedVolume.ejectCandidates(from: MountedVolume.mounted())
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func eject(_ selected: [MountedVolume]) {
        guard !isEjecting else { return }
        isEjecting = true
        failures = []
        didEject = false
        Task {
            failures = await Task.detached(priority: .userInitiated) {
                Self.ejectSelected(selected)
            }.value
            refresh()
            isEjecting = false
            didEject = true
        }
    }

    private nonisolated static func ejectSelected(_ selected: [MountedVolume]) -> [Failure] {
        selected.compactMap { volume in
            // One device can host multiple volumes. A previous eject may have unmounted this one.
            guard let current = MountedVolume.mounted().first(where: { $0.url == volume.url }) else { return nil }
            guard current == volume, !MountedVolume.ejectCandidates(from: [current]).isEmpty else {
                return Failure(volume: volume, reason: L("The mounted volume changed. Refresh and try again."))
            }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
                return nil
            } catch {
                return Failure(volume: volume, reason: error.localizedDescription)
            }
        }
    }
}

struct QuarantineHelperView: View {
    let tool: ToolDescriptor

    private struct FileRow: Identifiable, Sendable {
        let url: URL
        let status: QuarantineStatus?
        let inspection: QuarantineInspection?
        let error: String?

        var id: URL { url }

        var isQuarantined: Bool {
            if case .present? = status { return true }
            return false
        }
    }

    @State private var files: [FileRow] = []
    @State private var isImporting = false
    @State private var isWorking = false
    @State private var importError: String?

    var body: some View {
        ToolPage(tool: tool) {
            Text(L("Removing quarantine bypasses macOS’s first-open checks for downloaded items. Only remove it from items you trust."))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Label(L("Drop files here"), systemImage: "arrow.down.doc")
                    .foregroundStyle(.secondary)
                Button(L("Choose Files…")) { isImporting = true }
                    .disabled(isWorking)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.secondary)
            }
            .dropDestination(for: URL.self) { urls, _ in
                let fileURLs = urls.filter { $0.isFileURL }
                guard !fileURLs.isEmpty, !isWorking else { return false }
                inspect(fileURLs)
                return true
            }

            if let importError {
                ErrorMessage(text: importError)
            }
            if isWorking {
                ProgressView().controlSize(.small).accessibilityLabel(L("Working with files"))
            }
            if !files.isEmpty {
                Pane(L("Files"), accessory: {
                    Button(L("Clear")) { files = [] }
                        .disabled(isWorking)
                    Button(L("Remove Quarantine from All")) {
                        removeQuarantine(from: files.filter(\.isQuarantined))
                    }
                    .disabled(isWorking || !files.contains(where: { $0.isQuarantined }))
                }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(files) { row in
                                fileRow(row)
                            }
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): inspect(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    private func fileRow(_ row: FileRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(row.url.lastPathComponent, systemImage: "doc")
                    .fontWeight(.medium)
                Spacer()
                if row.isQuarantined {
                    Badge(text: L("Quarantined"), tint: .orange)
                    Button(L("Remove Quarantine")) { removeQuarantine(from: [row]) }
                        .disabled(isWorking)
                } else if row.status == .absent {
                    Badge(text: L("No quarantine attribute"), tint: .green)
                } else if row.error != nil {
                    Button(L("Inspect Again")) { inspect([row.url]) }
                        .disabled(isWorking)
                }
            }
            Text(row.url.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error = row.error {
                ErrorMessage(text: error)
            }
            switch row.status {
            case .present(let record)?:
                if let record {
                    let agent = record.agentName ?? L("Unavailable")
                    let date = record.date?.formatted(date: .abbreviated, time: .shortened) ?? L("Unavailable")
                    let flags = String(record.flags, radix: 16, uppercase: true)
                    MacUtilityMetrics(rows: [(L("Agent"), agent), (L("Date added"), date), (L("Flags"), "0x" + flags)])
                    if let eventID = record.eventID {
                        HStack {
                            Text(L("Event ID")).foregroundStyle(.secondary)
                            Text(eventID).textSelection(.enabled)
                            InlineCopyButton(text: eventID)
                        }
                    }
                } else {
                    Text(L("The quarantine attribute has an unrecognized format.")).foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
    }

    private func inspect(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        updateFiles {
            var seen: Set<URL> = []
            return urls.filter { seen.insert($0).inserted }.map { Self.inspectFile($0) }
        }
    }

    private func removeQuarantine(from rows: [FileRow]) {
        guard !rows.isEmpty else { return }
        updateFiles {
            rows.compactMap { row in
                guard let inspection = row.inspection else { return nil }
                return Self.inspectFile(row.url, removing: inspection)
            }
        }
    }

    private func updateFiles(_ work: @escaping @Sendable () -> [FileRow]) {
        guard !isWorking else { return }
        isWorking = true
        importError = nil
        Task {
            defer { isWorking = false }
            let rows = await Task.detached(priority: .userInitiated) { work() }.value
            for row in rows {
                if let index = files.firstIndex(where: { $0.id == row.id }) {
                    files[index] = row
                } else {
                    files.append(row)
                }
            }
        }
    }

    private nonisolated static func inspectFile(_ url: URL, removing: QuarantineInspection? = nil) -> FileRow {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            if let removing {
                try QuarantineAttribute.remove(at: url, matching: removing)
                return FileRow(url: url, status: .absent, inspection: nil, error: nil)
            }
            let inspection = try QuarantineAttribute.inspect(at: url)
            return FileRow(url: url, status: inspection.status, inspection: inspection, error: nil)
        } catch {
            return FileRow(url: url, status: nil, inspection: nil, error: error.localizedDescription)
        }
    }
}
