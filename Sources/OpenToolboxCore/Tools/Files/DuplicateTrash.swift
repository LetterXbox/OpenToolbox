import Darwin
import Foundation

public struct DuplicateTrashIssue: Sendable {
    public let file: URL
    public let message: String
}

public struct DuplicateTrashResult: Sendable {
    public let moved: Set<URL>
    public let issues: [DuplicateTrashIssue]
}

extension DuplicateScanner {
    public static func trashSelected(_ selected: Set<URL>, in groups: [DuplicateGroup]) -> DuplicateTrashResult {
        trashSelected(selected, in: groups) { staged in
            var receipt: NSURL?
            try FileManager.default.trashItem(at: staged, resultingItemURL: &receipt)
            guard let receipt else { throw DuplicateTrashError.unverifiedTrash }
            return receipt as URL
        }
    }

    static func trashSelected(
        _ selected: Set<URL>, in groups: [DuplicateGroup], trashItem: (URL) throws -> URL
    ) -> DuplicateTrashResult {
        var moved = Set<URL>()
        var issues: [DuplicateTrashIssue] = []
        for group in groups {
            let survivors = group.files.filter { !selected.contains($0.url) }
            for candidate in group.files where selected.contains(candidate.url) {
                do {
                    try trash(candidate, keeping: survivors, dataHash: group.dataHash, using: trashItem)
                    moved.insert(candidate.url)
                } catch {
                    issues.append(DuplicateTrashIssue(file: candidate.url, message: error.localizedDescription))
                }
            }
        }
        return DuplicateTrashResult(moved: moved, issues: issues)
    }

    private static func trash(
        _ candidate: DuplicateFile, keeping survivors: [DuplicateFile], dataHash: String,
        using trashItem: (URL) throws -> URL
    ) throws {
        let source = candidate.url
        let name = source.lastPathComponent
        let parentURL = source.deletingLastPathComponent()
        let parent = try FileToolDisk.openDirectory(parentURL)
        defer { close(parent) }
        guard survivors.contains(where: isUnchangedSurvivor) else { throw DuplicateTrashError.noSurvivor }

        // Use a private sibling directory on the same volume. If interrupted, the original
        // filename is still visible inside the recovery folder beside its original location.
        let recoveryName = "OpenToolbox Trash Review \(UUID().uuidString)"
        let recoveryURL = parentURL.appending(path: recoveryName, directoryHint: .isDirectory)
        let stagedURL = recoveryURL.appending(path: name, directoryHint: .notDirectory)
        guard mkdirat(parent, recoveryName, 0o700) == 0 else { throw FileToolDisk.posixError(at: recoveryURL) }
        let staging = openat(parent, recoveryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard staging >= 0 else { throw FileToolDisk.posixError(at: recoveryURL) }
        defer { close(staging) }
        var info = stat()
        guard fstat(staging, &info) == 0 else { throw FileToolDisk.posixError(at: recoveryURL) }
        let recoveryIdentity = FileIdentity(info)
        defer {
            if FileToolDisk.entry(recoveryName, in: parent).map(FileIdentity.init) == recoveryIdentity {
                _ = unlinkat(parent, recoveryName, AT_REMOVEDIR)
            }
        }
        guard info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw FileToolError.changed(recoveryURL)
        }
        try clearInheritedACL(from: staging, at: recoveryURL)

        guard FileToolDisk.entry(name, in: parent).flatMap(FileSnapshot.init) == candidate.snapshot else {
            throw FileToolError.changed(source)
        }
        try FileToolDisk.move(name, from: parent, to: staging, at: source)
        guard let stagedEntry = FileToolDisk.entry(name, in: staging) else {
            throw DuplicateTrashError.recoveryRequired(stagedURL)
        }
        let stagedIdentity = FileIdentity(stagedEntry)
        do {
            guard let stagedSnapshot = FileSnapshot(stagedEntry),
                  stagedSnapshot.matchesAfterRename(candidate.snapshot) else {
                throw FileToolError.changed(source)
            }
            let fd = try FileToolDisk.openFile(stagedURL, matching: stagedSnapshot)
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            let hashes = try HashGenerator.hashFile(handle, algorithms: [.sha256]) { _ in }
            guard hashes[.sha256] == dataHash,
                  try !FileToolDisk.hasResourceFork(fd, at: stagedURL),
                  FileToolDisk.snapshot(of: fd) == stagedSnapshot else {
                throw FileToolError.changed(source)
            }
            guard survivors.contains(where: isUnchangedSurvivor) else { throw DuplicateTrashError.noSurvivor }
            guard FileToolDisk.snapshot(at: stagedURL) == stagedSnapshot else { throw FileToolError.changed(source) }
            let receipt = try trashItem(stagedURL)
            guard FileToolDisk.snapshot(at: FileToolDisk.canonicalParent(of: receipt))?.identity == stagedIdentity else {
                throw DuplicateTrashError.unverifiedTrash
            }
        } catch {
            // A failed Trash call can already have moved the file. Restore only an entry
            // we can still identify in the private directory, and never overwrite an occupant.
            if let entry = FileToolDisk.entry(name, in: staging) {
                guard FileIdentity(entry) == stagedIdentity else {
                    throw DuplicateTrashError.recoveryRequired(stagedURL)
                }
                do {
                    try FileToolDisk.move(name, from: staging, to: parent, at: source)
                } catch {
                    throw DuplicateTrashError.recoveryRequired(stagedURL)
                }
            }
            throw error
        }
    }

    private static func clearInheritedACL(from directory: Int32, at url: URL) throws {
        // An inherited ACL can grant access even when the directory was created with mode 0700.
        guard let inherited = acl_get_fd(directory) else {
            if errno == ENOENT || errno == ENOTSUP { return }
            throw FileToolDisk.posixError(at: url)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(inherited)) }
        guard let empty = acl_init(0) else { throw FileToolDisk.posixError(at: url) }
        defer { _ = acl_free(UnsafeMutableRawPointer(empty)) }
        guard acl_set_fd(directory, empty) == 0 else { throw FileToolDisk.posixError(at: url) }
    }

    private static func isUnchangedSurvivor(_ file: DuplicateFile) -> Bool {
        guard let fd = try? FileToolDisk.openFile(file.url, matching: file.snapshot) else { return false }
        defer { close(fd) }
        return (try? FileToolDisk.hasResourceFork(fd, at: file.url)) == false && file.isUnchanged()
    }
}

private enum DuplicateTrashError: LocalizedError {
    case noSurvivor
    case recoveryRequired(URL)
    case unverifiedTrash

    var errorDescription: String? {
        switch self {
        case .noSurvivor:
            coreLocalized("No unchanged, unselected copy remains. Scan again before moving this file to Trash.")
        case .recoveryRequired(let url):
            coreLocalized("Could not restore the staged file automatically. Check “\(url.path)”.")
        case .unverifiedTrash:
            coreLocalized("Could not verify the moved file in Trash. Check Trash and scan again.")
        }
    }
}
