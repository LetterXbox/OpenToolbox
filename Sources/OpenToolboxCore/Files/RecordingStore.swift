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

    /// A recording captured straight into the store's hidden captures folder. Its lock marks it as still being
    /// recorded; a capture whose lock is free was interrupted and is moved into the store as a kept recording.
    public struct Capture: Sendable {
        public let url: URL
        let tool: ToolID
        let lease: Int32
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

    static let capturesFolder = ".captures"

    func openCaptures(in folder: Int32, create: Bool) -> Int32? {
        if create, mkdirat(folder, Self.capturesFolder, 0o700) != 0, errno != EEXIST { return nil }
        let captures = openat(folder, Self.capturesFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        return captures >= 0 ? captures : nil
    }

    /// Starts a capture inside the store, or returns `nil` when the store can't be used.
    public func beginCapture(for tool: ToolID, extension fileExtension: String) -> Capture? {
        guard let folder = try? openFolder(for: tool, create: true) else { return nil }
        defer { close(folder) }
        guard let captures = openCaptures(in: folder, create: true) else { return nil }
        defer { close(captures) }
        let id = UUID().uuidString
        let lease = openat(
            captures, "\(id).lease", O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { return nil }
        let url = self.folder(for: tool).appending(path: Self.capturesFolder, directoryHint: .isDirectory)
            .appending(path: "\(id).\(fileExtension)", directoryHint: .notDirectory)
        return Capture(url: url, tool: tool, lease: lease)
    }

    /// Releases a capture once its recording has been saved, kept or removed.
    public func endCapture(_ capture: Capture) {
        if let folder = try? openFolder(for: capture.tool, create: false) {
            if let captures = openCaptures(in: folder, create: false) {
                unlinkat(captures, capture.url.deletingPathExtension().lastPathComponent + ".lease", 0)
                close(captures)
            }
            close(folder)
        }
        close(capture.lease)
        notify()
    }

    /// Moves interrupted captures into the store as kept recordings, removes empty ones and free locks.
    func recoverCaptures(in folder: Int32) {
        guard let captures = openCaptures(in: folder, create: false) else { return }
        defer { close(captures) }
        for name in Self.names(in: captures) {
            guard let dot = name.lastIndex(of: "."), UUID(uuidString: String(name[..<dot])) != nil else { continue }
            let fileExtension = String(name[name.index(after: dot)...])
            let leaseName = "\(name[..<dot]).lease"
            let lease = openat(captures, leaseName, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lease >= 0 else { continue }
            defer {
                unlinkat(captures, leaseName, 0)
                close(lease)
            }
            var info = stat()
            guard fileExtension != "lease", fstatat(captures, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { continue }
            if info.st_size == 0 {
                unlinkat(captures, name, 0)
            } else {
                _ = Self.move(name, from: captures, into: folder, preferring: "Interrupted Recording.\(fileExtension)")
            }
        }
    }

    /// Moves `source` into `folder` under `name`, or a numbered variant of it, without replacing anything.
    /// Returns the name used.
    static func move(_ source: String, from sourceFolder: Int32, into folder: Int32, preferring name: String) -> String? {
        let base = OutputDirectory.sanitizedFileName(name)
        for counter in 1...OutputDirectory.maximumNumberedNames {
            let candidate = counter == 1 ? base : OutputDirectory.numberedName(base, counter)
            if renameatx_np(sourceFolder, source, folder, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { return nil }
        }
        return nil
    }

    static func identity(of name: String, in folder: Int32) -> (device: UInt64, inode: UInt64, created: Double)? {
        var info = stat()
        guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        let created = Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9
        return (UInt64(info.st_dev), UInt64(info.st_ino), created)
    }

    static func names(in folder: Int32) -> [String] {
        let copy = dup(folder)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
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
        guard let kept = Self.move(recording.path, from: AT_FDCWD, into: folder, preferring: name) else { return recording }
        return self.folder(for: tool).appending(path: kept, directoryHint: .notDirectory)
    }

    /// Kept recordings of `tools`, oldest first. Only regular files directly in the store count.
    public func recordings(of tools: [ToolID]) -> [Entry] {
        tools.flatMap { tool -> [(Entry, Double)] in
            guard let folder = try? openFolder(for: tool, create: false) else { return [] }
            defer { close(folder) }
            recoverCaptures(in: folder)
            return Self.names(in: folder).compactMap { name -> (Entry, Double)? in
                guard !name.hasPrefix("."), let identity = Self.identity(of: name, in: folder) else { return nil }
                let entry = Entry(
                    name: name, tool: tool, url: self.folder(for: tool).appending(path: name, directoryHint: .notDirectory),
                    device: identity.device, inode: identity.inode)
                return (entry, identity.created)
            }
        }
        .sorted { $0.1 == $1.1 ? $0.0.name < $1.0.name : $0.1 < $1.1 }
        .map(\.0)
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
        var opened = stat()
        guard fstat(source, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
            UInt64(opened.st_dev) == entry.device, UInt64(opened.st_ino) == entry.inode
        else { throw StoreError.notARecording(entry.name) }
        let saved = try output.writeNewFile(for: entry.tool, preferredName: entry.name) { destination in
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let writer = try FileHandle(forWritingTo: destination)
            do {
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                    try writer.write(contentsOf: chunk)
                }
                try writer.synchronize()
            } catch {
                try? writer.close()
                throw error
            }
            try writer.close()
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

    /// Moves the entry to a private name, checks that what moved is the kept recording, and only then unlinks it.
    /// Anything else that turns out to be there is moved back.
    func remove(_ entry: Entry, in folder: Int32) -> String? {
        let notARecording = StoreError.notARecording(entry.name).localizedDescription
        guard let identity = Self.identity(of: entry.name, in: folder),
            identity.device == entry.device, identity.inode == entry.inode
        else { return notARecording }
        let staged = ".discard-\(UUID().uuidString)"
        guard renameatx_np(folder, entry.name, folder, staged, UInt32(RENAME_EXCL)) == 0 else {
            return String(cString: strerror(errno))
        }
        guard let moved = Self.identity(of: staged, in: folder), moved.device == entry.device, moved.inode == entry.inode
        else {
            _ = Self.move(staged, from: folder, into: folder, preferring: entry.name)
            return notARecording
        }
        guard unlinkat(folder, staged, 0) == 0 else {
            let reason = String(cString: strerror(errno))
            _ = Self.move(staged, from: folder, into: folder, preferring: entry.name)
            return reason
        }
        return nil
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
