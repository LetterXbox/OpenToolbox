import Foundation
import Testing

@testable import OpenToolboxCore

/// Deterministic generator for reproducible tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("Clean links")
struct CleanLinksTests {
    @Test func removesTrackingParameters() {
        let result = CleanLinks.clean("https://example.com/page?utm_source=x&id=5&fbclid=abc#frag")
        #expect(result.cleaned == "https://example.com/page?id=5#frag")
        #expect(result.removedParameters == ["utm_source", "fbclid"])
        #expect(result.changed)
        #expect(!result.unwrapped)
    }

    @Test func dropsEmptyQuery() {
        #expect(CleanLinks.clean("https://example.com/?utm_source=a&UTM_MEDIUM=b").cleaned == "https://example.com/")
    }

    @Test func keepsOriginalEncoding() {
        let url = "https://example.com/search?q=a%20b+c&gclid=1"
        #expect(CleanLinks.clean(url).cleaned == "https://example.com/search?q=a%20b+c")
    }

    @Test func unwrapsRedirects() {
        let result = CleanLinks.clean("https://www.google.com/url?q=https://example.com/a?utm_medium%3Dy&sa=D")
        #expect(result.unwrapped)
        #expect(result.cleaned == "https://example.com/a")
    }

    @Test func leavesOtherSchemesAlone() {
        #expect(!CleanLinks.clean("mailto:someone@example.com?utm_source=x").changed)
        #expect(!CleanLinks.clean("not a url").changed)
    }

    @Test func cleansLinksInsideText() {
        let (text, results) = CleanLinks.cleanAll(
            in: "See https://a.example.com/x?utm_source=1 and https://b.example.com/y?ref=2 today")
        #expect(text == "See https://a.example.com/x and https://b.example.com/y?ref=2 today")
        #expect(results.count == 2)
        #expect(results.filter(\.changed).count == 1)
    }
}

@Suite("Lorem ipsum")
struct LoremIpsumTests {
    @Test func words() {
        var generator = SeededGenerator(seed: 1)
        let text = LoremIpsum.generate(12, unit: .words, using: &generator)
        #expect(text.split(separator: " ").count == 12)
        #expect(text.hasPrefix("Lorem ipsum dolor sit amet consectetur adipiscing elit"))
    }

    @Test func sentencesAndParagraphs() {
        var generator = SeededGenerator(seed: 2)
        let sentences = LoremIpsum.generate(3, unit: .sentences, using: &generator)
        #expect(sentences.filter { $0 == "." }.count == 3)
        #expect(sentences.hasPrefix(LoremIpsum.classicOpening))

        let paragraphs = LoremIpsum.generate(4, unit: .paragraphs, startWithClassic: false, using: &generator)
        #expect(paragraphs.components(separatedBy: "\n\n").count == 4)
        #expect(!paragraphs.hasPrefix("Lorem ipsum dolor"))
    }

    @Test func zeroCount() {
        #expect(LoremIpsum.generate(0, unit: .words).isEmpty)
        #expect(LoremIpsum.generate(-3, unit: .paragraphs).isEmpty)
    }
}

@Suite("Password generator")
struct PasswordGeneratorTests {
    @Test func includesEveryEnabledGroup() {
        var generator = SeededGenerator(seed: 3)
        for _ in 0..<50 {
            let password = PasswordGenerator.generate(PasswordGenerator.Options(length: 8), using: &generator)
            #expect(password.count == 8)
            #expect(password.contains(where: \.isLowercase))
            #expect(password.contains(where: \.isUppercase))
            #expect(password.contains(where: \.isNumber))
            #expect(password.contains(where: { PasswordGenerator.symbolSet.contains($0) }))
        }
    }

    @Test func excludesAmbiguousCharacters() {
        var generator = SeededGenerator(seed: 4)
        let options = PasswordGenerator.Options(length: 200, excludeAmbiguous: true)
        let password = PasswordGenerator.generate(options, using: &generator)
        #expect(!password.contains(where: { PasswordGenerator.ambiguous.contains($0) }))
    }

    @Test func edgeCases() {
        let none = PasswordGenerator.Options(lowercase: false, uppercase: false, digits: false, symbols: false)
        #expect(PasswordGenerator.generate(none).isEmpty)
        #expect(PasswordGenerator.generate(PasswordGenerator.Options(length: 2)).count == 2)
        #expect(PasswordGenerator.generate(PasswordGenerator.Options(length: 0)).isEmpty)
    }

    @Test func entropy() {
        let digits = PasswordGenerator.Options(length: 10, lowercase: false, uppercase: false, symbols: false)
        #expect(abs(PasswordGenerator.entropyBits(for: digits) - 33.219) < 0.01)
        #expect(PasswordGenerator.Strength(entropyBits: 33) == .weak)
        #expect(PasswordGenerator.Strength(entropyBits: 128) == .veryStrong)
    }
}

