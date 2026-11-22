import AVFoundation
import Foundation
import Testing

@testable import OpenToolboxApp

@MainActor
@Suite("Record Audio", .serialized)
struct AudioRecorderTests {
    @Test func aFinishDeliveredOffTheMainThreadIsHandled() async throws {
        try await withDefaults { defaults in
            let recorder = AudioRecorder(defaults: defaults)
            let url = URL.temporaryDirectory.appending(path: "unused-\(UUID().uuidString).m4a")
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    recorder.fileOutput(AVCaptureAudioFileOutput(), didFinishRecordingTo: url, from: [], error: nil)
                    continuation.resume()
                }
            }
            try await Task.sleep(for: .milliseconds(50))
            #expect(recorder.phase == .idle)
            #expect(recorder.failure == nil)
            #expect(recorder.saved == nil)
        }
    }

    @Test func aMissingChosenMicrophoneFallsBackToTheSystemDefault() throws {
        try withDefaults { defaults in
            defaults.set("unplugged", forKey: AudioRecorder.microphoneKey)
            let recorder = AudioRecorder(defaults: defaults)
            recorder.microphones = [Microphone(id: "usb", name: "USB Microphone")]
            #expect(recorder.selection == nil)
            #expect(recorder.isChosenMicrophoneMissing)

            recorder.selection = "usb"
            #expect(!recorder.isChosenMicrophoneMissing)
            #expect(defaults.string(forKey: AudioRecorder.microphoneKey) == "usb")
            #expect(AudioRecorder(defaults: defaults).chosenMicrophone == "usb")

            recorder.selection = nil
            #expect(defaults.string(forKey: AudioRecorder.microphoneKey) == nil)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "OpenToolboxAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "OpenToolboxAppTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }
}
