import Darwin
import Foundation

public enum ArchiveFormat: String, CaseIterable, Sendable, Identifiable {
    case zip
    case sevenZip
    case tar

    public var id: String { rawValue }

    public var sevenZipType: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tar: "tar"
        }
    }

    public var fileExtension: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tar: "tar"
        }
    }

    public var supportsPassword: Bool {
        self != .tar
    }
}

public enum ArchiveCompressionLevel: Int, CaseIterable, Sendable, Identifiable {
    case store = 0
    case fast = 1
    case balanced = 5
    case maximum = 9

    public var id: Int { rawValue }
}

public enum ArchiveToolError: Error, Equatable, LocalizedError {
    case noInputs
    case emptyArchive
    case unsafeArchiveEntry(String)
    case wrongPassword
    case passwordUnsupportedForFormat

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            coreLocalized("Choose at least one file or folder.")
        case .emptyArchive:
            coreLocalized("The archive did not contain any files.")
        case .unsafeArchiveEntry(let path):
            coreLocalized("The archive contains an unsupported link or special file (\(path)) and was not extracted.")
        case .wrongPassword:
            coreLocalized("The archive password is missing or incorrect.")
        case .passwordUnsupportedForFormat:
            coreLocalized("TAR archives do not support password encryption.")
        }
    }
}

public struct ArchiveExtractResult: Equatable, Sendable {
    public let output: URL
    public let extractedFileCount: Int

    public init(output: URL, extractedFileCount: Int) {
        self.output = output
        self.extractedFileCount = extractedFileCount
    }
}

/// Creates and extracts archives (ZIP, 7z, RAR, TAR, GZ, BZ2, XZ) via on-demand `7zz`.
public enum ArchiveTool {
    public typealias Runner = @Sendable (URL, [String]) async throws -> EngineProcessResult

    public static func compressArguments(
        inputs: [URL],
        destination: URL,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?
    ) throws -> [String] {
        guard !inputs.isEmpty else { throw ArchiveToolError.noInputs }
        let secret = password ?? ""
        if !secret.isEmpty, !format.supportsPassword {
            throw ArchiveToolError.passwordUnsupportedForFormat
        }
        var args = [
            "a",
            "-t\(format.sevenZipType)",
            "-mx=\(level.rawValue)",
            "-y",
            "-bd",
        ]
        if !secret.isEmpty {
            if format == .zip {
                args.append("-mem=AES256")
            } else if format == .sevenZip {
                args.append("-mhe=on")
            }
            args.append("-p\(secret)")
        }
        args.append("--")
        args.append(destination.path)
        args.append(contentsOf: inputs.map(\.path))
        return args
    }

    public static func extractArguments(
        archive: URL,
        destinationDirectory: URL,
        password: String?
    ) -> [String] {
        let secret = password ?? ""
        return [
            "x",
            "-y",
            "-bd",
            "-p\(secret)",
            "-o\(destinationDirectory.path)",
            "--",
            archive.path,
        ]
    }

