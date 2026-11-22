import AppKit
import Observation
import OpenToolboxCore
import SwiftUI

@MainActor
@Observable
private final class DiskSpeedSession {
    private(set) var phase: DiskSpeedTest.Phase?
    private(set) var fraction = 0.0
    private(set) var result: DiskSpeedResult?
    private(set) var error: String?
    private(set) var wasCancelled = false
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(on volume: SpeedTestVolume, bytes: Int64) {
        guard task == nil else { return }
        result = nil
        error = nil
        wasCancelled = false
        phase = .writing
        fraction = 0
        task = Task {
            defer {
                task = nil
                phase = nil
            }
            let session = self
            let job = Task.detached(priority: .userInitiated) {
                try DiskSpeedTest.run(
                    in: volume.testDirectory, volumeName: volume.name, expectedVolumeUUID: volume.volumeUUID, bytes: bytes
                ) { phase, fraction in
                    Task { @MainActor in session.show(phase, fraction) }
                }
            }
            do {
                result = try await withTaskCancellationHandler {
                    try await job.value
                } onCancel: {
                    job.cancel()
                }
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func show(_ phase: DiskSpeedTest.Phase, _ fraction: Double) {
        guard task != nil else { return }
        self.phase = phase
        self.fraction = fraction
    }
}

struct DiskSpeedTestView: View {
    private enum Size: Int64, CaseIterable, Identifiable {
        case small = 268_435_456
        case medium = 1_073_741_824
        case large = 4_294_967_296

        var id: Int64 { rawValue }
        var title: String { ByteCountFormatter.string(fromByteCount: rawValue, countStyle: .binary) }
    }

    let tool: ToolDescriptor
    @State private var volumes: [SpeedTestVolume] = []
    @State private var volume: SpeedTestVolume?
    @State private var size: Size = .medium
    @State private var session = DiskSpeedSession()

    var body: some View {
        ToolPage(tool: tool) {
            Form {
                Picker(L("Volume"), selection: $volume) {
                    ForEach(volumes) { volume in
                        Text(label(for: volume)).tag(Optional(volume))
                    }
                }
                Picker(L("Test file size"), selection: $size) {
                    ForEach(Size.allCases) { size in
                        Text(verbatim: size.title).tag(size)
                    }
                }
                Text(L("Writes one test file, then reads it back, bypassing the disk cache. The file is removed as soon as the test ends."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)
            .disabled(session.isRunning)

            HStack {
                Button(L("Start Test")) {
                    if let volume { session.start(on: volume, bytes: size.rawValue) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isRunning || volume == nil || volume?.isReadOnly == true)
                if session.isRunning {
                    Button(L("Cancel")) { session.cancel() }
                }
                Button(L("Refresh Volumes"), systemImage: "arrow.clockwise", action: refresh)
                    .disabled(session.isRunning)
            }

            if let phase = session.phase {
                ProgressView(value: session.fraction) {
                    Text(phase == .writing ? L("Writing…") : L("Reading…"))
                }
            }
            if let error = session.error {
                ErrorMessage(text: error)
            } else if session.wasCancelled {
                Text(L("Test cancelled.")).foregroundStyle(.secondary)
            }
            if let result = session.result {
                Pane(L("Results")) {
                    MacUtilityMetrics(rows: [
                        (L("Sequential write"), speed(result.writeBytesPerSecond)),
                        (L("Sequential read"), speed(result.readBytesPerSecond)),
                        (L("Amount tested"), ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .binary)),
                    ])
                }
            }
        }
        .onAppear { if volumes.isEmpty { refresh() } }
        .onDisappear { session.cancel() }
        .reportsActivity(session.isRunning)
    }

    private func refresh() {
        volumes = SpeedTestVolume.mounted()
        if let volume, let match = volumes.first(where: { $0.id == volume.id }) {
            self.volume = match
        } else {
            volume = volumes.first
        }
    }

    private func label(for volume: SpeedTestVolume) -> String {
        if volume.isReadOnly { return L("\(volume.name) (read-only)") }
        guard let available = volume.availableBytes else { return volume.name }
        return L("\(volume.name) (\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free)")
    }

    private func speed(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / 1_000_000
        return L("\(megabytes.formatted(.number.precision(.fractionLength(0...1)))) MB/s")
    }
}
