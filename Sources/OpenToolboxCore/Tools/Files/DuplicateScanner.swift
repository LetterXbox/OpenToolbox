import Darwin
import Foundation
import Synchronization

public struct DuplicateScanOptions: Sendable {
    public let includeHidden: Bool
    public let minimumSize: Int64

    public init(includeHidden: Bool = false, minimumSize: Int64 = 1) {
        self.includeHidden = includeHidden
        self.minimumSize = max(1, minimumSize)
    }
}

public struct DuplicateScanProgress: Sendable {
    public fileprivate(set) var filesScanned = 0
    public fileprivate(set) var bytesHashed: Int64 = 0
    public fileprivate(set) var unreadableEntries = 0

    public init() {}
}

public struct DuplicateFile: Identifiable, Sendable {
    public var id: URL { url }
    public let url: URL
    public var size: Int64 { snapshot.size }
    public var modificationDate: Date { snapshot.modificationDate }

    fileprivate let snapshot: FileSnapshot

    /// Checks that an item still matches the file scanned before passing it to a file operation.
    public func isUnchanged() -> Bool {
        FileToolDisk.snapshot(at: url) == snapshot
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let files: [DuplicateFile]
    public var wastedBytes: Int64 { (files.first?.size ?? 0) * Int64(max(0, files.count - 1)) }

    public func removingFiles(at urls: Set<URL>) -> DuplicateGroup? {
        let remaining = files.filter { !urls.contains($0.url) }
        guard remaining.count > 1 else { return nil }
        return DuplicateGroup(id: id, files: remaining)
    }
}

public enum DuplicateScanner {
    private static let quickHashLimit = 64 * 1024

    public static func scan(
        folders: [URL],
        options: DuplicateScanOptions = .init(),
        progress: @escaping @Sendable (DuplicateScanProgress) -> Void = { _ in }
    ) async throws -> [DuplicateGroup] {
        let worker = Task.detached(priority: .userInitiated) {
            try Self.findDuplicates(in: folders, options: options, report: progress)
        }
        return try await withTaskCancellationHandler {
            let groups = try await worker.value
            try Task.checkCancellation()
            return groups
        } onCancel: {
            worker.cancel()
        }
    }

    private static func findDuplicates(
        in folders: [URL], options: DuplicateScanOptions, report: @Sendable (DuplicateScanProgress) -> Void
    ) throws -> [DuplicateGroup] {
        let filesBySize = try enumerate(folders, options: options, report: report)
        var progress = filesBySize.progress
        var matches: [DuplicateGroup] = []
        for files in filesBySize.groups.values where files.count > 1 {
            try Task.checkCancellation()
            let quickGroups = try groupByHash(files, full: false, progress: &progress, report: report)
            for candidates in quickGroups.values where candidates.count > 1 {
                let fullGroups = try groupByHash(candidates, full: true, progress: &progress, report: report)
                for (hash, hashedFiles) in fullGroups where hashedFiles.count > 1 {
                    let unchanged = try hashedFiles.filter { file in
                        try Task.checkCancellation()
                        return file.isUnchanged()
                    }
                    guard unchanged.count > 1, let size = unchanged.first?.size else { continue }
                    let group = DuplicateGroup(id: "\(size):\(hash)", files: unchanged.sorted { $0.url.path < $1.url.path })
                    matches.append(group)
                }
            }
        }
        try Task.checkCancellation()
        report(progress)
        return matches.sorted {
            if $0.wastedBytes != $1.wastedBytes { return $0.wastedBytes > $1.wastedBytes }
            return $0.id < $1.id
        }
    }

    private static func enumerate(
        _ folders: [URL], options: DuplicateScanOptions, report: @Sendable (DuplicateScanProgress) -> Void
    ) throws -> (groups: [Int64: [DuplicateFile]], progress: DuplicateScanProgress) {
        var progress = DuplicateScanProgress()
        let enumerationErrors = Mutex(0)
        var flags: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { flags.insert(.skipsHiddenFiles) }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]

        var groups: [Int64: [DuplicateFile]] = [:]
        var seenRoots = Set<URL>()
        var seenFiles = Set<FileIdentity>()
        for folder in folders {
            try Task.checkCancellation()
            guard folder.isFileURL else { continue }
            let root = FileToolDisk.canonicalParent(of: folder)
            guard seenRoots.insert(root).inserted else { continue }
            let directory = try FileToolDisk.openDirectory(root)
            close(directory)

            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: flags,
                errorHandler: { _, _ in
                    enumerationErrors.withLock { $0 += 1 }
                    return !Task.isCancelled
                }
            ) else {
                throw ScanError.unreadableFolder(root)
            }

            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                do {
                    let resources = try url.resourceValues(forKeys: Set(keys))
                    if resources.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard resources.isRegularFile == true else { continue }
                    progress.filesScanned += 1
                    if let snapshot = FileToolDisk.snapshot(at: url) {
                        if snapshot.size >= options.minimumSize, seenFiles.insert(snapshot.identity).inserted {
                            groups[snapshot.size, default: []].append(DuplicateFile(url: url, snapshot: snapshot))
                        }
                    } else {
                        progress.unreadableEntries += 1
                    }
                } catch {
                    progress.unreadableEntries += 1
                }
                report(progress)
            }
        }
        progress.unreadableEntries += enumerationErrors.withLock { $0 }
        report(progress)
        return (groups, progress)
    }

    private static func groupByHash(
        _ files: [DuplicateFile], full: Bool, progress: inout DuplicateScanProgress,
        report: @Sendable (DuplicateScanProgress) -> Void
    ) throws -> [String: [DuplicateFile]] {
        var groups: [String: [DuplicateFile]] = [:]
        for file in files {
            try Task.checkCancellation()
            do {
                let fd = try FileToolDisk.openFile(file.url, matching: file.snapshot)
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }

                let hash: String
                if full {
                    let hashes = try HashGenerator.hashFile(handle, algorithms: [.sha256]) { count in
                        progress.bytesHashed += Int64(count)
                        report(progress)
                        try Task.checkCancellation()
                    }
                    guard let digest = hashes[.sha256] else { continue }
                    hash = digest
                } else {
                    let prefix = try handle.read(upToCount: quickHashLimit) ?? Data()
                    hash = HashGenerator.hash(prefix, algorithm: .sha256)
                    progress.bytesHashed += Int64(prefix.count)
                    report(progress)
                    try Task.checkCancellation()
                }
                guard FileToolDisk.snapshot(of: fd) == file.snapshot else { throw FileToolError.changed(file.url) }
                groups[hash, default: []].append(file)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                progress.unreadableEntries += 1
                report(progress)
            }
        }
        return groups
    }
}

private enum ScanError: LocalizedError {
    case unreadableFolder(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableFolder(let url): coreLocalized("Could not read the folder “\(url.lastPathComponent)”.")
        }
    }
}
