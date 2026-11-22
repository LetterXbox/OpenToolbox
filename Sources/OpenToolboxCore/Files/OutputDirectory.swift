import Darwin
import Foundation

public enum OutputDirectoryError: Error, Equatable, LocalizedError {
    case outsideOutputFolder(URL)

    public var errorDescription: String? {
        switch self {
        case .outsideOutputFolder(let url):
            coreLocalized("The folder “\(url.lastPathComponent)” leads outside the chosen output folder.")
        }
    }
}

/// Where file tools write results. Originals are never overwritten: every run
/// writes into `<base>/<yyyy-MM-dd>/<tool>/` and publishes under a free file name.
public struct OutputDirectory: Sendable {
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// `~/Downloads/OpenToolbox`
    public static func defaultBaseDirectory() -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads", directoryHint: .isDirectory)
        return downloads.appending(path: "OpenToolbox", directoryHint: .isDirectory)
    }

    /// The dated folder for a tool run; created if needed. Refuses a dated folder that a
    /// symlink redirects outside the output folder.
    public func runDirectory(
        for tool: ToolID,
        date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let directory = directoryURL(for: tool, date: date, calendar: calendar)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/") else {
            throw OutputDirectoryError.outsideOutputFolder(directory)
        }
        return directory
    }

    /// The run location without creating it, for file tools that preview the output first.
    func directoryURL(for tool: ToolID, date: Date, calendar: Calendar) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(
            format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        return baseDirectory
            .appending(path: day, directoryHint: .isDirectory)
            .appending(path: Self.folderName(for: tool), directoryHint: .isDirectory)
    }

    /// The name a new file would get right now, adding ` 2`, ` 3`, … before the extension on
    /// collisions. For display only: another writer can take the name first, so write files
    /// with ``writeNewFile(in:preferredName:write:)``.
    public static func uniqueFileURL(in directory: URL, preferredName: String) -> URL {
        let name = sanitizedFileName(preferredName)
        var counter = 1
        var candidate = directory.appending(path: name, directoryHint: .notDirectory)
        while FileManager.default.fileExists(atPath: candidate.path) {
            counter += 1
            candidate = directory.appending(path: numberedName(name, counter), directoryHint: .notDirectory)
        }
        return candidate
    }

    /// Writes a new file into `directory` without ever replacing an existing one, and returns its URL.
    ///
    /// `write` receives a private temporary URL inside `directory`. The finished file is then
    /// published as `preferredName`, or ` 2`, ` 3`, … on collision, with an exclusive rename,
    /// so concurrent exports with the same name all survive.
    public static func writeNewFile(
        in directory: URL, preferredName: String, write: (URL) throws -> Void
    ) throws -> URL {
        let name = sanitizedFileName(preferredName)
        let temporary = directory.appending(
            path: ".opentoolbox-\(UUID().uuidString).partial", directoryHint: .notDirectory)
        do {
            try write(temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        for counter in 1...maximumNumberedNames {
            let candidate = directory.appending(
                path: counter == 1 ? name : numberedName(name, counter), directoryHint: .notDirectory)
            if renamex_np(temporary.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            let code = errno
            guard code == EEXIST else {
                try? FileManager.default.removeItem(at: temporary)
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: candidate.path])
            }
        }
        try? FileManager.default.removeItem(at: temporary)
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.appending(path: name).path])
    }

    /// Writes a processed copy of `source` into the tool's dated folder and returns its URL.
    /// The result never replaces `source` or any other existing file.
    public func writeOutput(
        forSource source: URL,
        tool: ToolID,
        newExtension: String? = nil,
        date: Date = Date(),
        write: (URL) throws -> Void
    ) throws -> URL {
        var name = source.lastPathComponent
        if let newExtension {
            name = (name as NSString).deletingPathExtension + "." + newExtension
        }
        return try Self.writeNewFile(in: try runDirectory(for: tool, date: date), preferredName: name, write: write)
    }

    static let maximumNumberedNames = 10_000

    /// `photo.png`, 3 → `photo 3.png`
    static func numberedName(_ name: String, _ counter: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
    }

    /// `dev.json-formatter` → `json-formatter`
    static func folderName(for tool: ToolID) -> String {
        let name = tool.split(separator: ".").last.map(String.init) ?? tool
        return sanitizedFileName(name)
    }

    /// Replaces path separators and control characters so a name is a single path component.
    static func sanitizedFileName(_ name: String) -> String {
        let cleaned = String(
            name.unicodeScalars.map { scalar -> Character in
                if scalar == "/" || scalar == ":" || CharacterSet.controlCharacters.contains(scalar) { return "-" }
                return Character(scalar)
            })
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return "Untitled" }
        return trimmed
    }
}
