import Foundation

/// Holds recordings that couldn't be saved to the output folder, so they are never lost.
/// Recordings stay here, outside any window, until they are saved or the user discards them.
public struct RecordingStore: Sendable {
    public enum Outcome: Sendable {
        case saved(URL)
        /// The output folder refused the recording. It is now at `kept`, which is the original
        /// temporary file if even moving it into the store failed.
        case kept(URL, reason: String)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/OpenToolbox/Unsaved Recordings`
    public static func standard() -> RecordingStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return RecordingStore(
            directory: support.appending(path: "OpenToolbox/Unsaved Recordings", directoryHint: .isDirectory))
    }

    /// Copies `recording` into the output folder as `name`. If that fails, moves it into the store.
    public func publish(_ recording: URL, named name: String, output: OutputDirectory, tool: ToolID) -> Outcome {
        do {
            let saved = try output.writeNewFile(for: tool, preferredName: name) {
                try FileManager.default.copyItem(at: recording, to: $0)
            }
            try? FileManager.default.removeItem(at: recording)
            return .saved(saved)
        } catch {
            return .kept(keep(recording, named: name), reason: error.localizedDescription)
        }
    }

    func keep(_ recording: URL, named name: String) -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = OutputDirectory.uniqueFileURL(in: directory, preferredName: name)
            try FileManager.default.moveItem(at: recording, to: destination)
            return destination
        } catch {
            return recording
        }
    }

    /// Kept recordings, oldest first.
    public func recordings() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.sorted {
            let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return first == second ? $0.lastPathComponent < $1.lastPathComponent : first < second
        }
    }

    /// Copies a kept recording into the output folder, then removes it from the store.
    public func save(_ recording: URL, output: OutputDirectory, tool: ToolID) throws -> URL {
        let saved = try output.writeNewFile(for: tool, preferredName: recording.lastPathComponent) {
            try FileManager.default.copyItem(at: recording, to: $0)
        }
        try? FileManager.default.removeItem(at: recording)
        return saved
    }

    /// Removes a kept recording. Files outside the store are left alone.
    public func discard(_ recording: URL) throws {
        guard recording.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: recording)
    }
}
