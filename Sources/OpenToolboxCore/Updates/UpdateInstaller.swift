import Darwin
import Foundation

/// Runs a system tool for the installer. Injected so tests can observe the commands.
public protocol UpdateCommandRunner: Sendable {
    func run(_ executable: String, arguments: [String]) async throws -> Data
}

public struct SystemUpdateCommandRunner: UpdateCommandRunner {
    public init() {}

    public func run(_ executable: String, arguments: [String]) async throws -> Data {
        try await MacUtilityCommand.run(executable, arguments: arguments)
    }
}

/// A verified update copied next to the installed app, waiting to be swapped in.
public struct PreparedUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let stagedApp: URL
    public let installedApp: URL
}

/// Downloads, verifies, stages and installs a release disk image over the running app.
public struct UpdateInstaller: Sendable {
    static let stagedPrefix = ".OpenToolbox-update-"

    private let downloader: EngineDownloader
    private let commands: UpdateCommandRunner
    private let workRoot: URL
    private let bundleIdentifier: String

    public init(
        downloader: EngineDownloader = URLSessionEngineDownloader(),
        commands: UpdateCommandRunner = SystemUpdateCommandRunner(),
        workRoot: URL,
        bundleIdentifier: String = UpdateFeed.bundleIdentifier
    ) {
        self.downloader = downloader
        self.commands = commands
        self.workRoot = workRoot
        self.bundleIdentifier = bundleIdentifier
    }

