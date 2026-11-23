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

/// The app bundle's identity and `Info.plist`, taken at startup, before its executable is hashed in the background.
public struct LaunchRecord: Sendable {
    public enum Executable: Equatable, Sendable {
        /// The bundle's executable must contain this build of the running process.
        case running(UUID)
        case unchecked
    }

    let url: URL
    let identity: FileIdentity
    let infoPlist: String
    let executable: Executable
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
    static let stagedPrefix = ".OpenToolbox-staged-"

    private let downloader: EngineDownloader
    private let commands: UpdateCommandRunner
    private let workRoot: URL
    private let bundleIdentifier: String
    var willSwap: @Sendable () -> Void = {}

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

    /// The build of the running executable, or `nil` when it can't be read.
    public static func runningExecutable() -> LaunchRecord.Executable? {
        MachOImage.runningUUID().map(LaunchRecord.Executable.running)
    }

    /// Takes the quick part of the launch record. Call it as early as possible at startup.
    public static func launchRecord(at url: URL, executable: LaunchRecord.Executable) -> LaunchRecord? {
        guard let identity = fileIdentity(at: url),
            let data = readRegularFile(url.appending(path: "Contents/Info.plist"))
        else { return nil }
        return LaunchRecord(
            url: url, identity: identity, infoPlist: HashGenerator.hash(data, algorithm: .sha256), executable: executable)
    }

    /// Hashes the executable recorded in `record`. Returns `nil` when the bundle changed since `record` was taken
    /// or its executable is not the build that is running.
    public static func installedApp(completing record: LaunchRecord) -> InstalledApp? {
        guard let inspected = inspect(record.url), inspected.contents.infoPlist == record.infoPlist,
            fileIdentity(at: record.url) == record.identity
        else { return nil }
        if case .running(let uuid) = record.executable, !inspected.uuids.contains(uuid) { return nil }
        return InstalledApp(url: record.url, identity: record.identity, contents: inspected.contents)
    }

