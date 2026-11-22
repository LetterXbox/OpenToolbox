import Darwin
import Foundation
import Security

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
    let installedIdentity: FileIdentity
    let codeHash: Data
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
        guard let installedIdentity = Self.fileIdentity(at: installedApp) else {
            throw UpdateError.installFailed(coreLocalized("The installed app could not be found."))
        }
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
        let staged: (app: URL, codeHash: Data)
        do {
            try Task.checkCancellation()
            staged = try await stage(from: mountPoint, version: update.version, next: installedApp)
        } catch {
            await detach(mountPoint)
            throw error
        }
        await detach(mountPoint)

        let prepared = PreparedUpdate(
            version: update.version, stagedApp: staged.app, installedApp: installedApp,
            installedIdentity: installedIdentity, codeHash: staged.codeHash)
        guard !Task.isCancelled, isVerifiedCopy(prepared) else {
            discard(prepared)
            if Task.isCancelled { throw CancellationError() }
            throw UpdateError.diskImageContents(coreLocalized("its code signature is not valid."))
        }
        progress(1)
        return prepared
    }

    /// Swaps the staged app into place in one rename, then removes the previous copy.
    ///
    /// The staged copy must still be the bundle that was verified, and the installed path must still hold
    /// the app that was there when the update was prepared.
    public func install(_ prepared: PreparedUpdate) throws {
        let staged = prepared.stagedApp
        let installed = prepared.installedApp
        guard staged.deletingLastPathComponent() == installed.deletingLastPathComponent(),
            Self.isStagedName(staged.lastPathComponent),
            isVerifiedCopy(prepared)
        else { throw UpdateError.installFailed(coreLocalized("The prepared update is missing or has changed.")) }
        let replaced = UpdateError.installFailed(
            coreLocalized("OpenToolbox was moved or replaced after the update was downloaded."))
        guard Self.fileIdentity(at: installed) == prepared.installedIdentity else { throw replaced }

        guard renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        guard Self.fileIdentity(at: staged) == prepared.installedIdentity else {
            _ = renamex_np(staged.path, installed.path, UInt32(RENAME_SWAP))
            throw replaced
        }
        try? FileManager.default.removeItem(at: staged)
    }

    /// Removes the staged copy of an update that will not be installed.
    public func discard(_ prepared: PreparedUpdate) {
        let staged = prepared.stagedApp
        guard Self.isStagedName(staged.lastPathComponent),
            Self.bundleInfo(at: staged)?.identifier == bundleIdentifier
        else { return }
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

    static func bundleInfo(at app: URL) -> (identifier: String, version: AppVersion?, versionString: String?)? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let identifier = info["CFBundleIdentifier"] as? String
        else { return nil }
        let versionString = info["CFBundleShortVersionString"] as? String
        return (identifier, versionString.flatMap(AppVersion.init), versionString)
    }

    static func fileIdentity(at url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return FileIdentity(info)
    }

    /// The code directory hash of `app` when its signature is valid for every architecture and nested item.
    static func codeHash(of app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let checks = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, checks, nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
            == errSecSuccess,
            let dictionary = information as NSDictionary?
        else { return nil }
        return dictionary[kSecCodeInfoUnique as String] as? Data
    }

    private func isVerifiedCopy(_ prepared: PreparedUpdate) -> Bool {
        let app = prepared.stagedApp
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false,
            let info = Self.bundleInfo(at: app), info.identifier == bundleIdentifier,
            info.versionString == prepared.version.description
        else { return false }
        return Self.codeHash(of: app) == prepared.codeHash
    }

    private func attach(_ image: URL, under mountRoot: URL) async throws -> URL {
        let commands = commands
        let output = try await Task.detached {
            try await commands.run("/usr/bin/hdiutil", arguments: [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountroot", mountRoot.path, "-plist", image.path,
            ])
        }.value
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
        let commands = commands
        await Task.detached {
            if (try? await commands.run("/usr/bin/hdiutil", arguments: ["detach", mountPoint.path])) == nil {
                _ = try? await commands.run("/usr/bin/hdiutil", arguments: ["detach", "-force", mountPoint.path])
            }
        }.value
    }

    private func stage(from mountPoint: URL, version: AppVersion, next installedApp: URL) async throws
        -> (app: URL, codeHash: Data)
    {
        let source = mountPoint.appending(path: "OpenToolbox.app", directoryHint: .isDirectory)
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else {
            throw UpdateError.diskImageContents(coreLocalized("it does not contain OpenToolbox.app."))
        }
        guard let info = Self.bundleInfo(at: source), info.identifier == bundleIdentifier else {
            throw UpdateError.diskImageContents(coreLocalized("the app has a different bundle identifier."))
        }
        guard info.versionString == version.description else {
            throw UpdateError.diskImageContents(coreLocalized("the app's version does not match the release."))
        }
        guard let codeHash = Self.codeHash(of: source) else {
            throw UpdateError.diskImageContents(coreLocalized("its code signature is not valid."))
        }

        let staged = installedApp.deletingLastPathComponent()
            .appending(path: "\(Self.stagedPrefix)\(UUID().uuidString).app", directoryHint: .isDirectory)
        do {
            _ = try await commands.run("/usr/bin/ditto", arguments: [source.path, staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return (staged, codeHash)
    }
}
