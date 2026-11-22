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
    /// A receipt exists but the executable is missing.
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
            coreLocalized("The engine manifest contains an unsafe path: \(path)")
        case .executableMissing(let path):
            coreLocalized("The downloaded engine does not contain \(path).")
        case .extractionFailed(let status):
            coreLocalized("Extracting the archive failed (exit status \(status)).")
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

    // MARK: Paths

    func engineDirectory(_ id: EngineID) throws -> URL {
        guard EngineManifest.isValidID(id) else { throw EngineStoreError.invalidEngineID(id) }
        return rootDirectory.appending(path: id, directoryHint: .isDirectory)
    }

    private func receiptURL(_ id: EngineID) throws -> URL {
        try engineDirectory(id).appending(path: "receipt.json", directoryHint: .notDirectory)
    }

    // MARK: Queries

    public func receipt(for id: EngineID) -> EngineReceipt? {
        guard let url = try? receiptURL(id), let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(EngineReceipt.self, from: data)
    }

    /// The installed executable, if present.
    public func executableURL(for id: EngineID) -> URL? {
        guard let receipt = receipt(for: id), let directory = try? engineDirectory(id) else { return nil }
        let url = directory.appending(path: "files", directoryHint: .isDirectory)
            .appending(path: receipt.executableRelativePath, directoryHint: .notDirectory)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    public func status(of manifest: EngineManifest) -> EngineStatus {
        let artifact = manifest.artifact(for: architecture)
        guard let receipt = receipt(for: manifest.id) else {
            return artifact.map(EngineStatus.notInstalled) ?? .unavailable
        }
        guard executableURL(for: manifest.id) != nil else { return .damaged }
        if let artifact, artifact.sha256 != receipt.sha256 {
            return .updateAvailable(installed: receipt, artifact: artifact)
        }
        return .installed(receipt)
    }

    /// Bytes used on disk by an installed engine (0 if not installed).
    public func diskUsage(of id: EngineID) -> Int64 {
        guard let directory = try? engineDirectory(id) else { return 0 }
        return Self.allocatedSize(of: directory)
    }

    // MARK: Install / uninstall

    /// Downloads, verifies (size + SHA-256), and atomically installs an engine.
    /// Returns the existing receipt without downloading if the pinned build is already installed.
    @discardableResult
    public func install(
        _ manifest: EngineManifest,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> EngineReceipt {
        let finalDirectory = try engineDirectory(manifest.id)
        guard let version = manifest.version, let artifact = manifest.artifact(for: architecture) else {
            throw EngineStoreError.unavailable(manifest.id)
        }
        if case .installed(let receipt) = status(of: manifest) {
            progress(1)
            return receipt
        }
        let executablePath = artifact.payload.executableRelativePath
        guard Self.isSafeRelativePath(executablePath) else {
            throw EngineStoreError.unsafeArchivePath(executablePath)
        }

        let fileManager = FileManager.default
        let stagingRoot = rootDirectory.appending(path: ".staging", directoryHint: .isDirectory)
        let staging = stagingRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        // 1. Download into staging.
        let download = staging.appending(path: "download", directoryHint: .notDirectory)
        try await downloader.download(from: artifact.url, to: download, progress: progress)
        try Task.checkCancellation()

        // 2. Verify size and checksum before anything is unpacked.
        let actualSize = try Self.fileSize(download)
        if artifact.sizeBytes > 0, actualSize != artifact.sizeBytes {
            throw EngineStoreError.sizeMismatch(expected: artifact.sizeBytes, actual: actualSize)
        }
        let actualHash = try HashGenerator.hashFile(at: download, algorithm: .sha256)
        guard actualHash == artifact.sha256 else {
            throw EngineStoreError.checksumMismatch(expected: artifact.sha256, actual: actualHash)
        }

        // 3. Lay out the new engine directory inside staging.
        let newEngine = staging.appending(path: "engine", directoryHint: .isDirectory)
        let files = newEngine.appending(path: "files", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: files, withIntermediateDirectories: true)
        switch artifact.payload {
        case .executable(let fileName):
            try fileManager.moveItem(at: download, to: files.appending(path: fileName, directoryHint: .notDirectory))
        case .zip:
            try Self.extractZip(download, into: files)
        }
        let executable = files.appending(path: executablePath, directoryHint: .notDirectory)
        guard Self.isContained(executable, in: files), fileManager.fileExists(atPath: executable.path) else {
            throw EngineStoreError.executableMissing(executablePath)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let receipt = EngineReceipt(
            engineID: manifest.id,
            version: version,
            sha256: actualHash,
            sizeBytes: actualSize,
            executableRelativePath: executablePath,
            sourceURL: artifact.url,
            installedAt: Date()
        )
        try Self.encoder.encode(receipt)
            .write(to: newEngine.appending(path: "receipt.json", directoryHint: .notDirectory), options: .atomic)

        // 4. Swap into place with renames on the same volume.
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.moveItem(at: finalDirectory, to: staging.appending(path: "previous", directoryHint: .isDirectory))
        }
        try fileManager.moveItem(at: newEngine, to: finalDirectory)
        progress(1)
        return receipt
    }

    /// Removes an installed engine. Does nothing if it is not installed.
    public func uninstall(_ id: EngineID) throws {
        let directory = try engineDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func allocatedSize(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func extractZip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EngineStoreError.extractionFailed(process.terminationStatus)
        }
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
