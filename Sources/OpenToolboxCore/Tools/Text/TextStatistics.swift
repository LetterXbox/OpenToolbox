import Foundation

/// Word, character, sentence, and line counts for the Word Counter.
public struct TextStatistics: Equatable, Sendable {
    public var characters: Int
    public var charactersExcludingWhitespace: Int
    public var words: Int
    public var sentences: Int
    public var lines: Int
    public var paragraphs: Int
    public var utf8Bytes: Int

    /// Average silent reading speed used for the estimate.
    public static let readingWordsPerMinute = 238.0
    public static let speakingWordsPerMinute = 150.0

    public var readingTime: TimeInterval { Double(words) / Self.readingWordsPerMinute * 60 }
    public var speakingTime: TimeInterval { Double(words) / Self.speakingWordsPerMinute * 60 }

    public init(_ text: String) {
        characters = text.count
        charactersExcludingWhitespace = text.filter { !$0.isWhitespace }.count
        utf8Bytes = text.utf8.count

        var words = 0
        var sentences = 0
        let range = text.startIndex..<text.endIndex
        text.enumerateSubstrings(in: range, options: [.byWords, .substringNotRequired]) { _, _, _, _ in words += 1 }
        text.enumerateSubstrings(in: range, options: .bySentences) { substring, _, _, _ in
            if let substring, substring.contains(where: { $0.isLetter || $0.isNumber }) { sentences += 1 }
        }
        self.words = words
        self.sentences = sentences

        if text.isEmpty {
            lines = 0
        } else {
            lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        }
        paragraphs = text.components(separatedBy: .newlines)
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .count
    }
}
