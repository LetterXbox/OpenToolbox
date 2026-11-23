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

    convenience init(manifests: [EngineManifest] = EngineCatalog.all) {
        self.init(
            manifests: manifests,
            store: try? EngineStore(rootDirectory: EngineStore.defaultRootDirectory())
        )
    }

    init(manifests: [EngineManifest] = EngineCatalog.all, store: EngineStore?) {
        self.manifests = manifests
        self.store = store
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

    func allEnginesInstalled(for tool: ToolDescriptor) -> Bool {
        tool.requiredEngines.allSatisfy { id in
            if case .installed = status(of: id) { return true }
            return false
        }
    }

    func installedDiskUsage(for tool: ToolDescriptor) -> Int64 {
        Set(tool.requiredEngines).reduce(Int64(0)) { total, id in
            total + diskUsage[id, default: 0]
        }
    }

    func downloadProgress(for tool: ToolDescriptor) -> Double? {
        let required = Array(Set(tool.requiredEngines))
        guard !required.isEmpty, required.contains(where: { isInstalling($0) }) else { return nil }
        let sum = required.reduce(0.0) { partial, id in
            if let fraction = progress[id] {
                return partial + min(max(fraction, 0), 1)
            }
            if case .installed = status(of: id) {
                return partial + 1
            }
            return partial
        }
        return sum / Double(required.count)
    }

    func missingEngines(for tool: ToolDescriptor) -> [EngineManifest] {
        missingEngines(for: [tool])
    }

    func missingEngines(for tools: [ToolDescriptor]) -> [EngineManifest] {
        var neededIDs = Set<EngineID>()
        for tool in tools where tool.availability == .available {
            for id in tool.requiredEngines {
                if case .installed = status(of: id) { continue }
                neededIDs.insert(id)
            }
        }
        return manifests.filter { neededIDs.contains($0.id) }
    }

    func downloadableMissingEngines(for tools: [ToolDescriptor]) -> [EngineManifest] {
        missingEngines(for: tools).filter { $0.artifact() != nil && !isInstalling($0.id) }
    }

    func downloadableMissingEngines() -> [EngineManifest] {
        manifests.filter { manifest in
            if case .installed = status(of: manifest.id) { return false }
            return manifest.artifact() != nil && !isInstalling(manifest.id)
        }
    }

    func downloadSize(of manifests: [EngineManifest]) -> Int64 {
        var seen = Set<EngineID>()
        var total: Int64 = 0
        for manifest in manifests where seen.insert(manifest.id).inserted {
            total += manifest.artifact()?.sizeBytes ?? 0
        }
        return total
    }

    func refresh() {
        for manifest in manifests {
            statuses[manifest.id] = store?.status(of: manifest) ?? .unavailable
            diskUsage[manifest.id] = store?.diskUsage(of: manifest.id) ?? 0
        }
    }

    func install(_ manifests: [EngineManifest]) {
        var seen = Set<EngineID>()
        for manifest in manifests where seen.insert(manifest.id).inserted {
            if case .installed = status(of: manifest.id) { continue }
            install(manifest)
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
