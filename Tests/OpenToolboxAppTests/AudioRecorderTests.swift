import AVFoundation
import Foundation
import Testing

@testable import OpenToolboxApp
@testable import OpenToolboxCore

@MainActor
@Suite("Record Audio", .serialized)
struct AudioRecorderTests {
    @Test func aFinishDeliveredOffTheMainThreadSavesTheRecording() async throws {
        try await withRecorder { fixture in
            let output = AVCaptureAudioFileOutput()
            let temporary = try fixture.recording(Data("audio".utf8))
            fixture.recorder.adopt(output, session: nil, temporary: temporary, destination: fixture.destination)
            #expect(AudioRecorder.active.contains(fixture.recorder))

            deliverFinish(to: fixture.recorder, from: output, error: nil)
            try await waitUntil { fixture.recorder.phase == .idle }
            let saved = try #require(fixture.recorder.saved)
            #expect(FileManager.default.fileExists(atPath: saved.path))
            #expect(saved.path.hasPrefix(fixture.outputBase.path))
            #expect(fixture.recorder.failure == nil)
            #expect(!FileManager.default.fileExists(atPath: temporary.path))
            #expect(!AudioRecorder.active.contains(fixture.recorder))
        }
    }

    @Test func aFinishFromAnotherOutputIsIgnored() async throws {
        try await withRecorder { fixture in
            let output = AVCaptureAudioFileOutput()
            let temporary = try fixture.recording(Data("audio".utf8))
            fixture.recorder.adopt(output, session: nil, temporary: temporary, destination: fixture.destination)

            deliverFinish(to: fixture.recorder, from: AVCaptureAudioFileOutput(), error: nil)
            try await Task.sleep(for: .milliseconds(100))
            guard case .recording = fixture.recorder.phase else {
                Issue.record("a stale finish ended the recording")
                return
            }
            #expect(fixture.recorder.saved == nil)

            deliverFinish(to: fixture.recorder, from: output, error: nil)
            try await waitUntil { fixture.recorder.phase == .idle }
            #expect(fixture.recorder.saved != nil)
        }
    }

    @Test func anEmptyRecordingIsReportedAndRemoved() async throws {
        try await withRecorder { fixture in
            let output = AVCaptureAudioFileOutput()
            let temporary = try fixture.recording(Data())
            fixture.recorder.adopt(output, session: nil, temporary: temporary, destination: fixture.destination)

            deliverFinish(to: fixture.recorder, from: output, error: CocoaError(.fileWriteUnknown))
            try await waitUntil { fixture.recorder.phase == .idle }
            #expect(fixture.recorder.saved == nil)
            #expect(fixture.recorder.failure?.hasPrefix("Recording failed:") == true)
            #expect(!FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().path))
        }
    }

    @Test func aRecordingThatCantBeSavedIsKept() async throws {
        try await withRecorder { fixture in
            let blocked = fixture.root.appending(path: "not-a-folder")
            try Data().write(to: blocked)
            let output = AVCaptureAudioFileOutput()
            let temporary = try fixture.recording(Data("audio".utf8))
            fixture.recorder.adopt(
                output, session: nil, temporary: temporary,
                destination: (OutputDirectory(baseDirectory: blocked), fixture.destination.tool))

            deliverFinish(to: fixture.recorder, from: output, error: CocoaError(.fileWriteUnknown))
            try await waitUntil { fixture.recorder.phase == .idle }
            #expect(fixture.recorder.saved == nil)
            #expect(fixture.recorder.failure != nil)
            #expect(fixture.store.recordings(of: [fixture.destination.tool]).count == 1)
        }
    }

    @Test func closingDuringStartLetsTheAppQuit() async throws {
        try await withRecorder { fixture in
            fixture.recorder.requestStart(output: fixture.destination.output, tool: fixture.destination.tool)
            #expect(fixture.recorder.phase == .starting)
            #expect(AudioRecorder.active.contains(fixture.recorder))

            fixture.recorder.close()
            #expect(fixture.recorder.phase == .idle)
            #expect(!AudioRecorder.active.contains(fixture.recorder))
            #expect(await AudioRecorder.stopAll())
        }
    }

    @Test func aMissingChosenMicrophoneFallsBackToTheSystemDefault() async throws {
        try await withRecorder { fixture in
            fixture.defaults.set("unplugged", forKey: AudioRecorder.microphoneKey)
            let recorder = AudioRecorder(defaults: fixture.defaults, store: fixture.store)
            recorder.microphones = [Microphone(id: "usb", name: "USB Microphone")]
            #expect(recorder.selection == nil)
            #expect(recorder.isChosenMicrophoneMissing)

            recorder.selection = "usb"
            #expect(!recorder.isChosenMicrophoneMissing)
            #expect(fixture.defaults.string(forKey: AudioRecorder.microphoneKey) == "usb")
            #expect(AudioRecorder(defaults: fixture.defaults, store: fixture.store).chosenMicrophone == "usb")

            recorder.selection = nil
            #expect(fixture.defaults.string(forKey: AudioRecorder.microphoneKey) == nil)
        }
    }

    private func deliverFinish(to recorder: AudioRecorder, from output: AVCaptureAudioFileOutput, error: Error?) {
        let handoff = OutputHandoff(output: output)
        let url = URL.temporaryDirectory.appending(path: "finished.m4a")
        DispatchQueue.global().async {
            recorder.fileOutput(handoff.output, didFinishRecordingTo: url, from: [], error: error)
        }
    }

    private func withRecorder(_ body: @MainActor (RecorderFixture) async throws -> Void) async throws {
        let fixture = try RecorderFixture()
        defer { fixture.remove() }
        try await body(fixture)
        fixture.recorder.close()
    }
}

private struct OutputHandoff: @unchecked Sendable {
    let output: AVCaptureAudioFileOutput
}

@MainActor
final class RecorderFixture {
    let root: URL
    let outputBase: URL
    let store: RecordingStore
    let defaults: UserDefaults
    let suiteName = "OpenToolboxAppTests-\(UUID().uuidString)"
    let recorder: AudioRecorder
    let destination: (output: OutputDirectory, tool: ToolID)

    init() throws {
        root = URL.temporaryDirectory.appending(path: "AudioRecorderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        outputBase = root.appending(path: "Output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputBase, withIntermediateDirectories: true)
        store = RecordingStore(directory: root.appending(path: "Unsaved", directoryHint: .isDirectory))
        defaults = try #require(UserDefaults(suiteName: suiteName))
        recorder = AudioRecorder(defaults: defaults, store: store)
        destination = (OutputDirectory(baseDirectory: outputBase), "media.record-audio")
    }

    func recording(_ contents: Data) throws -> URL {
        let folder = root.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "recording.m4a")
        try contents.write(to: url)
        return url
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
