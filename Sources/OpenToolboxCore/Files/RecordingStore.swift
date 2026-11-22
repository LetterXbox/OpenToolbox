import Foundation

/// Holds recordings that couldn't be saved to the output folder, so they are never lost.
/// Recordings stay here, outside any window, until they are saved or the user discards them.
public struct RecordingStore: Sendable {
    public enum Outcome: Sendable {
        case saved(URL)
        /// The output folder refused the recording. It is now at `kept`, which is the original
        /// temporary file if even moving it into the store failed.
        case kept(URL, reason: String)
    }

    /// A kept recording and the tool that recorded it.
    public struct Entry: Hashable, Sendable {
        public let url: URL
        public let tool: ToolID
    }

    public struct SaveResult: Sendable {
        public let url: URL
        /// Set when the recording was saved but its kept copy couldn't be removed.
        public let cleanupFailure: String?
    }

    public enum StoreError: Error, Equatable, LocalizedError {
        case notARecording(String)

        public var errorDescription: String? {
            switch self {
            case .notARecording(let name): coreLocalized("“\(name)” isn't a recording kept by OpenToolbox.")
            }
        }
    }

    /// Posted on the main queue's notification center whenever the kept recordings change.
    public static let didChange = Notification.Name("OpenToolboxRecordingStoreDidChange")

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/OpenToolbox/Unsaved Recordings`
    public static func standard() -> RecordingStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return RecordingStore(
            directory: support.appending(path: "OpenToolbox/Unsaved Recordings", directoryHint: .isDirectory))
    }

    func folder(for tool: ToolID) -> URL {
        directory.appending(path: OutputDirectory.folderName(for: tool), directoryHint: .isDirectory)
    }

    /// Copies `recording` into the output folder as `name`. If that fails, moves it into the store.
    public func publish(_ recording: URL, named name: String, output: OutputDirectory, tool: ToolID) -> Outcome {
        do {
            let saved = try output.writeNewFile(for: tool, preferredName: name) {
                try FileManager.default.copyItem(at: recording, to: $0)
            }
            try? FileManager.default.removeItem(at: recording)
            return .saved(saved)
        } catch {
            return .kept(keep(recording, named: name, tool: tool), reason: error.localizedDescription)
        }
    }

    func keep(_ recording: URL, named name: String, tool: ToolID) -> URL {
        defer { notify() }
        do {
            let folder = folder(for: tool)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = OutputDirectory.uniqueFileURL(in: folder, preferredName: name)
            try FileManager.default.moveItem(at: recording, to: destination)
            return destination
        } catch {
            return recording
        }
    }

    /// Kept recordings of `tools`, oldest first. Only regular files the store wrote count.
    public func recordings(of tools: [ToolID]) -> [Entry] {
        tools.flatMap { tool -> [Entry] in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder(for: tool), includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])) ?? []
            return urls.filter(Self.isRegularFile).map { Entry(url: $0, tool: tool) }
        }
        .sorted {
            let first = (try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let second = (try? $1.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return first == second ? $0.url.lastPathComponent < $1.url.lastPathComponent : first < second
        }
    }

    static func samePath(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path == second.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    func validate(_ entry: Entry) throws {
        let inStore = Self.samePath(entry.url.deletingLastPathComponent(), folder(for: entry.tool))
        guard inStore, Self.isRegularFile(entry.url) else {
            throw StoreError.notARecording(entry.url.lastPathComponent)
        }
    }

    /// Copies a kept recording into its tool's output folder, then removes it from the store.
    public func save(_ entry: Entry, output: OutputDirectory) throws -> SaveResult {
        try validate(entry)
        let saved = try output.writeNewFile(for: entry.tool, preferredName: entry.url.lastPathComponent) {
            try FileManager.default.copyItem(at: entry.url, to: $0)
        }
        defer { notify() }
        do {
            try FileManager.default.removeItem(at: entry.url)
            return SaveResult(url: saved, cleanupFailure: nil)
        } catch {
            return SaveResult(url: saved, cleanupFailure: error.localizedDescription)
        }
    }

    public func discard(_ entry: Entry) throws {
        try validate(entry)
        defer { notify() }
        try FileManager.default.removeItem(at: entry.url)
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
