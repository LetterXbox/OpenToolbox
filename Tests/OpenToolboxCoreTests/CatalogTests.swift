import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("Tool catalog")
struct CatalogTests {
    @Test func toolIDsAreUnique() {
        let ids = ToolCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyCategoryHasTools() {
        for category in ToolCategory.allCases {
            #expect(!ToolCatalog.tools(in: category).isEmpty, "\(category) is empty")
        }
    }

    @Test func builtInToolsAreEnabledByDefault() throws {
        let preferences = ToolPreferences()
        let json = try #require(ToolCatalog.tool("dev.json-formatter"))
        let media = try #require(ToolCatalog.tool("media.convert"))
        #expect(preferences.isEnabled(json))
        #expect(!preferences.isEnabled(media))
    }

    @Test func preferencesStoreOnlyOverrides() throws {
        var preferences = ToolPreferences()
        let json = try #require(ToolCatalog.tool("dev.json-formatter"))
        preferences.setEnabled(false, for: json)
        #expect(!preferences.isEnabled(json))
        #expect(preferences.overrides == ["dev.json-formatter": false])
        preferences.setEnabled(true, for: json)
        #expect(preferences.overrides.isEmpty)

        let decoded = try JSONDecoder().decode(ToolPreferences.self, from: JSONEncoder().encode(preferences))
        #expect(decoded == preferences)
    }

    @Test func batchSetEnabledSkipsPlannedToolsAndMinimizesOverrides() throws {
        var preferences = ToolPreferences()
        let json = try #require(ToolCatalog.tool("dev.json-formatter"))
        let compressPDF = try #require(ToolCatalog.tool("pdf.compress"))
        let planned = ToolDescriptor(
            id: "test.planned",
            category: .developer,
            title: "Planned Tool",
            summary: "Not shipped yet",
            symbolName: "sparkles",
            requiredEngines: [EngineCatalog.ffmpegID],
            availability: .planned
        )

        preferences.setEnabled(true, for: [json, compressPDF, planned])
        #expect(preferences.isEnabled(json))
        #expect(preferences.isEnabled(compressPDF))
        #expect(!preferences.isEnabled(planned))
        #expect(preferences.overrides == ["pdf.compress": true])

        preferences.setEnabled(false, for: [json, compressPDF, planned])
        #expect(!preferences.isEnabled(json))
        #expect(!preferences.isEnabled(compressPDF))
        #expect(preferences.overrides == ["dev.json-formatter": false])
    }

    @Test func searchRanksTitlePrefixFirst() {
        let results = CommandSearch.rank("json", in: ToolCatalog.all).map(\.id)
        #expect(results.first == "dev.json-formatter")
        #expect(results.contains("dev.csv-json"))
    }

    @Test func searchMatchesKeywordsAndSubsequences() {
        #expect(CommandSearch.rank("sha256", in: ToolCatalog.all).first?.id == "dev.hash")
        #expect(CommandSearch.rank("epoch", in: ToolCatalog.all).first?.id == "dev.timestamp")
        #expect(CommandSearch.rank("jwtdec", in: ToolCatalog.all).first?.id == "dev.jwt")
        #expect(CommandSearch.rank("zzzzqqq", in: ToolCatalog.all).isEmpty)
    }

    @Test func emptySearchReturnsEverythingInOrder() {
        #expect(CommandSearch.rank("  ", in: ToolCatalog.all) == ToolCatalog.all)
    }
}

@Suite("Output directory")
struct OutputDirectoryTests {
    @Test func runDirectoryIsDatedAndPerTool() async throws {
        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let date = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 UTC
            let run = try output.runDirectory(for: "image.convert", date: date, calendar: calendar)
            #expect(run.path.hasSuffix("2023-11-14/convert"))
            #expect(FileManager.default.fileExists(atPath: run.path))
        }
    }

    @Test func uniqueFileNamesNeverCollide() async throws {
        try await withTemporaryDirectory { directory in
            let first = OutputDirectory.uniqueFileURL(in: directory, preferredName: "photo.png")
            #expect(first.lastPathComponent == "photo.png")
            try Data().write(to: first)
            let second = OutputDirectory.uniqueFileURL(in: directory, preferredName: "photo.png")
            #expect(second.lastPathComponent == "photo 2.png")
            try Data().write(to: second)
            #expect(OutputDirectory.uniqueFileURL(in: directory, preferredName: "photo.png").lastPathComponent == "photo 3.png")
            #expect(OutputDirectory.uniqueFileURL(in: directory, preferredName: "README").lastPathComponent == "README")
        }
    }