@Suite("Text statistics")
struct TextStatisticsTests {
    @Test func countsProse() {
        let stats = TextStatistics("Hello world. This is OpenToolbox!\n\nSecond paragraph here.")
        #expect(stats.words == 8)
        #expect(stats.sentences == 3)
        #expect(stats.lines == 3)
        #expect(stats.paragraphs == 2)
    }

    @Test func countsGraphemesAndBytes() {
        let stats = TextStatistics("héllo 👋🏽")
        #expect(stats.characters == 7)
        #expect(stats.charactersExcludingWhitespace == 6)
        #expect(stats.utf8Bytes == 15)
    }

    @Test func emptyText() {
        let stats = TextStatistics("")
        #expect(stats == TextStatistics(""))
        #expect(stats.words == 0 && stats.lines == 0 && stats.paragraphs == 0 && stats.characters == 0)
    }
}

@Suite("Case converter")
struct CaseConverterTests {
    @Test func splitsIdentifiers() {
        #expect(CaseConverter.words(in: "parseHTTPResponse_v2") == ["parse", "HTTP", "Response", "v2"])
        #expect(CaseConverter.words(in: "XMLHttpRequest") == ["XML", "Http", "Request"])
        #expect(CaseConverter.words(in: "version2Update") == ["version2", "Update"])
        #expect(CaseConverter.words(in: "kebab-case  words") == ["kebab", "case", "words"])
    }

    @Test(arguments: [
        (TextCase.camel, "helloWorldExample"),
        (.pascal, "HelloWorldExample"),
        (.snake, "hello_world_example"),
        (.screamingSnake, "HELLO_WORLD_EXAMPLE"),
        (.kebab, "hello-world-example"),
        (.dot, "hello.world.example"),
        (.lower, "hello world_example"),
        (.upper, "HELLO WORLD_EXAMPLE"),
    ])
    func identifierCases(_ textCase: TextCase, _ expected: String) {
        #expect(CaseConverter.convert("hello World_example", to: textCase, locale: Locale(identifier: "en_US")).lowercased() == expected.lowercased())
        #expect(CaseConverter.convert("hello world_example", to: textCase, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func proseCases() {
        #expect(CaseConverter.convert("the lord OF the rings", to: .title) == "The Lord of the Rings")
        #expect(CaseConverter.convert("hello WORLD. how are you?", to: .sentence) == "Hello world. How are you?")
    }

    @Test func keepsLines() {
        #expect(CaseConverter.convert("fooBar\nbazQux", to: .snake) == "foo_bar\nbaz_qux")
    }
}

@Suite("CSV")
struct CSVTests {
    @Test func parsesQuotedFields() throws {
        let rows = try CSV.parse("a,b,c\n1,\"x,y\",\"he said \"\"hi\"\"\"\r\n2,,3\n")
        #expect(rows == [["a", "b", "c"], ["1", "x,y", "he said \"hi\""], ["2", "", "3"]])
    }

    @Test func quotedNewlines() throws {
        #expect(try CSV.parse("\"line1\nline2\",b") == [["line1\nline2", "b"]])
    }

    @Test func unterminatedQuote() {
        #expect(throws: CSVError.unterminatedQuote(line: 2)) { try CSV.parse("a\n\"b,c") }
    }

    @Test func detectsDelimiter() {
        #expect(CSV.detectDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSV.detectDelimiter("a\tb\n1\t2") == "\t")
        #expect(CSV.detectDelimiter("single") == ",")
    }

    @Test func toJSONInfersTypes() throws {
        let json = try CSV.toJSON("name,age,active,id\nAda,36,true,007\nBob,,false,8", indent: nil)
        #expect(
            json
                == #"[{"name":"Ada","age":36,"active":true,"id":"007"},{"name":"Bob","age":null,"active":false,"id":8}]"#)
    }

    @Test func toJSONWithoutHeader() throws {
        let json = try CSV.toJSON(
            "a,1\nb,2", options: CSV.ToJSONOptions(firstRowIsHeader: false, inferTypes: false), indent: nil)
        #expect(json == #"[["a","1"],["b","2"]]"#)
    }

    @Test func duplicateAndEmptyHeaders() throws {
        let json = try CSV.toJSON("x,x,\n1,2,3", indent: nil)
        #expect(json == #"[{"x":1,"x_2":2,"column3":3}]"#)
    }

    @Test func fromJSON() throws {
        #expect(try CSV.fromJSON(#"[{"a":1,"b":"x,y"},{"b":"z","c":true}]"#) == "a,b,c\n1,\"x,y\",\n,z,true")
        #expect(try CSV.fromJSON(#"[["a","b"],[1,null]]"#) == "a,b\n1,")
        #expect(try CSV.fromJSON(#"[{"n":{"k":[1]}}]"#) == "n\n\"{\"\"k\"\":[1]}\"")
        #expect(throws: CSVError.notAnArrayOfObjects) { try CSV.fromJSON("{}") }
        #expect(throws: CSVError.notAnArrayOfObjects) { try CSV.fromJSON("[1,2]") }
    }

