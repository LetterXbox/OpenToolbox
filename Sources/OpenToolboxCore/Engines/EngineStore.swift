import Darwin
import Foundation

/// Record written next to an installed engine.
public struct EngineReceipt: Codable, Equatable, Sendable {
    public var engineID: EngineID
    public var version: String
    public var sha256: String
    public var sizeBytes: Int64
    public var executableRelativePath: String
    public var sourceURL: URL
    public var installedAt: Date
}

public enum EngineStatus: Equatable, Sendable {
    /// No verified build is pinned for this Mac's architecture.
    case unavailable
    case notInstalled(EngineArtifact)
    case installed(EngineReceipt)
    /// Installed, but the manifest pins a different build.
    case updateAvailable(installed: EngineReceipt, artifact: EngineArtifact)
    /// An existing installation could not be verified.
    case damaged

    public var isInstalled: Bool {
        switch self {
        case .installed, .updateAvailable: true
        default: false
        }
    }
}

public enum EngineStoreError: Error, Equatable, LocalizedError {
    case invalidEngineID(String)
    case unavailable(EngineID)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchivePath(String)
    case executableMissing(String)
    case extractionFailed(Int32)
    case invalidArchive
    case archiveLimitExceeded
    case unrecognizedInstallation(EngineID)
    case operationInProgress(EngineID)

    public var errorDescription: String? {
        switch self {
        case .invalidEngineID(let id):
            coreLocalized("“\(id)” is not a valid engine identifier.")
        case .unavailable(let id):
            coreLocalized("No verified build of \(id) is available for this Mac yet.")
        case .sizeMismatch(let expected, let actual):
            coreLocalized("The download has the wrong size (expected \(expected) bytes, got \(actual)).")
        case .checksumMismatch(let expected, let actual):
            coreLocalized("SHA-256 verification failed (expected \(expected), got \(actual)). The file was discarded.")
        case .unsafeArchivePath(let path):
            coreLocalized("The engine package contains an unsafe path: \(path)")
        case .executableMissing(let path):
            coreLocalized("The downloaded engine does not contain \(path).")
        case .extractionFailed(let status):
            coreLocalized("Extracting the archive failed (exit status \(status)).")
        case .invalidArchive:
            coreLocalized("The engine ZIP is invalid or uses unsupported features.")
        case .archiveLimitExceeded:
            coreLocalized("The engine ZIP exceeds the extraction limits.")
        case .unrecognizedInstallation(let id):
            coreLocalized("The existing directory for \(id) could not be verified and was preserved.")
        case .operationInProgress(let id):
            coreLocalized("An installation or removal for \(id) is already in progress.")
        }
    }
}

/// Installs, verifies, and removes on-demand engines under one root directory.
///
/// Layout:
/// ```
/// <root>/<engine-id>/receipt.json
/// <root>/<engine-id>/files/<executable…>
/// <root>/.staging/<uuid>/            (temporary, removed after each install)
/// ```
/// One copy per engine ID is shared by every tool that needs it.
public final class EngineStore: Sendable {
    public let rootDirectory: URL
    private let downloader: any EngineDownloader
    private let architecture: CPUArchitecture

    public init(
        rootDirectory: URL,
        downloader: any EngineDownloader = URLSessionEngineDownloader(),
        architecture: CPUArchitecture = .current
    ) {
        self.rootDirectory = rootDirectory
        self.downloader = downloader
        self.architecture = architecture
    }

