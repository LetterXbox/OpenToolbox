import Darwin
import Foundation

public struct DuplicateTrashOutcome: Identifiable, Sendable {
    public enum Disposition: Equatable, Sendable {
        case trashed(URL)
        case restored(to: URL, reason: String)
        case uncertain(reason: String)
        case skipped(reason: String)
    }

    public var id: URL { original }
    public let original: URL
    public let disposition: Disposition
    let removeFromResults: Bool
}

public struct DuplicateTrashResult: Sendable {
    public let outcomes: [DuplicateTrashOutcome]

    public var removedFromResults: Set<URL> {
        Set(outcomes.filter(\.removeFromResults).map(\.original))
    }
}

extension DuplicateScanner {
    public static func trashSelected(_ selected: Set<URL>, in groups: [DuplicateGroup]) -> DuplicateTrashResult {
        trashSelected(selected, in: groups) { source in
            var receipt: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &receipt)
            return receipt?.filePathURL
        }
    }

    static func trashSelected(
        _ selected: Set<URL>, in groups: [DuplicateGroup],
        trashItem: (URL) throws -> URL?
    ) -> DuplicateTrashResult {
        var outcomes: [DuplicateTrashOutcome] = []
        for group in groups {
            let survivors = group.files.filter { !selected.contains($0.url) }
            for candidate in group.files where selected.contains(candidate.url) {
                let disposition: DuplicateTrashOutcome.Disposition
                do {
                    disposition = try trash(
                        candidate, keeping: survivors, dataHash: group.dataHash, using: trashItem
                    )
                } catch {
                    disposition = .skipped(reason: error.localizedDescription)
                }
                let removeFromResults: Bool
                switch disposition {
                case .trashed:
                    removeFromResults = true
                case .restored(let destination, _) where destination.path == candidate.url.path:
                    removeFromResults = false
                default:
                    removeFromResults = FileToolDisk.snapshot(at: candidate.url)?.identity != candidate.snapshot.identity
                }
                outcomes.append(DuplicateTrashOutcome(
                    original: candidate.url, disposition: disposition, removeFromResults: removeFromResults
                ))
            }
        }
        return DuplicateTrashResult(outcomes: outcomes)
    }

    private static func trash(
        _ candidate: DuplicateFile, keeping survivors: [DuplicateFile], dataHash: String,
        using trashItem: (URL) throws -> URL?
    ) throws -> DuplicateTrashOutcome.Disposition {
        let source = candidate.url
        let parentURL = source.deletingLastPathComponent()
        let parent = try FileToolDisk.openDirectory(parentURL)
        defer { close(parent) }
        guard survivors.contains(where: isUnchangedSurvivor) else { throw DuplicateTrashError.noSurvivor }

        let fd = try FileToolDisk.openFile(source, matching: candidate.snapshot)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        let hashes = try HashGenerator.hashFile(handle, algorithms: [.sha256]) { _ in }
        guard hashes[.sha256] == dataHash,
              try !FileToolDisk.hasResourceFork(fd, at: source) else {
            throw FileToolError.changed(source)
        }
        guard survivors.contains(where: isUnchangedSurvivor) else { throw DuplicateTrashError.noSurvivor }
        try FileToolDisk.checkDirectory(parent, at: parentURL)
        guard FileToolDisk.snapshot(of: fd) == candidate.snapshot,
              FileToolDisk.snapshot(at: source) == candidate.snapshot else {
            throw FileToolError.changed(source)
        }

        // Pass the original URL so Finder can use that location for Put Back.
        let receipt: URL?
        do {
            receipt = try trashItem(source)
        } catch {
            if candidate.isUnchanged() { return .skipped(reason: error.localizedDescription) }
            return .uncertain(reason: coreLocalized("The Trash move reported an error: \(error.localizedDescription) Check Trash and scan again."))
        }
        let unverified = DuplicateTrashOutcome.Disposition.uncertain(
            reason: coreLocalized("Could not verify the moved file. Check Trash and scan again.")
        )
        guard let receipt, receipt.isFileURL,
              !["", "/", ".", ".."].contains(receipt.lastPathComponent) else { return unverified }
        let recycled = FileToolDisk.canonicalParent(of: receipt)
        let recycledParentURL = recycled.deletingLastPathComponent()
        let recycledName = recycled.lastPathComponent
        guard recycled.path != source.path else { return unverified }
        guard let recycledParent = try? FileToolDisk.openDirectory(recycledParentURL) else {
            // macOS privacy protection denies reading ~/.Trash without Full Disk Access.
            return movedUnchanged(fd, from: source, in: parent, to: recycled, matching: candidate.snapshot)
                ? .trashed(recycled) : unverified
        }
        defer { close(recycledParent) }
        let identity = candidate.snapshot.identity
        guard let recycledInfo = FileToolDisk.entry(recycledName, in: recycledParent),
              FileIdentity(recycledInfo) == identity,
              FileToolDisk.snapshot(at: source)?.identity != identity else { return unverified }
        if FileSnapshot(recycledInfo)?.matchesAfterRename(candidate.snapshot) == true {
            return .trashed(recycled)
        }

        do {
            let destination = try restore(
                recycled, from: recycledParent, matching: identity,
                to: parent, original: source
            )
            let reason = destination.path == source.path
                ? coreLocalized("The file changed during the move. Scan again before moving it to Trash.")
                : coreLocalized("The original name was taken. Scan again before moving the restored file to Trash.")
            return .restored(to: destination, reason: reason)
        } catch {
            return .uncertain(reason: coreLocalized("Could not verify recovery from “\(recycled.path)”. Check the original folder and Trash, then scan again."))
        }
    }

    private static func movedUnchanged(
        _ fd: Int32, from source: URL, in parent: Int32, to recycled: URL, matching snapshot: FileSnapshot
    ) -> Bool {
        guard FileToolDisk.snapshot(of: fd)?.matchesAfterRename(snapshot) == true,
              let actual = FileToolDisk.pathOfSingleLink(at: fd),
              FileToolDisk.canonicalParent(of: actual).path == recycled.path else { return false }
        return FileToolDisk.entry(source.lastPathComponent, in: parent).map(FileIdentity.init) != snapshot.identity
    }

    private static func restore(
        _ recycled: URL, from trash: Int32, matching identity: FileIdentity,
        to parent: Int32, original: URL
    ) throws -> URL {
        let parentURL = original.deletingLastPathComponent()
        try FileToolDisk.checkDirectory(parent, at: parentURL)
        let destination: URL
        do {
            try FileToolDisk.restore(recycled, from: trash, matching: identity, to: parent, at: original)
            destination = original
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST) {
            // Keep the fallback under the filename length limit even if the original name was at the limit.
            let extensionSuffix = original.pathExtension
            let shortExtension = extensionSuffix.utf8.count <= 32 && !extensionSuffix.isEmpty ? ".\(extensionSuffix)" : ""
            let recoveredName = "OpenToolbox Recovered \(UUID().uuidString)\(shortExtension)"
            destination = parentURL.appending(path: recoveredName, directoryHint: .inferFromPath)
            try FileToolDisk.checkDirectory(parent, at: parentURL)
            try FileToolDisk.restore(recycled, from: trash, matching: identity, to: parent, at: destination)
        }
        try FileToolDisk.checkDirectory(parent, at: parentURL)
        guard FileToolDisk.entry(destination.lastPathComponent, in: parent).map(FileIdentity.init) == identity else {
            throw FileToolError.changed(destination)
        }
        return destination
    }

    private static func isUnchangedSurvivor(_ file: DuplicateFile) -> Bool {
        guard let fd = try? FileToolDisk.openFile(file.url, matching: file.snapshot) else { return false }
        defer { close(fd) }
        return (try? FileToolDisk.hasResourceFork(fd, at: file.url)) == false && file.isUnchanged()
    }
}

private enum DuplicateTrashError: LocalizedError {
    case noSurvivor

    var errorDescription: String? {
        coreLocalized("No unchanged, unselected copy remains. Scan again before moving this file to Trash.")
    }
}
