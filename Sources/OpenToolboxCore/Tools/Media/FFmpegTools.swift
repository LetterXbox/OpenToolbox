import Foundation

public enum FFmpegToolError: Error, Equatable, LocalizedError {
    case invalidParameter(String)
    case notEnoughInputs
    case missingAudioTrack(String)
    case missingVideoTrack(String)
    case invalidProbeOutput

    public var errorDescription: String? {
        switch self {
        case .invalidParameter(let detail): detail
        case .notEnoughInputs: coreLocalized("Choose at least two videos to merge.")
        case .missingAudioTrack(let name): coreLocalized("“\(name)” does not contain an audio track.")
        case .missingVideoTrack(let name): coreLocalized("“\(name)” does not contain a video track.")
        case .invalidProbeOutput: coreLocalized("FFprobe returned unreadable media metadata.")
        }
    }
}

public struct MediaStreamInfo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let codecType: String
    public let codecName: String
    public let width: Int?
    public let height: Int?
    public let frameRate: String?
    public let sampleRate: String?
    public let channels: Int?
    public let bitRate: Int64?
    public let language: String?
}

public struct MediaProbeInfo: Equatable, Sendable {
    public let formatName: String
    public let formatLongName: String
    public let durationSeconds: Double?
    public let sizeBytes: Int64?
    public let bitRate: Int64?
    public let streams: [MediaStreamInfo]
    public let rawJSON: String

    public var hasVideo: Bool { streams.contains { $0.codecType == "video" } }
    public var hasAudio: Bool { streams.contains { $0.codecType == "audio" } }
    public var primaryVideo: MediaStreamInfo? { streams.first { $0.codecType == "video" } }
    public var primaryAudio: MediaStreamInfo? { streams.first { $0.codecType == "audio" } }
}

public enum VideoCompressionQuality: String, CaseIterable, Sendable, Identifiable {
    case high
    case balanced
    case small

    public var id: String { rawValue }

    public var crfH264: Int {
        switch self {
        case .high: 22
        case .balanced: 27
        case .small: 32
        }
    }

    public var crfHEVC: Int {
        switch self {
        case .high: 26
        case .balanced: 30
        case .small: 35
        }
    }
}

public enum VideoCodecChoice: String, CaseIterable, Sendable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }
}

public enum VideoContainerFormat: String, CaseIterable, Sendable, Identifiable {
    case mp4
    case mov
    case mkv
    case webm
    case avi
    case m4v

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
}

public enum VideoResolutionPreset: String, CaseIterable, Sendable, Identifiable {
    case original
    case p2160
    case p1080
    case p720
    case p480
    case p360

    public var id: String { rawValue }

    public var maxHeight: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        case .p360: 360
        }
    }
}

public enum VideoCropAspect: String, CaseIterable, Sendable, Identifiable {
    case none
    case ratio16x9
    case ratio9x16
    case ratio1x1
    case ratio4x3
    case custom

    public var id: String { rawValue }
}

public enum VideoRotation: Int, CaseIterable, Sendable, Identifiable {
    case none = 0
    case clockwise90 = 90
    case rotate180 = 180
    case clockwise270 = 270

    public var id: Int { rawValue }
}

public enum AudioOutputFormat: String, CaseIterable, Sendable, Identifiable {
    case m4a
    case mp3
    case wav
    case flac
    case ogg
    case opus
    case aiff

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var isLossy: Bool {
        switch self {
        case .m4a, .mp3, .ogg, .opus: true
        case .wav, .flac, .aiff: false
        }
    }
}

public struct AudioCleanupOptions: Equatable, Sendable {
    public var reduceNoise: Bool
    public var removeRumble: Bool
    public var tameHarshHighs: Bool
    public var normalizeLoudness: Bool

    public init(
        reduceNoise: Bool = true,
        removeRumble: Bool = true,
        tameHarshHighs: Bool = false,
        normalizeLoudness: Bool = true
    ) {
        self.reduceNoise = reduceNoise
        self.removeRumble = removeRumble
        self.tameHarshHighs = tameHarshHighs
        self.normalizeLoudness = normalizeLoudness
    }

