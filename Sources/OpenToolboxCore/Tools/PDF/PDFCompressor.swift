import Foundation
import PDFKit

public enum PDFCompressionPreset: String, CaseIterable, Sendable, Identifiable {
    case screen
    case ebook
    case printer
    case prepress

    public var id: String { rawValue }

    public var ghostscriptSetting: String {
        switch self {
        case .screen: "/screen"
        case .ebook: "/ebook"
        case .printer: "/printer"
        case .prepress: "/prepress"
        }
    }
}

public struct PDFCompressionResult: Equatable, Sendable {
    public let originalBytes: Int64
    public let compressedBytes: Int64
    /// `nil` when the compressed PDF would not be smaller than the original.
    public let output: URL?

    public init(originalBytes: Int64, compressedBytes: Int64, output: URL?) {
        self.originalBytes = originalBytes
        self.compressedBytes = compressedBytes
        self.output = output
    }

    public var savedFraction: Double {
        guard originalBytes > 0, compressedBytes < originalBytes else { return 0 }
        return Double(originalBytes - compressedBytes) / Double(originalBytes)
    }
}

public struct GhostscriptResources: Equatable, Sendable {
    public let searchPaths: [String]
    public let genericResourceDir: String?
    public let iccProfilesDir: String?

    public init(searchPaths: [String] = [], genericResourceDir: String? = nil, iccProfilesDir: String? = nil) {
        self.searchPaths = searchPaths
        self.genericResourceDir = genericResourceDir
        self.iccProfilesDir = iccProfilesDir
    }
}

public enum PDFCompressor {
    public typealias Runner = @Sendable (URL, [String]) async throws -> EngineProcessResult

    public static func resources(for executable: URL) -> GhostscriptResources {
        let prefix = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shareRoot = prefix.appending(path: "share/ghostscript", directoryHint: .isDirectory)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: shareRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return GhostscriptResources()
        }
        var searchPaths: [String] = []
        var genericResourceDir: String?
        var iccProfilesDir: String?
        for versionDir in versions.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for sub in ["Resource/Init", "lib", "Resource/Font"] {
                let candidate = versionDir.appending(path: sub, directoryHint: .isDirectory)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    searchPaths.append(candidate.path)
                }
            }
            if genericResourceDir == nil {
                let resDir = versionDir.appending(path: "Resource", directoryHint: .isDirectory)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resDir.path, isDirectory: &isDir), isDir.boolValue {
                    genericResourceDir = resDir.path.hasSuffix("/") ? resDir.path : resDir.path + "/"
                }
            }
            if iccProfilesDir == nil {
                let iccDir = versionDir.appending(path: "iccprofiles", directoryHint: .isDirectory)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: iccDir.path, isDirectory: &isDir), isDir.boolValue {
                    iccProfilesDir = iccDir.path.hasSuffix("/") ? iccDir.path : iccDir.path + "/"
                }
            }
        }
        return GhostscriptResources(
            searchPaths: searchPaths,
            genericResourceDir: genericResourceDir,
            iccProfilesDir: iccProfilesDir
        )
    }

    public static func arguments(
        input: URL,
        output: URL,
        preset: PDFCompressionPreset,
        resources: GhostscriptResources = GhostscriptResources()
    ) -> [String] {
        var args = [
            "-dSAFER",
            "-dBATCH",
            "-dNOPAUSE",
            "-dQUIET",
        ]
        if !resources.searchPaths.isEmpty {
            args.append("-I\(resources.searchPaths.joined(separator: ":"))")
        }
        if let genericResourceDir = resources.genericResourceDir {
            args.append("-sGenericResourceDir=\(genericResourceDir)")
        }
        if let iccProfilesDir = resources.iccProfilesDir {
            args.append("-sICCProfilesDir=\(iccProfilesDir)")
        }
        args += [
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-dPDFSETTINGS=\(preset.ghostscriptSetting)",
            "-sOutputFile=\(output.path)",
            "--",
            input.path,
        ]
        return args
    }

    public static func compress(
        _ source: URL,
        preset: PDFCompressionPreset,
        executable: URL,
        output: OutputDirectory,
        tool: ToolID,
        runner: Runner = { exe, args in try await EngineProcess.run(exe, arguments: args) }
    ) async throws -> PDFCompressionResult {
        _ = try PDFTools.open(source)
        let originalBytes = try fileSize(of: source)

        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: output.baseDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let tempOutput = staging.appending(path: "compressed.pdf", directoryHint: .notDirectory)
        let gsResources = resources(for: executable)
        let args = arguments(input: source, output: tempOutput, preset: preset, resources: gsResources)
        let result = try await runner(executable, args)
        guard result.exitCode == 0 else {
            throw EngineProcessError.failed(
                command: executable.lastPathComponent,
                exitCode: result.exitCode,
                detail: result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            )
        }
        guard FileManager.default.fileExists(atPath: tempOutput.path) else {
            throw PDFToolError.writeFailed
        }
        let compressedBytes = try fileSize(of: tempOutput)
        guard compressedBytes > 0 else { throw PDFToolError.writeFailed }
        guard compressedBytes < originalBytes else {
            return PDFCompressionResult(originalBytes: originalBytes, compressedBytes: compressedBytes, output: nil)
        }

        let base = source.deletingPathExtension().lastPathComponent
        let saved = try output.writeNewFile(for: tool, preferredName: "\(base) compressed.pdf") { destination in
            try FileManager.default.moveItem(at: tempOutput, to: destination)
        }
        return PDFCompressionResult(originalBytes: originalBytes, compressedBytes: compressedBytes, output: saved)
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