    @Test func outputNeverPointsAtTheSource() async throws {
        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory)
            let source = directory.appending(path: "input.heic")
            try Data([1, 2, 3]).write(to: source)
            let url = try output.writeOutput(forSource: source, tool: "image.convert", newExtension: "png") {
                try Data([9]).write(to: $0)
            }
            #expect(url.lastPathComponent == "input.png")
            #expect(url != source)
            #expect(try Data(contentsOf: url) == Data([9]))
            #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
        }
    }

    static func utcDay() -> (date: Date, calendar: Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return (Date(timeIntervalSince1970: 1_700_000_000), calendar)  // 2023-11-14 UTC
    }

    @Test func writeNewFileNeverReplacesAFileCreatedMeanwhile() async throws {
        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory)
            let (date, calendar) = Self.utcDay()
            let run = try output.runDirectory(for: "image.convert", date: date, calendar: calendar)
            // Another export claims the name while this one is still encoding.
            let url = try output.writeNewFile(
                for: "image.convert", preferredName: "photo.png", date: date, calendar: calendar
            ) { temporary in
                try Data("other".utf8).write(to: run.appending(path: "photo.png"))
                try Data("mine".utf8).write(to: temporary)
            }
            #expect(url.lastPathComponent == "photo 2.png")
            #expect(try Data(contentsOf: url) == Data("mine".utf8))
            #expect(try Data(contentsOf: run.appending(path: "photo.png")) == Data("other".utf8))
            let names = try FileManager.default.contentsOfDirectory(atPath: run.path).sorted()
            #expect(names == ["photo 2.png", "photo.png"])
        }
    }

    @Test func concurrentExportsWithTheSameNameAllSurvive() async throws {
        try await withTemporaryDirectory { directory in
            let output = OutputDirectory(baseDirectory: directory)
            let (date, calendar) = Self.utcDay()
            let count = 16
            let urls = try await withThrowingTaskGroup(of: URL.self) { group in
                for index in 0..<count {
                    group.addTask {
                        try output.writeNewFile(
                            for: "image.convert", preferredName: "photo.png", date: date, calendar: calendar
                        ) {
                            try Data("\(index)".utf8).write(to: $0)
                        }
                    }
                }
                return try await group.reduce(into: [URL]()) { $0.append($1) }
            }
            #expect(Set(urls.map(\.lastPathComponent)).count == count)
            let contents = try Set(urls.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) })
            #expect(contents == Set((0..<count).map(String.init)))
        }
    }

    @Test func failedWriteLeavesNothingBehind() async throws {
        struct Failure: Error {}
        try await withTemporaryDirectory { (directory: URL) async throws -> Void in
            let output = OutputDirectory(baseDirectory: directory)
            let (date, calendar) = Self.utcDay()
            #expect(throws: Failure.self) {
                try output.writeNewFile(
                    for: "image.convert", preferredName: "photo.png", date: date, calendar: calendar
                ) { temporary in
                    try Data("partial".utf8).write(to: temporary)
                    throw Failure()
                }
            }
            let run = try output.runDirectory(for: "image.convert", date: date, calendar: calendar)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: run.path)
            #expect(leftovers.isEmpty)
        }
    }

    @Test(arguments: ["day", "tool"])
    func linksInsideTheOutputFolderAreRefusedWithoutSideEffects(_ level: String) async throws {
        try await withTemporaryDirectory { (directory: URL) async throws -> Void in
            let base = directory.appending(path: "out")
            let elsewhere = directory.appending(path: "elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let (date, calendar) = Self.utcDay()
            if level == "day" {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    at: base.appending(path: "2023-11-14"), withDestinationURL: elsewhere)
            } else {
                let day = base.appending(path: "2023-11-14")
                try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: day.appending(path: "convert"), withDestinationURL: elsewhere)
            }
            let output = OutputDirectory(baseDirectory: base)
            #expect(throws: OutputDirectoryError.self) {
                try output.runDirectory(for: "image.convert", date: date, calendar: calendar)
            }
            #expect(throws: OutputDirectoryError.self) {
                try output.writeNewFile(
                    for: "image.convert", preferredName: "photo.png", date: date, calendar: calendar
                ) { try Data("x".utf8).write(to: $0) }
            }
            // Nothing was created or written through the link.
            let outside = try FileManager.default.contentsOfDirectory(atPath: elsewhere.path)
            #expect(outside.isEmpty)
        }
    }

    @Test func aFileWhereTheDayFolderShouldBeIsRefused() async throws {
        try await withTemporaryDirectory { (directory: URL) async throws -> Void in
            let (date, calendar) = Self.utcDay()
            try Data("x".utf8).write(to: directory.appending(path: "2023-11-14"))
            let output = OutputDirectory(baseDirectory: directory)
            #expect(throws: OutputDirectoryError.self) {
                try output.runDirectory(for: "image.convert", date: date, calendar: calendar)
            }
        }
    }
    @Test func fileNamesAreSanitized() {
        #expect(OutputDirectory.sanitizedFileName("a/b:c") == "a-b-c")
        #expect(OutputDirectory.sanitizedFileName("..") == "Untitled")
        #expect(OutputDirectory.sanitizedFileName("  ") == "Untitled")
    }
}
