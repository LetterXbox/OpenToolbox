import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("Recording store")
struct RecordingStoreTests {
    let audio: ToolID = "media.record-audio"
    let screen: ToolID = "media.record-screen"

    func makeRecording(in directory: URL, named name: String = "recording.m4a") throws -> URL {
        let folder = directory.appending(path: "temporary-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data("audio".utf8).write(to: url)
        return url
    }

    func blockedOutput(_ directory: URL) throws -> OutputDirectory {
        let blocked = directory.appending(path: "blocked")
        try Data("not a folder".utf8).write(to: blocked)
        return OutputDirectory(baseDirectory: blocked)
    }

    @Test func savesToTheOutputFolder() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let recording = try makeRecording(in: directory)
            let outcome = store.publish(
                recording, named: "Take.m4a", output: OutputDirectory(baseDirectory: directory.appending(path: "out")),
                tool: audio)
            guard case .saved(let url) = outcome else {
                Issue.record("expected the recording to be saved")
                return
            }
            #expect(url.lastPathComponent == "Take.m4a")
            #expect(try Data(contentsOf: url) == Data("audio".utf8))
            #expect(!FileManager.default.fileExists(atPath: recording.path))
            #expect(store.recordings(of: [audio]).isEmpty)
        }
    }

    @Test func keepsWhatTheOutputFolderRefusesAndSavesItLater() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let blocked = try blockedOutput(directory)
            let outcome = store.publish(try makeRecording(in: directory), named: "Take.m4a", output: blocked, tool: audio)
            guard case .kept(let kept, let reason) = outcome else {
                Issue.record("expected the recording to be kept")
                return
            }
            #expect(!reason.isEmpty)
            #expect(try Data(contentsOf: kept) == Data("audio".utf8))
            _ = store.publish(try makeRecording(in: directory), named: "Take.m4a", output: blocked, tool: audio)
            _ = store.publish(try makeRecording(in: directory, named: "Clip.mov"), named: "Clip.mov", output: blocked, tool: screen)

            let entries = store.recordings(of: [audio, screen])
            #expect(entries.count == 3)
            #expect(entries.filter { $0.tool == screen }.map(\.url.lastPathComponent) == ["Clip.mov"])

            let base = directory.appending(path: "out")
            let output = OutputDirectory(baseDirectory: base)
            let clip = try #require(entries.first { $0.tool == screen })
            let result = try store.save(clip, output: output)
            #expect(result.cleanupFailure == nil)
            #expect(result.url.deletingLastPathComponent().lastPathComponent == "record-screen")
            #expect(store.recordings(of: [audio, screen]).count == 2)
        }
    }

    @Test func ignoresAndRefusesThingsItDidNotKeep() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let folder = store.folder(for: audio)
            let planted = folder.appending(path: "Photos", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true)
            try Data("keep me".utf8).write(to: planted.appending(path: "a.txt"))
            let outside = try makeRecording(in: directory)
            try FileManager.default.createSymbolicLink(at: folder.appending(path: "link.m4a"), withDestinationURL: outside)

            #expect(store.recordings(of: [audio]).isEmpty)
            let fake = RecordingStore.Entry(name: "Photos", tool: audio, url: planted, device: 0, inode: 0)
            #expect(throws: RecordingStore.StoreError.self) { try store.discard(fake) }
            #expect(FileManager.default.fileExists(atPath: planted.appending(path: "a.txt").path))
            #expect(FileManager.default.fileExists(atPath: outside.path))

            let kept = store.keep(outside, named: "Take.m4a", tool: audio)
            #expect(kept != outside)
            let entries = store.recordings(of: [audio])
            #expect(entries.map(\.name) == ["Take.m4a"])
            try store.discard(try #require(entries.first))
            #expect(store.recordings(of: [audio]).isEmpty)
        }
    }

    @Test func aLinkedToolFolderIsNeverUsed() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            let elsewhere = directory.appending(path: "elsewhere", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let precious = elsewhere.appending(path: "precious.m4a")
            try Data("mine".utf8).write(to: precious)
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: store.folder(for: audio), withDestinationURL: elsewhere)

            #expect(store.recordings(of: [audio]).isEmpty)
            let recording = try makeRecording(in: directory)
            #expect(store.keep(recording, named: "Take.m4a", tool: audio) == recording)
            #expect(try Data(contentsOf: precious) == Data("mine".utf8))
            #expect(!FileManager.default.fileExists(atPath: elsewhere.appending(path: "Take.m4a").path))
        }
    }

    @Test func aReplacedEntryIsLeftAlone() async throws {
        try await withTemporaryDirectory { directory in
            let store = RecordingStore(directory: directory.appending(path: "store"))
            _ = store.keep(try makeRecording(in: directory), named: "Take.m4a", tool: audio)
            let entry = try #require(store.recordings(of: [audio]).first)
            try FileManager.default.removeItem(at: entry.url)
            try FileManager.default.createDirectory(at: entry.url, withIntermediateDirectories: true)
            try Data("inside".utf8).write(to: entry.url.appending(path: "note.txt"))

            #expect(throws: RecordingStore.StoreError.notARecording("Take.m4a")) { try store.discard(entry) }
            #expect(throws: RecordingStore.StoreError.notARecording("Take.m4a")) {
                try store.save(entry, output: OutputDirectory(baseDirectory: directory.appending(path: "out")))
            }
            #expect(try Data(contentsOf: entry.url.appending(path: "note.txt")) == Data("inside".utf8))

            try FileManager.default.removeItem(at: entry.url)
            try Data("other".utf8).write(to: entry.url)
            #expect(throws: RecordingStore.StoreError.notARecording("Take.m4a")) { try store.discard(entry) }
            #expect(FileManager.default.fileExists(atPath: entry.url.path))
        }
    }
}
