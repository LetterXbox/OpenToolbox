import Foundation

/// A latitude and longitude in decimal degrees (WGS 84).
public struct GeoCoordinate: Equatable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude)
        else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    static let posix = Locale(identifier: "en_US_POSIX")

    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", locale: posix, value)
    }

    /// `48.858370, 2.294481`
    public var decimal: String { "\(Self.fixed(latitude, 6)), \(Self.fixed(longitude, 6))" }

    public var latitudeText: String { Self.fixed(latitude, 6) }
    public var longitudeText: String { Self.fixed(longitude, 6) }

    /// `48°51′30.1″N 2°17′40.1″E`
    public var degreesMinutesSeconds: String {
        "\(Self.dms(latitude, positive: "N", negative: "S")) \(Self.dms(longitude, positive: "E", negative: "W"))"
    }

    static func dms(_ value: Double, positive: String, negative: String) -> String {
        let tenths = Int((abs(value) * 36_000).rounded())
        let degrees = tenths / 36_000
        let minutes = (tenths % 36_000) / 600
        let seconds = Double(tenths % 600) / 10
        return "\(degrees)°\(minutes)′\(fixed(seconds, 1))″\(value < 0 ? negative : positive)"
    }

    /// GeoJSON order: longitude first.
    public var geoJSON: String { "[\(Self.fixed(longitude, 6)), \(Self.fixed(latitude, 6))]" }

    /// Parses `48.8584, 2.2945`, `48.8584 2.2945`, or degrees-minutes-seconds such as
    /// `48°51'30"N 2°17'40"E`. Decimal input is latitude first.
    public static func parse(_ text: String) -> GeoCoordinate? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let pair = parseDMS(trimmed) { return pair }
        let numbers = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .compactMap { Double($0) }
        guard numbers.count == 2 else { return nil }
        return GeoCoordinate(latitude: numbers[0], longitude: numbers[1])
    }

    static func parseDMS(_ text: String) -> GeoCoordinate? {
        let normalized = text.uppercased()
            .replacingOccurrences(of: "′", with: "'").replacingOccurrences(of: "″", with: "\"")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "”", with: "\"")
        var parts: [(value: Double, hemisphere: Character)] = []
        var numbers: [Double] = []
        var current = ""
        func flushNumber() {
            if let value = Double(current) { numbers.append(value) }
            current = ""
        }
        for character in normalized {
            if character.isNumber || character == "." {
                current.append(character)
            } else if "NSEW".contains(character) {
                flushNumber()
                guard (1...3).contains(numbers.count) else { return nil }
                let value = numbers.enumerated().reduce(0.0) { sum, item in
                    sum + item.element / pow(60, Double(item.offset))
                }
                parts.append((value, character))
                numbers = []
            } else {
                flushNumber()
            }
        }
        guard numbers.isEmpty, parts.count == 2 else { return nil }
        var latitude: Double?
        var longitude: Double?
        for part in parts {
            switch part.hemisphere {
            case "N": latitude = part.value
            case "S": latitude = -part.value
            case "E": longitude = part.value
            default: longitude = -part.value
            }
        }
        guard let latitude, let longitude else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}
