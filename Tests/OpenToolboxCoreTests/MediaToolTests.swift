import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing

@testable import OpenToolboxCore

/// Writes a mono sine tone.
func writeTone(to url: URL, seconds: Double, sampleRate: Double = 44_100) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(frames) {
        samples[index] = Float(sin(2 * Double.pi * 440 * Double(index) / sampleRate)) * 0.4
    }
    let settings: [String: Any] =
        url.pathExtension == "m4a"
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1]
        : format.settings
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
}

/// Writes a short H.264 video whose frames change color over time.
func writeTestVideo(to url: URL, frames: Int, fps: Int32 = 10, size: CGSize = CGSize(width: 160, height: 120))
    async throws
{
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
    writer.add(input)
    #expect(writer.startWriting())
    writer.startSession(atSourceTime: .zero)
    for index in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let bytes = CVPixelBufferGetBytesPerRow(buffer) * Int(size.height)
        let shade = UInt8(index * 255 / max(frames - 1, 1))
        for offset in stride(from: 0, to: bytes, by: 4) {
            base[offset] = shade
            base[offset + 1] = 255 - shade
            base[offset + 2] = 128
            base[offset + 3] = 255
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    #expect(writer.status == .completed)
}

@Suite("Media time")
struct MediaTimeTests {
    @Test func parses() {
        #expect(MediaTime.parse("90") == 90)
        #expect(MediaTime.parse("1:30") == 90)
        #expect(MediaTime.parse("1:02:03.5") == 3723.5)
        #expect(MediaTime.parse(" 12.25 ") == 12.25)
        #expect(MediaTime.parse("1:60") == nil)
        #expect(MediaTime.parse("1.5:00") == nil)
        #expect(MediaTime.parse("-3") == nil)
        #expect(MediaTime.parse("a") == nil)
        #expect(MediaTime.parse("1:2:3:4") == nil)
    }

    @Test func formats() {
        #expect(MediaTime.format(0) == "0:00")
        #expect(MediaTime.format(5) == "0:05")
        #expect(MediaTime.format(123.25) == "2:03.25")
        #expect(MediaTime.format(123.5) == "2:03.5")
        #expect(MediaTime.format(3723) == "1:02:03")
        #expect(MediaTime.parse(MediaTime.format(3723.5)) == 3723.5)
    }
}

@Suite("Extract frames")
struct ExtractFramesTests {
    @Test func plansFrameTimes() throws {
        #expect(try FrameExtractor.times(for: .every(2), duration: 5) == [0, 2, 4])
        #expect(try FrameExtractor.times(for: .count(2), duration: 4) == [1, 3])
        #expect(try FrameExtractor.times(for: .times([1, 9, 3]), duration: 5) == [1, 3])
        #expect(throws: MediaToolError.invalidRange) { try FrameExtractor.times(for: .times([9]), duration: 5) }
        #expect(throws: MediaToolError.invalidRange) { try FrameExtractor.times(for: .every(0), duration: 5) }
        #expect(throws: MediaToolError.tooManyFrames(FrameExtractor.maximumFrames)) {
            try FrameExtractor.times(for: .every(0.001), duration: 5)
        }
        #expect(throws: MediaToolError.tooManyFrames(FrameExtractor.maximumFrames)) {
            try FrameExtractor.times(for: .every(1e-18), duration: 60)
        }
        #expect(throws: MediaToolError.tooManyFrames(FrameExtractor.maximumFrames)) {
            try FrameExtractor.times(for: .every(.leastNonzeroMagnitude), duration: 60)
        }
    }

    @Test func savesFrames() async throws {
        try await withTemporaryDirectory { directory in
            let video = directory.appending(path: "clip.mov")
            try await writeTestVideo(to: video, frames: 30)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let saved = try await FrameExtractor.extract(
                video, selection: .count(3), format: .png, longEdge: 80, output: output, tool: "media.frames")
            #expect(saved.count == 3)
            #expect(Set(saved.map(\.lastPathComponent)).count == 3)
            let properties = ImageProcessor.properties(of: try #require(saved.first))
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == 80)
        }
    }

    @Test func refusesAudioOnlyFiles() async throws {
        try await withTemporaryDirectory { directory in
            let tone = directory.appending(path: "tone.m4a")
            try writeTone(to: tone, seconds: 1)
            await #expect(throws: MediaToolError.noVideo("tone.m4a")) {
                try await FrameExtractor.extract(
                    tone, selection: .count(1), format: .png, longEdge: nil,
                    output: OutputDirectory(baseDirectory: directory.appending(path: "out")), tool: "media.frames")
            }
        }
    }
}

@Suite("Trim audio")
struct TrimAudioTests {
    @Test func wavStaysLosslessAndExact() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "tone.wav")
            try writeTone(to: source, seconds: 3)
            #expect(abs(try AudioTrimmer.duration(of: source) - 3) < 0.001)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            let trimmed = try AudioTrimmer.trim(source, start: 1, end: 2, output: output, tool: "media.trim-audio")
            #expect(trimmed.lastPathComponent == "tone trimmed.wav")
            let file = try AVAudioFile(forReading: trimmed)
            #expect(file.length == 44_100)
            #expect(try AudioTrimmer.duration(of: source) == 3)
        }
    }

    @Test func compressedBecomesAAC() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "tone.m4a")
            try writeTone(to: source, seconds: 3)
            let trimmed = try AudioTrimmer.trim(
                source, start: 0.5, end: 2, output: OutputDirectory(baseDirectory: directory.appending(path: "out")),
                tool: "media.trim-audio")
            #expect(trimmed.pathExtension == "m4a")
            #expect(abs(try AudioTrimmer.duration(of: trimmed) - 1.5) < 0.1)
        }
    }

    @Test func refusesEmptyRanges() async throws {
        try await withTemporaryDirectory { directory in
            let source = directory.appending(path: "tone.wav")
            try writeTone(to: source, seconds: 1)
            let output = OutputDirectory(baseDirectory: directory.appending(path: "out"))
            #expect(throws: MediaToolError.invalidRange) {
                try AudioTrimmer.trim(source, start: 0.8, end: 0.5, output: output, tool: "media.trim-audio")
            }
            #expect(throws: MediaToolError.invalidRange) {
                try AudioTrimmer.trim(source, start: 5, end: 6, output: output, tool: "media.trim-audio")
            }
        }
    }
}

@Suite("Microphone choice")
struct MicrophoneChoiceTests {
    @Test func usesTheChosenMicrophoneWhileItIsConnected() {
        #expect(MicrophoneChoice.selection(chosen: "usb", connected: ["built-in", "usb"]) == "usb")
        #expect(MicrophoneChoice.device(chosen: "usb", connected: ["built-in", "usb"], systemDefault: "built-in") == "usb")
    }

    @Test func fallsBackToTheSystemDefault() {
        #expect(MicrophoneChoice.selection(chosen: "usb", connected: ["built-in"]) == nil)
        #expect(MicrophoneChoice.selection(chosen: nil, connected: ["built-in"]) == nil)
        #expect(MicrophoneChoice.device(chosen: "usb", connected: ["built-in"], systemDefault: "built-in") == "built-in")
        #expect(MicrophoneChoice.device(chosen: nil, connected: ["built-in", "usb"], systemDefault: "usb") == "usb")
        #expect(MicrophoneChoice.device(chosen: nil, connected: ["built-in"], systemDefault: nil) == "built-in")
        #expect(MicrophoneChoice.device(chosen: "usb", connected: [], systemDefault: nil) == nil)
    }
}
