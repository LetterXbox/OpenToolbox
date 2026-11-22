import AppKit
import OpenToolboxCore
import SwiftUI

/// Lists on-demand engines with size, license, verification status, and install/remove actions.
struct EngineManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let engines = model.engines
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Engines are external open-source programs that some tools need. They are downloaded only when you install them, verified with SHA-256, shared by every tool that uses them, and can be removed at any time."))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(L("Using \(engines.totalDiskUsage.formatted(.byteCount(style: .file))) on disk"))
                            .font(.callout)
                        Spacer()
                        if let root = engines.rootDirectory {
                            Button(L("Show in Finder")) {
                                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([root])
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L("Available engines")) {
                ForEach(engines.manifests) { manifest in
                    EngineRow(manifest: manifest)
                }
            }
        }
        .navigationTitle(L("Engines"))
        .toolbar {
            Button {
                engines.refresh()
            } label: {
                Label(L("Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .onAppear { engines.refresh() }
    }
}

private struct EngineRow: View {
    @Environment(AppModel.self) private var model
    let manifest: EngineManifest
    @State private var isConfirmingRemoval = false

    private var dependentTools: [ToolDescriptor] {
        ToolCatalog.tools(requiring: manifest.id).filter(model.isEnabled)
    }

    var body: some View {
        let engines = model.engines
        let status = engines.status(of: manifest.id)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(status.isInstalled ? Color.accentColor : Color.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(manifest.displayName).font(.headline)
                    if let version = manifest.version {
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                Text(manifest.localizedSummary)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label(manifest.license, systemImage: "doc.text")
                    Link(destination: manifest.homepage) {
                        Label(L("Website"), systemImage: "safari")
                    }
                    let users = ToolCatalog.tools(requiring: manifest.id)
                    if !users.isEmpty {
                        Label(
                            L("Used by \(users.map(\.localizedTitle).formatted(.list(type: .and)))"),
                            systemImage: "wrench.and.screwdriver")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let fraction = engines.progress[manifest.id] {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 260)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                statusBadge(status)
                actions(status)
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            L("Remove \(manifest.displayName)?"),
            isPresented: $isConfirmingRemoval
        ) {
            Button(L("Remove"), role: .destructive) { engines.uninstall(manifest.id) }
        } message: {
            if dependentTools.isEmpty {
                Text(L("You can download it again later."))
            } else {
                Text(
                    L("\(dependentTools.map(\.localizedTitle).formatted(.list(type: .and))) will stop working until you download it again."))
            }
        }
    }

    @ViewBuilder private func statusBadge(_ status: EngineStatus) -> some View {
        switch status {
        case .unavailable:
            Badge(text: L("Coming soon"), tint: .secondary)
        case .notInstalled(let artifact):
            Badge(text: L("\(artifact.sizeBytes.formatted(.byteCount(style: .file))) download"), tint: .blue)
        case .installed(let receipt):
            Badge(
                text: L("Installed · \(model.engines.diskUsage[receipt.engineID, default: 0].formatted(.byteCount(style: .file)))"),
                tint: .green)
        case .updateAvailable(_, let artifact):
            Badge(text: L("Update · \(artifact.sizeBytes.formatted(.byteCount(style: .file)))"), tint: .orange)
        case .damaged:
            Badge(text: L("Damaged"), tint: .red)
        }
    }

    @ViewBuilder private func actions(_ status: EngineStatus) -> some View {
        let engines = model.engines
        if engines.isInstalling(manifest.id) {
            Button(L("Cancel")) { engines.cancelInstall(manifest.id) }
        } else {
            switch status {
            case .unavailable:
                EmptyView()
            case .notInstalled:
                Button(L("Download")) { engines.install(manifest) }
                    .buttonStyle(.borderedProminent)
            case .installed:
                Button(L("Remove"), role: .destructive) { isConfirmingRemoval = true }
            case .updateAvailable:
                HStack {
                    Button(L("Remove"), role: .destructive) { isConfirmingRemoval = true }
                    Button(L("Update")) { engines.install(manifest) }
                        .buttonStyle(.borderedProminent)
                }
            case .damaged:
                HStack {
                    Button(L("Remove"), role: .destructive) { engines.uninstall(manifest.id) }
                    if manifest.artifact() != nil {
                        Button(L("Reinstall")) { engines.install(manifest) }
                    }
                }
            }
        }
    }
}
