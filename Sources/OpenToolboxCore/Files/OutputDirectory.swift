import Darwin
import Foundation

public enum OutputDirectoryError: Error, Equatable, LocalizedError {
    /// A dated or tool folder inside the output folder is a symlink or not a folder.
    case unsafeFolder(URL)

    public var errorDescription: String? {
        switch self {
        case .unsafeFolder(let url):
            coreLocalized(
                "“\(url.lastPathComponent)” in the output folder is a link or not a folder, so nothing was written.")
        }
    }
}

/// Where file tools write results. Originals are never overwritten: every run
/// writes into `<base>/<yyyy-MM-dd>/<tool>/` and publishes under a free file name.
///
/// Below the chosen base folder, the dated and tool folders are created and opened
/// without following symlinks, and files are published relative to that open folder,
/// so a link planted inside the output folder cannot redirect a write elsewhere.
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

    /// The dated folder for a tool run, created if needed (for display and Show in Finder).
    public func runDirectory(
        for tool: ToolID,
        date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let descriptor = try openRunDirectory(for: tool, date: date, calendar: calendar)
        close(descriptor)
        return directoryURL(for: tool, date: date, calendar: calendar)
    }

    /// The run location without creating it, for file tools that preview the output first.
    func directoryURL(for tool: ToolID, date: Date, calendar: Calendar) -> URL {
        baseDirectory
            .appending(path: Self.dayName(date, calendar: calendar), directoryHint: .isDirectory)
            .appending(path: Self.folderName(for: tool), directoryHint: .isDirectory)
    }

    /// Writes a new file into the tool's dated folder without ever replacing an existing
    /// file, and returns its URL.
    ///
    /// `write` receives a private temporary URL on the output folder's volume. The finished
    /// file is then published into the opened run folder as `preferredName`, or ` 2`, ` 3`, …
    /// on collision, with an exclusive rename, so concurrent exports with the same name all survive.
    public func writeNewFile(
        for tool: ToolID,
        preferredName: String,
        date: Date = Date(),
        calendar: Calendar = .current,
        write: (URL) throws -> Void
    ) throws -> URL {
        let name = Self.sanitizedFileName(preferredName)
        let directory = try openRunDirectory(for: tool, date: date, calendar: calendar)
        defer { close(directory) }
        // A private folder on the same volume, so the final rename never crosses volumes.
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: baseDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appending(path: name, directoryHint: .notDirectory)
        try write(temporary)

        let runURL = directoryURL(for: tool, date: date, calendar: calendar)
        for counter in 1...Self.maximumNumberedNames {
            let candidate = counter == 1 ? name : Self.numberedName(name, counter)
            if renameatx_np(AT_FDCWD, temporary.path, directory, candidate, UInt32(RENAME_EXCL)) == 0 {
                return runURL.appending(path: candidate, directoryHint: .notDirectory)
            }
            let code = errno
            guard code == EEXIST else { throw Self.posixError(code, runURL.appending(path: candidate)) }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: runURL.appending(path: name).path])
    }

    /// Creates a new folder in the tool's dated output folder without replacing an existing
    /// entry, and returns its URL.
    public func writeNewDirectory(
        for tool: ToolID,
        preferredName: String,
        date: Date = Date(),
        calendar: Calendar = .current,
        populate: (URL) throws -> Void
    ) throws -> URL {
        let name = Self.sanitizedFileName(preferredName)
        let directory = try openRunDirectory(for: tool, date: date, calendar: calendar)
        defer { close(directory) }
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: baseDirectory, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        try populate(temporary)

        let runURL = directoryURL(for: tool, date: date, calendar: calendar)
        for counter in 1...Self.maximumNumberedNames {
            let candidate = counter == 1 ? name : Self.numberedName(name, counter)
            if renameatx_np(AT_FDCWD, temporary.path, directory, candidate, UInt32(RENAME_EXCL)) == 0 {
                return runURL.appending(path: candidate, directoryHint: .isDirectory)
            }
            let code = errno
            guard code == EEXIST else { throw Self.posixError(code, runURL.appending(path: candidate)) }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: runURL.appending(path: name).path])
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
        return try writeNewFile(for: tool, preferredName: name, date: date, write: write)
    }

    /// The name a new file would get right now, adding ` 2`, ` 3`, … before the extension on
    /// collisions. For display only: write files with ``writeNewFile(for:preferredName:date:calendar:write:)``.
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

    // MARK: Helpers

    /// Opens `<base>/<day>/<tool>`, creating the two inner folders without following links.
    /// The caller closes the returned descriptor.
    func openRunDirectory(for tool: ToolID, date: Date, calendar: Calendar) throws -> Int32 {
        // The base folder is the user's own choice and may itself be a link; trust it.
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        var descriptor = open(baseDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.posixError(errno, baseDirectory) }
        var url = baseDirectory
        for component in [Self.dayName(date, calendar: calendar), Self.folderName(for: tool)] {
            url = url.appending(path: component, directoryHint: .isDirectory)
            // mkdirat never follows a link in the last component: an existing link yields EEXIST.
            if mkdirat(descriptor, component, 0o755) != 0, errno != EEXIST {
                let code = errno
                close(descriptor)
                throw Self.posixError(code, url)
            }
            let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            guard child >= 0 else {
                if code == ELOOP || code == ENOTDIR { throw OutputDirectoryError.unsafeFolder(url) }
                throw Self.posixError(code, url)
            }
            descriptor = child
        }
        return descriptor
    }

    static func dayName(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static let maximumNumberedNames = 10_000

    /// `photo.png`, 3 → `photo 3.png`
    static func numberedName(_ name: String, _ counter: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
    }

    static func posixError(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
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
