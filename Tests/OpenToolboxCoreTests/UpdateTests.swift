import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("App updates", .serialized)
struct UpdateTests {
    @Test func versionsParseAndCompareNumerically() throws {
        let v011 = try #require(AppVersion("v0.1.1"))
        #expect(v011.description == "0.1.1")
        #expect(try #require(AppVersion("0.1.10")) > v011)
        #expect(try #require(AppVersion("0.2")) > v011)
        #expect(AppVersion("0.1") == AppVersion("0.1.0"))
        #expect(Set([AppVersion("1.0")!, AppVersion("1.0.0")!]).count == 1)
        #expect(AppVersion(" 1.2 ") == AppVersion("1.2"))
        for bad in ["", "v", "1..2", "1.2-beta", "1.2.3.4.5", "a.b", "１.2", "+1.2"] {
            #expect(AppVersion(bad) == nil, "\(bad)")
        }
    }

    @Test func newerReleaseWithDigestIsAvailable() throws {
        let result = try UpdateFeed.evaluate(Self.release(tag: "v0.2.0"), current: AppVersion("0.1.1")!)
        guard case .available(let update) = result else { Issue.record("expected an update"); return }
        #expect(update.version == AppVersion("0.2.0"))
        #expect(update.diskImageName == "OpenToolbox-0.2.0-macOS-universal.dmg")
        #expect(update.sha256 == String(repeating: "ab", count: 32))
        #expect(update.sizeBytes == 4_096)
        #expect(update.releasePage.absoluteString == "https://github.com/LetterXbox/OpenToolbox/releases/tag/v0.2.0")
    }

