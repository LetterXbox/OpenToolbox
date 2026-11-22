import AVFoundation
import AppKit
import Foundation
import PDFKit
import Testing

@testable import OpenToolboxCore

@Suite("Document text")
struct DocumentTextTests {
    @Test func chunksRespectTheLimit() {
        let paragraph = String(repeating: "Alpha beta gamma. ", count: 30)
        let text = [paragraph, "Short one.", paragraph].joined(separator: "\n\n")
        let chunks = DocumentText.chunks(text, limit: 200)
        #expect(chunks.allSatisfy { $0.count <= 200 })
        #expect(chunks.joined(separator: " ").contains("Short one."))
        let words = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace).filter { $0 == "gamma." }
        #expect(words.count == 60)
    }

    @Test func smallTextIsOneChunk() {
        #expect(DocumentText.chunks("One.\n\nTwo.", limit: 100) == ["One.\n\nTwo."])
        #expect(DocumentText.chunks("   ", limit: 100).isEmpty)
    }

    @Test func longWordsAreSplit() {
        let chunks = DocumentText.chunks(String(repeating: "x", count: 25), limit: 10)
        #expect(chunks.map(\.count) == [10, 10, 5])
    }

    @Test func readsTextRTFAndPDF() async throws {
        try await withTemporaryDirectory { directory in
            let text = directory.appending(path: "note.txt")
            try Data("Hello there\n".utf8).write(to: text)
            #expect(try DocumentText.read(text) == "Hello there")

            let rtf = directory.appending(path: "note.rtf")
            let attributed = NSAttributedString(string: "Rich words")
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: rtf)
            #expect(try DocumentText.read(rtf) == "Rich words")

            let html = directory.appending(path: "page.html")
            try Data(#"<p>Hi</p><img src="https://example.com/pixel.png">"#.utf8).write(to: html)
            #expect(throws: DocumentTextError.unreadable("page.html")) { try DocumentText.read(html) }
            #expect(!DocumentText.readableTypes.contains(.html))

            let empty = directory.appending(path: "empty.txt")
            try Data("  \n".utf8).write(to: empty)
            #expect(throws: DocumentTextError.empty("empty.txt")) { try DocumentText.read(empty) }
        }
    }
}

@Suite("Transcripts")
struct TranscriptTests {
    let segments = [
        TranscriptSegment(start: 0, end: 1.5, text: "Hello there."),
        TranscriptSegment(start: 3661.25, end: 3662.5, text: "Later on"),
    ]

    @Test func rendersSRT() {
        #expect(
            Transcript.render(segments, as: .srt)
                == "1\n00:00:00,000 --> 00:00:01,500\nHello there.\n\n2\n01:01:01,250 --> 01:01:02,500\nLater on\n")
    }

    @Test func rendersVTTAndText() {
        #expect(
            Transcript.render(segments, as: .vtt)
                == "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\nHello there.\n\n01:01:01.250 --> 01:01:02.500\nLater on\n")
        #expect(Transcript.render(segments, as: .text) == "Hello there.\nLater on")
        #expect(TranscriptFormat.text.fileExtension == "txt")
        #expect(TranscriptFormat.srt.fileExtension == "srt")
    }

    @Test func groupsWordsIntoLines() {
        let words = ["One", "two", "three.", "Four", "five", "six", "seven"].enumerated().map { index, word in
            TranscriptSegment(start: Double(index), end: Double(index) + 0.9, text: word)
        }
        let lines = Transcript.lines(from: words, maximumDuration: 2.5)
        #expect(lines.map(\.text) == ["One two three.", "Four five six", "seven"])
        #expect(lines[0].start == 0)
        #expect(lines[0].end == 2.9)
    }
}

@Suite("Summarizer")
struct SummarizerTests {
    @Test func unavailableStatesExplainThemselves() {
        let states: [SummarizerAvailability] = [
            .needsNewerMacOS, .deviceNotEligible, .appleIntelligenceOff, .modelNotReady, .unavailable,
        ]
        #expect(states.allSatisfy { $0.message?.isEmpty == false })
        #expect(SummarizerAvailability.available.message == nil)
    }

    @Test func refusesEmptyText() async {
        await #expect(throws: SummarizerError.emptyText) { try await Summarizer.summarize("  ", style: .paragraph) }
    }
}

@Suite("Text to speech")
struct SpeechSynthesisTests {
    @Test func refusesEmptyText() async throws {
        try await withTemporaryDirectory { directory in
            await #expect(throws: SpeechSynthesisError.emptyText) {
                try await SpeechSynthesis.export(" ", voice: nil, rate: 0.5, to: directory.appending(path: "a.m4a"))
            }
        }
    }

    @Test(.enabled(if: !AVSpeechSynthesisVoice.speechVoices().isEmpty))
    func savesAudio() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appending(path: "hello.m4a")
            try await SpeechSynthesis.export(
                "Hello from OpenToolbox.", voice: SpeechSynthesis.defaultVoiceID(), rate: 0.5, to: url)
            let file = try AVAudioFile(forReading: url)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            #expect(seconds > 0.3)
            #expect(seconds < 20)
        }
    }
}
