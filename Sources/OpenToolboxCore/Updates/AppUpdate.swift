/// A dotted numeric release version such as `0.1.1`, optionally followed by a pre-release suffix such as
/// `-beta.2` or `-rc.1`. A leading `v` is accepted. Versions compare by Semantic Versioning precedence, so
/// `0.3.0-rc.1` < `0.3.0-rc.10` < `0.3.0`.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: [String]
    public let description: String

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        let core: Substring
        var identifiers: [String] = []
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            let suffix = text[text.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false)
            guard (1...4).contains(suffix.count) else { return nil }
            for identifier in suffix {
                guard !identifier.isEmpty, identifier.count <= 20, identifier.utf8.allSatisfy(Self.isAlphanumeric),
                    !(Self.isNumeric(identifier) && (identifier.count > 9 || identifier.count > 1 && identifier.first == "0"))
                else { return nil }
                identifiers.append(String(identifier))
            }
        } else {
            core = text
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, Self.isNumeric(part), let value = Int(part) else { return nil }
            values.append(value)
        }
        components = values
        prerelease = identifiers
        description = String(text)
    }

    private static func isNumeric(_ text: Substring) -> Bool {
        text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func padded(to count: Int) -> [Int] {
        components + Array(repeating: 0, count: max(0, count - components.count))
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return lhs.padded(to: count) == rhs.padded(to: count) && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(prerelease)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        let left = lhs.padded(to: count)
        let right = rhs.padded(to: count)
        if left != right { return left.lexicographicallyPrecedes(right) }
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, _): return false
        case (true, false): return true
        case (true, true): break
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

/// A newer published release, with the disk image the updater installs.
public struct AppUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let releasePage: URL
    public let diskImageName: String
    public let diskImageURL: URL
    public let sizeBytes: Int64
    /// Lowercase hex SHA-256 of the disk image, as published by GitHub for the release asset.
    public let sha256: String
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(latest: AppVersion)
    case available(AppUpdate)
}

public enum UpdateError: Error, Equatable, LocalizedError {
    case noPublishedRelease
    case httpStatus(Int)
    case invalidResponse
    case missingDiskImage(String)
    case missingChecksum(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch
    case diskImageContents(String)
    case notInstallable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            coreLocalized("No published release was found on GitHub.")
        case .httpStatus(let code):
            coreLocalized("GitHub responded with HTTP status \(code).")
        case .invalidResponse:
            coreLocalized("GitHub returned release information that OpenToolbox can't read.")
        case .missingDiskImage(let name):
            coreLocalized("The latest release has no disk image named “\(name)”.")
        case .missingChecksum(let name):
            coreLocalized("GitHub did not publish a SHA-256 checksum for “\(name)”.")
        case .sizeMismatch(let expected, let actual):
            coreLocalized("The downloaded update is \(actual) bytes, but \(expected) bytes were expected.")
        case .checksumMismatch:
            coreLocalized("The downloaded update does not match its published SHA-256 checksum.")
        case .diskImageContents(let detail):
            coreLocalized("The update's disk image is not a valid OpenToolbox release: \(detail)")
        case .notInstallable(let reason):
            reason
        case .installFailed(let detail):
            coreLocalized("The update could not be installed: \(detail)")
        }
    }
}

/// Where releases are published and how their disk images are named (see `docs/RELEASING.md`).
public enum UpdateFeed {
    public static let repository = "LetterXbox/OpenToolbox"
    public static let bundleIdentifier = "io.github.letterxbox.OpenToolbox"

    public static var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    public static func diskImageName(for version: AppVersion) -> String {
        "OpenToolbox-\(version.description)-macOS-universal.dmg"
    }

