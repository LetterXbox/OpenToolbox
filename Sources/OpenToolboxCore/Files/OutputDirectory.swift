import Foundation

public enum OutputDirectoryError: Error, Equatable, LocalizedError {
    case wouldOverwriteSource(URL)

    public var errorDescription: String? {
        switch self {
        case .wouldOverwriteSource(let url):
            coreLocalized("Refusing to overwrite the original file “\(url.lastPathComponent)”.")
        }
    }
}

/// Where file tools write results. Originals are never overwritten: every run
/// writes into `<base>/<yyyy-MM-dd>/<tool>/` and picks a free file name.
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

    /// The dated folder for a tool run; created if needed.
    public func runDirectory(
        for tool: ToolID,
        date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let directory = directoryURL(for: tool, date: date, calendar: calendar)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    /// A file URL in `directory` named `preferredName` that does not exist yet,
    /// adding ` 2`, ` 3`, … before the extension on collisions.
    public static func uniqueFileURL(in directory: URL, preferredName: String) -> URL {
        let name = sanitizedFileName(preferredName)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name, directoryHint: .notDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appending(path: numbered, directoryHint: .notDirectory)
            counter += 1
        }
        return candidate
    }

    /// Resolves the output URL for a processed copy of `source`, guaranteeing it is not `source`.
    public func outputURL(
        forSource source: URL,
        tool: ToolID,
        newExtension: String? = nil,
        date: Date = Date()
    ) throws -> URL {
        var name = source.lastPathComponent
        if let newExtension {
            name = (name as NSString).deletingPathExtension + "." + newExtension
        }
        let url = Self.uniqueFileURL(in: try runDirectory(for: tool, date: date), preferredName: name)
        guard url.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath()
        else {
            throw OutputDirectoryError.wouldOverwriteSource(source)
        }
        return url
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