    public static func compress(
        _ inputs: [URL],
        archiveName: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel = .balanced,
        password: String? = nil,
        executable: URL,
        output: OutputDirectory,
        tool: ToolID,
        runner: Runner = { exe, args in try await EngineProcess.run(exe, arguments: args) }
    ) async throws -> URL {
        guard !inputs.isEmpty else { throw ArchiveToolError.noInputs }
        let baseName = archiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = baseName.isEmpty
            ? (inputs.count == 1 ? inputs[0].deletingPathExtension().lastPathComponent : "Archive")
            : baseName
        let preferredName = stem.hasSuffix(".\(format.fileExtension)") ? stem : "\(stem).\(format.fileExtension)"

        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: output.baseDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let tempArchive = staging.appending(path: "archive.\(format.fileExtension)", directoryHint: .notDirectory)
        let args = try compressArguments(
            inputs: inputs,
            destination: tempArchive,
            format: format,
            level: level,
            password: password
        )
        let result = try await runner(executable, args)
        guard result.exitCode == 0 else {
            throw EngineProcessError.failed(
                command: executable.lastPathComponent,
                exitCode: result.exitCode,
                detail: sanitizeError(result.stderrString.isEmpty ? result.stdoutString : result.stderrString, password: password)
            )
        }
        return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
            try FileManager.default.moveItem(at: tempArchive, to: destination)
        }
    }

    public static func extract(
        _ archive: URL,
        password: String? = nil,
        executable: URL,
        output: OutputDirectory,
        tool: ToolID,
        runner: Runner = { exe, args in try await EngineProcess.run(exe, arguments: args) }
    ) async throws -> ArchiveExtractResult {
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: output.baseDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let extractRoot = staging.appending(path: "extracted", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: extractRoot, withIntermediateDirectories: false)

        let args = extractArguments(archive: archive, destinationDirectory: extractRoot, password: password)
        let result = try await runner(executable, args)
        guard result.exitCode == 0 else {
            let combined = result.stderrString + "\n" + result.stdoutString
            if isWrongPassword(combined) {
                throw ArchiveToolError.wrongPassword
            }
            throw EngineProcessError.failed(
                command: executable.lastPathComponent,
                exitCode: result.exitCode,
                detail: sanitizeError(result.stderrString.isEmpty ? result.stdoutString : result.stderrString, password: password)
            )
        }

        let fileCount = try auditExtractedTree(at: extractRoot)
        let topEntries = try FileManager.default.contentsOfDirectory(atPath: extractRoot.path)
        guard !topEntries.isEmpty else { throw ArchiveToolError.emptyArchive }

        if topEntries.count == 1 {
            let only = extractRoot.appending(path: topEntries[0])
            var info = stat()
            guard lstat(only.path, &info) == 0 else { throw POSIXError(.EIO) }
            if (info.st_mode & S_IFMT) == S_IFREG {
                let saved = try output.writeNewFile(for: tool, preferredName: topEntries[0]) { destination in
                    try FileManager.default.moveItem(at: only, to: destination)
                }
                return ArchiveExtractResult(output: saved, extractedFileCount: max(fileCount, 1))
            }
        }

        let folderName = archiveStem(for: archive)
        let savedFolder = try output.writeNewDirectory(for: tool, preferredName: folderName) { destination in
            for entry in topEntries {
                try FileManager.default.moveItem(
                    at: extractRoot.appending(path: entry),
                    to: destination.appending(path: entry)
                )
            }
        }
        return ArchiveExtractResult(output: savedFolder, extractedFileCount: fileCount)
    }

    static func auditExtractedTree(at root: URL) throws -> Int {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ArchiveToolError.unsafeArchiveEntry(root.lastPathComponent)
        }
        return try auditDirectory(root, relativePrefix: "", device: rootInfo.st_dev, depth: 0)
    }

    private static func auditDirectory(_ url: URL, relativePrefix: String, device: dev_t, depth: Int) throws -> Int {
        guard depth <= 64 else { throw ArchiveToolError.unsafeArchiveEntry(relativePrefix) }
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var fileCount = 0
        for name in names {
            let child = url.appending(path: name)
            let rel = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            var info = stat()
            guard lstat(child.path, &info) == 0, info.st_dev == device else {
                throw ArchiveToolError.unsafeArchiveEntry(rel)
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                guard info.st_nlink == 1 else { throw ArchiveToolError.unsafeArchiveEntry(rel) }
                fileCount += 1
            case S_IFDIR:
                fileCount += try auditDirectory(child, relativePrefix: rel, device: device, depth: depth + 1)
            default:
                throw ArchiveToolError.unsafeArchiveEntry(rel)
            }
        }
        return fileCount
    }

    static func archiveStem(for url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] {
            if lower.hasSuffix(compound) {
                let stem = String(name.dropLast(compound.count))
                return stem.isEmpty ? "Extracted" : stem
            }
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "Extracted" : stem
    }

    private static func isWrongPassword(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("wrong password") || lower.contains("can not open encrypted archive")
    }

    private static func sanitizeError(_ text: String, password: String?) -> String {
        guard let password, !password.isEmpty else { return text }
        return text.replacingOccurrences(of: password, with: "••••")
    }
}
