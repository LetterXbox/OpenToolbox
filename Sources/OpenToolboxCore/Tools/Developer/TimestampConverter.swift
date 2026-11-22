import Foundation

public enum TimestampUnit: String, CaseIterable, Sendable, Identifiable {
    case seconds
    case milliseconds
    case microseconds
    case nanoseconds

    public var id: String { rawValue }

    /// Units per second.
    public var perSecond: Double {
        switch self {
        case .seconds: 1
        case .milliseconds: 1_000
        case .microseconds: 1_000_000
        case .nanoseconds: 1_000_000_000
        }
    }

    public var localizedName: String {
        switch self {
        case .seconds: coreLocalized("Seconds")
        case .milliseconds: coreLocalized("Milliseconds")
        case .microseconds: coreLocalized("Microseconds")
        case .nanoseconds: coreLocalized("Nanoseconds")
        }
    }
}

public struct ParsedTimestamp: Equatable, Sendable {
    public var date: Date
    /// The unit a numeric input was read in; `nil` when the input was a date string.
    public var unit: TimestampUnit?
}

public enum TimestampError: Error, Equatable, LocalizedError {
    case empty
    case unrecognized

    public var errorDescription: String? {
        switch self {
        case .empty: coreLocalized("Enter a Unix timestamp or a date.")
        case .unrecognized: coreLocalized("Not a recognized timestamp or date format.")
        }
    }
}

public struct TimestampRepresentation: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case unixSeconds
        case unixMilliseconds
        case iso8601UTC
        case iso8601Local
        case rfc2822
        case localized
        case relative

        public var localizedName: String {
            switch self {
            case .unixSeconds: coreLocalized("Unix (seconds)")
            case .unixMilliseconds: coreLocalized("Unix (milliseconds)")
            case .iso8601UTC: coreLocalized("ISO 8601 (UTC)")
            case .iso8601Local: coreLocalized("ISO 8601 (selected time zone)")
            case .rfc2822: coreLocalized("RFC 2822")
            case .localized: coreLocalized("Readable")
            case .relative: coreLocalized("Relative")
            }
        }
    }

    public var kind: Kind
    public var value: String
    public var id: Kind { kind }
}

public enum TimestampConverter {
    /// Parses a Unix timestamp (unit auto-detected unless given) or a date string.
    /// Date strings without an explicit offset are read in `timeZone`.
    public static func parse(_ input: String, unit: TimestampUnit? = nil, timeZone: TimeZone = .current) throws
        -> ParsedTimestamp
    {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TimestampError.empty }

        if isNumeric(text), let value = Double(text) {
            let resolvedUnit = unit ?? detectUnit(text)
            return ParsedTimestamp(date: Date(timeIntervalSince1970: value / resolvedUnit.perSecond), unit: resolvedUnit)
        }
        if let date = parseDateString(text, timeZone: timeZone) {
            return ParsedTimestamp(date: date, unit: nil)
        }
        throw TimestampError.unrecognized
    }

    /// Picks a unit from the number of integer digits (10 ≈ seconds, 13 ≈ ms, 16 ≈ µs, 19 ≈ ns).
    public static func detectUnit(_ text: String) -> TimestampUnit {
        let integerDigits = text.drop { $0 == "-" || $0 == "+" }.prefix { $0 != "." }.count
        switch integerDigits {
        case ...11: return .seconds
        case 12...14: return .milliseconds
        case 15...17: return .microseconds
        default: return .nanoseconds
        }
    }

    public static func representations(
        of date: Date,
        timeZone: TimeZone = .current,
        now: Date = Date(),
        locale: Locale = .current
    ) -> [TimestampRepresentation] {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let hasFraction = milliseconds % 1000 != 0
        let seconds = hasFraction ? String(format: "%.3f", Double(milliseconds) / 1000) : String(milliseconds / 1000)

        // Build ISO 8601 from whole seconds plus exact milliseconds; formatters can
        // truncate binary floating-point fractions (…123 → …122).
        let wholeSeconds = Int64((Double(milliseconds) / 1000).rounded(.down))
        let fraction = milliseconds - wholeSeconds * 1000
        let whole = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        func iso8601(in zone: TimeZone) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = zone
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            var text = formatter.string(from: whole)
            if hasFraction { text += String(format: ".%03lld", fraction) }
            formatter.dateFormat = "XXXXX"
            return text + formatter.string(from: whole)
        }
        let isoUTC = iso8601(in: TimeZone(identifier: "UTC")!)
        let isoLocal = iso8601(in: timeZone)

        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = timeZone
        rfc.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        let readable = DateFormatter()
        readable.locale = locale
        readable.timeZone = timeZone
        readable.dateStyle = .full
        readable.timeStyle = .long

        let relative = RelativeDateTimeFormatter()
        relative.locale = locale
        relative.unitsStyle = .full

        return [
            TimestampRepresentation(kind: .unixSeconds, value: seconds),
            TimestampRepresentation(kind: .unixMilliseconds, value: String(milliseconds)),
            TimestampRepresentation(kind: .iso8601UTC, value: isoUTC),
            TimestampRepresentation(kind: .iso8601Local, value: isoLocal),
            TimestampRepresentation(kind: .rfc2822, value: rfc.string(from: date)),
            TimestampRepresentation(kind: .localized, value: readable.string(from: date)),
            TimestampRepresentation(kind: .relative, value: relative.localizedString(for: date, relativeTo: now)),
        ]
    }

    // MARK: Helpers

    static func isNumeric(_ text: String) -> Bool {
        var body = Substring(text)
        if body.first == "-" || body.first == "+" { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty else { return false }
        return parts.allSatisfy { part in part.allSatisfy(\.isASCIIDigitCharacter) } && !(parts.count == 2 && parts[1].isEmpty)
    }

    static func parseDateString(_ text: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

extension Character {
    fileprivate var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}
