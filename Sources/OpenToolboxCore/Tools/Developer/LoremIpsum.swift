import Foundation

/// Generates classic placeholder text.
public enum LoremIpsum {
    public enum Unit: String, CaseIterable, Sendable, Identifiable {
        case words, sentences, paragraphs
        public var id: String { rawValue }
    }

    public static let classicOpening = "Lorem ipsum dolor sit amet, consectetur adipiscing elit"

    /// Latin word pool (public-domain vocabulary of the traditional placeholder text).
    static let words: [String] = """
        lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore \
        magna aliqua enim ad minim veniam quis nostrud exercitation ullamco laboris nisi aliquip ex ea commodo \
        consequat duis aute irure in reprehenderit voluptate velit esse cillum fugiat nulla pariatur excepteur sint \
        occaecat cupidatat non proident sunt culpa qui officia deserunt mollit anim id est laborum perspiciatis unde \
        omnis iste natus error voluptatem accusantium doloremque laudantium totam rem aperiam eaque ipsa quae ab \
        illo inventore veritatis quasi architecto beatae vitae dicta explicabo nemo ipsam quia voluptas aspernatur \
        aut odit fugit consequuntur magni dolores eos ratione sequi nesciunt neque porro quisquam dolorem adipisci \
        numquam eius modi tempora incidunt magnam quaerat
        """.split(separator: " ").map(String.init)

    public static func generate(
        _ count: Int,
        unit: Unit,
        startWithClassic: Bool = true,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        let count = max(0, count)
        switch unit {
        case .words:
            var result = (0..<count).map { _ in words.randomElement(using: &generator)! }
            if startWithClassic {
                let opening = classicOpening.replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
                for (index, word) in opening.prefix(count).enumerated() { result[index] = word.lowercased() }
            }
            if let first = result.first { result[0] = first.capitalized }
            return result.joined(separator: " ")
        case .sentences:
            var sentences = (0..<count).map { _ in sentence(using: &generator) }
            if startWithClassic, !sentences.isEmpty { sentences[0] = classicOpening + "." }
            return sentences.joined(separator: " ")
        case .paragraphs:
            var paragraphs = (0..<count).map { _ in
                (0..<Int.random(in: 4...7, using: &generator)).map { _ in sentence(using: &generator) }
                    .joined(separator: " ")
            }
            if startWithClassic, !paragraphs.isEmpty {
                paragraphs[0] = classicOpening + ". " + paragraphs[0]
            }
            return paragraphs.joined(separator: "\n\n")
        }
    }

    public static func generate(_ count: Int, unit: Unit, startWithClassic: Bool = true) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(count, unit: unit, startWithClassic: startWithClassic, using: &generator)
    }

    static func sentence(using generator: inout some RandomNumberGenerator) -> String {
        let length = Int.random(in: 6...14, using: &generator)
        var picked = (0..<length).map { _ in words.randomElement(using: &generator)! }
        if length > 8 {
            let commaIndex = Int.random(in: 3...(length - 4), using: &generator)
            picked[commaIndex] += ","
        }
        return picked.joined(separator: " ").capitalizedFirstLetter + "."
    }
}

extension String {
    var capitalizedFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
