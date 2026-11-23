import Foundation

public enum VideoDownloadQuality: String, CaseIterable, Sendable, Identifiable {
    case best
    case p1080
    case p720
    case audioM4A
    case audioMP3

    public var id: String { rawValue }
}

public enum VideoDownloadError: Error, Equatable, LocalizedError {
    case invalidURL
    case noOutputFile

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            coreLocalized("Enter a valid http:// or https:// web address.")
        case .noOutputFile:
            coreLocalized("yt-dlp finished without creating a media file.")
        }
    }
}

/// Downloads video or audio from supported websites via on-demand `yt-dlp` and `ffmpeg`.
public enum VideoDownloader {
    public typealias Runner = @Sendable (URL, [String], (@Sendable (String) -> Void)?) async throws -> EngineProcessResult

    public static let defaultRunner: Runner = { exe, args, onStdoutLine in
        try await EngineProcess.run(exe, arguments: args, onStdoutLine: onStdoutLine)
    }

    public static func validateURL(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VideoDownloadError.invalidURL }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty, !host.hasPrefix("-") else {
            throw VideoDownloadError.invalidURL
        }
        return url
    }

    public static func arguments(
        url: URL,
        quality: VideoDownloadQuality,
        includeSubtitles: Bool,
        ffmpegDirectory: URL,
        outputDirectory: URL
    ) -> [String] {
        var args = [
            "--ignore-config",
            "--no-plugin-dirs",
            "--no-playlist",
            "--no-color",
            "--newline",
            "--restrict-filenames",
            "--ffmpeg-location", ffmpegDirectory.path,
            "--progress-template", "download:PROGRESS %(progress._percent_str)s",
            "-P", outputDirectory.path,
            "-o", "%(title).120s.%(ext)s",
        ]
        switch quality {
        case .best:
            args += ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
        case .p1080:
            args += ["-f", "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b", "--merge-output-format", "mp4"]
        case .p720:
            args += ["-f", "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b", "--merge-output-format", "mp4"]
        case .audioM4A:
            args += ["-x", "--audio-format", "m4a"]
        case .audioMP3:
            args += ["-x", "--audio-format", "mp3"]
        }
        if includeSubtitles {
            args += ["--write-subs", "--sub-langs", "en.*,en"]
        }
        args += ["--", url.absoluteString]
        return args
    }

    /// Parses `PROGRESS 42.5%` lines emitted by `--progress-template`.
    public static func parseProgressLine(_ line: String) -> Double? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("PROGRESS ") else { return nil }
        let value = trimmed
            .dropFirst("PROGRESS ".count)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "%", with: "")
        guard let percent = Double(value), percent.isFinite else { return nil }
        return min(1, max(0, percent / 100))
    }

    public static func download(
        urlString: String,
        quality: VideoDownloadQuality,
        includeSubtitles: Bool,
        ytDlp: URL,
        ffmpeg: URL,
        output: OutputDirectory,
        tool: ToolID,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        runner: Runner = defaultRunner
    ) async throws -> [URL] {
        let url = try validateURL(urlString)
        let staging = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: output.baseDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        let args = arguments(
            url: url,
            quality: quality,
            includeSubtitles: includeSubtitles,
            ffmpegDirectory: ffmpeg.deletingLastPathComponent(),
            outputDirectory: staging
        )
        let result = try await runner(ytDlp, args) { line in
            if let fraction = parseProgressLine(line) {
                progress(fraction)
            }
        }
        guard result.exitCode == 0 else {
            throw EngineProcessError.failed(
                command: ytDlp.lastPathComponent,
                exitCode: result.exitCode,
                detail: result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            )
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else { throw VideoDownloadError.noOutputFile }

        let runDate = Date()
        let calendar = Calendar.current
        var saved: [URL] = []
        for file in files {
            let published = try output.writeNewFile(
                for: tool,
                preferredName: file.lastPathComponent,
                date: runDate,
                calendar: calendar
            ) { destination in
                try FileManager.default.moveItem(at: file, to: destination)
            }
            saved.append(published)
        }
        progress(1)
        return saved
    }
}
