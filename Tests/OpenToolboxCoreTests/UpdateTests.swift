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
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0")
            try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.2.0"))
            #expect(!FileManager.default.fileExists(atPath: prepared.stagedApp.path))
        }
    }

    @Test func installRefusesUnexpectedStagedPaths() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0")
            let other = root.appending(path: "Other.app", directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: prepared.stagedApp, to: other)
            let unexpected = PreparedUpdate(
                version: prepared.version, stagedApp: other, installed: installed,
                codeHash: prepared.codeHash, contents: prepared.contents)
            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(unexpected)
            }
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.0"))
            #expect(FileManager.default.fileExists(atPath: other.path))
        }
    }

    @Test func installLeavesAReplacedDestinationInPlace() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0")
            let moved = root.appending(path: "Moved.app", directoryHint: .isDirectory)
            try FileManager.default.moveItem(at: installed.url, to: moved)
            try Self.makeApp(in: root, version: "0.1.5")

            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            }
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.5"))
            #expect(UpdateInstaller.bundleInfo(at: moved)?.version == AppVersion("0.1.0"))
            #expect(UpdateInstaller.bundleInfo(at: prepared.stagedApp)?.version == AppVersion("0.2.0"))
        }
    }

    @Test func installLeavesAnInstalledAppChangedInPlaceAlone() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0")
            let executable = installed.url.appending(path: "Contents/MacOS/OpenToolbox")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)
            #expect(UpdateInstaller.fileIdentity(at: installed.url) == installed.identity)

            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            }
            #expect(try HashGenerator.hashFile(at: executable, algorithm: .sha256)
                == HashGenerator.hashFile(at: URL(fileURLWithPath: "/bin/echo"), algorithm: .sha256))
            #expect(UpdateInstaller.bundleInfo(at: prepared.stagedApp)?.version == AppVersion("0.2.0"))
        }
    }

    @Test func prepareRefusesAnAppReplacedSinceLaunch() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            try FileManager.default.removeItem(at: installed.url)
            try Self.makeApp(in: root, version: "0.1.0")
            let image = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let update = Self.update(version: "0.2.0", image: image,
                sha256: try HashGenerator.hashFile(at: image, algorithm: .sha256))
            let commands = RecordingCommands()
            let work = root.appending(path: "work")
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]), commands: commands,
                workRoot: work)

            await #expect(throws: UpdateError.self) {
                try await installer.prepare(update, replacing: installed) { _ in }
            }
            #expect(commands.calls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: work.path))
        }
    }

    @Test func installRefusesAStagedAppChangedAfterVerification() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0")
            let installer = UpdateInstaller(workRoot: root.appending(path: "work"))
            let executable = prepared.stagedApp.appending(path: "Contents/MacOS/OpenToolbox")
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: executable)

            #expect(throws: UpdateError.self) { try installer.install(prepared) }
            try await Self.sign(prepared.stagedApp)
            #expect(throws: UpdateError.self) { try installer.install(prepared) }
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.0"))
            #expect(FileManager.default.fileExists(atPath: prepared.stagedApp.path))
        }
    }

    @Test func installRefusesAStagedAppMissingAnArchitecture() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
            let universal = try await Self.makeUniversalExecutable(in: root)
            let prepared = try await Self.stagedUpdate(for: installed, version: "0.2.0", executable: universal)
            let executable = prepared.stagedApp.appending(path: "Contents/MacOS/OpenToolbox")
            #if arch(arm64)
                let otherArchitecture = "x86_64"
            #else
                let otherArchitecture = "arm64"
            #endif
            let thinned = root.appending(path: "thinned")
            _ = try await SystemUpdateCommandRunner().run(
                "/usr/bin/lipo", arguments: [executable.path, "-remove", otherArchitecture, "-output", thinned.path])
            try FileManager.default.removeItem(at: executable)
            try FileManager.default.moveItem(at: thinned, to: executable)
            try #require(UpdateInstaller.codeHash(of: prepared.stagedApp) == prepared.codeHash)

            #expect(throws: UpdateError.self) {
                try UpdateInstaller(workRoot: root.appending(path: "work")).install(prepared)
            }
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.0"))
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
            let swapping = try Self.makeApp(in: root, version: "0.1.0", name: "OpenToolbox (update in progress 1A2B3C4D).app")
            UpdateInstaller(workRoot: root.appending(path: "work")).removeLeftovers(next: installed)
            #expect(FileManager.default.fileExists(atPath: swapping.path))
            #expect(!FileManager.default.fileExists(atPath: leftover.path))
            #expect(FileManager.default.fileExists(atPath: foreign.path))
            #expect(FileManager.default.fileExists(atPath: lookalike.path))
            #expect(FileManager.default.fileExists(atPath: installed.path))
        }
    }

    @Test func checksumMismatchStopsBeforeMounting() async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
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
            let installed = try Self.installedApp(in: installDir, version: "0.1.0")
            let image = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let update = Self.update(version: "0.2.0", image: image,
                sha256: try HashGenerator.hashFile(at: image, algorithm: .sha256))
            let installer = UpdateInstaller(
                downloader: LocalFileDownloader(files: [update.diskImageURL: image]),
                workRoot: root.appending(path: "work"))

            let prepared = try await installer.prepare(update, replacing: installed) { _ in }
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.0"))
            #expect(UpdateInstaller.bundleInfo(at: prepared.stagedApp)?.version == AppVersion("0.2.0"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "work").path).isEmpty)

            try installer.install(prepared)
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.2.0"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: installDir.path) == ["OpenToolbox.app"])
        }
    }

    @Test(arguments: ["0.3.0", "0.2"])
    func diskImageWithWrongVersionIsRejected(imageVersion: String) async throws {
        try await withTemporaryDirectory { root in
            let installed = try Self.installedApp(in: root, version: "0.1.0")
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
            let installed = try Self.installedApp(in: root, version: "0.1.0")
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
            #expect(UpdateInstaller.bundleInfo(at: installed.url)?.version == AppVersion("0.1.0"))
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

    @Test func pathsResolveTheSameWhetherOrNotTheyExist() throws {
        try withTemporaryDirectorySync { root in
            let folder = root.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let missing = UpdateInstaller.resolved(folder.appending(path: "missing.dmg").path)
            #expect(missing == UpdateInstaller.resolved(folder.path) + "/missing.dmg")
            #expect(UpdateInstaller.resolved(folder.path) == UpdateInstaller.resolved(folder.path + "/"))
        }
    }

    @Test func staleWorkIsKeptWhenAttachedImagesAreUnknown() async throws {
        try await withTemporaryDirectory { root in
            let work = root.appending(path: "work", directoryHint: .isDirectory)
            let interrupted = work.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
            let image = interrupted.appending(path: "update.dmg").path
            let pending = work.appending(path: ".pending-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

            let inventories: [[String: Any]] = [
                [:],
                ["images": [["image-path": image]]],
                ["images": [["image-path": image, "system-entities": [["mount-point": interrupted.path]]]]],
            ]
            for inventory in inventories {
                let commands = FixedInventory(inventory)
                await UpdateInstaller(commands: commands, workRoot: work).removeStaleWork()
                #expect(FileManager.default.fileExists(atPath: interrupted.path))
            }
            await UpdateInstaller(commands: FixedInventory(["images": []]), workRoot: work).removeStaleWork()
            #expect(!FileManager.default.fileExists(atPath: interrupted.path))
            #expect(FileManager.default.fileExists(atPath: pending.path))
        }
    }

    @Test func workHeldByARunningCopyIsLeftAlone() async throws {
        try await withTemporaryDirectory { root in
            let work = root.appending(path: "work", directoryHint: .isDirectory)
            let live = work.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
            let source = try await Self.makeDiskImage(in: root, version: "0.2.0")
            let image = live.appending(path: "update.dmg")
            try FileManager.default.copyItem(at: source, to: image)
            let runner = SystemUpdateCommandRunner()
            _ = try await runner.run("/usr/bin/hdiutil", arguments: ["attach", "-nomount", image.path])
            let lease = try #require(UpdateInstaller.lease(live))

            await UpdateInstaller(workRoot: work).removeStaleWork()
            #expect(FileManager.default.fileExists(atPath: image.path))
            var info = try await runner.run("/usr/bin/hdiutil", arguments: ["info"])
            #expect(String(decoding: info, as: UTF8.self).contains(live.lastPathComponent))

            close(lease)
            await UpdateInstaller(workRoot: work).removeStaleWork()
            #expect(!FileManager.default.fileExists(atPath: live.path))
            info = try await runner.run("/usr/bin/hdiutil", arguments: ["info"])
            #expect(!String(decoding: info, as: UTF8.self).contains(live.lastPathComponent))
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

    static func installedApp(in folder: URL, version: String) throws -> InstalledApp {
        let app = try makeApp(in: folder, version: version)
        return try #require(UpdateInstaller.installedApp(at: app))
    }

    static func stagedUpdate(
        for installed: InstalledApp,
        version: String,
        executable: URL = URL(fileURLWithPath: "/usr/bin/true")
    ) async throws -> PreparedUpdate {
        let staged = try makeApp(in: installed.url.deletingLastPathComponent(), version: version,
            name: "\(UpdateInstaller.stagedPrefix)\(UUID().uuidString).app", executable: executable)
        try await sign(staged)
        return PreparedUpdate(
            version: try #require(AppVersion(version)), stagedApp: staged, installed: installed,
            codeHash: try #require(UpdateInstaller.codeHash(of: staged)),
            contents: try #require(UpdateInstaller.contents(of: staged)))
    }

    static func sign(_ app: URL) async throws {
        _ = try await SystemUpdateCommandRunner().run(
            "/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", app.path])
    }

    static func makeUniversalExecutable(in folder: URL) async throws -> URL {
        let source = folder.appending(path: "main.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        let executable = folder.appending(path: "universal")
        _ = try await SystemUpdateCommandRunner().run("/usr/bin/xcrun", arguments: [
            "clang", "-arch", "arm64", "-arch", "x86_64", source.path, "-o", executable.path,
        ])
        return executable
    }

    @discardableResult
    static func makeApp(
        in folder: URL,
        version: String,
        name: String = "OpenToolbox.app",
        identifier: String = UpdateFeed.bundleIdentifier,
        executable: URL = URL(fileURLWithPath: "/usr/bin/true")
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
        try FileManager.default.copyItem(at: executable, to: contents.appending(path: "MacOS/OpenToolbox"))
        return app
    }

    static func makeDiskImage(in root: URL, version: String) async throws -> URL {
        let source = root.appending(path: "dmg-\(version)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let app = try makeApp(in: source, version: version)
        let runner = SystemUpdateCommandRunner()
        try await sign(app)
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

final class FixedInventory: UpdateCommandRunner, @unchecked Sendable {
    private let inventory: Data

    init(_ inventory: [String: Any]) {
        self.inventory = try! PropertyListSerialization.data(fromPropertyList: inventory, format: .xml, options: 0)
    }

    func run(_ executable: String, arguments: [String]) async throws -> Data {
        guard arguments == ["info", "-plist"] else { throw UpdateError.installFailed("not expected") }
        return inventory
    }
}
