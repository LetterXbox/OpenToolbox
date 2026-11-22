import Foundation
import Testing

@testable import OpenToolboxApp
@testable import OpenToolboxCore

@MainActor
@Suite("Update channel", .serialized)
struct UpdateCenterTests {
    @Test func testBuildsDefaultToTheRunningBuildsChannel() throws {
        try withFixture(version: "0.3.0") { fixture in
            #expect(!fixture.center().receivesTestBuilds)
        }
        try withFixture(version: "0.3.0-rc.1") { fixture in
            #expect(fixture.center().receivesTestBuilds)
            fixture.defaults.set(false, forKey: "UpdatesReceiveTestBuilds")
            #expect(!fixture.center().receivesTestBuilds)
        }
        try withFixture(version: "0.3.0") { fixture in
            let center = fixture.center()
            center.receivesTestBuilds = true
            #expect(fixture.defaults.object(forKey: "UpdatesReceiveTestBuilds") as? Bool == true)
            #expect(fixture.center().receivesTestBuilds)
        }
    }

    @Test func turningTestBuildsOffDropsAnOfferedTestBuild() async throws {
        try await withFixture(version: "0.2.0", testBuilds: true) { fixture in
            let update = fixture.update("0.3.0-rc.1")
            fixture.checks.results = [.available(update)]
            let center = fixture.center()
            center.checkNow(userInitiated: true)
            try await waitUntil { center.phase == .available(update) }

            center.receivesTestBuilds = false
            #expect(center.phase == .idle)
        }
    }

    @Test func turningTestBuildsOffDiscardsAStagedTestBuild() async throws {
        try await withFixture(version: "0.2.0", testBuilds: true) { fixture in
            let update = fixture.update("0.3.0-rc.1")
            let center = fixture.center()
            center.install(update)
            try await waitUntil { if case .ready = center.phase { true } else { false } }

            center.receivesTestBuilds = false
            #expect(center.phase == .idle)
            #expect(fixture.installer.discarded == [fixture.stagedApp])
            center.installOnQuit()
            #expect(fixture.installer.installed.isEmpty)
        }
    }

    @Test func aTestBuildFinishingAfterOptingOutIsDiscarded() async throws {
        try await withFixture(version: "0.2.0", testBuilds: true) { fixture in
            let update = fixture.update("0.3.0-rc.1")
            fixture.installer.holdsPrepare = true
            let center = fixture.center()
            center.install(update)
            try await waitUntil { fixture.installer.prepareStarted }
            #expect(center.phase == .downloading(update, 0))

            center.receivesTestBuilds = false
            fixture.installer.releasePrepare()
            try await waitUntil { !fixture.installer.discarded.isEmpty }
            try await waitUntil { center.phase == .idle }
            #expect(fixture.installer.discarded == [fixture.stagedApp])
            center.installOnQuit()
            #expect(fixture.installer.installed.isEmpty)
        }
    }

    @Test func aStagedFullReleaseSurvivesOptingOut() async throws {
        try await withFixture(version: "0.3.0-rc.1") { fixture in
            let update = fixture.update("0.3.0")
            let center = fixture.center()
            center.install(update)
            try await waitUntil { if case .ready = center.phase { true } else { false } }

            center.receivesTestBuilds = false
            guard case .ready = center.phase else { Issue.record("the full release was dropped"); return }
            #expect(fixture.installer.discarded.isEmpty)
            center.installOnQuit()
            #expect(fixture.installer.installed == [fixture.stagedApp])
        }
    }

    @Test func switchingChannelsDuringACheckChecksAgain() async throws {
        try await withFixture(version: "0.2.0") { fixture in
            let update = fixture.update("0.3.0-rc.1")
            fixture.checks.results = [.upToDate(latest: AppVersion("0.2.0")!), .available(update)]
            fixture.checks.holdsFirst = true
            let center = fixture.center()
            center.checkNow(userInitiated: true)
            try await waitUntil { fixture.checks.requests.count == 1 }

            center.receivesTestBuilds = true
            fixture.checks.releaseFirst()
            try await waitUntil { center.phase == .available(update) }
            #expect(fixture.checks.requests == [false, true])
        }
    }
}

@MainActor
final class UpdateFixture {
    let root: URL
    let appURL: URL
    let stagedApp: URL
    let defaults: UserDefaults
    let suiteName = "OpenToolboxAppTests-\(UUID().uuidString)"
    let installer: StubInstaller
    let checks = StubChecks()

