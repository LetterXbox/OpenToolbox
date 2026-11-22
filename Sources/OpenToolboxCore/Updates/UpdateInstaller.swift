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

/// The running app's bundle as it was when the app started: its location, file identity and contents.
public struct InstalledApp: Equatable, Sendable {
    public let url: URL
    let identity: FileIdentity
    let contents: BundleContents
}

/// SHA-256 digests of a bundle's whole main executable, every architecture included, and its `Info.plist`.
struct BundleContents: Equatable, Sendable {
    let executable: String
    let infoPlist: String
}

/// A verified update copied next to the installed app, waiting to be swapped in.
public struct PreparedUpdate: Equatable, Sendable {
    public let version: AppVersion
    public let stagedApp: URL
    let installed: InstalledApp
    let codeHash: Data
    let contents: BundleContents

    public var installedApp: URL { installed.url }
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

    /// Records the identity and contents of the app at `url`, or `nil` when it is not a readable app bundle.
    public static func installedApp(at url: URL) -> InstalledApp? {
        guard let identity = fileIdentity(at: url), let contents = contents(of: url) else { return nil }
        return InstalledApp(url: url, identity: identity, contents: contents)
    }

    /// Downloads `update`, checks its size, SHA-256, bundle identifier, version and code signature,
    /// and copies the app next to `installed` without touching the installed copy.
    public func prepare(
        _ update: AppUpdate,
        replacing installed: InstalledApp,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedUpdate {
        guard Self.isUnchanged(installed) else { throw Self.replacedError }
        let work = workRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        guard let lease = Self.lease(work) else {
            try? FileManager.default.removeItem(at: work)
            throw UpdateError.installFailed(coreLocalized("The update's work folder could not be locked."))
        }
        var keepWork = false
        defer {
            if !keepWork { try? FileManager.default.removeItem(at: work) }
            close(lease)
        }

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
        let staged: (app: URL, codeHash: Data, contents: BundleContents)
        do {
            let mountPoint = try await attach(image, under: mountRoot)
            try Task.checkCancellation()
            staged = try await stage(from: mountPoint, version: update.version, next: installed.url)
        } catch {
            if !(await detach(image)) { keepWork = true }
            throw error
        }
        guard await detach(image) else {
            keepWork = true
            try? FileManager.default.removeItem(at: staged.app)
            throw UpdateError.installFailed(coreLocalized("The update's disk image could not be ejected."))
        }

        let prepared = PreparedUpdate(
            version: update.version, stagedApp: staged.app, installed: installed,
            codeHash: staged.codeHash, contents: staged.contents)
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
    /// the app, byte for byte, that was running when OpenToolbox started.
    public func install(_ prepared: PreparedUpdate) throws {
        let staged = prepared.stagedApp
        let installed = prepared.installed
        guard staged.deletingLastPathComponent() == installed.url.deletingLastPathComponent(),
            Self.isStagedName(staged.lastPathComponent),
            isVerifiedCopy(prepared)
        else { throw UpdateError.installFailed(coreLocalized("The prepared update is missing or has changed.")) }
        guard Self.isUnchanged(installed) else { throw Self.replacedError }

        guard renamex_np(staged.path, installed.url.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        let displaced = InstalledApp(url: staged, identity: installed.identity, contents: installed.contents)
        guard Self.isUnchanged(displaced) else { throw Self.restore(staged, to: installed.url) }
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
    /// Work folders that another running copy of OpenToolbox still holds are left alone.
    public func removeStaleWork() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workRoot.path) else { return }
        var leased: [(folder: URL, lease: Int32)] = []
        for name in names where UUID(uuidString: name) != nil {
            let folder = workRoot.appending(path: name, directoryHint: .isDirectory)
            if let lease = Self.lease(folder) { leased.append((folder, lease)) }
        }
        defer { for entry in leased { close(entry.lease) } }
        guard !leased.isEmpty, let images = await Self.attachedImages(commands) else { return }

        var kept = Set<URL>()
        for image in images {
            guard let entry = leased.first(where: { entry in
                let prefix = Self.resolved(entry.folder.path) + "/"
                return image.path.hasPrefix(prefix) || image.mountPoints.contains { $0.hasPrefix(prefix) }
            }) else { continue }
            if !(await detach(URL(fileURLWithPath: image.path))) { kept.insert(entry.folder) }
        }
        for entry in leased where !kept.contains(entry.folder) {
            try? FileManager.default.removeItem(at: entry.folder)
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

    static func contents(of app: URL) -> BundleContents? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/")
        else { return nil }
        let executable = app.appending(path: "Contents/MacOS/\(name)")
        var status = stat()
        guard lstat(executable.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            let digest = try? HashGenerator.hashFile(at: executable, algorithm: .sha256)
        else { return nil }
        return BundleContents(executable: digest, infoPlist: HashGenerator.hash(data, algorithm: .sha256))
    }

    /// Takes an exclusive, non-blocking lock on `folder`, held until the returned descriptor is closed.
    static func lease(_ folder: URL) -> Int32? {
        let descriptor = open(folder.appending(path: ".lease").path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
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

    private static var replacedError: UpdateError {
        .installFailed(coreLocalized(
            "OpenToolbox was moved, replaced or changed after it was opened. Quit and reopen it, then try again."))
    }

    private static func isUnchanged(_ app: InstalledApp) -> Bool {
        fileIdentity(at: app.url) == app.identity && contents(of: app.url) == app.contents
    }

    /// Puts back an item that turned out to be at the installed path during the swap.
    private static func restore(_ displaced: URL, to original: URL) -> UpdateError {
        if renamex_np(displaced.path, original.path, UInt32(RENAME_SWAP)) == 0 { return replacedError }
        let aside = displaced.deletingLastPathComponent()
            .appending(path: "OpenToolbox (moved aside \(UUID().uuidString.prefix(8))).app", directoryHint: .isDirectory)
        let location = renamex_np(displaced.path, aside.path, UInt32(RENAME_EXCL)) == 0 ? aside : displaced
        return .installFailed(coreLocalized(
            "Another app was found in place of OpenToolbox during the update. It was kept at \(location.path)."))
    }

    private func isVerifiedCopy(_ prepared: PreparedUpdate) -> Bool {
        let app = prepared.stagedApp
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false,
            let info = Self.bundleInfo(at: app), info.identifier == bundleIdentifier,
            info.versionString == prepared.version.description,
            Self.contents(of: app) == prepared.contents
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
        let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]]
        guard let path = entities?.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.diskImageContents(coreLocalized("it could not be opened."))
        }
        let mountPoint = URL(fileURLWithPath: path, isDirectory: true)
        guard mountPoint.deletingLastPathComponent().resolvingSymlinksInPath().path
            == mountRoot.resolvingSymlinksInPath().path
        else { throw UpdateError.diskImageContents(coreLocalized("it opened in an unexpected location.")) }
        return mountPoint
    }

    /// Detaches `image` if it is attached, looking up its current device before each attempt.
    /// Returns whether the image is no longer attached.
    private func detach(_ image: URL) async -> Bool {
        let commands = commands
        let target = Self.resolved(image.path)
        return await Task.detached {
            for arguments in [["detach"], ["detach", "-force"]] {
                guard let images = await Self.attachedImages(commands) else { return false }
                guard let device = images.first(where: { $0.path == target })?.device else { return true }
                _ = try? await commands.run("/usr/bin/hdiutil", arguments: arguments + [device])
            }
            guard let images = await Self.attachedImages(commands) else { return false }
            return !images.contains { $0.path == target }
        }.value
    }

    private struct AttachedImage: Sendable {
        let path: String
        let device: String?
        let mountPoints: [String]
    }

    private static func attachedImages(_ commands: UpdateCommandRunner) async -> [AttachedImage]? {
        guard let output = try? await commands.run("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        else { return nil }
        return ((plist["images"] as? [[String: Any]]) ?? []).compactMap { image in
            guard let path = image["image-path"] as? String else { return nil }
            let entities = (image["system-entities"] as? [[String: Any]]) ?? []
            return AttachedImage(
                path: resolved(path), device: entities.first?["dev-entry"] as? String,
                mountPoints: entities.compactMap { $0["mount-point"] as? String }.map(resolved))
        }
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func stage(from mountPoint: URL, version: AppVersion, next installedApp: URL) async throws
        -> (app: URL, codeHash: Data, contents: BundleContents)
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
        guard let codeHash = Self.codeHash(of: source), let contents = Self.contents(of: source) else {
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
        return (staged, codeHash, contents)
    }
}
