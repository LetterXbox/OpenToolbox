import Foundation

/// Converts text between naming and writing cases.
public enum TextCase: String, CaseIterable, Sendable, Identifiable {
    case lower
    case upper
    case title
    case sentence
    case camel
    case pascal
    case snake
    case screamingSnake
    case kebab
    case dot

    public var id: String { rawValue }

    /// Example rendering, used as the label in the UI.
    public var example: String {
        switch self {
        case .lower: "lower case"
        case .upper: "UPPER CASE"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        case .camel: "camelCase"
        case .pascal: "PascalCase"
        case .snake: "snake_case"
        case .screamingSnake: "SCREAMING_SNAKE_CASE"
        case .kebab: "kebab-case"
        case .dot: "dot.case"
        }
    }
}

public enum CaseConverter {
    /// Converts each line separately so multi-line input keeps its shape.
    public static func convert(_ text: String, to textCase: TextCase, locale: Locale? = nil) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { convertLine(String($0), to: textCase, locale: locale) }
            .joined(separator: "\n")
    }

    static func convertLine(_ line: String, to textCase: TextCase, locale: Locale?) -> String {
        switch textCase {
        case .lower: return line.lowercased(with: locale)
        case .upper: return line.uppercased(with: locale)
        case .title: return titleCase(line, locale: locale)
        case .sentence: return sentenceCase(line, locale: locale)
        case .camel, .pascal, .snake, .screamingSnake, .kebab, .dot:
            let parts = words(in: line).map { $0.lowercased(with: locale) }
            switch textCase {
            case .camel:
                return parts.enumerated().map { $0.offset == 0 ? $0.element : $0.element.capitalizedFirstLetter }.joined()
            case .pascal: return parts.map(\.capitalizedFirstLetter).joined()
            case .snake: return parts.joined(separator: "_")
            case .screamingSnake: return parts.joined(separator: "_").uppercased(with: locale)
            case .kebab: return parts.joined(separator: "-")
            default: return parts.joined(separator: ".")
            }
        }
    }

    /// Splits identifiers and prose into words: `parseHTTPResponse_v2` → `parse`, `HTTP`, `Response`, `v2`.
    /// Digits stay attached to the preceding letters.
    public static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if let previous = current.last {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let lowerToUpper = previous.isLowercase && character.isUppercase
                let digitToUpper = previous.isNumber && character.isUppercase
                // "HTTPResponse": split before the last capital of an acronym followed by lowercase.
                let acronymEnd = previous.isUppercase && character.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || digitToUpper || acronymEnd {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    static let minorWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "in", "nor", "of", "on", "or", "so", "the", "to", "up", "yet",
    ]

    static func titleCase(_ line: String, locale: Locale?) -> String {
        var result = ""
        var wordIndex = 0
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let lowered = current.lowercased(with: locale)
            if wordIndex > 0, minorWords.contains(lowered) {
                result += lowered
            } else {
                result += lowered.capitalizedFirstLetter
            }
            wordIndex += 1
            current = ""
        }
        for character in line {
            if character.isWhitespace {
                flush()
                result.append(character)
            } else {
                current.append(character)
            }
        }
        flush()
        return result
    }

    static func sentenceCase(_ line: String, locale: Locale?) -> String {
        var result = ""
        var capitalizeNext = true
        for character in line.lowercased(with: locale) {
            if capitalizeNext, character.isLetter {
                result += character.uppercased()
                capitalizeNext = false
            } else {
                result.append(character)
            }
            if character == "." || character == "!" || character == "?" { capitalizeNext = true }
        }
        return result
    }
}
