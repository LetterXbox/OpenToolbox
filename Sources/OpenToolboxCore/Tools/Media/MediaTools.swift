import AVFoundation
import CoreGraphics
import Foundation

public enum MediaToolError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case noVideo(String)
    case invalidRange
    case tooManyFrames(Int)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): coreLocalized("“\(name)” could not be opened.")
        case .noVideo(let name): coreLocalized("“\(name)” has no video track.")
        case .invalidRange: coreLocalized("The end must come after the start, inside the file's length.")
        case .tooManyFrames(let limit): coreLocalized("That would save more than \(limit) frames. Choose fewer.")
        case .writeFailed(let detail): coreLocalized("The file could not be saved: \(detail)")
        }
    }
}

/// Times written as `90`, `1:30`, `1:02:03.5` or `12.25`.
public enum MediaTime {
    public static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            if index > 0, value >= 60 { return nil }
            if index < parts.count - 1, value.rounded() != value { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// `1:02:03.5`, `2:03.25`, `0:05`
    public static func format(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        let hours = hundredths / 360_000
        let minutes = (hundredths / 6_000) % 60
        let secs = (hundredths / 100) % 60
        let fraction = hundredths % 100
        let tail =
            if fraction == 0 { "" } else if fraction % 10 == 0 { ".\(fraction / 10)" } else { String(format: ".%02d", fraction) }
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) + tail }
        return String(format: "%d:%02d", minutes, secs) + tail
    }
}

public enum FrameSelection: Equatable, Sendable {
    /// One frame every so many seconds, starting at 0.
    case every(Double)
    /// This many frames spread evenly over the video.
    case count(Int)
    /// Frames at these times, in seconds.
    case times([Double])
}

/// Saves still frames from videos with AVFoundation.
public enum FrameExtractor {
    public static let maximumFrames = 2_000

    static func times(for selection: FrameSelection, duration: Double) throws -> [Double] {
        guard duration > 0, duration.isFinite else { return [] }
        let times: [Double]
        switch selection {
        case .every(let interval):
            guard interval > 0, interval.isFinite else { throw MediaToolError.invalidRange }
            let count = Int((duration / interval).rounded(.up))
            guard count <= maximumFrames else { throw MediaToolError.tooManyFrames(maximumFrames) }
            times = (0..<count).map { Double($0) * interval }.filter { $0 < duration }
        case .count(let count):
            guard count > 0 else { throw MediaToolError.invalidRange }
            guard count <= maximumFrames else { throw MediaToolError.tooManyFrames(maximumFrames) }
            times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        case .times(let list):
            guard list.count <= maximumFrames else { throw MediaToolError.tooManyFrames(maximumFrames) }
            times = list.filter { $0 >= 0 && $0 <= duration }
            guard !times.isEmpty else { throw MediaToolError.invalidRange }
        }
        return times
    }

    public static func extract(
        _ url: URL, selection: FrameSelection, format: ImageFormat, longEdge: Int?, output: OutputDirectory,
        tool: ToolID, progress: @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw MediaToolError.noVideo(url.lastPathComponent)
        }
        let duration = try await asset.load(.duration).seconds
        let times = try times(for: selection, duration: duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if let longEdge { generator.maximumSize = CGSize(width: longEdge, height: longEdge) }

        let base = url.deletingPathExtension().lastPathComponent
        let runDate = Date(), calendar = Calendar.current
        var saved: [URL] = []
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            let (image, actual) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            let label = MediaTime.format(actual.seconds).replacingOccurrences(of: ":", with: ".")
            let name = "\(base) \(label).\(format.fileExtension)"
            saved.append(
                try output.writeNewFile(for: tool, preferredName: name, date: runDate, calendar: calendar) {
                    try ImageProcessor.write(image, to: $0, format: format, quality: 0.9)
                })
            progress(Double(index + 1) / Double(times.count))
        }
        return saved
    }
}

/// Frame-accurate audio trimming. WAV, AIFF and CAF stay lossless; other formats become AAC.
public enum AudioTrimmer {
    static let losslessExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf"]

    public static func duration(of url: URL) throws -> Double {
        let file = try open(url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw MediaToolError.unreadable(url.lastPathComponent)
        }
    }

    public static func trim(_ url: URL, start: Double, end: Double, output: OutputDirectory, tool: ToolID) throws -> URL {
        let input = try open(url)
        let format = input.processingFormat
        let rate = format.sampleRate
        guard start.isFinite, end.isFinite, start >= 0 else { throw MediaToolError.invalidRange }
        let first = AVAudioFramePosition((start * rate).rounded())
        let last = min(AVAudioFramePosition((end * rate).rounded()), input.length)
        guard last > first else { throw MediaToolError.invalidRange }

        let ext = url.pathExtension.lowercased()
        let lossless = losslessExtensions.contains(ext)
        let settings: [String: Any] =
            lossless
            ? input.fileFormat.settings
            : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 192_000 * Int(min(format.channelCount, 2)) / 2,
            ]
        let base = url.deletingPathExtension().lastPathComponent
        return try output.writeNewFile(for: tool, preferredName: "\(base) trimmed.\(lossless ? ext : "m4a")") { destination in
            do {
                let writer = try AVAudioFile(
                    forWriting: destination, settings: settings, commonFormat: format.commonFormat,
                    interleaved: format.isInterleaved)
                input.framePosition = first
                let chunk: AVAudioFrameCount = 32_768
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                    throw MediaToolError.writeFailed("buffer")
                }
                var remaining = last - first
                while remaining > 0 {
                    let frames = AVAudioFrameCount(min(Int64(chunk), remaining))
                    try input.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { break }
                    try writer.write(from: buffer)
                    remaining -= AVAudioFramePosition(buffer.frameLength)
                }
            } catch let error as MediaToolError {
                throw error
            } catch {
                throw MediaToolError.writeFailed(error.localizedDescription)
            }
        }
    }
}
