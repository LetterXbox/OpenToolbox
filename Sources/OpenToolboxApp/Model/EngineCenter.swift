import Foundation
import Observation
import OpenToolboxCore

/// Main-actor façade over `EngineStore` for the Engine Manager UI.
@MainActor
@Observable
final class EngineCenter {
    let manifests: [EngineManifest]
    private(set) var statuses: [EngineID: EngineStatus] = [:]
    private(set) var diskUsage: [EngineID: Int64] = [:]
    /// Download progress for installs in flight.
    private(set) var progress: [EngineID: Double] = [:]
    var errorMessage: String?

    private let store: EngineStore?
    @ObservationIgnored private var tasks: [EngineID: Task<Void, Never>] = [:]

    init(manifests: [EngineManifest] = EngineCatalog.all) {
        self.manifests = manifests
        store = try? EngineStore(rootDirectory: EngineStore.defaultRootDirectory())
        refresh()
    }

    var rootDirectory: URL? { store?.rootDirectory }

    var totalDiskUsage: Int64 { diskUsage.values.reduce(0, +) }

    func status(of id: EngineID) -> EngineStatus {
        statuses[id] ?? .unavailable
    }

    func isInstalling(_ id: EngineID) -> Bool {
        progress[id] != nil
    }

    func executableURL(for id: EngineID) -> URL? {
        store?.executableURL(for: id)
    }

    /// Engines a tool needs that are not ready at the pinned build yet.
    func missingEngines(for tool: ToolDescriptor) -> [EngineManifest] {
        tool.requiredEngines.compactMap { id in
            if case .installed = status(of: id) { return nil }
            return manifests.first { $0.id == id }
        }
    }

    func refresh() {
        for manifest in manifests {
            statuses[manifest.id] = store?.status(of: manifest) ?? .unavailable
            diskUsage[manifest.id] = store?.diskUsage(of: manifest.id) ?? 0
        }
    }

    func install(_ manifest: EngineManifest) {
        guard let store, tasks[manifest.id] == nil else { return }
        let id = manifest.id
        progress[id] = 0
        errorMessage = nil
        tasks[id] = Task {
            do {
                try await store.install(manifest) { fraction in
                    Task { @MainActor in self.updateProgress(id, fraction) }
                }
            } catch is CancellationError {
                // User cancelled; nothing to report.
            } catch let error as URLError where error.code == .cancelled {
                // Cancelled download.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.progress[id] = nil
            self.tasks[id] = nil
            self.refresh()
        }
    }

    func cancelInstall(_ id: EngineID) {
        tasks[id]?.cancel()
    }

    func uninstall(_ id: EngineID) {
        do {
            try store?.uninstall(id)
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func updateProgress(_ id: EngineID, _ fraction: Double) {
        guard progress[id] != nil else { return }
        progress[id] = fraction
    }
}