    /// Recent releases, newest first, including pre-releases. Read only when test builds are turned on.
    public static var recentReleasesURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    /// Reads a `releases/latest` response and decides whether it offers a newer, installable version.
    public static func evaluate(_ data: Data, current: AppVersion) throws -> UpdateCheckResult {
        guard let release = try? decoder.decode(GitHubRelease.self, from: data),
            release.tagName.hasPrefix("v"),
            let version = AppVersion(release.tagName)
        else { throw UpdateError.invalidResponse }
        guard release.prerelease || !version.isPrerelease else { throw UpdateError.invalidResponse }
        guard !release.draft, !release.prerelease, version > current else {
            return .upToDate(latest: version)
        }
        return .available(try offer(release, version: version))
    }

    /// Reads a `releases` list and offers the highest version in it, whether a stable release or a test build.
    /// Releases whose tag can't be read, or whose pre-release flag disagrees with their tag, are skipped.
    public static func evaluateIncludingTestBuilds(_ data: Data, current: AppVersion) throws -> UpdateCheckResult {
        guard let releases = try? decoder.decode([GitHubRelease].self, from: data) else {
            throw UpdateError.invalidResponse
        }
        let candidates = releases.compactMap { release -> (GitHubRelease, AppVersion)? in
            guard !release.draft, release.tagName.hasPrefix("v"), let version = AppVersion(release.tagName),
                release.prerelease == version.isPrerelease
            else { return nil }
            return (release, version)
        }
        guard let (release, version) = candidates.max(by: { $0.1 < $1.1 }) else {
            throw releases.isEmpty ? UpdateError.noPublishedRelease : UpdateError.invalidResponse
        }
        guard version > current else { return .upToDate(latest: version) }
        return .available(try offer(release, version: version))
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func offer(_ release: GitHubRelease, version: AppVersion) throws -> AppUpdate {
        let name = diskImageName(for: version)
        guard let asset = release.assets.first(where: { $0.name == name }),
            isReleaseDownload(asset.browserDownloadUrl, tag: release.tagName, name: name),
            asset.size > 0
        else { throw UpdateError.missingDiskImage(name) }
        guard let sha256 = checksum(fromDigest: asset.digest) else { throw UpdateError.missingChecksum(name) }

        let page = isGitHubPage(release.htmlUrl) ? release.htmlUrl : releasesPage
        return AppUpdate(
            version: version, releasePage: page, diskImageName: name, diskImageURL: asset.browserDownloadUrl,
            sizeBytes: asset.size, sha256: sha256)
    }

    static func checksum(fromDigest digest: String?) -> String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        let hex = digest.dropFirst("sha256:".count).lowercased()
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        return hex
    }

    private static func isReleaseDownload(_ url: URL, tag: String, name: String) -> Bool {
        url.scheme == "https" && url.host == "github.com"
            && url.path == "/\(repository)/releases/download/\(tag)/\(name)"
    }

    private static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repository)/releases/")
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let size: Int64
            let digest: String?
        }
    }
}

/// Fetches a small HTTPS resource. Injected so tests never touch the network.
public protocol UpdateHTTPClient: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

public struct URLSessionUpdateClient: UpdateHTTPClient {
    private let userAgent: String

    public init(appVersion: AppVersion) {
        userAgent = "OpenToolbox/\(appVersion.description)"
    }

    public func get(_ url: URL) async throws -> (Data, Int) {
        guard url.scheme == "https" else { throw EngineDownloadError.insecureURL(url) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else {
            throw UpdateError.invalidResponse
        }
        return (data, http.statusCode)
    }
}

public struct UpdateChecker: Sendable {
    private let client: UpdateHTTPClient

    public init(client: UpdateHTTPClient) {
        self.client = client
    }

    public func check(current: AppVersion, includingTestBuilds: Bool = false) async throws -> UpdateCheckResult {
        let url = includingTestBuilds ? UpdateFeed.recentReleasesURL : UpdateFeed.latestReleaseURL
        let (data, status) = try await client.get(url)
        switch status {
        case 200:
            return includingTestBuilds
                ? try UpdateFeed.evaluateIncludingTestBuilds(data, current: current)
                : try UpdateFeed.evaluate(data, current: current)
        case 404: throw UpdateError.noPublishedRelease
        default: throw UpdateError.httpStatus(status)
        }
    }
}
