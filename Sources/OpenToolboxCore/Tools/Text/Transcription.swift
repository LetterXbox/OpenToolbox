import AVFoundation
import Foundation
import Speech

public enum TranscriptionError: Error, Equatable, LocalizedError {
    case notAuthorized
    case unsupportedLanguage(String)
    case onDeviceUnavailable(String)
    case noAudio(String)
    case nothingRecognized
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            coreLocalized(
                "Allow OpenToolbox in System Settings → Privacy & Security → Speech Recognition to transcribe.")
        case .unsupportedLanguage(let language): coreLocalized("Transcription doesn't support \(language).")
        case .onDeviceUnavailable(let language):
            coreLocalized("On-device transcription isn't available for \(language) on this Mac.")
        case .noAudio(let name): coreLocalized("“\(name)” has no audio track.")
        case .nothingRecognized: coreLocalized("No speech was recognized.")
        case .failed(let detail): coreLocalized("Transcription failed: \(detail)")
        }
    }
}

public struct TranscriptSegment: Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum TranscriptFormat: String, CaseIterable, Sendable, Identifiable {
    case text, srt, vtt

    public var id: String { rawValue }
    public var fileExtension: String { rawValue == "text" ? "txt" : rawValue }
}

public enum Transcript {
    public static func render(_ segments: [TranscriptSegment], as format: TranscriptFormat) -> String {
        switch format {
        case .text:
            return segments.map(\.text).joined(separator: "\n")
        case .srt:
            return segments.enumerated().map { index, segment in
                "\(index + 1)\n\(timestamp(segment.start, separator: ",")) --> \(timestamp(segment.end, separator: ","))\n\(segment.text)\n"
            }.joined(separator: "\n")
        case .vtt:
            return "WEBVTT\n\n"
                + segments.map { segment in
                    "\(timestamp(segment.start, separator: ".")) --> \(timestamp(segment.end, separator: "."))\n\(segment.text)\n"
                }.joined(separator: "\n")
        }
    }

    /// `01:02:03,456`
    static func timestamp(_ seconds: TimeInterval, separator: String) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let secs = (milliseconds / 1000) % 60
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, separator, milliseconds % 1000)
    }

    /// Groups timed words into caption lines that end at sentence punctuation, after
    /// `maximumDuration` seconds, or at `maximumCharacters`.
    public static func lines(
        from words: [TranscriptSegment], maximumDuration: TimeInterval = 6, maximumCharacters: Int = 84
    ) -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        var current: TranscriptSegment?
        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var line = current {
                line.text += " " + text
                line.end = word.end
                current = line
            } else {
                current = TranscriptSegment(start: word.start, end: word.end, text: text)
            }
            if let line = current,
                ".?!。？！".contains(where: { text.hasSuffix(String($0)) })
                    || line.end - line.start >= maximumDuration || line.text.count >= maximumCharacters
            {
                result.append(line)
                current = nil
            }
        }
        if let current { result.append(current) }
        return result
    }
}

/// On-device speech recognition for audio and video files.
public enum Transcriber {
    /// Languages the recognizer that will run can transcribe on this Mac.
    public static func supportedLocales() async -> [Locale] {
        let locales: [Locale]
        if #available(macOS 26, *) {
            locales = await SpeechTranscriber.supportedLocales
        } else {
            locales = SFSpeechRecognizer.supportedLocales().filter {
                SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
            }
        }
        return locales.sorted { $0.identifier < $1.identifier }
    }

    @MainActor
    public static func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Transcribes `url` without sending audio anywhere. On macOS 26 and later this uses the
    /// newer speech model, which macOS may download once for the language.
    public static func transcribe(_ url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let audio = try await audioFile(for: url)
        defer { if audio.isTemporary { try? FileManager.default.removeItem(at: audio.url.deletingLastPathComponent()) } }
        if #available(macOS 26, *) {
            return try await ModernTranscriber.transcribe(audio.url, locale: locale)
        }
        return try await LegacyTranscriber.transcribe(audio.url, locale: locale)
    }

    static func audioFile(for url: URL) async throws -> (url: URL, isTemporary: Bool) {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw TranscriptionError.noAudio(url.lastPathComponent) }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        if videoTracks.isEmpty { return (url, false) }
        let folder = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL.temporaryDirectory, create: true)
        let output = folder.appending(path: "audio.m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.noAudio(url.lastPathComponent)
        }
        do {
            try await session.export(to: output, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw TranscriptionError.failed(error.localizedDescription)
        }
        return (output, true)
    }
}

enum LegacyTranscriber {
    static func transcribe(_ url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw TranscriptionError.unsupportedLanguage(language)
        }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriptionError.onDeviceUnavailable(language) }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let box = RecognitionBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[TranscriptSegment], Error>) in
                box.start(recognizer: recognizer, request: request, continuation: continuation)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

final class RecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var isCancelled = false

    func start(
        recognizer: SFSpeechRecognizer, request: SFSpeechURLRecognitionRequest,
        continuation: CheckedContinuation<[TranscriptSegment], Error>
    ) {
        let cancelled = lock.withLock {
            self.continuation = continuation
            return isCancelled
        }
        if cancelled {
            resume(.failure(CancellationError()))
            return
        }
        let task = recognizer.recognitionTask(with: request) { [self] result, error in
            if let error {
                resume(.failure(TranscriptionError.failed(error.localizedDescription)))
            } else if let result, result.isFinal {
                let words = result.bestTranscription.segments.map {
                    TranscriptSegment(start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
                }
                let lines = Transcript.lines(from: words)
                resume(lines.isEmpty ? .failure(TranscriptionError.nothingRecognized) : .success(lines))
            }
        }
        lock.withLock { self.task = task }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
        resume(.failure(CancellationError()))
    }

    private func resume(_ result: Result<[TranscriptSegment], Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

@available(macOS 26, *)
enum ModernTranscriber {
    static func transcribe(_ url: URL, locale: Locale) async throws -> [TranscriptSegment] {
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLanguage(language)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(
                    TranscriptSegment(
                        start: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
            return segments
        }
        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }
        let segments = try await collector.value
        guard !segments.isEmpty else { throw TranscriptionError.nothingRecognized }
        return segments
    }
}