    @Test func roundTrip() throws {
        let rows = [["a", "b"], ["with,comma", "with \"quote\""], [" padded ", "multi\nline"]]
        #expect(try CSV.parse(CSV.write(rows)) == rows)
    }
}

@Suite("Regex tester")
struct RegexTesterTests {
    @Test func matchesWithGroups() throws {
        let matches = try RegexTester.matches(#"(\d+)-(?<word>[a-z]+)"#, in: "10-ab x 7-c")
        #expect(matches.map(\.value) == ["10-ab", "7-c"])
        #expect(matches[0].groups.map(\.value) == ["10", "ab"])
        #expect(matches[0].groups[1].name == "word")
        #expect(matches[0].groups[0].name == nil)
    }

    @Test func optionalGroupsAndOptions() throws {
        let matches = try RegexTester.matches("a(b)?", in: "a ab")
        #expect(matches[0].groups[0].value == nil)
        #expect(matches[1].groups[0].value == "b")
        #expect(try RegexTester.matches("abc", in: "ABC abc", options: .caseInsensitive).count == 2)
        #expect(try RegexTester.matches("^x", in: "x\nx", options: .multiline).count == 2)
        #expect(try RegexTester.matches("a.b", in: "a\nb", options: .dotMatchesNewlines).count == 1)
    }

    @Test func invalidPattern() {
        #expect(throws: RegexTester.InvalidPattern.self) { try RegexTester.matches("(", in: "x") }
    }

    @Test func replacementTemplates() throws {
        #expect(try RegexTester.replace(#"(?<y>\d{4})-(\d{2})"#, in: "on 2024-05", with: "${y}/$2") == "on 2024/05")
    }

    @Test func groupNumbering() {
        #expect(RegexTester.groupNames(in: #"(?:a)(?<n>b)(?<=c)\((d)[(](?<m>e)"#) == [1: "n", 3: "m"])
    }
}

@Suite("Text diff")
struct TextDiffTests {
    @Test func linesAddedAndRemoved() {
        let lines = TextDiff.diff("a\nb\nc", "a\nB\nc\nd")
        #expect(lines.map(\.kind) == [.unchanged, .removed, .added, .unchanged, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(lines[1].oldNumber == 2 && lines[1].newNumber == nil)
        #expect(lines[4].newNumber == 4)
        #expect(TextDiff.summary(of: lines) == TextDiff.Summary(added: 2, removed: 1, unchanged: 2))
        #expect(TextDiff.unifiedText(lines) == " a\n-b\n+B\n c\n+d")
    }

    @Test func ignoreOptions() {
        let caseless = TextDiff.diff("a\nb", "A\nB", options: TextDiff.Options(ignoreCase: true))
        #expect(TextDiff.summary(of: caseless).isIdentical)
        let spaces = TextDiff.diff("a  b", " a b", options: TextDiff.Options(ignoreWhitespace: true))
        #expect(TextDiff.summary(of: spaces).isIdentical)
    }

    @Test func lineSplitting() {
        #expect(TextDiff.lines("") == [])
        #expect(TextDiff.lines("a\n") == ["a"])
        #expect(TextDiff.lines("a\r\nb") == ["a", "b"])
        #expect(TextDiff.diff("", "x").map(\.kind) == [.added])
    }
}

@Suite("Unicode inspector")
struct UnicodeInspectorTests {
    @Test func describesScalars() {
        let a = UnicodeInspector.describe("A")
        #expect(a.codePoint == "U+0041")
        #expect(a.name == "LATIN CAPITAL LETTER A")
        #expect(a.utf8 == "41")
        #expect(a.utf16 == "0041")
        #expect(a.category.hasPrefix("Lu"))

        let face = UnicodeInspector.describe("😀")
        #expect(face.codePoint == "U+1F600")
        #expect(face.name == "GRINNING FACE")
        #expect(face.utf8 == "F0 9F 98 80")
        #expect(face.utf16 == "D83D DE00")
    }

    @Test func flagsInvisibleCharacters() {
        let zwsp = UnicodeInspector.describe("\u{200B}")
        #expect(zwsp.isInvisible)
        #expect(zwsp.name == "ZERO WIDTH SPACE")
        #expect(!UnicodeInspector.describe("x").isInvisible)
    }

    @Test func groupsScalarsIntoCharacters() {
        let characters = UnicodeInspector.inspect("é👋🏽")
        #expect(characters.count == 2)
        #expect(characters[1].scalars.map(\.codePoint) == ["U+1F44B", "U+1F3FD"])
        #expect(Set(characters.flatMap(\.scalars).map(\.id)).count == 3)
    }

    @Test func normalizations() {
        let forms = Dictionary(uniqueKeysWithValues: UnicodeInspector.normalizations(of: "e\u{301}").map { ($0.name, $0.value) })
        #expect(forms["NFC"]?.unicodeScalars.count == 1)
        #expect(forms["NFD"]?.unicodeScalars.count == 2)
    }
}