    /// `~/Library/Application Support/OpenToolbox/engines`
    public static func defaultRootDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appending(path: "OpenToolbox", directoryHint: .isDirectory)
            .appending(path: "engines", directoryHint: .isDirectory)
    }

    public func receipt(for id: EngineID) -> EngineReceipt? {
        guard EngineManifest.isValidID(id),
              let root = try? EngineDirectory.openPath(self.rootDirectory),
              let installation = try? Self.installation(id, in: root) else { return nil }
        return installation.receipt
    }

    /// Resolves an executable against the built-in trusted catalog.
    public func executableURL(for id: EngineID) -> URL? {
        guard let manifest = EngineCatalog.manifest(id) else { return nil }
        return self.executableURL(for: manifest)
    }

    /// Resolves the pinned executable from a trusted manifest supplied by the caller.
    public func executableURL(for manifest: EngineManifest) -> URL? {
        guard case .installed = self.status(of: manifest),
              let path = manifest.artifact(for: self.architecture)?.payload.executableRelativePath else { return nil }
        return self.rootDirectory.appending(path: manifest.id).appending(path: "files").appending(path: path)
    }

    public func status(of manifest: EngineManifest) -> EngineStatus {
        guard EngineManifest.isValidID(manifest.id),
              let artifact = manifest.artifact(for: self.architecture),
              let version = manifest.version else { return .unavailable }
        do {
            let root = try EngineDirectory.openPath(self.rootDirectory)
            guard let installation = try Self.installation(manifest.id, in: root) else { return .notInstalled(artifact) }
            return Self.status(of: installation, version: version, artifact: artifact)
        } catch let error as POSIXError where error.code == .ENOENT {
            return .notInstalled(artifact)
        } catch {
            return .damaged
        }
    }

    private static func status(of installation: Installation, version: String, artifact: EngineArtifact) -> EngineStatus {
        let record = installation.receipt
        if record.version != version || record.sha256 != artifact.sha256 {
            // A historical receipt can identify an update candidate. Executable lookup
            // only accepts the current pin and uses the path in that manifest.
            guard (try? Self.executable(record.executableRelativePath, in: installation.directory, ready: true)) != nil
            else { return .damaged }
            return .updateAvailable(installed: record, artifact: artifact)
        }
        let path = artifact.payload.executableRelativePath
        guard record.executableRelativePath == path, record.sourceURL == artifact.url,
              artifact.sizeBytes <= 0 || record.sizeBytes == artifact.sizeBytes,
              (try? Self.executable(path, in: installation.directory, ready: true)) != nil else { return .damaged }
        return .installed(record)
    }

    /// Bytes used on disk by a recognized installation.
    public func diskUsage(of id: EngineID) -> Int64 {
        guard EngineManifest.isValidID(id),
              let root = try? EngineDirectory.openPath(self.rootDirectory),
              let installation = try? Self.installation(id, in: root),
              let info = try? installation.directory.metadata() else { return 0 }
        return (try? Self.allocatedSize(of: installation.directory, device: info.st_dev, depth: 0)) ?? 0
    }

    /// Downloads, verifies, and atomically publishes an engine. Concurrent callers for the
    /// same store and engine wait for the writer, then check the installed build again.
    @discardableResult
    public func install(
        _ manifest: EngineManifest,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> EngineReceipt {
        try await self.install(manifest, progress: progress) { _ in }
    }

    enum InstallationCheckpoint: CaseIterable, Equatable, Sendable {
        case didHashChunk
        case didExtractChunk
        case willPublish
    }

    @discardableResult
    func install(
        _ manifest: EngineManifest,
        progress: @escaping @Sendable (Double) -> Void,
        checkpoint: (InstallationCheckpoint) throws -> Void
    ) async throws -> EngineReceipt {
        let id = manifest.id
        guard EngineManifest.isValidID(id) else { throw EngineStoreError.invalidEngineID(id) }
        guard let version = manifest.version, let artifact = manifest.artifact(for: self.architecture) else {
            throw EngineStoreError.unavailable(id)
        }
        let executablePath = artifact.payload.executableRelativePath
        guard let components = Self.relativePathComponents(executablePath.utf8) else {
            throw EngineStoreError.unsafeArchivePath(executablePath)
        }
        if case .executable = artifact.payload, components.count != 1 {
            throw EngineStoreError.unsafeArchivePath(executablePath)
        }

        try Task.checkCancellation()
        let root = try EngineDirectory.openPath(self.rootDirectory, create: true)
        let lock = try Self.mutationLock(id, in: root)
        defer { try? lock.close() }
        while try !Self.tryLock(lock) {
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
        try self.requireCurrentRoot(root)

        let previous = try Self.installation(id, in: root)
        if let previous, case .installed(let receipt) = Self.status(of: previous, version: version, artifact: artifact) {
            progress(1)
            return receipt
        }

        let rootInfo = try root.metadata()
        let stagingRoot = try Self.managedDirectory(".staging", in: root)
        let stagingName = UUID().uuidString
        let staging = try stagingRoot.makeDirectory(stagingName)
        var preserveStaging = false
        defer {
            if !preserveStaging {
                try? Self.removeScratch(staging, named: stagingName, in: stagingRoot, device: rootInfo.st_dev)
            }
        }

        // The downloader needs a pathname. Keep that path independent of the engine root,
        // then verify and consume the download through a single open descriptor.
        let temporaryURL = try EngineDirectory.systemTemporaryDirectory()
        let temporaryRoot = try EngineDirectory.openPath(temporaryURL)
        let temporaryInfo = try temporaryRoot.metadata()
        let temporaryName = "OpenToolbox-engine-\(UUID().uuidString)"
        let temporary = try temporaryRoot.makeDirectory(temporaryName)
        defer {
            try? Self.removeScratch(temporary, named: temporaryName, in: temporaryRoot, device: temporaryInfo.st_dev)
        }
        let destination = temporaryURL.appending(path: temporaryName).appending(path: "download")
        try await self.downloader.download(from: artifact.url, to: destination, progress: progress)
        try Task.checkCancellation()

        let download = try temporary.regularFile("download")
        let actualSize = try EngineDirectory.metadata(download.fileDescriptor).st_size
        if artifact.sizeBytes > 0, actualSize != artifact.sizeBytes {
            throw EngineStoreError.sizeMismatch(expected: artifact.sizeBytes, actual: actualSize)
        }
        let hashes = try HashGenerator.hashFile(download, algorithms: [.sha256]) { _ in
            try checkpoint(.didHashChunk)
            try Task.checkCancellation()
        }
        let actualHash = hashes[.sha256] ?? ""
        guard actualHash == artifact.sha256 else {
            throw EngineStoreError.checksumMismatch(expected: artifact.sha256, actual: actualHash)
        }
        try download.seek(toOffset: 0)

        let newEngine = try staging.makeDirectory("engine")
        let files = try newEngine.makeDirectory("files")
        switch artifact.payload {
        case .executable(let fileName):
            let output = try files.createFile(fileName)
            while let chunk = try download.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.close()
        case .zip:
            try EngineZIP.extract(download, size: actualSize, into: files) {
                try checkpoint(.didExtractChunk)
                try Task.checkCancellation()
            }
        case .tarXz:
            try EngineTarXZ.extract(download, size: actualSize, into: files) {
                try checkpoint(.didExtractChunk)
                try Task.checkCancellation()
            }
        case .pkg(let payloadPath, _, let includedPrefixes):
            try EnginePKG.extract(
                download, size: actualSize, payloadPath: payloadPath, includedPrefixes: includedPrefixes, into: files
            ) {
                try checkpoint(.didExtractChunk)
                try Task.checkCancellation()
            }
        }
        let executable: FileHandle
        do {
            executable = try Self.executable(executablePath, in: newEngine, ready: false)
        } catch {
            throw EngineStoreError.executableMissing(executablePath)
        }
        guard fchmod(executable.fileDescriptor, 0o755) == 0 else { throw EngineDirectory.posixError() }

        // The receipt encoder uses whole seconds.
        let installedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let receipt = EngineReceipt(engineID: id, version: version, sha256: actualHash, sizeBytes: actualSize,
                                    executableRelativePath: executablePath, sourceURL: artifact.url, installedAt: installedAt)
        let record = try newEngine.createFile("receipt.json")
        try record.write(contentsOf: Self.encoder.encode(receipt))
        try record.close()

        try checkpoint(.willPublish)
        try self.requireCurrentRoot(root)
        try Self.requireIdentity(newEngine, named: "engine", in: staging)
        if let previous {
            try Self.requireIdentity(previous.directory, named: id, in: root)
            try Task.checkCancellation()
            try staging.rename("engine", to: root, as: id, flags: UInt32(RENAME_SWAP))
            do {
                try Self.requireIdentity(previous.directory, named: "engine", in: staging)
            } catch {
                // An external writer changed the destination. Preserve the displaced
                // directory if we cannot restore it to its original name.
                preserveStaging = true
                try Self.requireIdentity(newEngine, named: id, in: root)
                try root.rename(id, to: staging, as: "engine", flags: UInt32(RENAME_SWAP))
                preserveStaging = false
                throw error
            }
        } else {
            try Task.checkCancellation()
            try staging.rename("engine", to: root, as: id, flags: UInt32(RENAME_EXCL))
        }
        progress(1)
        return receipt
    }

    /// Removes an identified installation. Refuses a concurrent writer for the same ID.
    public func uninstall(_ id: EngineID) throws {
        guard EngineManifest.isValidID(id) else { throw EngineStoreError.invalidEngineID(id) }
        let root: EngineDirectory
        do {
            root = try EngineDirectory.openPath(self.rootDirectory)
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        }
        let lock = try Self.mutationLock(id, in: root)
        defer { try? lock.close() }
        guard try Self.tryLock(lock) else { throw EngineStoreError.operationInProgress(id) }
        guard let current = try Self.installation(id, in: root) else { return }

        let stagingRoot = try Self.managedDirectory(".staging", in: root)
        let stagingName = UUID().uuidString
        let staging = try stagingRoot.makeDirectory(stagingName)
        let device = try root.metadata().st_dev
        defer {
            if (try? Self.requireIdentity(staging, named: stagingName, in: stagingRoot)) != nil {
                _ = unlinkat(stagingRoot.fd, stagingName, AT_REMOVEDIR)
            }
        }
        try self.requireCurrentRoot(root)
        try Self.requireIdentity(current.directory, named: id, in: root)
        try root.rename(id, to: staging, as: "removed", flags: UInt32(RENAME_EXCL))
        do {
            try Self.requireIdentity(current.directory, named: "removed", in: staging)
        } catch {
            try staging.rename("removed", to: root, as: id, flags: UInt32(RENAME_EXCL))
            throw error
        }
        try staging.removeTree("removed", device: device)
    }

    private struct Installation {
        let directory: EngineDirectory
        let receipt: EngineReceipt
    }

    private static func installation(_ id: EngineID, in root: EngineDirectory) throws -> Installation? {
        guard let info = try root.metadata(id) else { return nil }
        do {
            let directory = try root.directory(id)
            try directory.requireOwner()
            guard try directory.isSameDirectory(as: info), try info.st_dev == root.metadata().st_dev else {
                throw POSIXError(.EPERM)
            }
            let handle = try directory.regularFile("receipt.json")
            guard let data = try handle.read(upToCount: 16 * 1024 + 1), data.count <= 16 * 1024 else {
                throw POSIXError(.EINVAL)
            }
            let receipt = try Self.decoder.decode(EngineReceipt.self, from: data)
            guard receipt.engineID == id, !receipt.version.isEmpty, receipt.sizeBytes >= 0,
                  receipt.sha256.utf8.count == 64,
                  receipt.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  receipt.sourceURL.scheme?.lowercased() == "https",
                  Self.relativePathComponents(receipt.executableRelativePath.utf8) != nil else { throw POSIXError(.EINVAL) }
            return Installation(directory: directory, receipt: receipt)
        } catch {
            throw EngineStoreError.unrecognizedInstallation(id)
        }
    }

    private static func executable(_ path: String, in engine: EngineDirectory, ready: Bool) throws -> FileHandle {
        guard let parts = Self.relativePathComponents(path.utf8) else { throw EngineStoreError.unsafeArchivePath(path) }
        let files = try engine.directory("files")
        try files.requireOwner()
        guard try files.metadata().st_dev == engine.metadata().st_dev else { throw POSIXError(.EXDEV) }
        let parent = try files.parent(of: parts)
        let handle = try parent.regularFile(parts[parts.count - 1])
        if ready {
            let mode = try EngineDirectory.metadata(handle.fileDescriptor).st_mode
            guard mode & 0o100 != 0 else { throw EngineStoreError.executableMissing(path) }
        }
        return handle
    }

    private static func managedDirectory(_ name: String, in root: EngineDirectory) throws -> EngineDirectory {
        let directory = try root.directory(name, create: true)
        try directory.requireOwner()
        guard try directory.metadata().st_dev == root.metadata().st_dev else { throw POSIXError(.EXDEV) }
        return directory
    }

    private static func mutationLock(_ id: EngineID, in root: EngineDirectory) throws -> FileHandle {
        let locks = try Self.managedDirectory(".locks", in: root)
        // Keep the lock inode in place so all store instances lock the same file.
        do {
            return try locks.createFile(id)
        } catch let error as POSIXError where error.code == .EEXIST {
            return try locks.regularFile(id, flags: O_WRONLY)
        }
    }

    private static func tryLock(_ lock: FileHandle) throws -> Bool {
        if flock(lock.fileDescriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK || errno == EINTR { return false }
        throw EngineDirectory.posixError()
    }

    private static func requireIdentity(_ directory: EngineDirectory, named name: String, in parent: EngineDirectory) throws {
        guard let current = try parent.metadata(name), try directory.isSameDirectory(as: current) else {
            throw POSIXError(.EBUSY)
        }
    }

    private static func removeScratch(_ directory: EngineDirectory, named name: String, in parent: EngineDirectory,
                                      device: dev_t) throws {
        try Self.requireIdentity(directory, named: name, in: parent)
        try parent.removeTree(name, device: device)
    }

    private func requireCurrentRoot(_ root: EngineDirectory) throws {
        let current = try EngineDirectory.openPath(self.rootDirectory)
        guard try current.isSameDirectory(as: root.metadata()) else { throw POSIXError(.EBUSY) }
    }

    static func relativePathComponents(_ path: some Collection<UInt8>) -> [String]? {
        guard path.first != 0x7e, path.count <= 1023, !path.contains(0x5c) else { return nil }
        // The filesystem splits on slash bytes even when a slash is part of a grapheme cluster.
        let parts = path.split(separator: 0x2f, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 32 else { return nil }
        var components: [String] = []
        for part in parts {
            guard part.count <= 255, let name = String(validating: part, as: UTF8.self),
                  EngineDirectory.isSingleComponent(name) else { return nil }
            components.append(name)
        }
        return components
    }

    private static func allocatedSize(of directory: EngineDirectory, device: dev_t, depth: Int) throws -> Int64 {
        guard depth <= 64 else { throw POSIXError(.ELOOP) }
        var bytes: Int64 = 0
        try directory.forEachEntry { name in
            guard let info = try directory.metadata(name), info.st_dev == device else { return }
            switch EngineDirectory.type(of: info) {
            case S_IFREG:
                bytes += Int64(info.st_blocks) * 512
            case S_IFDIR:
                let child = try directory.directory(name)
                guard try child.isSameDirectory(as: info) else { return }
                bytes += try Self.allocatedSize(of: child, device: device, depth: depth + 1)
            default:
                break
            }
        }
        return bytes
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
