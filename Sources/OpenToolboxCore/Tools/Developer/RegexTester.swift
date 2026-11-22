import Foundation

/// Evaluates ICU regular expressions (`NSRegularExpression`) for the Regex Tester.
public enum RegexTester {
    public struct Options: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let caseInsensitive = Options(rawValue: 1 << 0)
        /// `^` and `$` match at line breaks.
        public static let multiline = Options(rawValue: 1 << 1)
        /// `.` also matches line breaks.
        public static let dotMatchesNewlines = Options(rawValue: 1 << 2)
        /// Ignore whitespace and `#` comments in the pattern.
        public static let extended = Options(rawValue: 1 << 3)

        var foundation: NSRegularExpression.Options {
            var result: NSRegularExpression.Options = []
            if contains(.caseInsensitive) { result.insert(.caseInsensitive) }
            if contains(.multiline) { result.insert(.anchorsMatchLines) }
            if contains(.dotMatchesNewlines) { result.insert(.dotMatchesLineSeparators) }
            if contains(.extended) { result.insert(.allowCommentsAndWhitespace) }
            return result
        }
    }

    public struct Group: Equatable, Sendable {
        public var index: Int
        public var name: String?
        /// `nil` when the group did not participate in the match.
        public var value: String?
        public var range: Range<String.Index>?
    }

    public struct Match: Equatable, Sendable, Identifiable {
        public var id: Int { index }
        public var index: Int
        public var value: String
        public var range: Range<String.Index>
        public var groups: [Group]
    }

    public struct InvalidPattern: Error, Equatable, LocalizedError {
        public var message: String
        public var errorDescription: String? { coreLocalized("Invalid pattern: \(message)") }
    }

    /// Upper bound on reported matches so a pathological pattern cannot flood the UI.
    public static let maximumMatches = 10_000

    public static func compile(_ pattern: String, options: Options) throws -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options.foundation)
        } catch {
            let message = (error as NSError).userInfo["NSInvalidValue"] as? String ?? error.localizedDescription
            throw InvalidPattern(message: message)
        }
    }

    public struct SearchResult: Equatable, Sendable {
        public var matches: [Match]
        /// `false` when the search stopped early: cancelled, out of time, or at ``maximumMatches``.
        public var isComplete: Bool
    }

    public static func matches(_ pattern: String, in text: String, options: Options = []) throws -> [Match] {
        try search(pattern, in: text, options: options, shouldStop: { false }).matches
    }

    /// Finds matches, polling `shouldStop` while ICU works (including inside one slow,
    /// backtracking match attempt) so a runaway pattern can be abandoned.
    public static func search(
        _ pattern: String, in text: String, options: Options = [], shouldStop: () -> Bool
    ) throws -> SearchResult {
        let regex = try compile(pattern, options: options)
        let names = groupNames(in: pattern)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []
        var isComplete = true
        regex.enumerateMatches(in: text, options: .reportProgress, range: nsRange) { result, _, stop in
            if shouldStop() {
                isComplete = false
                stop.pointee = true
                return
            }
            guard let result, let range = Range(result.range, in: text) else { return }
            var groups: [Group] = []
            if result.numberOfRanges > 1 {
                for groupIndex in 1..<result.numberOfRanges {
                    let groupRange = Range(result.range(at: groupIndex), in: text)
                    groups.append(
                        Group(
                            index: groupIndex,
                            name: names[groupIndex],
                            value: groupRange.map { String(text[$0]) },
                            range: groupRange))
                }
            }
            matches.append(Match(index: matches.count, value: String(text[range]), range: range, groups: groups))
            if matches.count >= maximumMatches {
                isComplete = false
                stop.pointee = true
            }
        }
        return SearchResult(matches: matches, isComplete: isComplete)
    }

    /// Replaces matches using a template (`$1`, `${name}`, `\$` for a literal dollar sign).
    public static func replace(_ pattern: String, in text: String, with template: String, options: Options = []) throws
        -> String
    {
        // Never stops early, so the result is always present.
        try replace(pattern, in: text, with: template, options: options, shouldStop: { false }) ?? text
    }

    /// Like ``replace(_:in:with:options:)``, but returns `nil` once `shouldStop` returns `true`.
    public static func replace(
        _ pattern: String, in text: String, with template: String, options: Options = [], shouldStop: () -> Bool
    ) throws -> String? {
        let regex = try compile(pattern, options: options)
        let names = groupNames(in: pattern)
        // NSRegularExpression templates do not understand ${name}; map names to numbers first.
        var resolved = template
        for (index, name) in names {
            resolved = resolved.replacingOccurrences(of: "${\(name)}", with: "$\(index)")
        }
        let source = text as NSString
        var output = ""
        var cursor = 0
        var stopped = false
        regex.enumerateMatches(in: text, options: .reportProgress, range: NSRange(location: 0, length: source.length)) {
            result, _, stop in
            if shouldStop() {
                stopped = true
                stop.pointee = true
                return
            }
            guard let result else { return }
            output += source.substring(with: NSRange(location: cursor, length: result.range.location - cursor))
            output += regex.replacementString(for: result, in: text, offset: 0, template: resolved)
            cursor = NSMaxRange(result.range)
        }
        if stopped { return nil }
        output += source.substring(from: cursor)
        return output
    }

    /// Maps capture-group numbers to names for `(?<name>…)` groups.
    static func groupNames(in pattern: String) -> [Int: String] {
        var names: [Int: String] = [:]
        var groupIndex = 0
        var characters = Array(pattern)[...]
        var inClass = false
        while let character = characters.popFirst() {
            switch character {
            case "\\":
                _ = characters.popFirst()
            case "[" where !inClass:
                inClass = true
            case "]" where inClass:
                inClass = false
            case "(" where !inClass:
                if characters.first == "?" {
                    let rest = characters.dropFirst()
                    // Named group (?<name>…) but not look-behind (?<= / (?<!.
                    if rest.first == "<", let after = rest.dropFirst().first, after != "=", after != "!" {
                        groupIndex += 1
                        let name = rest.dropFirst().prefix { $0 != ">" }
                        names[groupIndex] = String(name)
                    }
                } else {
                    groupIndex += 1
                }
            default:
                break
            }
        }
        return names
    }
}
