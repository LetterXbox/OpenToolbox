import AVFoundation
import Foundation

public enum SpeechSynthesisError: Error, Equatable, LocalizedError {
    case emptyText
    case noAudio
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText: coreLocalized("Enter some text to read.")
        case .noAudio: coreLocalized("The voice produced no audio.")
        case .writeFailed(let detail): coreLocalized("The audio file could not be saved: \(detail)")
        }
    }
}

public struct SpeechVoice: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let language: String
    public let isEnhanced: Bool

    public var languageName: String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }
}

/// Text to speech with the voices installed on this Mac, saved as AAC audio.
public enum SpeechSynthesis {
    public static func voices() -> [SpeechVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .map {
                SpeechVoice(
                    id: $0.identifier, name: $0.name, language: $0.language, isEnhanced: $0.quality != .default)
            }
            .sorted { ($0.languageName, $0.name) < ($1.languageName, $1.name) }
    }

    public static func defaultVoiceID() -> String? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
    }

    public static func utterance(_ text: String, voice: String?, rate: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if let voice, let match = AVSpeechSynthesisVoice(identifier: voice) { utterance.voice = match }
        utterance.rate = min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        return utterance
    }

    /// Writes spoken `text` to an `.m4a` file at `url`.
    public static func export(_ text: String, voice: String?, rate: Float, to url: URL) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechSynthesisError.emptyText }
        let writer = SpeechFileWriter(url: url)
        try await writer.run(utterance(text, voice: voice, rate: rate))
    }
}

/// Collects the synthesizer's buffers into a file. AVSpeechSynthesizer calls back on its
/// own queue, so all state is guarded by a lock.
final class SpeechFileWriter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private let synthesizer = AVSpeechSynthesizer()
    private var file: AVAudioFile?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var isFinished = false

    init(url: URL) {
        self.url = url
        super.init()
        synthesizer.delegate = self
    }

    func run(_ utterance: AVSpeechUtterance) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                synthesizer.write(utterance) { [self] buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        finish()
                    } else {
                        append(pcm)
                    }
                }
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
            finish(error: CancellationError())
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isFinished, failure == nil else { return }
            do {
                if file == nil {
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: buffer.format.sampleRate,
                        AVNumberOfChannelsKey: buffer.format.channelCount,
                    ]
                    file = try AVAudioFile(
                        forWriting: url, settings: settings, commonFormat: buffer.format.commonFormat,
                        interleaved: buffer.format.isInterleaved)
                }
                try file?.write(from: buffer)
            } catch {
                failure = SpeechSynthesisError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func finish(error: Error? = nil) {
        let (continuation, result): (CheckedContinuation<Void, Error>?, Result<Void, Error>) = lock.withLock {
            guard !isFinished else { return (nil, .success(())) }
            isFinished = true
            let pending = self.continuation
            self.continuation = nil
            let wroteAudio = file != nil
            file = nil
            if let error = error ?? failure { return (pending, .failure(error)) }
            return (pending, wroteAudio ? .success(()) : .failure(SpeechSynthesisError.noAudio))
        }
        continuation?.resume(with: result)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(error: CancellationError())
    }
}
