import Foundation

/// Stable identifier for an on-demand engine, for example `ffmpeg`.
/// Must match `^[a-z0-9][a-z0-9._-]*$` so it is safe to use as a directory name.
public typealias EngineID = String

public enum CPUArchitecture: String, Codable, Sendable, CaseIterable {
    case arm64
    case x86_64

    public static var current: CPUArchitecture {
        #if arch(arm64)
            return .arm64
        #else
            return .x86_64
        #endif
    }
}

/// How a downloaded artifact is laid out.
public enum EnginePayload: Codable, Hashable, Sendable {
    /// The download is the executable itself, saved under `fileName`.
    case executable(fileName: String)
    /// The download is a ZIP archive; `executablePath` is relative to the archive root.
    case zip(executablePath: String)
    /// The download is an XZ-compressed tar archive; `executablePath` is relative to the archive root.
    case tarXz(executablePath: String)
    /// The download is a macOS `.pkg` (XAR) installer; `payloadPath` names the gzip CPIO payload inside
    /// the TOC, `executablePath` is relative to the payload root, and `includedPrefixes` limits extraction.
    case pkg(payloadPath: String, executablePath: String, includedPrefixes: [String])

    /// Path of the executable relative to the engine's `files` directory.
    public var executableRelativePath: String {
        switch self {
        case .executable(let fileName): fileName
        case .zip(let executablePath): executablePath
        case .tarXz(let executablePath): executablePath
        case .pkg(_, let executablePath, _): executablePath
        }
    }
}

/// One downloadable build of an engine for a CPU architecture.
public struct EngineArtifact: Codable, Hashable, Sendable {
    public var architecture: CPUArchitecture
    /// HTTPS download URL.
    public var url: URL
    /// Lowercase hex SHA-256 of the downloaded file.
    public var sha256: String
    /// Download size in bytes, shown before the user confirms.
    public var sizeBytes: Int64
    public var payload: EnginePayload

    public init(architecture: CPUArchitecture, url: URL, sha256: String, sizeBytes: Int64, payload: EnginePayload) {
        self.architecture = architecture
        self.url = url
        self.sha256 = sha256.lowercased()
        self.sizeBytes = sizeBytes
        self.payload = payload
    }
}

/// Metadata for an on-demand engine. Manifests ship inside the app so nothing
/// is fetched at launch; the app only goes online when the user installs.
public struct EngineManifest: Codable, Hashable, Sendable, Identifiable {
    public var id: EngineID
    public var displayName: String
    /// English one-line description; also the localization key.
    public var summaryKey: String
    /// SPDX-style license expression of the engine itself.
    public var license: String
    public var homepage: URL
    /// Pinned version; `nil` while no verified build is pinned yet.
    public var version: String?
    public var artifacts: [EngineArtifact]

    public init(
        id: EngineID,
        displayName: String,
        summary: String,
        license: String,
        homepage: URL,
        version: String?,
        artifacts: [EngineArtifact]
    ) {
        self.id = id
        self.displayName = displayName
        self.summaryKey = summary
        self.license = license
        self.homepage = homepage
        self.version = version
        self.artifacts = artifacts
    }

    public var localizedSummary: String { coreLocalized(dynamicKey: summaryKey) }

    public func artifact(for architecture: CPUArchitecture = .current) -> EngineArtifact? {
        guard version != nil else { return nil }
        return artifacts.first { $0.architecture == architecture }
    }

    /// Validates that an identifier is safe to use as a single path component.
    public static func isValidID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 64 else { return false }
        let lowerDigits = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let allowed = lowerDigits.union(CharacterSet(charactersIn: "._-"))
        return lowerDigits.contains(first) && id.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// Engines OpenToolbox knows about.
public enum EngineCatalog {
    public static let ffmpegID: EngineID = "ffmpeg"
    public static let ffprobeID: EngineID = "ffprobe"
    public static let ytDlpID: EngineID = "yt-dlp"
    public static let sevenZipID: EngineID = "7zz"
    public static let ghostscriptID: EngineID = "ghostscript"

    private static let ytDlpURL = URL(
        string: "https://github.com/yt-dlp/yt-dlp/releases/download/2026.10.26/yt-dlp_macos")!
    private static let ytDlpSHA256 = "0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa"
    private static let ytDlpSize: Int64 = 37_466_304

    private static let ghostscriptURL = URL(
        string: "https://pages.uoregon.edu/koch/Ghostscript-10.07.1.pkg")!
    private static let ghostscriptSHA256 = "7ea1d591c186b9f6f3e1d9cfd4ab2ef8570c5bcfd19b54086e8e183ed5892061"
    private static let ghostscriptSize: Int64 = 42_675_565
    private static let ghostscriptPayload = EnginePayload.pkg(
        payloadPath: "Ghostscript-10.07.1-Start.pkg/Payload",
        executablePath: "usr/local/bin/gs-noX11",
        includedPrefixes: ["usr/local/bin/gs-noX11"]
    )