    @Test func sameOrOlderReleaseIsUpToDate() throws {
        let current = AppVersion("0.2.0")!
        #expect(try UpdateFeed.evaluate(Self.release(tag: "v0.2.0"), current: current) == .upToDate(latest: current))
        #expect(try UpdateFeed.evaluate(Self.release(tag: "v0.1.1"), current: current)
            == .upToDate(latest: AppVersion("0.1.1")!))
        #expect(try UpdateFeed.evaluate(Self.release(tag: "v0.3.0", prerelease: true), current: current)
            == .upToDate(latest: AppVersion("0.3.0")!))
    }

    @Test func releaseWithoutTrustedAssetIsRejected() throws {
        let current = AppVersion("0.1.0")!
        #expect(throws: UpdateError.missingChecksum("OpenToolbox-0.2.0-macOS-universal.dmg")) {
            try UpdateFeed.evaluate(Self.release(tag: "v0.2.0", digest: nil), current: current)
        }
        #expect(throws: UpdateError.missingChecksum("OpenToolbox-0.2.0-macOS-universal.dmg")) {
            try UpdateFeed.evaluate(Self.release(tag: "v0.2.0", digest: "sha512:abcd"), current: current)
        }
        #expect(throws: UpdateError.missingDiskImage("OpenToolbox-0.2.0-macOS-universal.dmg")) {
            try UpdateFeed.evaluate(Self.release(tag: "v0.2.0", assetName: "OpenToolbox-0.1.0-macOS-universal.dmg"),
                current: current)
        }
        #expect(throws: UpdateError.missingDiskImage("OpenToolbox-0.2.0-macOS-universal.dmg")) {
            try UpdateFeed.evaluate(Self.release(tag: "v0.2.0", host: "example.com"), current: current)
        }
        #expect(throws: UpdateError.invalidResponse) {
            try UpdateFeed.evaluate(Data("{}".utf8), current: current)
        }
        #expect(throws: UpdateError.invalidResponse) {
            try UpdateFeed.evaluate(Self.release(tag: "nightly"), current: current)
        }
        #expect(throws: UpdateError.invalidResponse) {
            try UpdateFeed.evaluate(Self.release(tag: "0.2.0"), current: current)
        }
    }

    @Test func checkerMapsHTTPStatus() async throws {
        let current = AppVersion("0.1.0")!
        let ok = StubHTTPClient(status: 200, body: Self.release(tag: "v0.2.0"))
        guard case .available = try await UpdateChecker(client: ok).check(current: current) else {
            Issue.record("expected an update"); return
        }
        #expect(ok.requests == [UpdateFeed.latestReleaseURL])
        await #expect(throws: UpdateError.noPublishedRelease) {
            try await UpdateChecker(client: StubHTTPClient(status: 404, body: Data())).check(current: current)
        }
        await #expect(throws: UpdateError.httpStatus(403)) {
            try await UpdateChecker(client: StubHTTPClient(status: 403, body: Data())).check(current: current)
        }
    }

    @Test func unsupportedLocationsAreReported() throws {
        try withTemporaryDirectorySync { root in
            let app = try Self.makeApp(in: root, version: "0.1.0")
            #expect(UpdateInstaller.unsupportedReason(for: app, bundleIdentifier: UpdateFeed.bundleIdentifier) == nil)
            #expect(UpdateInstaller.unsupportedReason(for: app, bundleIdentifier: "com.example.other") != nil)
            #expect(UpdateInstaller.unsupportedReason(
                for: root.appending(path: "OpenToolbox"), bundleIdentifier: UpdateFeed.bundleIdentifier) != nil)
            #expect(UpdateInstaller.unsupportedReason(
                for: URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/OpenToolbox.app"),
                bundleIdentifier: UpdateFeed.bundleIdentifier) != nil)
        }
    }

    @Test func relaunchCommandPassesValuesAsArguments() {
        let app = URL(fileURLWithPath: "/Applications/Open \"Tool\"; box.app")
        let command = UpdateInstaller.relaunchCommand(waitingFor: 4242, app: app)
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments.suffix(3) == ["sh", "4242", app.path])
        #expect(!command.arguments[1].contains(app.path))
    }

    @Test func installSwapsStagedAppAndRemovesOldCopy() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(next: installed, version: "0.2.0")
            try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.2.0"))
            #expect(!FileManager.default.fileExists(atPath: prepared.stagedApp.path))
        }
    }

    @Test func installRefusesUnexpectedStagedPaths() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(next: installed, version: "0.2.0")
            let other = root.appending(path: "Other.app", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: prepared.stagedApp, to: other)
            let unexpected = PreparedUpdate(
                version: prepared.version, stagedApp: other, installedApp: installed,
                installedIdentity: prepared.installedIdentity, codeHash: prepared.codeHash)
            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(unexpected)
            }
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.1.0"))
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }

    @Test func installLeavesAReplacedDestinationInPlace() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(next: installed, version: "0.2.0")
            let moved = root.appending(path: "Moved.app", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: installed, to: moved)
            try Self.makeApp(in: root, version: "0.1.5")

            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            }
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.1.5"))
            #expect(UpdateInstaller.bundleInfo(at: moved)?.version == AppVersion("0.1.0"))
            #expect(UpdateInstaller.bundleInfo(at: prepared.stagedApp)?.version == AppVersion("0.2.0"))
        }
    }

    @Test func installRefusesAStagedAppChangedAfterVerification() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(next: installed, version: "0.2.0")
            let installer = UpdateInstaller(workRoot: root.appending(path: "work"))
            let executable = prepared.stagedApp.appending(path: "Contents/MacOS/OpenToolbox")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)

            #expect(throws: UpdateError.self) { try installer.install(prepared) }
            _ = try await SystemUpdateCommandRunner().run(
                "/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", prepared.stagedApp.path])
            #expect(throws: UpdateError.self) { try installer.install(prepared) }
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.1.0"))
            #expect(FileManager.default.fileExists(atPath: prepared.stagedApp.path))
        }
    }

    @Test func leftoversAreRemovedOnlyWhenTheyAreStagedCopies() throws {
        try withTemporaryDirectorySync { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let leftover = try Self.makeApp(in: root, version: "0.2.0",
                name: "\(UpdateInstaller.stagedPrefix)\(UUID().uuidString).app")
            let foreign = try Self.makeApp(in: root, version: "0.2.0",
                name: "\(UpdateInstaller.stagedPrefix)\(UUID().uuidString).app", identifier: "com.example.other")
            let lookalike = try Self.makeApp(in: root, version: "0.2.0", name: "\(UpdateInstaller.stagedPrefix)notes.app")
            UpdateInstaller(workRoot: root.appending(path: "work")).removeLeftovers(next: installed)
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(FileManager.default.fileExists(atPath: lookalike.path))
            #expect(FileManager.default.fileExists(atPath: installed.path))
        }
    }

    @Test func checksumMismatchStopsBeforeMounting() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let image = root.appending(path: "fake.dmg")
            try Data(repeating: 7, count: 64).write(to: image)
            let update = Self.update(version: "0.2.0", image: image, sha256: String(repeating: "0", count: 64))
            let commands = RecordingCommands()
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]), commands: commands,
                workRoot: root.appending(path: "work"))
            await #expect(throws: UpdateError.checksumMismatch) {
                try await installer.prepare(update, replacing: installed) { _ in }
            }
            #expect(commands.calls.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path).isEmpty)
        }
    }

    @Test func diskImageRoundTripInstallsVerifiedApp() async throws {
        try await withTemporaryDirectory { root in
            let installDir = root.appending(path: "Applications", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)
            let installed = try Self.makeApp(in: installDir, version: "0.1.0")
            let image = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let update = Self.update(version: "0.2.0", image: image,
                sha256: try HashGenerator.hashFile(at: image, algorithm: .sha256))
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]),
                workRoot: root.appending(path: "work"))

            let prepared = try await installer.prepare(update, replacing: installed) { _ in }
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.1.0"))
            #expect(UpdateInstaller.bundleInfo(at: prepared.stagedApp)?.version == AppVersion("0.2.0"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path).isEmpty)

            try installer.install(prepared)
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.2.0"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: installDir.path) == ["OpenToolbox.app"])
        }
    }

    @Test(arguments: ["0.3.0", "0.2"])
    func diskImageWithWrongVersionIsRejected(imageVersion: String) async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let image = try await Self.makeDiskImage(in: root, version: imageVersion)
            let update = Self.update(version: "0.2.0", image: image,
                sha256: try HashGenerator.hashFile(at: image, algorithm: .sha256))
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]),
                workRoot: root.appending(path: "work"))
            await #expect(throws: UpdateError.self) {
                try await installer.prepare(update, replacing: installed) { _ in }
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!names.contains(where: { UpdateInstaller.isStagedName($0) }))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path).isEmpty)
        }
    }

    @Test func cancellingAfterMountingDetachesAndLeavesNoStagedCopy() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.makeApp(in: root, version: "0.1.0")
            let image = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let update = Self.update(version: "0.2.0", image: image,
                sha256: try HashGenerator.hashFile(at: image, algorithm: .sha256))
            let commands = CancelAfterAttach()
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]), commands: commands,
                workRoot: root.appending(path: "work"))
            let task = Task { try await installer.prepare(update, replacing: installed) { _ in } }
            commands.cancelAfterAttach(task)

            await #expect(throws: CancellationError.self) { try await task.value }
            let info = try await SystemUpdateCommandRunner().run("/usr/bin/hdiutil", arguments: ["info"])
            #expect(!String(decoding: info, as: UTF8.self).contains(root.lastPathComponent))
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!names.contains(where: { UpdateInstaller.isStagedName($0) }))
            #expect(UpdateInstaller.bundleInfo(at: installed)?.version == AppVersion("0.1.0"))
        }
    }

    @Test func staleWorkIsDetachedAndRemoved() async throws {
        try await withTemporaryDirectory { root in
            let work = root.appending(path: "work", directoryHint: .isDirectory)
            let interrupted = work.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let mountRoot = interrupted.appending(path: "mount", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
            let unrelated = work.appending(path: "keep-me", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
            let image = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let runner = SystemUpdateCommandRunner()
            _ = try await runner.run("/usr/bin/hdiutil", arguments: [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountroot", mountRoot.path, image.path,
            ])

            let unmounted = interrupted.appending(path: "unmounted.dmg")
            try FileManager.default.copyItem(at: image, to: unmounted)
            _ = try await runner.run("/usr/bin/hdiutil", arguments: ["attach", "-nomount", unmounted.path])

            await UpdateInstaller(workRoot: work).removeStaleWork()

            #expect(!FileManager.default.fileExists(atPath: interrupted.path))
            #expect(FileManager.default.fileExists(atPath: unrelated.path))
            let info = try await runner.run("/usr/bin/hdiutil", arguments: ["info"])
            #expect(!String(decoding: info, as: UTF8.self).contains(interrupted.lastPathComponent))
        }
    }

    static func release(
        tag: String,
        prerelease: Bool = false,
        assetName: String? = nil,
        host: String = "github.com",
        digest: String? = "sha256:" + String(repeating: "AB", count: 32)
    ) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let name = assetName ?? "OpenToolbox-\(version)-macOS-universal.dmg"
        var asset: [String: Any] = [
            "name": name,
            "browser_download_url": "https://\(host)/LetterXbox/OpenToolbox/releases/download/\(tag)/\(name)",
            "size": 4_096,
        ]
        if let digest { asset["digest"] = digest }
        let release: [String: Any] = [
            "tag_name": tag,
            "html_url": "https://github.com/LetterXbox/OpenToolbox/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": [asset],
        ]
        return try! JSONSerialization.data(withJSONObject: release)
    }

    static func update(version: String, image: URL, sha256: String) -> AppUpdate {
        let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? NSNumber)?.int64Value ?? 0
        let name = "OpenToolbox-\(version)-macOS-universal.dmg"
        return AppUpdate(
            version: AppVersion(version)!,
            releasePage: URL(string: "https://github.com/LetterXbox/OpenToolbox/releases/tag/v\(version)")!,
            diskImageName: name,
            diskImageURL: URL(string: "https://github.com/LetterXbox/OpenToolbox/releases/download/v\(version)/\(name)")!,
            sizeBytes: size, sha256: sha256)
    }

    static func stagedUpdate(next installed: URL, version: String) async throws -> PreparedUpdate {
        let staged = try makeApp(in: installed.deletingLastPathComponent(), version: version,
            name: "\(UpdateInstaller.stagedPrefix)\(UUID().uuidString).app")
        _ = try await SystemUpdateCommandRunner().run(
            "/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", staged.path])
        return PreparedUpdate(
            version: try #require(AppVersion(version)), stagedApp: staged, installedApp: installed,
            installedIdentity: try #require(UpdateInstaller.fileIdentity(at: installed)),
            codeHash: try #require(UpdateInstaller.codeHash(of: staged)))
    }

    @discardableResult
    static func makeApp(
        in folder: URL,
        version: String,
        name: String = "OpenToolbox.app",
        identifier: String = UpdateFeed.bundleIdentifier
    ) throws -> URL {
        let app = folder.appending(path: name, directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: contents.appending(path: "MacOS", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
            "CFBundleExecutable": "OpenToolbox", "CFBundlePackageType": "APPL", "CFBundleName": "OpenToolbox",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appending(path: "MacOS/OpenToolbox"))
        return app
    }

    static func makeDiskImage(in root: URL, version: String) async throws -> URL {
        let source = root.appending(path: "dmg-\(version)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let app = try makeApp(in: source, version: version)
        let runner = SystemUpdateCommandRunner()
        _ = try await runner.run("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", app.path])
        let image = root.appending(path: "OpenToolbox-\(version).dmg")
        _ = try await runner.run("/usr/bin/hdiutil", arguments: [
            "create", "-quiet", "-srcfolder", source.path, "-volname", "OpenToolbox", "-format", "UDZO", image.path,
        ])
        return image
    }
}

func withTemporaryDirectorySync<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = try EngineDirectory.systemTemporaryDirectory()
        .appending(path: "OpenToolboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

final class StubHTTPClient: UpdateHTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: Data
    private var _requests: [URL] = []

    init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    var requests: [URL] { lock.withLock { _requests } }

    func get(_ url: URL) async throws -> (Data, Int) {
        lock.withLock { _requests.append(url) }
        return (body, status)
    }
}

final class RecordingCommands: UpdateCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ executable: String, arguments: [String]) async throws -> Data {
        lock.withLock { _calls.append([executable] + arguments) }
        throw UpdateError.installFailed("not expected")
    }
}

final class CancelAfterAttach: UpdateCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let system = SystemUpdateCommandRunner()
    private var target: Task<PreparedUpdate, Error>?

    func cancelAfterAttach(_ task: Task<PreparedUpdate, Error>) {
        lock.withLock { target = task }
    }

    func run(_ executable: String, arguments: [String]) async throws -> Data {
        let output = try await system.run(executable, arguments: arguments)
        if arguments.first == "attach" {
            while lock.withLock({ target }) == nil { try await Task.sleep(for: .milliseconds(10)) }
            lock.withLock { target }?.cancel()
        }
        return output
    }
}