    public static func defaultWorkRoot() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: UpdateFeed.bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Updates", directoryHint: .isDirectory)
    }

    /// Why the app at `app` can't replace itself, or `nil` when it can.
    public static func unsupportedReason(for app: URL, bundleIdentifier: String?) -> String? {
        guard app.pathExtension == "app", bundleIdentifier == UpdateFeed.bundleIdentifier else {
            return coreLocalized("Updates install only in the packaged OpenToolbox app.")
        }
        if app.path.contains("/AppTranslocation/") {
            return coreLocalized(
                "macOS is running OpenToolbox from a temporary location. Move it to the Applications folder and open it from there to install updates.")
        }
        let folder = app.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true || access(folder.path, W_OK) != 0 || access(app.path, W_OK) != 0 {
            return coreLocalized(
                "OpenToolbox can't write to the folder it's in. Download the update from GitHub and install it yourself.")
        }
        return nil
    }

    /// Downloads `update`, checks its size, SHA-256, bundle identifier, version and code signature,
    /// and copies the app next to `installedApp` without touching the installed copy.
    public func prepare(
        _ update: AppUpdate,
        replacing installedApp: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedUpdate {
        let work = workRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let image = work.appending(path: update.diskImageName)
        try await downloader.download(from: update.diskImageURL, to: image) { progress($0 * 0.8) }
        try Task.checkCancellation()

        let size = (try FileManager.default.attributesOfItem(atPath: image.path)[.size] as? NSNumber)?.int64Value ?? -1
        guard size == update.sizeBytes else { throw UpdateError.sizeMismatch(expected: update.sizeBytes, actual: size) }
        guard try HashGenerator.hashFile(at: image, algorithm: .sha256).lowercased() == update.sha256 else {
            throw UpdateError.checksumMismatch
        }
        progress(0.85)

        let mountRoot = work.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let mountPoint = try await attach(image, under: mountRoot)
        do {
            let staged = try await stage(from: mountPoint, version: update.version, next: installedApp)
            await detach(mountPoint)
            progress(1)
            return PreparedUpdate(version: update.version, stagedApp: staged, installedApp: installedApp)
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    /// Swaps the staged app into place in one rename, then removes the previous copy.
    public func install(_ prepared: PreparedUpdate) throws {
        let staged = prepared.stagedApp
        let installed = prepared.installedApp
        guard staged.deletingLastPathComponent() == installed.deletingLastPathComponent(),
            Self.isStagedName(staged.lastPathComponent),
            Self.bundleInfo(at: staged)?.identifier == bundleIdentifier
        else { throw UpdateError.installFailed(coreLocalized("The prepared update is missing.")) }

        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        try? FileManager.default.removeItem(at: staged)
    }

    /// The shell command that waits for `pid` to exit and then opens `app`.
    public static func relaunchCommand(waitingFor pid: Int32, app: URL) -> (executable: String, arguments: [String]) {
        ("/bin/sh", [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
            "sh", String(pid), app.path,
        ])
    }

    /// Removes staged copies left next to `installedApp` by an update that was never installed.
    public func removeLeftovers(next installedApp: URL) {
        let folder = installedApp.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where Self.isStagedName(name) {
            let candidate = folder.appending(path: name, directoryHint: .isDirectory)
            guard Self.bundleInfo(at: candidate)?.identifier == bundleIdentifier else { continue }
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    /// Detaches disk images and removes downloads that an interrupted update left in the work folder.
    public func removeStaleWork() async {
        let root = workRoot.resolvingSymlinksInPath().path + "/"
        if let output = try? await commands.run("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        {
            let mounts = images.flatMap { ($0["system-entities"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["mount-point"] as? String }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            for mount in mounts where mount.resolvingSymlinksInPath().path.hasPrefix(root) {
                await detach(mount)
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workRoot.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            try? FileManager.default.removeItem(at: workRoot.appending(path: name, directoryHint: .isDirectory))
        }
    }

    static func isStagedName(_ name: String) -> Bool {
        guard name.hasPrefix(stagedPrefix), name.hasSuffix(".app") else { return false }
        let id = name.dropFirst(stagedPrefix.count).dropLast(".app".count)
        return UUID(uuidString: String(id)) != nil
    }

    static func bundleInfo(at app: URL) -> (identifier: String, version: AppVersion?)? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String
        else { return nil }
        return (identifier, (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init))
    }

    private func attach(_ image: URL, under mountRoot: URL) async throws -> URL {
        let output = try await commands.run("/usr/bin/hdiutil", arguments: [
            "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountroot", mountRoot.path, "-plist", image.path,
        ])
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]],
            let path = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateError.diskImageContents(coreLocalized("it could not be opened.")) }
        let mountPoint = URL(fileURLWithPath: path, isDirectory: true)
        guard mountPoint.deletingLastPathComponent().resolvingSymlinksInPath().path
            == mountRoot.resolvingSymlinksInPath().path
        else {
            await detach(mountPoint)
            throw UpdateError.diskImageContents(coreLocalized("it opened in an unexpected location."))
        }
        return mountPoint
    }

    private func detach(_ mountPoint: URL) async {
        if (try? await commands.run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])) == nil {
            _ = try? await commands.run("/usr/bin/hdiutil", arguments: ["detach", "-force", mountPoint.path])
        }
    }

    private func stage(from mountPoint: URL, version: AppVersion, next installedApp: URL) async throws -> URL {
        let source = mountPoint.appending(path: "OpenToolbox.app", directoryHint: .isDirectory)
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else {
            throw UpdateError.diskImageContents(coreLocalized("it does not contain OpenToolbox.app."))
        }
        guard let info = Self.bundleInfo(at: source), info.identifier == bundleIdentifier else {
            throw UpdateError.diskImageContents(coreLocalized("the app has a different bundle identifier."))
        }
        guard info.version == version else {
            throw UpdateError.diskImageContents(coreLocalized("the app's version does not match the release."))
        }
        try await verifySignature(source)

        let staged = installedApp.deletingLastPathComponent()
            .appending(path: "\(Self.stagedPrefix)\(UUID().uuidString).app", directoryHint: .isDirectory)
        do {
            _ = try await commands.run("/usr/bin/ditto", arguments: [source.path, staged.path])
            try await verifySignature(staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    private func verifySignature(_ app: URL) async throws {
        do {
            _ = try await commands.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.diskImageContents(coreLocalized("its code signature is not valid."))
        }
    }
}