    /// Engines without a pinned build are listed but not installable.
    /// Each pinned build must come with a verified SHA-256 before it is added here.
    public static let all: [EngineManifest] = [
        EngineManifest(
            id: ffmpegID,
            displayName: "FFmpeg",
            summary: "Converts, compresses, trims, merges, and filters audio and video.",
            license: "GPL-3.0-or-later",
            homepage: URL(string: "https://ffmpeg.org")!,
            version: "9.1",
            artifacts: [
                EngineArtifact(
                    architecture: .arm64,
                    url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1795207104_9.1/ffmpeg.zip")!,
                    sha256: "1f66e9a690a7f1c9e60b012379f8869c11818d1797f45b21dbb2f2564ba61ae1",
                    sizeBytes: 28_623_086,
                    payload: .zip(executablePath: "ffmpeg")
                ),
                EngineArtifact(
                    architecture: .x86_64,
                    url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/amd64/1795212433_9.1/ffmpeg.zip")!,
                    sha256: "35b3d82cccc2c1d644d49d15f5e57eb913a08ef68f798042c90eecec62c51f1e",
                    sizeBytes: 34_064_287,
                    payload: .zip(executablePath: "ffmpeg")
                ),
            ]
        ),
        EngineManifest(
            id: ffprobeID,
            displayName: "FFprobe",
            summary: "Inspects streams, codecs, duration, and metadata of media files.",
            license: "GPL-3.0-or-later",
            homepage: URL(string: "https://ffmpeg.org")!,
            version: "9.1",
            artifacts: [
                EngineArtifact(
                    architecture: .arm64,
                    url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1795207104_9.1/ffprobe.zip")!,
                    sha256: "6ef2df5f575042923a28537ab37adf936f28bf3e7b85de23a1447ed447ec1dbd",
                    sizeBytes: 28_541_295,
                    payload: .zip(executablePath: "ffprobe")
                ),
                EngineArtifact(
                    architecture: .x86_64,
                    url: URL(string: "https://ffmpeg.martin-riedl.de/download/macos/amd64/1795212433_9.1/ffprobe.zip")!,
                    sha256: "41ca7b7cba7992e33f1da3f1bf54db8ec103a4d387b1bfac3162062e8b1074ad",
                    sizeBytes: 33_959_464,
                    payload: .zip(executablePath: "ffprobe")
                ),
            ]
        ),
        EngineManifest(
            id: ytDlpID,
            displayName: "yt-dlp",
            summary: "Downloads video and audio from supported websites.",
            license: "Unlicense",
            homepage: URL(string: "https://github.com/yt-dlp/yt-dlp")!,
            version: "2026.10.26",
            artifacts: [
                EngineArtifact(
                    architecture: .arm64,
                    url: ytDlpURL,
                    sha256: ytDlpSHA256,
                    sizeBytes: ytDlpSize,
                    payload: .executable(fileName: "yt-dlp")
                ),
                EngineArtifact(
                    architecture: .x86_64,
                    url: ytDlpURL,
                    sha256: ytDlpSHA256,
                    sizeBytes: ytDlpSize,
                    payload: .executable(fileName: "yt-dlp")
                ),
            ]
        ),
        EngineManifest(
            id: sevenZipID,
            displayName: "7-Zip (7zz)",
            summary: "Creates and extracts ZIP, 7z, TAR, and RAR archives.",
            license: "LGPL-2.1-or-later, BSD-3-Clause",
            homepage: URL(string: "https://7-zip.org")!,
            version: "26.06",
            artifacts: [
                EngineArtifact(
                    architecture: .arm64,
                    url: URL(string: "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac.tar.xz")!,
                    sha256: "b6f17920b4240940461dac8ef4009891881ac44d2a5ead625ede2ec8472185dd",
                    sizeBytes: 965_712,
                    payload: .tarXz(executablePath: "7zz")
                ),
                EngineArtifact(
                    architecture: .x86_64,
                    url: URL(string: "https://github.com/ip7z/7zip/releases/download/26.06/7z2606-mac-x64.tar.xz")!,
                    sha256: "3af68b124052da7fc2a246c96b0bea6a68bfee389baa788f4cead1a133445586",
                    sizeBytes: 1_025_228,
                    payload: .tarXz(executablePath: "7zz")
                ),
            ]
        ),
        EngineManifest(
            id: ghostscriptID,
            displayName: "Ghostscript",
            summary: "Compresses PDFs by downsampling images and optimizing streams.",
            license: "AGPL-3.0-or-later",
            homepage: URL(string: "https://ghostscript.com")!,
            version: "10.07.1",
            artifacts: [
                EngineArtifact(
                    architecture: .arm64,
                    url: ghostscriptURL,
                    sha256: ghostscriptSHA256,
                    sizeBytes: ghostscriptSize,
                    payload: ghostscriptPayload
                ),
                EngineArtifact(
                    architecture: .x86_64,
                    url: ghostscriptURL,
                    sha256: ghostscriptSHA256,
                    sizeBytes: ghostscriptSize,
                    payload: ghostscriptPayload
                ),
            ]
        ),
    ]

    public static func manifest(_ id: EngineID) -> EngineManifest? {
        all.first { $0.id == id }
    }
}
