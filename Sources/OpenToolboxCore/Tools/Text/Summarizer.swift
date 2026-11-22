import Foundation
import FoundationModels

public enum SummaryStyle: String, CaseIterable, Sendable, Identifiable {
    case paragraph
    case bullets
    case oneLine

    public var id: String { rawValue }

    var instruction: String {
        switch self {
        case .paragraph: "Write one short paragraph."
        case .bullets: "Write three to seven short bullet points, each starting with \"- \"."
        case .oneLine: "Write a single sentence."
        }
    }
}

public enum SummarizerAvailability: Equatable, Sendable {
    case available
    case needsNewerMacOS
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    case unavailable

    public var message: String? {
        switch self {
        case .available: nil
        case .needsNewerMacOS: coreLocalized("Summarize needs macOS 26 or later.")
        case .deviceNotEligible: coreLocalized("Summarize needs a Mac that supports Apple Intelligence.")
        case .appleIntelligenceOff:
            coreLocalized("Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri to summarize.")
        case .modelNotReady: coreLocalized("Apple Intelligence is still getting ready. Try again later.")
        case .unavailable: coreLocalized("Apple Intelligence isn't available right now.")
        }
    }
}

public enum SummarizerError: Error, Equatable, LocalizedError {
    case emptyText
    case tooLong
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText: coreLocalized("Enter or drop some text to summarize.")
        case .tooLong: coreLocalized("This text is too long to summarize. Try a shorter part of it.")
        case .unavailable(let message): message
        case .failed(let detail): coreLocalized("The summary couldn't be written: \(detail)")
        }
    }
}

/// Summaries from Apple's on-device language model. Text never leaves the Mac.
public enum Summarizer {
    static let chunkLimit = 2_400

    public static var availability: SummarizerAvailability {
        guard #available(macOS 26, *) else { return .needsNewerMacOS }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unavailable
        }
    }

    public static func summarize(_ text: String, style: SummaryStyle) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummarizerError.emptyText }
        let state = availability
        guard state == .available, #available(macOS 26, *) else {
            throw SummarizerError.unavailable(state.message ?? "")
        }
        do {
            var pieces = DocumentText.chunks(trimmed, limit: chunkLimit)
            while pieces.count > 1 {
                let before = pieces.reduce(0) { $0 + $1.count }
                var notes: [String] = []
                for piece in pieces {
                    try Task.checkCancellation()
                    notes.append(try await respond(to: piece, instruction: "Write the key points in a few sentences."))
                }
                pieces = DocumentText.chunks(notes.joined(separator: "\n\n"), limit: chunkLimit)
                guard pieces.reduce(0, { $0 + $1.count }) < before else { throw SummarizerError.tooLong }
            }
            try Task.checkCancellation()
            return try await respond(to: pieces.first ?? trimmed, instruction: style.instruction)
        } catch let error as CancellationError {
            throw error
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.failed(error.localizedDescription)
        }
    }

    @available(macOS 26, *)
    static func respond(to text: String, instruction: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: """
                You summarize the text the user gives you. Keep its language. Keep facts, names and numbers \
                exactly as written and add nothing that isn't in the text. \(instruction)
                """)
        let response = try await session.respond(to: text)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