    public var isEmpty: Bool {
        !reduceNoise && !removeRumble && !tameHarshHighs && !normalizeLoudness
    }
}

/// Argument builders and async runners for all FFmpeg / FFprobe media tools.
public enum FFmpegTools {
    public typealias Runner = @Sendable (URL, [String], (@Sendable (String) -> Void)?) async throws -> EngineProcessResult

    public static let defaultRunner: Runner = { exe, args, onStdoutLine in
        try await EngineProcess.run(exe, arguments: args, onStdoutLine: onStdoutLine)
    }

    public static func probeArguments(input: URL) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            input.path,
        ]
    }

    public static func probe(
        _ source: URL,
        ffprobe: URL,
        runner: Runner = defaultRunner
    ) async throws -> MediaProbeInfo {
        let result = try await runner(ffprobe, probeArguments(input: source), nil)
        guard result.exitCode == 0 else {
            throw EngineProcessError.failed(
                command: ffprobe.lastPathComponent,
                exitCode: result.exitCode,
                detail: result.stderrString
            )
        }
        return try parseProbeJSON(result.stdout)
    }

    public static func parseProbeJSON(_ data: Data) throws -> MediaProbeInfo {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FFmpegToolError.invalidProbeOutput
        }
        let format = root["format"] as? [String: Any] ?? [:]
        let formatName = format["format_name"] as? String ?? "unknown"
        let formatLongName = format["format_long_name"] as? String ?? formatName
        let duration = (format["duration"] as? String).flatMap(Double.init)
        let size = (format["size"] as? String).flatMap(Int64.init)
        let bitRate = (format["bit_rate"] as? String).flatMap(Int64.init)

        let rawStreams = root["streams"] as? [[String: Any]] ?? []
        let streams: [MediaStreamInfo] = rawStreams.enumerated().map { offset, item in
            let tags = item["tags"] as? [String: Any] ?? [:]
            return MediaStreamInfo(
                id: item["index"] as? Int ?? offset,
                codecType: item["codec_type"] as? String ?? "unknown",
                codecName: item["codec_name"] as? String ?? "unknown",
                width: item["width"] as? Int,
                height: item["height"] as? Int,
                frameRate: formattedFrameRate(item["avg_frame_rate"] as? String ?? item["r_frame_rate"] as? String),
                sampleRate: item["sample_rate"] as? String,
                channels: item["channels"] as? Int,
                bitRate: (item["bit_rate"] as? String).flatMap(Int64.init),
                language: tags["language"] as? String
            )
        }
        let pretty: String
        if let prettyData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            pretty = String(decoding: prettyData, as: UTF8.self)
        } else {
            pretty = String(decoding: data, as: UTF8.self)
        }
        return MediaProbeInfo(
            formatName: formatName,
            formatLongName: formatLongName,
            durationSeconds: duration,
            sizeBytes: size,
            bitRate: bitRate,
            streams: streams,
            rawJSON: pretty
        )
    }

    private static func formattedFrameRate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "0/0" else { return nil }
        let parts = raw.split(separator: "/")
        if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
            let fps = num / den
            if fps.rounded() == fps { return "\(Int(fps)) fps" }
            return String(format: "%.2f fps", fps)
        }
        return raw
    }

    /// Parses `out_time_us=<microseconds>` or `progress=end` from `ffmpeg -progress pipe:1`.
    public static func parseProgressLine(_ line: String, durationSeconds: Double?) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "progress=end" { return 1 }
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        if trimmed.hasPrefix("out_time_us="),
           let microseconds = Double(trimmed.dropFirst("out_time_us=".count)),
           microseconds >= 0
        {
            return min(1, max(0, (microseconds / 1_000_000) / durationSeconds))
        }
        return nil
    }

    /// Builds chained `atempo` filters because each FFmpeg `atempo` stage supports `0.5...2.0`.
    public static func atempoFilterChain(speed: Double) throws -> String {
        guard speed.isFinite, speed >= 0.25, speed <= 4.0 else {
            throw FFmpegToolError.invalidParameter(coreLocalized("Speed must be between 0.25x and 4x."))
        }
        var remaining = speed
        var stages: [Double] = []
        while remaining > 2.0 {
            stages.append(2.0)
            remaining /= 2.0
        }
        while remaining < 0.5 {
            stages.append(0.5)
            remaining /= 0.5
        }
        stages.append(remaining)
        return stages.map { String(format: "atempo=%.4f", $0) }.joined(separator: ",")
    }

    public static func cropRotateFilter(
        aspect: VideoCropAspect,
        customRect: (x: Int, y: Int, width: Int, height: Int)? = nil,
        rotation: VideoRotation = .none,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) throws -> String? {
        var filters: [String] = []
        switch aspect {
        case .none:
            break
        case .ratio16x9:
            filters.append("crop='min(iw,ih*16/9)':'min(ih,iw*9/16)'")
        case .ratio9x16:
            filters.append("crop='min(iw,ih*9/16)':'min(ih,iw*16/9)'")
        case .ratio1x1:
            filters.append("crop='min(iw,ih)':'min(iw,ih)'")
        case .ratio4x3:
            filters.append("crop='min(iw,ih*4/3)':'min(ih,iw*3/4)'")
        case .custom:
            guard let rect = customRect, rect.width >= 2, rect.height >= 2, rect.x >= 0, rect.y >= 0 else {
                throw FFmpegToolError.invalidParameter(coreLocalized("Enter a valid crop width, height, and position."))
            }
            let evenWidth = rect.width / 2 * 2
            let evenHeight = rect.height / 2 * 2
            filters.append("crop=\(evenWidth):\(evenHeight):\(rect.x):\(rect.y)")
        }
        switch rotation {
        case .none: break
        case .clockwise90: filters.append("transpose=1")
        case .rotate180: filters.append("transpose=1,transpose=1")
        case .clockwise270: filters.append("transpose=2")
        }
        if flipHorizontal { filters.append("hflip") }
        if flipVertical { filters.append("vflip") }
        guard !filters.isEmpty else { return nil }
        filters.append("scale=trunc(iw/2)*2:trunc(ih/2)*2")
        return filters.joined(separator: ",")
    }

    public static func audioCleanupFilter(_ options: AudioCleanupOptions) throws -> String {
        guard !options.isEmpty else {
            throw FFmpegToolError.invalidParameter(coreLocalized("Turn on at least one cleanup step."))
        }
        var filters: [String] = []
        if options.removeRumble { filters.append("highpass=f=80") }
        if options.tameHarshHighs { filters.append("lowpass=f=12000") }
        if options.reduceNoise { filters.append("afftdn=nf=-25") }
        if options.normalizeLoudness { filters.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
        return filters.joined(separator: ",")
    }

    public static func audioCodecArguments(format: AudioOutputFormat, bitrateKbps: Int, sampleRate: Int?) -> [String] {
        var args: [String] = []
        let clampedBitrate = min(max(bitrateKbps, 64), 320)
        switch format {
        case .m4a:
            args += ["-c:a", "aac", "-b:a", "\(clampedBitrate)k"]
        case .mp3:
            args += ["-c:a", "libmp3lame", "-b:a", "\(clampedBitrate)k"]
        case .wav:
            args += ["-c:a", "pcm_s16le"]
        case .flac:
            args += ["-c:a", "flac"]
        case .ogg:
            args += ["-c:a", "libvorbis", "-b:a", "\(clampedBitrate)k"]
        case .opus:
            args += ["-c:a", "libopus", "-b:a", "\(clampedBitrate)k"]
        case .aiff:
            args += ["-c:a", "pcm_s16be"]
        }
        if let sampleRate, sampleRate >= 8_000, sampleRate <= 192_000 {
            args += ["-ar", "\(sampleRate)"]
        }
        return args
    }

    public static func compressVideo(
        _ source: URL,
        quality: VideoCompressionQuality,
        codec: VideoCodecChoice,
        maxResolution: VideoResolutionPreset,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let duration = await probeDuration(source, ffprobe: ffprobe, runner: runner)
        var args = ["-i", source.path]
        if let maxHeight = maxResolution.maxHeight {
            args += ["-vf", "scale=-2:'min(\(maxHeight),ih)'"]
        }
        switch codec {
        case .h264:
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", "\(quality.crfH264)", "-pix_fmt", "yuv420p"]
        case .hevc:
            args += [
                "-c:v", "libx265", "-preset", "medium", "-crf", "\(quality.crfHEVC)",
                "-tag:v", "hvc1", "-pix_fmt", "yuv420p",
            ]
        }
        args += ["-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) compressed.mp4",
            fileExtension: "mp4",
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func convertVideo(
        _ source: URL,
        format: VideoContainerFormat,
        quality: VideoCompressionQuality = .high,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let duration = await probeDuration(source, ffprobe: ffprobe, runner: runner)
        var args = ["-i", source.path]
        switch format {
        case .mp4, .mov, .m4v, .mkv:
            args += [
                "-c:v", "libx264", "-preset", "medium", "-crf", "\(quality.crfH264)",
                "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k",
            ]
            if format == .mp4 || format == .mov || format == .m4v {
                args += ["-movflags", "+faststart"]
            }
        case .webm:
            args += [
                "-c:v", "libvpx-vp9", "-crf", "\(quality.crfH264 + 8)", "-b:v", "0",
                "-c:a", "libopus", "-b:a", "128k",
            ]
        case .avi:
            args += ["-c:v", "mpeg4", "-q:v", "5", "-c:a", "libmp3lame", "-b:a", "192k"]
        }
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base).\(format.fileExtension)",
            fileExtension: format.fileExtension,
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func resizeVideo(
        _ source: URL,
        preset: VideoResolutionPreset,
        customWidth: Int?,
        customHeight: Int?,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let filter: String
        if let maxHeight = preset.maxHeight {
            filter = "scale=-2:\(maxHeight)"
        } else if let width = customWidth, let height = customHeight, width >= 16, height >= 16 {
            filter = "scale=\(width / 2 * 2):\(height / 2 * 2)"
        } else if let width = customWidth, width >= 16 {
            filter = "scale=\(width / 2 * 2):-2"
        } else if let height = customHeight, height >= 16 {
            filter = "scale=-2:\(height / 2 * 2)"
        } else {
            throw FFmpegToolError.invalidParameter(coreLocalized("Choose a preset or enter a width or height of at least 16 px."))
        }
        let duration = await probeDuration(source, ffprobe: ffprobe, runner: runner)
        let args = [
            "-i", source.path,
            "-vf", filter,
            "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
        ]
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) resized.mp4",
            fileExtension: "mp4",
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func cropAndRotateVideo(
        _ source: URL,
        aspect: VideoCropAspect,
        customRect: (x: Int, y: Int, width: Int, height: Int)? = nil,
        rotation: VideoRotation = .none,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        guard let filter = try cropRotateFilter(
            aspect: aspect, customRect: customRect, rotation: rotation,
            flipHorizontal: flipHorizontal, flipVertical: flipVertical
        ) else {
            throw FFmpegToolError.invalidParameter(coreLocalized("Choose a crop, rotation, or flip to apply."))
        }
        let duration = await probeDuration(source, ffprobe: ffprobe, runner: runner)
        let args = [
            "-i", source.path,
            "-vf", filter,
            "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
        ]
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) edited.mp4",
            fileExtension: "mp4",
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func trimVideo(
        _ source: URL,
        startSeconds: Double,
        endSeconds: Double,
        accurateReencode: Bool,
        ffmpeg: URL,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        guard startSeconds.isFinite, endSeconds.isFinite, startSeconds >= 0, endSeconds > startSeconds else {
            throw MediaToolError.invalidRange
        }
        let span = endSeconds - startSeconds
        let ext = accurateReencode ? "mp4" : (source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased())
        var args = ["-ss", String(format: "%.3f", startSeconds), "-i", source.path, "-t", String(format: "%.3f", span)]
        if accurateReencode {
            args += [
                "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            ]
        } else {
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) trimmed.\(ext)",
            fileExtension: ext,
            durationSeconds: span,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func mergeVideos(
        _ sources: [URL],
        reencodeToMatch: Bool,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        guard sources.count >= 2 else { throw FFmpegToolError.notEnoughInputs }
        let staging = try makeStaging(appropriateFor: output.baseDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        var totalDuration = 0.0
        var firstWidth = 1920
        var firstHeight = 1080
        var clipInfos: [MediaProbeInfo?] = Array(repeating: nil, count: sources.count)
        if let ffprobe {
            for (index, url) in sources.enumerated() {
                if let info = try? await probe(url, ffprobe: ffprobe, runner: runner) {
                    clipInfos[index] = info
                    totalDuration += info.durationSeconds ?? 0
                    if index == 0, let video = info.primaryVideo, let w = video.width, let h = video.height {
                        firstWidth = max(2, w / 2 * 2)
                        firstHeight = max(2, h / 2 * 2)
                    }
                }
            }
        }

        let base = sources[0].deletingPathExtension().lastPathComponent
        if !reencodeToMatch {
            let listFile = staging.appending(path: "concat.txt", directoryHint: .notDirectory)
            let lines = sources.map { url -> String in
                let escaped = url.path.replacingOccurrences(of: "'", with: "'\\''")
                return "file '\(escaped)'"
            }
            try lines.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)
            let ext = sources[0].pathExtension.isEmpty ? "mp4" : sources[0].pathExtension.lowercased()
            let args = ["-f", "concat", "-safe", "0", "-i", listFile.path, "-c", "copy"]
            return try await runToOutput(
                ffmpeg: ffmpeg,
                arguments: args,
                preferredName: "\(base) merged.\(ext)",
                fileExtension: ext,
                durationSeconds: totalDuration > 0 ? totalDuration : nil,
                output: output,
                tool: tool,
                progress: progress,
                runner: runner
            )
        }

        let includeAudio = clipInfos.contains { $0?.hasAudio ?? true }
        var args: [String] = []
        var filterParts: [String] = []
        var concatInputs = ""
        for (index, url) in sources.enumerated() {
            args += ["-i", url.path]
            filterParts.append(
                "[\(index):v]scale=\(firstWidth):\(firstHeight):force_original_aspect_ratio=decrease,pad=\(firstWidth):\(firstHeight):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)]"
            )
            if includeAudio {
                let info = clipInfos[index]
                if info?.hasAudio ?? true {
                    filterParts.append("[\(index):a]aresample=48000,aformat=channel_layouts=stereo[a\(index)]")
                } else {
                    let clipDuration = max(0.05, info?.durationSeconds ?? 1.0)
                    filterParts.append(
                        String(format: "anullsrc=channel_layout=stereo:sample_rate=48000,atrim=duration=%.3f[a%d]", clipDuration, index)
                    )
                }
                concatInputs += "[v\(index)][a\(index)]"
            } else {
                concatInputs += "[v\(index)]"
            }
        }
        if includeAudio {
            filterParts.append("\(concatInputs)concat=n=\(sources.count):v=1:a=1[v][a]")
            args += [
                "-filter_complex", filterParts.joined(separator: ";"),
                "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            ]
        } else {
            filterParts.append("\(concatInputs)concat=n=\(sources.count):v=1:a=0[v]")
            args += [
                "-filter_complex", filterParts.joined(separator: ";"),
                "-map", "[v]",
                "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
                "-an", "-movflags", "+faststart",
            ]
        }
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) merged.mp4",
            fileExtension: "mp4",
            durationSeconds: totalDuration > 0 ? totalDuration : nil,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func muteVideo(
        _ source: URL,
        ffmpeg: URL,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        let args = ["-i", source.path, "-c:v", "copy", "-an"]
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) muted.\(ext)",
            fileExtension: ext,
            durationSeconds: nil,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func replaceAudio(
        video: URL,
        audio: URL,
        loopAudioToFit: Bool,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let duration = await probeDuration(video, ffprobe: ffprobe, runner: runner)
        var args = ["-i", video.path]
        if loopAudioToFit {
            args += ["-stream_loop", "-1"]
        }
        args += [
            "-i", audio.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "copy",
            "-c:a", "aac", "-b:a", "192k",
            "-shortest",
            "-movflags", "+faststart",
        ]
        let base = video.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) new audio.mp4",
            fileExtension: "mp4",
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func changeVideoSpeed(
        _ source: URL,
        speed: Double,
        muteAudio: Bool,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let audioChain = try atempoFilterChain(speed: speed)
        let probeInfo: MediaProbeInfo? = if let ffprobe { try? await probe(source, ffprobe: ffprobe, runner: runner) } else { nil }
        let hasAudio = !muteAudio && (probeInfo?.hasAudio ?? true)
        let expectedDuration = probeInfo?.durationSeconds.map { $0 / speed }

        var args = ["-i", source.path]
        let videoFilter = String(format: "setpts=%.6f*PTS", 1.0 / speed)
        if hasAudio {
            args += [
                "-filter_complex", "[0:v]\(videoFilter)[v];[0:a]\(audioChain)[a]",
                "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
            ]
        } else {
            args += [
                "-vf", videoFilter, "-an",
                "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
                "-movflags", "+faststart",
            ]
        }
        let base = source.deletingPathExtension().lastPathComponent
        let label = String(format: "%.2gx", speed)
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) \(label).mp4",
            fileExtension: "mp4",
            durationSeconds: expectedDuration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func videoToGIF(
        _ source: URL,
        fps: Int = 12,
        width: Int = 480,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let clampedFPS = min(max(fps, 1), 30)
        let clampedWidth = min(max(width, 64), 1920)
        var args: [String] = []
        var expectedDuration: Double?
        if let start = startSeconds, start > 0 {
            args += ["-ss", String(format: "%.3f", start)]
        }
        args += ["-i", source.path]
        if let end = endSeconds {
            let start = max(0, startSeconds ?? 0)
            guard end > start else { throw MediaToolError.invalidRange }
            let span = end - start
            args += ["-t", String(format: "%.3f", span)]
            expectedDuration = span
        } else if let total = await probeDuration(source, ffprobe: ffprobe, runner: runner) {
            expectedDuration = max(0.1, total - max(0, startSeconds ?? 0))
        }
        let filter = "fps=\(clampedFPS),scale=\(clampedWidth):-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer"
        args += ["-vf", filter, "-loop", "0"]
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base).gif",
            fileExtension: "gif",
            durationSeconds: expectedDuration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func burnInSubtitles(
        video: URL,
        subtitles: URL,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let duration = await probeDuration(video, ffprobe: ffprobe, runner: runner)
        let staging = try makeStaging(appropriateFor: output.baseDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        let subExt = subtitles.pathExtension.isEmpty ? "srt" : subtitles.pathExtension.lowercased()
        let safeSub = staging.appending(path: "subtitles.\(subExt)", directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: subtitles, to: safeSub)
        let escapedPath = escapeFilterPath(safeSub.path)
        let filter = subExt == "ass" || subExt == "ssa" ? "ass='\(escapedPath)'" : "subtitles='\(escapedPath)'"

        let args = [
            "-i", video.path,
            "-vf", filter,
            "-c:v", "libx264", "-preset", "medium", "-crf", "22", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
        ]
        let base = video.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base) subtitled.mp4",
            fileExtension: "mp4",
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    static func escapeFilterPath(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    public static func convertAudio(
        _ source: URL,
        format: AudioOutputFormat,
        bitrateKbps: Int = 192,
        sampleRate: Int? = nil,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let duration = await probeDuration(source, ffprobe: ffprobe, runner: runner)
        var args = ["-i", source.path, "-vn"]
        args += audioCodecArguments(format: format, bitrateKbps: bitrateKbps, sampleRate: sampleRate)
        let base = source.deletingPathExtension().lastPathComponent
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: "\(base).\(format.fileExtension)",
            fileExtension: format.fileExtension,
            durationSeconds: duration,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func extractAudio(
        _ source: URL,
        format: AudioOutputFormat,
        bitrateKbps: Int = 192,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        if let ffprobe, let info = try? await probe(source, ffprobe: ffprobe, runner: runner), !info.hasAudio {
            throw FFmpegToolError.missingAudioTrack(source.lastPathComponent)
        }
        return try await convertAudio(
            source,
            format: format,
            bitrateKbps: bitrateKbps,
            sampleRate: nil,
            ffmpeg: ffmpeg,
            ffprobe: ffprobe,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    public static func cleanUpAudio(
        _ source: URL,
        options: AudioCleanupOptions,
        outputFormat: AudioOutputFormat = .m4a,
        ffmpeg: URL,
        ffprobe: URL?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> URL {
        let filter = try audioCleanupFilter(options)
        let probeInfo: MediaProbeInfo? = if let ffprobe { try? await probe(source, ffprobe: ffprobe, runner: runner) } else { nil }
        if let probeInfo, !probeInfo.hasAudio {
            throw FFmpegToolError.missingAudioTrack(source.lastPathComponent)
        }
        let hasVideo = probeInfo?.hasVideo ?? false
        let base = source.deletingPathExtension().lastPathComponent
        var args = ["-i", source.path]
        let fileExtension: String
        let preferredName: String
        if hasVideo {
            args += ["-c:v", "copy", "-af", filter, "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
            fileExtension = "mp4"
            preferredName = "\(base) cleaned.mp4"
        } else {
            args += ["-vn", "-af", filter]
            args += audioCodecArguments(format: outputFormat, bitrateKbps: 192, sampleRate: nil)
            fileExtension = outputFormat.fileExtension
            preferredName = "\(base) cleaned.\(fileExtension)"
        }
        return try await runToOutput(
            ffmpeg: ffmpeg,
            arguments: args,
            preferredName: preferredName,
            fileExtension: fileExtension,
            durationSeconds: probeInfo?.durationSeconds,
            output: output,
            tool: tool,
            progress: progress,
            runner: runner
        )
    }

    private static func probeDuration(_ source: URL, ffprobe: URL?, runner: Runner) async -> Double? {
        guard let ffprobe else { return nil }
        return (try? await probe(source, ffprobe: ffprobe, runner: runner))?.durationSeconds
    }

    private static func runToOutput(
        ffmpeg: URL,
        arguments: [String],
        preferredName: String,
        fileExtension: String,
        durationSeconds: Double?,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void,
        runner: Runner
    ) async throws -> URL {
        let staging = try makeStaging(appropriateFor: output.baseDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }

        let tempOut = staging.appending(path: "output.\(fileExtension)", directoryHint: .notDirectory)
        let fullArgs = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-progress", "pipe:1", "-y",
        ] + arguments + [tempOut.path]

        let result = try await runner(ffmpeg, fullArgs) { line in
            if let fraction = parseProgressLine(line, durationSeconds: durationSeconds) {
                progress(fraction)
            }
        }
        guard result.exitCode == 0, FileManager.default.fileExists(atPath: tempOut.path) else {
            throw EngineProcessError.failed(
                command: ffmpeg.lastPathComponent,
                exitCode: result.exitCode,
                detail: result.stderrString
            )
        }
        progress(1)
        return try output.writeNewFile(for: tool, preferredName: preferredName) { destination in
            try FileManager.default.moveItem(at: tempOut, to: destination)
        }
    }

    private static func makeStaging(appropriateFor base: URL) throws -> URL {
        try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: base,
            create: true
        )
    }
}
