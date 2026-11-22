import AppKit
import Foundation
import Observation
import OpenToolboxCore

@MainActor
@Observable
final class UpdateCenter {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(AppVersion)
        case available(AppUpdate)
        case downloading(AppUpdate, Double)
        case ready(PreparedUpdate)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastChecked: Date?
    private var lastAutomaticAttempt: Date?
    private var isAutomaticTransaction = false
    private var hasLaunchNotice = false
    private(set) var windowRequest = 0 {
        didSet { hasPendingWindowRequest = true }
    }
    private var hasPendingWindowRequest = false

    func takeWindowRequest() -> Bool {
        defer { hasPendingWindowRequest = false }
        return hasPendingWindowRequest
    }

    var checksAutomatically: Bool {
        didSet {
            defaults.set(checksAutomatically, forKey: Self.checksKey)
            if !checksAutomatically {
                installsAutomatically = false
            } else if !oldValue {
                checkNow(userInitiated: false)
            }
        }
    }

    var installsAutomatically: Bool {
        didSet {
            defaults.set(installsAutomatically, forKey: Self.installsKey)
            if oldValue, !installsAutomatically { discardAutomaticUpdate() }
        }
    }

    let currentVersion: AppVersion?
    let unsupportedReason: String?

    private let defaults: UserDefaults
    private let appURL: URL
    private let installer: UpdateInstaller?
    private var task: Task<Void, Never>?
    private var launchRecord: Task<InstalledApp?, Never>?
    private var timer: Timer?

    private static let checksKey = "UpdatesCheckAutomatically"
    private static let installsKey = "UpdatesInstallAutomatically"
    private static let lastCheckedKey = "UpdatesLastChecked"
    private static let lastAutomaticAttemptKey = "UpdatesLastAutomaticAttempt"
    private static let installNoticeKey = "UpdatesInstallNotice"
    private static let interval: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        appURL = bundle.bundleURL
        currentVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        unsupportedReason = UpdateInstaller.unsupportedReason(for: bundle.bundleURL, bundleIdentifier: bundle.bundleIdentifier)
        checksAutomatically = defaults.bool(forKey: Self.checksKey)
        installsAutomatically = defaults.bool(forKey: Self.installsKey)
        lastChecked = defaults.object(forKey: Self.lastCheckedKey) as? Date
        lastAutomaticAttempt = defaults.object(forKey: Self.lastAutomaticAttemptKey) as? Date
        installer = (try? UpdateInstaller.defaultWorkRoot()).map { UpdateInstaller(workRoot: $0) }

        if unsupportedReason == nil { installer?.removeLeftovers(next: appURL) }
        let installer = installer
        let appURL = appURL
        let supported = unsupportedReason == nil
        launchRecord = Task.detached {
            let installed = supported ? UpdateInstaller.installedApp(at: appURL) : nil
            await installer?.removeStaleWork()
            return installed
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        if let notice = defaults.string(forKey: Self.installNoticeKey) {
            defaults.removeObject(forKey: Self.installNoticeKey)
            phase = .failed(L("The update could not be installed when OpenToolbox quit: \(notice)"))
            hasLaunchNotice = true
        } else {
            checkIfDue()
        }
    }

    /// Whether an install that failed when the app last quit should be reported now. Reports it once.
    func takeLaunchNotice() -> Bool {
        defer { hasLaunchNotice = false }
        return hasLaunchNotice
    }

    var canCheck: Bool { currentVersion != nil }
    var canInstall: Bool { canCheck && unsupportedReason == nil && installer != nil }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }

    /// Checks GitHub now. A user-initiated check reports its result in the Software Update window.
    func checkNow(userInitiated: Bool) {
        guard let currentVersion, !isBusy else { return }
        if case .ready(let prepared) = phase {
            if FileManager.default.fileExists(atPath: prepared.stagedApp.path) { return }
            phase = .idle
        }
        if !userInitiated { recordAutomaticAttempt() }
        phase = .checking
        task = Task {
            do {
                let result = try await UpdateChecker(client: URLSessionUpdateClient(appVersion: currentVersion))
                    .check(current: currentVersion)
                recordCheck()
                switch result {
                case .upToDate(let latest):
                    phase = .upToDate(max(latest, currentVersion))
                case .available(let update):
                    phase = .available(update)
                    if !userInitiated, installsAutomatically, canInstall {
                        download(update, automatic: true)
                    } else if !userInitiated {
                        windowRequest += 1
                    }
                }
            } catch {
                phase = userInitiated && !Task.isCancelled ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    func install(_ update: AppUpdate) {
        download(update, automatic: false)
    }

    func cancel() {
        task?.cancel()
    }

    /// Installs the prepared update and reopens the new version.
    func restartNow() {
        guard case .ready(let prepared) = phase, let installer else { return }
        do {
            try installer.install(prepared)
            phase = .idle
            let command = UpdateInstaller.relaunchCommand(
                waitingFor: ProcessInfo.processInfo.processIdentifier, app: prepared.installedApp)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            try process.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Installs a prepared update without reopening, used when the app quits.
    func installOnQuit() {
        task?.cancel()
        guard case .ready(let prepared) = phase, let installer, !isAutomaticTransaction || installsAutomatically
        else { return }
        do {
            try installer.install(prepared)
        } catch {
            defaults.set(error.localizedDescription, forKey: Self.installNoticeKey)
        }
        phase = .idle
    }

    func openReleasePage(for update: AppUpdate?) {
        NSWorkspace.shared.open(update?.releasePage ?? UpdateFeed.releasesPage)
    }

    private func checkIfDue() {
        guard checksAutomatically, canCheck else { return }
        if let last = [lastChecked, lastAutomaticAttempt].compactMap({ $0 }).max(),
            Date().timeIntervalSince(last) < Self.interval
        { return }
        checkNow(userInitiated: false)
    }

    private func discardAutomaticUpdate() {
        guard isAutomaticTransaction else { return }
        switch phase {
        case .downloading:
            task?.cancel()
        case .ready(let prepared):
            installer?.discard(prepared)
            isAutomaticTransaction = false
            phase = .idle
        default:
            break
        }
    }

    private func showProgress(_ fraction: Double, for update: AppUpdate) {
        guard case .downloading(let current, _) = phase, current == update else { return }
        phase = .downloading(update, fraction)
    }

    private func recordAutomaticAttempt() {
        let now = Date()
        lastAutomaticAttempt = now
        defaults.set(now, forKey: Self.lastAutomaticAttemptKey)
    }

    private func recordCheck() {
        let now = Date()
        lastChecked = now
        defaults.set(now, forKey: Self.lastCheckedKey)
    }

    private func download(_ update: AppUpdate, automatic: Bool) {
        guard canInstall, let installer, !isBusy else { return }
        isAutomaticTransaction = automatic
        phase = .downloading(update, 0)
        let launchRecord = launchRecord
        task = Task {
            guard let installed = await launchRecord?.value ?? nil else {
                phase = automatic
                    ? .available(update)
                    : .failed(L("OpenToolbox couldn't read its own app bundle when it opened. Quit and reopen OpenToolbox, then try again."))
                return
            }
            do {
                let prepared = try await installer.prepare(update, replacing: installed) { fraction in
                    Task { @MainActor in self.showProgress(fraction, for: update) }
                }
                guard !Task.isCancelled else {
                    installer.discard(prepared)
                    phase = .available(update)
                    return
                }
                phase = .ready(prepared)
                if automatic { windowRequest += 1 }
            } catch {
                if Task.isCancelled || automatic {
                    phase = .available(update)
                } else {
                    phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}
