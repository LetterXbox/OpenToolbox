import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("Recording store")
struct RecordingStoreTests {
    func makeRecording(in directory: URL) throws -> URL {
        let folder = directory.appending(path: "temporary", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "recording.m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    @Test func savesToTheOutputFolder() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let recording = try makeRecording(in: directory)
            let outcome = store.publish(
                recording, named: "Take.m4a", output: OutputDirectory(baseDirectory: directory.appending(path: "out")),
                tool: "media.record-audio")
            guard case .saved(let url) = outcome else {
                Issue.record("expected the recording to be saved")
                return
            }
            #expect(url.lastPathComponent == "Take.m4a")
            #expect(try Data(contentsOf: url) == Data("audio".utf8))
            #expect(!FileManager.default.fileExists(atPath: recording.path))
            #expect(store.recordings().isEmpty)
        }
    }

    @Test func keepsARecordingTheOutputFolderRefuses() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let blocked = directory.appending(path: "blocked")
            try Data("not a folder".utf8).write(to: blocked)
            let recording = try makeRecording(in: directory)
            let outcome = store.publish(
                recording, named: "Take.m4a", output: OutputDirectory(baseDirectory: blocked), tool: "media.record-audio")
            guard case .kept(let kept, let reason) = outcome else {
                Issue.record("expected the recording to be kept")
                return
            }
            #expect(!reason.isEmpty)
            #expect(kept.deletingLastPathComponent().standardizedFileURL == store.directory.standardizedFileURL)
            #expect(store.recordings().map(\.lastPathComponent) == ["Take.m4a"])
            #expect(try Data(contentsOf: kept) == Data("audio".utf8))

            let second = try makeRecording(in: directory)
            _ = store.publish(second, named: "Take.m4a", output: OutputDirectory(baseDirectory: blocked), tool: "media.record-audio")
            #expect(store.recordings().count == 2)

            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let saved = try store.save(kept, output: output, tool: "media.record-audio")
            #expect(try Data(contentsOf: saved) == Data("audio".utf8))
            #expect(store.recordings().count == 1)
        }
    }

    @Test func discardsOnlyItsOwnFiles() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let outside = try makeRecording(in: directory)
            try store.discard(outside)
            #expect(FileManager.default.fileExists(atPath: outside.path))
            let kept = store.keep(outside, named: "Take.m4a")
            try store.discard(kept)
            #expect(store.recordings().isEmpty)
        }
    }
}
