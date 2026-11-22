import Foundation

/// Generates random passwords with `SystemRandomNumberGenerator` (cryptographically secure on Apple platforms).
public enum PasswordGenerator {
    public struct Options: Equatable, Sendable {
        public var length: Int
        public var lowercase: Bool
        public var uppercase: Bool
        public var digits: Bool
        public var symbols: Bool
        /// Leaves out look-alike characters such as `l`, `1`, `I`, `O`, and `0`.
        public var excludeAmbiguous: Bool

        public init(
            length: Int = 20, lowercase: Bool = true, uppercase: Bool = true, digits: Bool = true,
            symbols: Bool = true, excludeAmbiguous: Bool = false
        ) {
            self.length = length
            self.lowercase = lowercase
            self.uppercase = uppercase
            self.digits = digits
            self.symbols = symbols
            self.excludeAmbiguous = excludeAmbiguous
        }
    }

    public enum Strength: Int, Comparable, Sendable {
        case veryWeak, weak, fair, strong, veryStrong

        public static func < (lhs: Strength, rhs: Strength) -> Bool { lhs.rawValue < rhs.rawValue }

        public var localizedName: String {
            switch self {
            case .veryWeak: coreLocalized("Very weak")
            case .weak: coreLocalized("Weak")
            case .fair: coreLocalized("Fair")
            case .strong: coreLocalized("Strong")
            case .veryStrong: coreLocalized("Very strong")
            }
        }

        public init(entropyBits: Double) {
            switch entropyBits {
            case ..<28: self = .veryWeak
            case ..<36: self = .weak
            case ..<60: self = .fair
            case ..<100: self = .strong
            default: self = .veryStrong
            }
        }
    }

    static let ambiguous: Set<Character> = ["l", "1", "I", "O", "0", "o", "|", "`", "'", "\""]
    static let lowercaseSet = Array("abcdefghijklmnopqrstuvwxyz")
    static let uppercaseSet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digitSet = Array("0123456789")
    static let symbolSet = Array("!#$%&()*+,-./:;<=>?@[]^_{|}~")

    /// Character groups enabled by `options`, with ambiguous characters removed if requested.
    static func groups(for options: Options) -> [[Character]] {
        var groups: [[Character]] = []
        if options.lowercase { groups.append(lowercaseSet) }
        if options.uppercase { groups.append(uppercaseSet) }
        if options.digits { groups.append(digitSet) }
        if options.symbols { groups.append(symbolSet) }
        if options.excludeAmbiguous {
            groups = groups.map { $0.filter { !ambiguous.contains($0) } }
        }
        return groups.filter { !$0.isEmpty }
    }

    /// Generates a password containing at least one character from every enabled group.
    /// Returns an empty string when no group is enabled or the length is 0.
    public static func generate(_ options: Options, using generator: inout some RandomNumberGenerator) -> String {
        let groups = groups(for: options)
        let length = max(0, options.length)
        guard !groups.isEmpty, length > 0 else { return "" }
        let pool = groups.flatMap { $0 }
        var characters: [Character] = []
        characters.reserveCapacity(length)
        // One from each group first (when the length allows), then fill from the full pool.
        for group in groups.prefix(length) {
            characters.append(group.randomElement(using: &generator)!)
        }
        while characters.count < length {
            characters.append(pool.randomElement(using: &generator)!)
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }

    public static func generate(_ options: Options) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(options, using: &generator)
    }

    /// Entropy of a password generated with `options`, in bits.
    public static func entropyBits(for options: Options) -> Double {
        let poolSize = groups(for: options).reduce(0) { $0 + $1.count }
        guard poolSize > 1 else { return 0 }
        return Double(max(0, options.length)) * log2(Double(poolSize))
    }
}
