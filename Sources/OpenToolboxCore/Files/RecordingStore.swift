import Darwin
import Foundation

/// Holds recordings that couldn't be saved to the output folder, so they are never lost.
/// Recordings stay here, outside any window, until they are saved or the user discards them.
///
/// The store's folders are opened without following links, and kept files are checked by
/// file identity and removed with a file-only unlink, so nothing outside the store, and no
/// folder, is ever deleted.
public struct RecordingStore: Sendable {
    public enum Outcome: Sendable {
        case saved(URL)
        /// The output folder refused the recording. It is now at `kept`, which is the original
        /// temporary file if even moving it into the store failed.
        case kept(URL, reason: String)
    }

    /// A kept recording and the tool that recorded it.
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let tool: ToolID
        public let url: URL
        let device: UInt64
        let inode: UInt64
    }

    public struct SaveResult: Sendable {
        public let url: URL
        /// Set when the recording was saved but its kept copy couldn't be removed.
        public let cleanupFailure: String?
    }

    public enum StoreError: Error, Equatable, LocalizedError {
        case notARecording(String)
        case unsafeFolder

        public var errorDescription: String? {
            switch self {
            case .notARecording(let name): coreLocalized("“\(name)” isn't a recording kept by OpenToolbox.")
            case .unsafeFolder: coreLocalized("The Unsaved Recordings folder is a link or not a folder, so it wasn't used.")
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

    func openFolder(for tool: ToolID, create: Bool) throws -> Int32 {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw StoreError.unsafeFolder }
        defer { close(root) }
        let name = OutputDirectory.folderName(for: tool)
        if create, mkdirat(root, name, 0o700) != 0, errno != EEXIST { throw StoreError.unsafeFolder }
        let folder = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw StoreError.unsafeFolder }
        return folder
    }

    static func identity(of name: String, in folder: Int32) -> (device: UInt64, inode: UInt64)? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
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

    /// Moves `recording` into the store and returns where it is; on failure it stays where it was.
    public func keep(_ recording: URL, named name: String, tool: ToolID) -> URL {
        defer { notify() }
        guard let folder = try? openFolder(for: tool, create: true) else { return recording }
        defer { close(folder) }
        let base = OutputDirectory.sanitizedFileName(name)
        for counter in 1...OutputDirectory.maximumNumberedNames {
            let candidate = counter == 1 ? base : OutputDirectory.numberedName(base, counter)
            if renameatx_np(AT_FDCWD, recording.path, folder, candidate, UInt32(RENAME_EXCL)) == 0 {
                return self.folder(for: tool).appending(path: candidate, directoryHint: .notDirectory)
            }
            guard errno == EEXIST else { return recording }
        }
        return recording
    }

    /// Kept recordings of `tools`, oldest first. Only regular files directly in the store count.
    public func recordings(of tools: [ToolID]) -> [Entry] {
        tools.flatMap { tool -> [Entry] in
            guard let folder = try? openFolder(for: tool, create: false) else { return [] }
            defer { close(folder) }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: self.folder(for: tool).path)) ?? []
            return names.filter { !$0.hasPrefix(".") }.compactMap { name in
                guard let identity = Self.identity(of: name, in: folder) else { return nil }
                return Entry(
                    name: name, tool: tool, url: self.folder(for: tool).appending(path: name, directoryHint: .notDirectory),
                    device: identity.device, inode: identity.inode)
            }
        }
        .sorted {
            let first = (try? $0.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let second = (try? $1.url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return first == second ? $0.name < $1.name : first < second
        }
    }

    func verifiedFolder(for entry: Entry) throws -> Int32 {
        let folder = try openFolder(for: entry.tool, create: false)
        guard !entry.name.contains("/"), let identity = Self.identity(of: entry.name, in: folder),
            identity.device == entry.device, identity.inode == entry.inode
        else {
            close(folder)
            throw StoreError.notARecording(entry.name)
        }
        return folder
    }

    /// Copies a kept recording into its tool's output folder, then removes it from the store.
    public func save(_ entry: Entry, output: OutputDirectory) throws -> SaveResult {
        let folder = try verifiedFolder(for: entry)
        defer { close(folder) }
        let source = openat(folder, entry.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw StoreError.notARecording(entry.name) }
        let handle = FileHandle(fileDescriptor: source, closeOnDealloc: true)
        let saved = try output.writeNewFile(for: entry.tool, preferredName: entry.name) { destination in
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let writer = try FileHandle(forWritingTo: destination)
            defer { try? writer.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
        }
        defer { notify() }
        return SaveResult(url: saved, cleanupFailure: remove(entry, in: folder))
    }

    public func discard(_ entry: Entry) throws {
        let folder = try verifiedFolder(for: entry)
        defer { close(folder) }
        defer { notify() }
        if let failure = remove(entry, in: folder) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }

    func remove(_ entry: Entry, in folder: Int32) -> String? {
        guard let identity = Self.identity(of: entry.name, in: folder),
            identity.device == entry.device, identity.inode == entry.inode
        else { return StoreError.notARecording(entry.name).localizedDescription }
        guard unlinkat(folder, entry.name, 0) == 0 else { return String(cString: strerror(errno)) }
        return nil
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
