import Foundation

/// An sRGB color with components in 0...1.
public struct SRGBColor: Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    static func clamp(_ value: Double) -> Double { value.isFinite ? min(max(value, 0), 1) : 0 }

    static func byte(_ value: Double) -> Int { Int((value * 255).rounded()) }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without `#`.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy(\.isHexDigit) else { return nil }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 || text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let shift: UInt32 = hasAlpha ? 8 : 0
        self.init(
            red: Double((value >> (16 + shift)) & 0xFF) / 255,
            green: Double((value >> (8 + shift)) & 0xFF) / 255,
            blue: Double((value >> shift) & 0xFF) / 255,
            alpha: hasAlpha ? Double(value & 0xFF) / 255 : 1)
    }

    public var hex: String {
        let rgb = String(format: "#%02X%02X%02X", Self.byte(red), Self.byte(green), Self.byte(blue))
        return alpha < 1 ? rgb + String(format: "%02X", Self.byte(alpha)) : rgb
    }

    public var rgb: String {
        let (r, g, b) = (Self.byte(red), Self.byte(green), Self.byte(blue))
        return alpha < 1 ? "rgb(\(r) \(g) \(b) / \(Self.decimal(alpha)))" : "rgb(\(r), \(g), \(b))"
    }

    /// Hue in degrees, saturation and lightness in 0...1.
    public var hslComponents: (hue: Double, saturation: Double, lightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let lightness = (maximum + minimum) / 2
        let delta = maximum - minimum
        guard delta > 0 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        return (hue(maximum: maximum, delta: delta), saturation, lightness)
    }

    /// Hue in degrees, saturation and brightness in 0...1.
    public var hsbComponents: (hue: Double, saturation: Double, brightness: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard maximum > 0, delta > 0 else { return (0, 0, maximum) }
        return (hue(maximum: maximum, delta: delta), delta / maximum, maximum)
    }

    private func hue(maximum: Double, delta: Double) -> Double {
        let sector: Double =
            if maximum == red { ((green - blue) / delta).truncatingRemainder(dividingBy: 6) }
            else if maximum == green { (blue - red) / delta + 2 }
            else { (red - green) / delta + 4 }
        let degrees = sector * 60
        return degrees < 0 ? degrees + 360 : degrees
    }

    public var hsl: String {
        let (h, s, l) = hslComponents
        let (hue, saturation, lightness) = (
            Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded())
        )
        return alpha < 1
            ? "hsl(\(hue) \(saturation)% \(lightness)% / \(Self.decimal(alpha)))"
            : "hsl(\(hue), \(saturation)%, \(lightness)%)"
    }

    public var hsb: String {
        let (h, s, b) = hsbComponents
        return "\(Int(h.rounded()) % 360)°, \(Int((s * 100).rounded()))%, \(Int((b * 100).rounded()))%"
    }

    public var swiftUI: String {
        "Color(red: \(Self.decimal(red)), green: \(Self.decimal(green)), blue: \(Self.decimal(blue))"
            + (alpha < 1 ? ", opacity: \(Self.decimal(alpha)))" : ")")
    }

    public var appKit: String {
        "NSColor(srgbRed: \(Self.decimal(red)), green: \(Self.decimal(green)), blue: \(Self.decimal(blue)), alpha: \(Self.decimal(alpha)))"
    }

    static func decimal(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded.formatted(.number.precision(.fractionLength(0...3)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
