import Foundation
import Testing

@testable import OpenToolboxCore

@Suite("JSON")
struct JSONTests {
    @Test func prettyPrintKeepsKeyOrderAndNumbers() throws {
        let input = #"{"b":1.50,"a":[1,2,{"z":null}],"c":"x","e":{},"f":[],"big":12345678901234567890}"#
        let expected = """
            {
              "b": 1.50,
              "a": [
                1,
                2,
                {
                  "z": null
                }
              ],
              "c": "x",
              "e": {},
              "f": [],
              "big": 12345678901234567890
            }
            """
        #expect(try JSONFormatter.prettyPrinted(input) == expected)
    }

    @Test func sortKeysAndTabs() throws {
        let output = try JSONFormatter.prettyPrinted(#"{"b":true,"a":false}"#, indent: .tab, sortKeys: true)
        #expect(output == "{\n\t\"a\": false,\n\t\"b\": true\n}")
    }

    @Test func minifyRoundTrips() throws {
        let input = """
            {
              "name" : "Ada \\u00e9 \\ud83d\\ude00",
              "list" : [ 1 , -2.5e-3 , true ]
            }
            """
        let minified = try JSONFormatter.minified(input)
        #expect(minified == #"{"name":"Ada é 😀","list":[1,-2.5e-3,true]}"#)
        #expect(try JSONFormatter.minified(minified) == minified)
    }

    @Test func escapesControlCharacters() throws {
        #expect(try JSONFormatter.minified(#"["a\"b\\c\n\u0001"]"#) == #"["a\"b\\c\n\u0001"]"#)
    }

    @Test func reportsErrorPosition() {
        do {
            _ = try JSONParser.parse("{\n  \"a\": 1,\n  \"b\": tru\n}")
            Issue.record("Expected a parse error")
        } catch let error as JSONParseError {
            #expect(error.line == 3)
            #expect(error.column == 11)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "-", "\"abc", "\"\\x\"", "[1] 2", "\"\\ud800\"", "\"a\u{01}\""])
    func rejectsInvalidJSON(_ input: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(input) }
    }

    @Test func rejectsExcessiveNesting() {
        let deep = String(repeating: "[", count: JSONParser.maximumDepth + 1)
            + String(repeating: "]", count: JSONParser.maximumDepth + 1)
        do {
            _ = try JSONParser.parse(deep)
            Issue.record("Expected nestingTooDeep")
        } catch let error as JSONParseError {
            #expect(error.reason == .nestingTooDeep)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    /// Runs on a Swift Testing worker thread (small stack), so this also proves the
    /// parser and serializer do not recurse per nesting level.
    @Test func maximumNestingIsStackSafe() throws {
        let depth = JSONParser.maximumDepth
        let arrays = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        #expect(try JSONFormatter.minified(arrays) == arrays)
        let emptyInnermost = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(try JSONFormatter.minified(emptyInnermost) == emptyInnermost)
        let pretty = try JSONFormatter.prettyPrinted(arrays)
        #expect(try JSONFormatter.minified(pretty) == arrays)

        let objects = String(repeating: #"{"k":"#, count: depth) + "null" + String(repeating: "}", count: depth)
        #expect(try JSONFormatter.minified(objects) == objects)
    }

    @Test func mixedContainers() throws {
        let input = #"{"a":[{"b":[]},{"c":{"d":[1,{"e":2}]}}],"f":{}}"#
        #expect(try JSONFormatter.minified(input) == input)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(#"{"a":[1}"#) }
        #expect(throws: JSONParseError.self) { try JSONParser.parse(#"{"a":1,}"#) }
        #expect(throws: JSONParseError.self) { try JSONParser.parse(#"[1 2]"#) }
    }
}

@Suite("Base64 / Hex")
struct ByteEncodingTests {
    let text = "Hello, OpenToolbox! ✓"

    @Test func base64RoundTrip() throws {
        let encoded = ByteEncoding.base64Encode(Data(text.utf8))
        #expect(encoded == "SGVsbG8sIE9wZW5Ub29sYm94ISDinJM=")
        #expect(try ByteEncoding.base64Decode(encoded) == Data(text.utf8))
    }

    @Test func base64URLAndPadding() throws {
        let bytes = Data([0xFB, 0xFF, 0xFE])
        #expect(ByteEncoding.base64Encode(bytes) == "+//+")
        #expect(ByteEncoding.base64Encode(bytes, urlSafe: true) == "-__-")
        #expect(try ByteEncoding.base64Decode("-__-") == bytes)
        #expect(ByteEncoding.base64Encode(Data("ab".utf8), padded: false) == "YWI")
        #expect(try ByteEncoding.base64Decode("YWI") == Data("ab".utf8))
        #expect(try ByteEncoding.base64Decode(" SGVs\nbG8= ") == Data("Hello".utf8))
    }

    @Test func base64RejectsGarbage() {
        #expect(throws: ByteEncodingError.invalidBase64) { try ByteEncoding.base64Decode("abcde") }
        #expect(throws: ByteEncodingError.invalidBase64) { try ByteEncoding.base64Decode("ab$=") }
    }

    @Test func hexRoundTrip() throws {
        let bytes = Data([0x00, 0x7F, 0xAB, 0xFF])
        #expect(ByteEncoding.hexEncode(bytes) == "007fabff")
        #expect(ByteEncoding.hexEncode(bytes, uppercase: true, separator: " ") == "00 7F AB FF")
        #expect(try ByteEncoding.hexDecode("007fabff") == bytes)
        #expect(try ByteEncoding.hexDecode("0x00 0x7F ab:FF") == bytes)
    }

    @Test func hexRejectsInvalidInput() {
        #expect(throws: ByteEncodingError.oddHexLength) { try ByteEncoding.hexDecode("abc") }
        #expect(throws: ByteEncodingError.invalidHexCharacter("g")) { try ByteEncoding.hexDecode("0g") }
    }
}

@Suite("Hash generator")
struct HashTests {
    @Test(arguments: [
        (HashAlgorithm.md5, "900150983cd24fb0d6963f7d28e17f72"),
        (.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (.sha384, "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7"),
        (
            .sha512,
            "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
        ),
    ])
    func knownVectors(_ algorithm: HashAlgorithm, _ expected: String) {
        #expect(HashGenerator.hash("abc", algorithm: algorithm) == expected)
    }

    @Test func emptyInput() {
        #expect(
            HashGenerator.hash(Data(), algorithm: .sha256)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func fileHashingMatchesInMemoryAcrossChunks() async throws {
        try await withTemporaryDirectory { directory in
            let file = directory.appending(path: "data.bin")
            let data = Data((0..<10_000).map { UInt8($0 % 251) })
            try data.write(to: file)
            let hashes = try HashGenerator.hashFile(at: file, algorithms: HashAlgorithm.allCases, chunkSize: 777)
            for algorithm in HashAlgorithm.allCases {
                #expect(hashes[algorithm] == HashGenerator.hash(data, algorithm: algorithm))
            }
        }
    }

    @Test func compareIgnoresCaseAndSeparators() {
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(HashGenerator.matches(digest, expected: "  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD\n"))
        #expect(!HashGenerator.matches(digest, expected: "ba78"))
        #expect(!HashGenerator.matches(digest, expected: ""))
    }
}

@Suite("UUID")
struct UUIDTests {
    struct FixedGenerator: RandomNumberGenerator {
        mutating func next() -> UInt64 { 0xFFFF_FFFF_FFFF_FFFF }
    }

    @Test func v7LayoutAndTimestamp() throws {
        var generator = FixedGenerator()
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let uuid = UUIDTools.v7(date: date, using: &generator)
        let text = UUIDTools.format(uuid)
        // 1700000000123 ms = 0x018bcfe5687b
        #expect(text == "018bcfe5-687b-7fff-bfff-ffffffffffff")
        let info = try #require(UUIDTools.inspect(text))
        #expect(info.version == 7)
        #expect(info.variant == .rfc9562)
        #expect(info.timestamp?.timeIntervalSince1970 == 1_700_000_000.123)
    }

    @Test func v7ClampsOutOfRangeDates() {
        var generator = FixedGenerator()
        let far = UUIDTools.format(UUIDTools.v7(date: Date(timeIntervalSince1970: 1e300), using: &generator))
        #expect(far.hasPrefix("ffffffff-ffff-7"))
        let past = UUIDTools.format(UUIDTools.v7(date: Date(timeIntervalSince1970: -1e300), using: &generator))
        #expect(past.hasPrefix("00000000-0000-7"))
    }

    @Test func v7IsSortableByTime() {
        let earlier = UUIDTools.format(UUIDTools.v7(date: Date(timeIntervalSince1970: 1_000)))
        let later = UUIDTools.format(UUIDTools.v7(date: Date(timeIntervalSince1970: 2_000)))
        #expect(earlier < later)
    }

    @Test func v4HasVersionAndVariant() throws {
        let info = try #require(UUIDTools.inspect(UUIDTools.format(UUIDTools.generate(.v4))))
        #expect(info.version == 4)
        #expect(info.variant == .rfc9562)
        #expect(info.timestamp == nil)
    }

    @Test func formatting() throws {
        let uuid = try #require(UUID(uuidString: "018BCFE5-687B-7FFF-BFFF-FFFFFFFFFFFF"))
        #expect(UUIDTools.format(uuid, UUIDFormat(uppercase: true)) == "018BCFE5-687B-7FFF-BFFF-FFFFFFFFFFFF")
        #expect(UUIDTools.format(uuid, UUIDFormat(hyphens: false)) == "018bcfe5687b7fffbfffffffffffffff")
        #expect(UUIDTools.format(uuid, UUIDFormat(braces: true)) == "{018bcfe5-687b-7fff-bfff-ffffffffffff}")
    }

    @Test(arguments: [
        "018bcfe5687b7fffbfffffffffffffff",
        "{018BCFE5-687B-7FFF-BFFF-FFFFFFFFFFFF}",
        "urn:uuid:018bcfe5-687b-7fff-bfff-ffffffffffff",
    ])
    func parsesAlternateForms(_ text: String) {
        #expect(UUIDTools.parse(text) == UUID(uuidString: "018BCFE5-687B-7FFF-BFFF-FFFFFFFFFFFF"))
    }

    @Test func v1Timestamp() throws {
        // RFC 9562 Appendix A.1 example: 2022-02-22 19:22:22 UTC.
        let info = try #require(UUIDTools.inspect("C232AB00-9414-11EC-B3C8-9F6BDECED846"))
        #expect(info.version == 1)
        #expect(info.timestamp?.timeIntervalSince1970 == 1_645_557_742)
    }

    @Test func nilAndInvalid() throws {
        #expect(try #require(UUIDTools.inspect("00000000-0000-0000-0000-000000000000")).isNil)
        #expect(UUIDTools.inspect("not-a-uuid") == nil)
    }
}

@Suite("JWT decoder")
struct JWTTests {
    static let token =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkFkYSIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAwMDAzNjAwfQ.XHDm8dmGYBSG_eDBYmMsZ-8XPkCwj7bYuNgvHSgwfkg"

    @Test func decodesHeaderPayloadAndClaims() throws {
        let jwt = try JWTDecoder.decode("Bearer \(Self.token)\n")
        #expect(jwt.algorithm == "HS256")
        #expect(jwt.payload["name"]?.stringValue == "Ada")
        #expect(jwt.signature == "XHDm8dmGYBSG_eDBYmMsZ-8XPkCwj7bYuNgvHSgwfkg")
        #expect(jwt.timeClaims.map(\.name) == ["iat", "exp"])
        #expect(jwt.timeClaims.last?.date == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(jwt.isExpired(at: Date(timeIntervalSince1970: 1_700_003_600)))
        #expect(!jwt.isExpired(at: Date(timeIntervalSince1970: 1_700_000_001)))
        #expect(jwt.prettyHeader == "{\n  \"alg\": \"HS256\",\n  \"typ\": \"JWT\"\n}")
    }

    @Test func rejectsMalformedTokens() {
        #expect(throws: JWTDecodeError.empty) { try JWTDecoder.decode("  ") }
        #expect(throws: JWTDecodeError.wrongSegmentCount(2)) { try JWTDecoder.decode("abc.def") }
        #expect(throws: JWTDecodeError.encryptedToken) { try JWTDecoder.decode("a.b.c.d.e") }
        #expect(throws: JWTDecodeError.self) { try JWTDecoder.decode("!!!.e30.sig") }
    }

    /// An unsecured token with the given JSON payload.
    static func unsecured(_ payload: String) -> String {
        let encoded = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded)."
    }

    @Test func validityDistinguishesMissingInvalidAndExpiredClaims() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"sub":"a"}"#)).validity(at: now) == .noTimeLimit)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"exp":"unknown"}"#)).validity(at: now) == .invalidTimeClaim)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"exp":1e300}"#)).validity(at: now) == .invalidTimeClaim)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"nbf":true,"exp":1800000000}"#)).validity(at: now) == .invalidTimeClaim)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"exp":1600000000}"#)).validity(at: now) == .expired)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"nbf":1800000000}"#)).validity(at: now) == .notYetValid)
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"exp":1800000000}"#)).validity(at: now) == .valid)
        // Out-of-range numbers never become displayable dates.
        #expect(try JWTDecoder.decode(Self.unsecured(#"{"iat":1e300}"#)).timeClaims.isEmpty)
    }

    @Test func acceptsUnsecuredTokens() throws {
        // {"alg":"none"} . {} . (empty signature)
        let jwt = try JWTDecoder.decode("eyJhbGciOiJub25lIn0.e30.")
        #expect(jwt.algorithm == "none")
        #expect(jwt.signature.isEmpty)
    }
}

@Suite("Timestamp converter")
struct TimestampTests {
    let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        ("1700000000", TimestampUnit.seconds),
        ("1700000000000", .milliseconds),
        ("1700000000000000", .microseconds),
        ("1700000000000000000", .nanoseconds),
    ])
    func autoDetectsUnits(_ input: String, _ unit: TimestampUnit) throws {
        let parsed = try TimestampConverter.parse(input)
        #expect(parsed.unit == unit)
        #expect(abs(parsed.date.timeIntervalSince1970 - 1_700_000_000) < 0.001)
    }

    @Test func explicitUnitOverridesDetection() throws {
        let parsed = try TimestampConverter.parse("1700000000", unit: .milliseconds)
        #expect(parsed.date.timeIntervalSince1970 == 1_700_000)
    }

    @Test func parsesDateStrings() throws {
        #expect(try TimestampConverter.parse("2023-11-14T22:13:20Z").date.timeIntervalSince1970 == 1_700_000_000)
        #expect(
            try TimestampConverter.parse("2023-11-14T23:13:20.500+01:00").date.timeIntervalSince1970 == 1_700_000_000.5)
        #expect(
            try TimestampConverter.parse("2023-11-14 22:13:20", timeZone: utc).date.timeIntervalSince1970
                == 1_700_000_000)
        #expect(
            try TimestampConverter.parse("Tue, 14 Nov 2023 22:13:20 +0000").date.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test func rejectsUnknownInput() {
        #expect(throws: TimestampError.empty) { try TimestampConverter.parse(" ") }
        #expect(throws: TimestampError.unrecognized) { try TimestampConverter.parse("yesterday-ish") }
        #expect(throws: TimestampError.unrecognized) { try TimestampConverter.parse("12.") }
    }

