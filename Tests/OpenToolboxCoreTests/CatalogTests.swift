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
            let url = try output.outputURL(forSource: source, tool: "image.convert", newExtension: "png")
            #expect(url.lastPathComponent == "input.png")
            #expect(url != source)
            #expect(try Data(contentsOf: source) == Data([1, 2, 3]))
        }
    }

    @Test func fileNamesAreSanitized() {
        #expect(OutputDirectory.sanitizedFileName("a/b:c") == "a-b-c")
        #expect(OutputDirectory.sanitizedFileName("..") == "Untitled")
        #expect(OutputDirectory.sanitizedFileName("  ") == "Untitled")
    }
}
