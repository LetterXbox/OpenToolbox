import Foundation

public enum UUIDVersion: Int, CaseIterable, Sendable, Identifiable {
    case v4 = 4
    case v7 = 7

    public var id: Int { rawValue }
}

/// Formatting choices for generated UUIDs.
public struct UUIDFormat: Equatable, Sendable {
    public var uppercase: Bool
    public var hyphens: Bool
    public var braces: Bool

    public init(uppercase: Bool = false, hyphens: Bool = true, braces: Bool = false) {
        self.uppercase = uppercase
        self.hyphens = hyphens
        self.braces = braces
    }
}

/// Details decoded from an existing UUID.
public struct UUIDInfo: Equatable, Sendable {
    public enum Variant: String, Sendable {
        case ncs = "NCS (reserved)"
        case rfc9562 = "RFC 9562"
        case microsoft = "Microsoft (reserved)"
        case future = "Reserved for future use"

        public var localizedName: String { coreLocalized(dynamicKey: rawValue) }
    }

    public var uuid: UUID
    public var version: Int
    public var variant: Variant
    /// Embedded creation time for time-based versions (1, 6, and 7).
    public var timestamp: Date?
    public var isNil: Bool
    public var isMax: Bool
}

public enum UUIDTools {
    public static func generate(_ version: UUIDVersion) -> UUID {
        switch version {
        case .v4: UUID()
        case .v7: v7()
        }
    }

    public static func v7(date: Date = Date()) -> UUID {
        var generator = SystemRandomNumberGenerator()
        return v7(date: date, using: &generator)
    }

    /// RFC 9562 UUIDv7: 48-bit Unix milliseconds, version 7, then 74 random bits.
    public static func v7(date: Date, using generator: inout some RandomNumberGenerator) -> UUID {
        let milliseconds = UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down))) & 0xFFFF_FFFF_FFFF
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> (8 * (5 - index)))
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        bytes[6] = 0x70 | (bytes[6] & 0x0F)
        bytes[8] = 0x80 | (bytes[8] & 0x3F)
        return uuid(from: bytes)
    }

    public static func format(_ uuid: UUID, _ format: UUIDFormat = UUIDFormat()) -> String {
        var text = uuid.uuidString
        if !format.uppercase { text = text.lowercased() }
        if !format.hyphens { text = text.replacingOccurrences(of: "-", with: "") }
        if format.braces { text = "{\(text)}" }
        return text
    }

    /// Parses hyphenated, compact (32 digits), braced, or `urn:uuid:` forms.
    public static func parse(_ text: String) -> UUID? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("urn:uuid:") { cleaned = String(cleaned.dropFirst(9)) }
        if cleaned.hasPrefix("{"), cleaned.hasSuffix("}") { cleaned = String(cleaned.dropFirst().dropLast()) }
        if cleaned.count == 32, !cleaned.contains("-") {
            let characters = Array(cleaned)
            cleaned = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
                .map { String(characters[$0]) }
                .joined(separator: "-")
        }
        return UUID(uuidString: cleaned)
    }

    public static func inspect(_ text: String) -> UUIDInfo? {
        guard let uuid = parse(text) else { return nil }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        let version = Int(bytes[6] >> 4)
        let variant: UUIDInfo.Variant =
            switch bytes[8] {
            case 0x00..<0x80: .ncs
            case 0x80..<0xC0: .rfc9562
            case 0xC0..<0xE0: .microsoft
            default: .future
            }
        let isNil = bytes.allSatisfy { $0 == 0 }
        let isMax = bytes.allSatisfy { $0 == 0xFF }

        var timestamp: Date?
        if variant == .rfc9562 {
            switch version {
            case 7:
                let milliseconds = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                timestamp = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            case 1:
                let low = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let mid = bytes[4..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let high = (UInt64(bytes[6] & 0x0F) << 8) | UInt64(bytes[7])
                timestamp = gregorianDate(fromTicks: high << 48 | mid << 32 | low)
            case 6:
                let high = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let low = (UInt64(bytes[6] & 0x0F) << 8) | UInt64(bytes[7])
                timestamp = gregorianDate(fromTicks: high << 12 | low)
            default:
                break
            }
        }
        return UUIDInfo(
            uuid: uuid, version: version, variant: variant, timestamp: timestamp, isNil: isNil, isMax: isMax)
    }

    /// 100-ns ticks since 1582-10-15 (UUID v1/v6 epoch) to `Date`.
    private static func gregorianDate(fromTicks ticks: UInt64) -> Date {
        let offsetToUnixEpoch: UInt64 = 0x01B2_1DD2_1381_4000
        let unixTicks = Double(Int64(bitPattern: ticks &- offsetToUnixEpoch))
        return Date(timeIntervalSince1970: unixTicks / 10_000_000)
    }

    private static func uuid(from b: [UInt8]) -> UUID {
        UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
