import Foundation

/// Describes the characters and code points in a string.
public enum UnicodeInspector {
    public struct ScalarInfo: Equatable, Sendable, Identifiable {
        public var id: Int
        public var scalar: Unicode.Scalar
        /// `U+1F600`
        public var codePoint: String
        /// Official Unicode name, or a label for unnamed scalars such as controls.
        public var name: String
        public var category: String
        public var utf8: String
        public var utf16: String
        public var isInvisible: Bool
    }

    public struct CharacterInfo: Equatable, Sendable, Identifiable {
        public var id: Int
        public var character: Character
        public var scalars: [ScalarInfo]
    }

    public static func inspect(_ text: String, limit: Int = 2_000) -> [CharacterInfo] {
        var scalarID = 0
        return text.prefix(limit).enumerated().map { index, character in
            let scalars = character.unicodeScalars.map { scalar -> ScalarInfo in
                defer { scalarID += 1 }
                return describe(scalar, id: scalarID)
            }
            return CharacterInfo(id: index, character: character, scalars: scalars)
        }
    }

    public static func describe(_ scalar: Unicode.Scalar, id: Int = 0) -> ScalarInfo {
        let properties = scalar.properties
        let name = properties.name ?? properties.nameAlias ?? fallbackName(scalar)
        let utf8 = Array(String(scalar).utf8).map { String(format: "%02X", $0) }.joined(separator: " ")
        let utf16 = Array(String(scalar).utf16).map { String(format: "%04X", $0) }.joined(separator: " ")
        let category = categoryName(properties.generalCategory)
        let invisible: Bool =
            switch properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator, .unassigned: true
            default: false
            }
        return ScalarInfo(
            id: id, scalar: scalar, codePoint: codePoint(scalar), name: name, category: category, utf8: utf8,
            utf16: utf16, isInvisible: invisible)
    }

    public static func codePoint(_ scalar: Unicode.Scalar) -> String {
        "U+" + String(format: "%04X", scalar.value)
    }

    /// Normalization forms of the whole text.
    public static func normalizations(of text: String) -> [(name: String, value: String)] {
        [
            ("NFC", text.precomposedStringWithCanonicalMapping),
            ("NFD", text.decomposedStringWithCanonicalMapping),
            ("NFKC", text.precomposedStringWithCompatibilityMapping),
            ("NFKD", text.decomposedStringWithCompatibilityMapping),
        ]
    }

    static func fallbackName(_ scalar: Unicode.Scalar) -> String {
        switch scalar.properties.generalCategory {
        case .control: "<control>"
        case .privateUse: "<private use>"
        case .surrogate: "<surrogate>"
        case .unassigned: "<unassigned>"
        default: "<unnamed>"
        }
    }

    /// `Lu · Uppercase letter`: the standard code stays verbatim, the description is localized.
    static func categoryName(_ category: Unicode.GeneralCategory) -> String {
        let (code, description) = categoryParts(category)
        return code.isEmpty ? description : "\(code) · \(description)"
    }

    static func categoryParts(_ category: Unicode.GeneralCategory) -> (code: String, description: String) {
        switch category {
        case .uppercaseLetter: ("Lu", coreLocalized("Uppercase letter"))
        case .lowercaseLetter: ("Ll", coreLocalized("Lowercase letter"))
        case .titlecaseLetter: ("Lt", coreLocalized("Titlecase letter"))
        case .modifierLetter: ("Lm", coreLocalized("Modifier letter"))
        case .otherLetter: ("Lo", coreLocalized("Other letter"))
        case .nonspacingMark: ("Mn", coreLocalized("Nonspacing mark"))
        case .spacingMark: ("Mc", coreLocalized("Spacing mark"))
        case .enclosingMark: ("Me", coreLocalized("Enclosing mark"))
        case .decimalNumber: ("Nd", coreLocalized("Decimal number"))
        case .letterNumber: ("Nl", coreLocalized("Letter number"))
        case .otherNumber: ("No", coreLocalized("Other number"))
        case .connectorPunctuation: ("Pc", coreLocalized("Connector punctuation"))
        case .dashPunctuation: ("Pd", coreLocalized("Dash punctuation"))
        case .openPunctuation: ("Ps", coreLocalized("Open punctuation"))
        case .closePunctuation: ("Pe", coreLocalized("Close punctuation"))
        case .initialPunctuation: ("Pi", coreLocalized("Initial punctuation"))
        case .finalPunctuation: ("Pf", coreLocalized("Final punctuation"))
        case .otherPunctuation: ("Po", coreLocalized("Other punctuation"))
        case .mathSymbol: ("Sm", coreLocalized("Math symbol"))
        case .currencySymbol: ("Sc", coreLocalized("Currency symbol"))
        case .modifierSymbol: ("Sk", coreLocalized("Modifier symbol"))
        case .otherSymbol: ("So", coreLocalized("Other symbol"))
        case .spaceSeparator: ("Zs", coreLocalized("Space separator"))
        case .lineSeparator: ("Zl", coreLocalized("Line separator"))
        case .paragraphSeparator: ("Zp", coreLocalized("Paragraph separator"))
        case .control: ("Cc", coreLocalized("Control"))
        case .format: ("Cf", coreLocalized("Format"))
        case .surrogate: ("Cs", coreLocalized("Surrogate"))
        case .privateUse: ("Co", coreLocalized("Private use"))
        case .unassigned: ("Cn", coreLocalized("Unassigned"))
        @unknown default: ("", coreLocalized("Unknown category"))
        }
    }
}