    /// Downloads `update`, checks its size, SHA-256, bundle identifier, version and code signature,
    /// and copies the app next to `installed` without touching the installed copy.
    public func prepare(
        _ update: AppUpdate,
        replacing installed: InstalledApp,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedUpdate {
        guard Self.isUnchanged(installed) else { throw Self.replacedError }
        let id = UUID().uuidString
        let pending = workRoot.appending(path: ".pending-\(id)", directoryHint: .isDirectory)
        let work = workRoot.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        guard let lease = Self.lease(pending) else {
            try? FileManager.default.removeItem(at: pending)
            throw UpdateError.installFailed(coreLocalized("The update's work folder could not be locked."))
        }
        guard rename(pending.path, work.path) == 0 else {
            close(lease)
            try? FileManager.default.removeItem(at: pending)
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
            Self.releaseStaging(staged.app)
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
        else { throw UpdateError.installFailed(Self.changedMessage) }
        guard Self.isUnchanged(installed) else { throw Self.replacedError }

        let swapping = staged.deletingLastPathComponent().appending(
            path: "OpenToolbox (update in progress \(UUID().uuidString.prefix(8))).app", directoryHint: .isDirectory)
        willSwap()
        guard renamex_np(staged.path, swapping.path, UInt32(RENAME_EXCL)) == 0 else {
            throw UpdateError.installFailed(String(cString: strerror(errno)))
        }
        guard renamex_np(swapping.path, installed.url.path, UInt32(RENAME_SWAP)) == 0 else {
            let reason = String(cString: strerror(errno))
            guard renamex_np(swapping.path, staged.path, UInt32(RENAME_EXCL)) == 0 else {
                throw UpdateError.installFailed(Self.updateLeftNote(reason, at: swapping))
            }
            throw UpdateError.installFailed(reason)
        }
        let displaced = InstalledApp(url: swapping, identity: installed.identity, contents: installed.contents)
        guard Self.isUnchanged(displaced) else { throw Self.restore(swapping, to: installed.url, staged: staged) }
        guard isVerifiedCopy(prepared, at: installed.url) else {
            throw Self.restore(swapping, to: installed.url, staged: staged, incomingChanged: true)
        }
        try? FileManager.default.removeItem(at: swapping)
        Self.releaseStaging(staged)
    }

    /// Gives up a prepared update without removing its staged copy, so cleanup at a later launch may remove it.
    public func abandon(_ prepared: PreparedUpdate) {
        Self.releaseStaging(prepared.stagedApp)
    }

    /// Removes the staged copy of an update that will not be installed.
    public func discard(_ prepared: PreparedUpdate) {
        let staged = prepared.stagedApp
        defer { Self.releaseStaging(staged) }
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
    /// Copies that another running copy of OpenToolbox staged and still holds are left alone.
    public func removeLeftovers(next installedApp: URL) {
        let folder = installedApp.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where Self.isStagedName(name) {
            let candidate = folder.appending(path: name, directoryHint: .isDirectory)
            guard Self.bundleInfo(at: candidate)?.identifier == bundleIdentifier,
                let lease = Self.lease(file: Self.stagingLease(for: candidate))
            else { continue }
            try? FileManager.default.removeItem(at: candidate)
            unlink(Self.stagingLease(for: candidate).path)
            close(lease)
        }
        for name in names where Self.isStagingLeaseName(name) {
            let lease = folder.appending(path: name, directoryHint: .notDirectory)
            let app = folder.appending(path: String(name.dropLast(".lease".count)) + ".app", directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: app.path), let descriptor = Self.lease(file: lease) else { continue }
            unlink(lease.path)
            close(descriptor)
        }
    }

    /// Detaches disk images and removes downloads that an interrupted update left in the work folder.
    /// Work folders that another running copy of OpenToolbox still holds are left alone.
    public func removeStaleWork() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: workRoot.path) else { return }
        for name in names where Self.isPendingName(name) {
            let folder = workRoot.appending(path: name, directoryHint: .isDirectory)
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, Date().timeIntervalSince(modified) > Self.pendingGrace,
                let lease = Self.lease(folder)
            else { continue }
            try? FileManager.default.removeItem(at: folder)
            close(lease)
        }

        var leased: [(folder: URL, lease: Int32)] = []
        for name in names where UUID(uuidString: name) != nil {
            let folder = workRoot.appending(path: name, directoryHint: .isDirectory)
            if let lease = Self.lease(folder) { leased.append((folder, lease)) }
        }
        defer { for entry in leased { close(entry.lease) } }
        guard !leased.isEmpty, let images = await Self.attachedImages(commands) else { return }

        var kept = Set<URL>()
        for entry in leased {
            let prefix = Self.resolved(entry.folder.path) + "/"
            let isInside: @Sendable (AttachedImage) -> Bool = { $0.isInside(prefix) }
            guard images.contains(where: isInside) else { continue }
            if !(await Self.detach(commands, where: isInside)) { kept.insert(entry.folder) }
        }
        for entry in leased where !kept.contains(entry.folder) {
            try? FileManager.default.removeItem(at: entry.folder)
        }
    }

    static func isStagedName(_ name: String) -> Bool {
        isStagedName(name, suffix: ".app")
    }

    static func isStagingLeaseName(_ name: String) -> Bool {
        isStagedName(name, suffix: ".lease")
    }

    private static func isStagedName(_ name: String, suffix: String) -> Bool {
        guard name.hasPrefix(stagedPrefix), name.hasSuffix(suffix) else { return false }
        let id = name.dropFirst(stagedPrefix.count).dropLast(suffix.count)
        return UUID(uuidString: String(id)) != nil
    }

    static func isPendingName(_ name: String) -> Bool {
        name.hasPrefix(".pending-") && UUID(uuidString: String(name.dropFirst(".pending-".count))) != nil
    }

    static let pendingGrace: TimeInterval = 10 * 60

    /// The lock file that marks `staged` as held by the running copy of OpenToolbox that staged it.
    static func stagingLease(for staged: URL) -> URL {
        staged.deletingLastPathComponent().appending(
            path: staged.deletingPathExtension().lastPathComponent + ".lease", directoryHint: .notDirectory)
    }

    private static let stagingLock = NSLock()
    nonisolated(unsafe) private static var heldStagings: [String: Int32] = [:]

    static func holdStaging(_ staged: URL) -> Bool {
        let path = stagingLease(for: staged).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        stagingLock.withLock { heldStagings[path] = descriptor }
        return true
    }

    static func releaseStaging(_ staged: URL) {
        let path = stagingLease(for: staged).path
        guard let descriptor = stagingLock.withLock({ heldStagings.removeValue(forKey: path) }) else { return }
        unlink(path)
        close(descriptor)
    }

    static func bundleInfo(at app: URL) -> (identifier: String, version: AppVersion?, versionString: String?)? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = readRegularFile(plist),
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
        inspect(app)?.contents
    }

