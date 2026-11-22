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

    /// Path of the executable relative to the engine's `files` directory.
    public var executableRelativePath: String {
        switch self {
        case .executable(let fileName): fileName
        case .zip(let executablePath): executablePath
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
    public static let ytDlpID: EngineID = "yt-dlp"

    /// Phase 2 engines. Builds are not pinned yet, so they are listed but not installable.
    /// Each pinned build must come with a published SHA-256 before it is added here.
    public static let all: [EngineManifest] = [
        EngineManifest(
            id: ffmpegID,
            displayName: "FFmpeg",
            summary: "Converts, compresses, trims, and inspects audio and video.",
            license: "LGPL-2.1-or-later or GPL-3.0-or-later (build dependent)",
            homepage: URL(string: "https://ffmpeg.org")!,
            version: nil,
            artifacts: []
        ),
        EngineManifest(
            id: ytDlpID,
            displayName: "yt-dlp",
            summary: "Downloads video and audio from supported websites.",
            license: "Unlicense",
            homepage: URL(string: "https://github.com/yt-dlp/yt-dlp")!,
            version: nil,
            artifacts: []
        ),
    ]

    public static func manifest(_ id: EngineID) -> EngineManifest? {
        all.first { $0.id == id }
    }
}