    init(version: String) throws {
        root = URL.temporaryDirectory.appending(path: "UpdateCenterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        appURL = root.appending(path: "OpenToolbox.app", directoryHint: .isDirectory)
        stagedApp = root.appending(path: ".OpenToolbox-update-test.app", directoryHint: .isDirectory)
        let macOS = appURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: macOS.appending(path: "OpenToolbox"))
        let info: [String: Any] = [
            "CFBundleIdentifier": UpdateFeed.bundleIdentifier,
            "CFBundleExecutable": "OpenToolbox",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: appURL.appending(path: "Contents/Info.plist"))
        defaults = UserDefaults(suiteName: suiteName)!
        installer = StubInstaller(stagedApp: stagedApp)
    }

    func center() -> UpdateCenter {
        let checks = checks
        return UpdateCenter(
            defaults: defaults, bundle: Bundle(url: appURL)!, installer: installer,
            check: { _, includingTestBuilds in try await checks.answer(includingTestBuilds: includingTestBuilds) })
    }

    func update(_ version: String) -> AppUpdate {
        let name = UpdateFeed.diskImageName(for: AppVersion(version)!)
        return AppUpdate(
            version: AppVersion(version)!,
            releasePage: URL(string: "https://github.com/LetterXbox/OpenToolbox/releases/tag/v\(version)")!,
            diskImageName: name,
            diskImageURL: URL(string: "https://github.com/LetterXbox/OpenToolbox/releases/download/v\(version)/\(name)")!,
            sizeBytes: 4_096, sha256: String(repeating: "ab", count: 32))
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
func withFixture(version: String, testBuilds: Bool? = nil, _ body: (UpdateFixture) throws -> Void) throws {
    let fixture = try UpdateFixture(version: version)
    defer { fixture.remove() }
    if let testBuilds { fixture.defaults.set(testBuilds, forKey: "UpdatesReceiveTestBuilds") }
    try body(fixture)
}

@MainActor
func withFixture(
    version: String, testBuilds: Bool? = nil, _ body: (UpdateFixture) async throws -> Void
) async throws {
    let fixture = try UpdateFixture(version: version)
    defer { fixture.remove() }
    if let testBuilds { fixture.defaults.set(testBuilds, forKey: "UpdatesReceiveTestBuilds") }
    try await body(fixture)
}

@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for the update state")
}

final class StubInstaller: UpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private let stagedApp: URL
    private var _discarded: [URL] = []
    private var _installed: [URL] = []
    private var _prepareStarted = false
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    var holdsPrepare = false

    init(stagedApp: URL) {
        self.stagedApp = stagedApp
    }

    var discarded: [URL] { lock.withLock { _discarded } }
    var installed: [URL] { lock.withLock { _installed } }
    var prepareStarted: Bool { lock.withLock { _prepareStarted } }

    func releasePrepare() {
        let pending = lock.withLock {
            released = true
            defer { held = nil }
            return held
        }
        pending?.resume()
    }

    func removeLeftovers(next installedApp: URL) {}

    func removeStaleWork() async {}

    func prepare(
        _ update: AppUpdate, replacing installed: InstalledApp, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedUpdate {
        lock.withLock { _prepareStarted = true }
        if holdsPrepare {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released { return true }
                    held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return PreparedUpdate(
            version: update.version, stagedApp: stagedApp, installed: installed, codeHash: Data(),
            contents: installed.contents)
    }

    func install(_ prepared: PreparedUpdate) throws {
        lock.withLock { _installed.append(prepared.stagedApp) }
    }

    func discard(_ prepared: PreparedUpdate) {
        lock.withLock { _discarded.append(prepared.stagedApp) }
    }
}

final class StubChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [Bool] = []
    private var _results: [UpdateCheckResult] = []
    private var held: CheckedContinuation<Void, Never>?
    private var released = false
    private var _holdsFirst = false

    var requests: [Bool] { lock.withLock { _requests } }

    var results: [UpdateCheckResult] {
        get { lock.withLock { _results } }
        set { lock.withLock { _results = newValue } }
    }

    var holdsFirst: Bool {
        get { lock.withLock { _holdsFirst } }
        set { lock.withLock { _holdsFirst = newValue } }
    }

    func releaseFirst() {
        let pending = lock.withLock {
            released = true
            defer { held = nil }
            return held
        }
        pending?.resume()
    }

    func answer(includingTestBuilds: Bool) async throws -> UpdateCheckResult {
        let (isFirst, holds) = lock.withLock {
            _requests.append(includingTestBuilds)
            return (_requests.count == 1, _holdsFirst)
        }
        if isFirst, holds {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if released { return true }
                    held = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return lock.withLock {
            guard !_results.isEmpty else { return .upToDate(latest: AppVersion("0.0.1")!) }
            return _results.removeFirst()
        }
    }
}