    /// The bundle's contents and the build identifiers of its executable, read from one open file.
    static func inspect(_ app: URL) -> (contents: BundleContents, uuids: [UUID])? {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = readRegularFile(plist),
            let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/")
        else { return nil }
        let descriptor = open(
            app.appending(path: "Contents/MacOS/\(name)").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        let uuids = MachOImage.uuids(of: handle)
        guard (try? handle.seek(toOffset: 0)) != nil,
            let digest = (try? HashGenerator.hashFile(handle, algorithms: [.sha256]) { _ in })?[.sha256]
        else { return nil }
        return (BundleContents(executable: digest, infoPlist: HashGenerator.hash(data, algorithm: .sha256)), uuids)
    }

    /// The contents of `url` when it is a regular file. Opening never waits, so a pipe or device put in its place
    /// can't block the caller.
    static func readRegularFile(_ url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? handle.readToEnd() ?? Data()
    }

    /// Takes an exclusive, non-blocking lock on `folder`, held until the returned descriptor is closed.
    static func lease(_ folder: URL) -> Int32? {
        lease(file: folder.appending(path: ".lease"))
    }

    static func lease(file: URL) -> Int32? {
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        return descriptor >= 0 ? descriptor : nil
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

    private static var replacedMessage: String {
        coreLocalized("OpenToolbox was moved, replaced or changed after it was opened. Quit and reopen it, then try again.")
    }

    private static var replacedError: UpdateError { .installFailed(replacedMessage) }

    private static func isUnchanged(_ app: InstalledApp) -> Bool {
        fileIdentity(at: app.url) == app.identity && contents(of: app.url) == app.contents
    }

    /// Puts back an item that turned out to be at the installed path during the swap. `displaced` has a name
    /// that startup cleanup never removes, so the item stays there if it can't be put back.
    private static func restore(
        _ displaced: URL, to original: URL, staged: URL, incomingChanged: Bool = false
    ) -> UpdateError {
        guard renamex_np(displaced.path, original.path, UInt32(RENAME_SWAP)) == 0 else {
            if incomingChanged {
                return .installFailed(coreLocalized(
                    "The update changed after it was checked, and the previous copy of OpenToolbox couldn't be put back. It was kept at \(displaced.path). Download OpenToolbox from GitHub and install it again."))
            }
            return .installFailed(coreLocalized(
                "Another app was found in place of OpenToolbox during the update. It was kept at \(displaced.path)."))
        }
        let reason = incomingChanged ? changedMessage : replacedMessage
        guard renamex_np(displaced.path, staged.path, UInt32(RENAME_EXCL)) == 0 else {
            return .installFailed(updateLeftNote(reason, at: displaced))
        }
        return .installFailed(reason)
    }

    private static var changedMessage: String {
        coreLocalized("The prepared update is missing or has changed.")
    }

    private static func updateLeftNote(_ reason: String, at location: URL) -> String {
        coreLocalized("\(reason) The downloaded update was left at \(location.path).")
    }

    private func isVerifiedCopy(_ prepared: PreparedUpdate, at location: URL? = nil) -> Bool {
        let app = location ?? prepared.stagedApp
        let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false,
            let info = Self.bundleInfo(at: app), info.identifier == bundleIdentifier,
            info.versionString == prepared.version.description,
            Self.contents(of: app) == prepared.contents
        else { return false }
        return Self.codeHash(of: app) == prepared.codeHash
    }

    static var usesDiskutilImage: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

    private func attach(_ image: URL, under mountRoot: URL) async throws -> URL {
        let commands = commands
        let output = try await Task.detached {
            if Self.usesDiskutilImage {
                let mountPoint = mountRoot.appending(path: "OpenToolbox", directoryHint: .isDirectory)
                if let output = try? await commands.run("/usr/sbin/diskutil", arguments: [
                    "image", "attach", "--readOnly", "--nobrowse", "--mountPoint", mountPoint.path, "--plist", image.path,
                ]) {
                    return output
                }
            }
            return try await commands.run("/usr/bin/hdiutil", arguments: [
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

    /// Detaches `image` if it is attached, together with any image mounted inside its work folder
    /// that macOS lists without a path. Returns whether none of them is still attached.
    private func detach(_ image: URL) async -> Bool {
        let target = Self.resolved(image.path)
        let folder = Self.resolved(image.deletingLastPathComponent().path) + "/"
        return await Self.detach(commands) { $0.path == target || ($0.path == nil && $0.isInside(folder)) }
    }

    /// Detaches every attached image that `matches` selects, looking up its current device before each attempt.
    /// Returns whether none of them is still attached.
    private static func detach(
        _ commands: UpdateCommandRunner, where matches: @escaping @Sendable (AttachedImage) -> Bool
    ) async -> Bool {
        await Task.detached {
            for attempt in Self.detachAttempts {
                guard let images = await Self.attachedImages(commands) else { return false }
                let matching = images.filter(matches)
                if matching.isEmpty { return true }
                for image in matching {
                    guard let device = image.device else { return false }
                    _ = try? await commands.run(attempt.executable, arguments: attempt.arguments + [device])
                }
            }
            guard let images = await Self.attachedImages(commands) else { return false }
            return !images.contains(where: matches)
        }.value
    }

    private static var detachAttempts: [(executable: String, arguments: [String])] {
        if usesDiskutilImage {
            return [("/usr/sbin/diskutil", ["eject"]), ("/usr/bin/hdiutil", ["detach", "-force"])]
        }
        return [("/usr/bin/hdiutil", ["detach"]), ("/usr/bin/hdiutil", ["detach", "-force"])]
    }

    struct AttachedImage: Sendable {
        let path: String?
        let device: String?
        let mountPoints: [String]

        func isInside(_ folder: String) -> Bool {
            path?.hasPrefix(folder) == true || mountPoints.contains { $0.hasPrefix(folder) }
        }
    }

    private static func attachedImages(_ commands: UpdateCommandRunner) async -> [AttachedImage]? {
        guard let output = try? await commands.run("/usr/bin/hdiutil", arguments: ["info", "-plist"]),
            let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
            let images = plist["images"] as? [[String: Any]]
        else { return nil }
        return images.compactMap { image in
            let entities = (image["system-entities"] as? [[String: Any]]) ?? []
            let mountPoints = entities.compactMap { $0["mount-point"] as? String }.map(resolved)
            let path = (image["image-path"] as? String).map(resolved)
            guard path != nil || !mountPoints.isEmpty else { return nil }
            return AttachedImage(path: path, device: entities.first?["dev-entry"] as? String, mountPoints: mountPoints)
        }
    }

    /// The canonical form of `path`: its deepest existing folder through `realpath`, then the rest as given.
    static func resolved(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while true {
            if let real = realpath(existing.path, nil) {
                defer { free(real) }
                return rest.reversed().reduce(URL(fileURLWithPath: String(cString: real))) {
                    $0.appending(path: $1)
                }.path
            }
            guard existing.path != "/" else {
                return rest.reversed().reduce(existing) { $0.appending(path: $1) }.path
            }
            rest.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
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
        guard Self.holdStaging(staged) else {
            throw UpdateError.installFailed(coreLocalized("The update's copy next to OpenToolbox could not be locked."))
        }
        do {
            _ = try await commands.run("/usr/bin/ditto", arguments: [source.path, staged.path])
        } catch {
            try? FileManager.default.removeItem(at: staged)
            Self.releaseStaging(staged)
            throw error
        }
        return (staged, codeHash, contents)
    }
}