    @Test func rejectsTimestampsOutsideTheSupportedRange() throws {
        // Previously trapped converting milliseconds to Int64 while rendering.
        #expect(throws: TimestampError.outOfRange) {
            try TimestampConverter.parse("10000000000000000", unit: .seconds)
        }
        #expect(throws: TimestampError.outOfRange) {
            try TimestampConverter.parse("-99999999999999", unit: .seconds)
        }
        // 400 digits overflow Double; whichever way it is rejected, it must not trap.
        #expect(throws: TimestampError.self) {
            try TimestampConverter.parse(String(repeating: "9", count: 400))
        }
        #expect(try TimestampConverter.parse("253402300799", unit: .seconds).date.timeIntervalSince1970 == 253_402_300_799)
        #expect(TimestampConverter.representations(of: Date(timeIntervalSince1970: 1e16)).isEmpty)
        #expect(TimestampConverter.representations(of: .distantFuture).isEmpty == false)
    }

    @Test func representations() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let values = Dictionary(
            uniqueKeysWithValues: TimestampConverter.representations(
                of: date, timeZone: TimeZone(identifier: "Europe/Berlin")!, now: date, locale: Locale(identifier: "en_US")
            ).map { ($0.kind, $0.value) })
        #expect(values[.unixSeconds] == "1700000000")
        #expect(values[.unixMilliseconds] == "1700000000000")
        #expect(values[.iso8601UTC] == "2023-11-14T22:13:20Z")
        #expect(values[.iso8601Local] == "2023-11-14T23:13:20+01:00")
        #expect(values[.rfc2822] == "Tue, 14 Nov 2023 23:13:20 +0100")
    }

    @Test func fractionalRepresentations() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let values = Dictionary(
            uniqueKeysWithValues: TimestampConverter.representations(of: date, timeZone: utc).map { ($0.kind, $0.value) })
        #expect(values[.unixSeconds] == "1700000000.123")
        #expect(values[.unixMilliseconds] == "1700000000123")
        #expect(values[.iso8601UTC] == "2023-11-14T22:13:20.123Z")
    }
}
