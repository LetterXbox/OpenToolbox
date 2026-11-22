import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

private var mediaTypes: [UTType] {
    var types: [UTType] = [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff]
    for ext in ["mkv", "webm", "avi", "m4v", "m4a", "flac", "ogg", "opus", "aac", "caf"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

private var audioOnlyTypes: [UTType] {
    var types: [UTType] = [.audio, .mp3, .wav, .aiff]
    for ext in ["m4a", "flac", "ogg", "opus", "aac", "caf"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

private var videoOnlyTypes: [UTType] {
    var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    for ext in ["mkv", "webm", "avi", "m4v", "mov", "mp4", "ts", "flv"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

struct MediaInfoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var info: MediaProbeInfo?
    @State private var isLoading = false
    @State private var failure: String?
    @State private var probeTask: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: mediaTypes, allowsMultiple: false, prompt: L("Drop a video or audio file"))
            if isLoading {
                ProgressView().controlSize(.small)
            }
            if let failure { ErrorMessage(text: failure) }
            if let info {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox(L("Container")) {
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                                GridRow {
                                    Text(L("Format")).foregroundStyle(.secondary)
                                    Text(info.formatLongName)
                                }
                                if let duration = info.durationSeconds {
                                    GridRow {
                                        Text(L("Duration")).foregroundStyle(.secondary)
                                        Text(MediaTime.format(duration)).monospacedDigit()
                                    }
                                }
                                if let size = info.sizeBytes {
                                    GridRow {
                                        Text(L("Size")).foregroundStyle(.secondary)
                                        Text(size.formatted(.byteCount(style: .file))).monospacedDigit()
                                    }
                                }
                                if let bitRate = info.bitRate {
                                    GridRow {
                                        Text(L("Bitrate")).foregroundStyle(.secondary)
                                        Text("\(bitRate / 1_000) kbps").monospacedDigit()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }

                        ForEach(info.streams) { stream in
                            GroupBox(L("Stream #\(stream.id) · \(stream.codecType.capitalized)")) {
                                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                                    GridRow {
                                        Text(L("Codec")).foregroundStyle(.secondary)
                                        Text(stream.codecName)
                                    }
                                    if let w = stream.width, let h = stream.height {
                                        GridRow {
                                            Text(L("Dimensions")).foregroundStyle(.secondary)
                                            Text("\(w) × \(h)").monospacedDigit()
                                        }
                                    }
                                    if let fps = stream.frameRate {
                                        GridRow {
                                            Text(L("Frame rate")).foregroundStyle(.secondary)
                                            Text(fps)
                                        }
                                    }
                                    if let sr = stream.sampleRate {
                                        GridRow {
                                            Text(L("Sample rate")).foregroundStyle(.secondary)
                                            Text("\(sr) Hz").monospacedDigit()
                                        }
                                    }
                                    if let ch = stream.channels {
                                        GridRow {
                                            Text(L("Channels")).foregroundStyle(.secondary)
                                            Text("\(ch)").monospacedDigit()
                                        }
                                    }
                                    if let lang = stream.language {
                                        GridRow {
                                            Text(L("Language")).foregroundStyle(.secondary)
                                            Text(lang)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                        }

                        Pane(L("Raw FFprobe JSON")) {
                            CopyButton(text: info.rawJSON)
                        } content: {
                            CodeOutput(text: info.rawJSON)
                                .frame(minHeight: 180)
                        }
                    }
                }
            }
        }
        .onChange(of: files) { inspect() }
        .onDisappear { probeTask?.cancel() }
        .reportsActivity(isLoading)
    }

    private func inspect() {
        probeTask?.cancel()
        probeTask = nil
        info = nil
        failure = nil
        guard let url = files.first, let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID) else {
            isLoading = false
            return
        }
        isLoading = true
        probeTask = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let probed = try await FFmpegTools.probe(url, ffprobe: ffprobe)
                guard !Task.isCancelled, self.files.first == url else { return }
                info = probed
                isLoading = false
            } catch is CancellationError {
                if self.files.first == url { isLoading = false }
            } catch {
                guard !Task.isCancelled, self.files.first == url else { return }
                failure = error.localizedDescription
                isLoading = false
            }
        }
    }
}

struct ConvertAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var format: AudioOutputFormat = .m4a
    @State private var bitrateKbps = 192
    @State private var sampleRate = 0
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: audioOnlyTypes, prompt: L("Drop audio files here"))
            Form {
                Picker(L("Format"), selection: $format) {
                    ForEach(AudioOutputFormat.allCases) { item in
                        Text(verbatim: item.fileExtension.uppercased()).tag(item)
                    }
                }
                if format.isLossy {
                    Picker(L("Bitrate"), selection: $bitrateKbps) {
                        Text(verbatim: "96 kbps").tag(96)
                        Text(verbatim: "128 kbps").tag(128)
                        Text(verbatim: "192 kbps").tag(192)
                        Text(verbatim: "256 kbps").tag(256)
                        Text(verbatim: "320 kbps").tag(320)
                    }
                }
                Picker(L("Sample rate"), selection: $sampleRate) {
                    Text(L("Keep original")).tag(0)
                    Text(verbatim: "44.1 kHz").tag(44_100)
                    Text(verbatim: "48 kHz").tag(48_000)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: format.isLossy ? 170 : 130)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Convert \(files.count) Files"),
                disabled: files.isEmpty,
                onRun: run,
                onStop: { task?.cancel() }
            )
            FileResultsView(results: results)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID) else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let files = self.files, format = self.format, bitrate = bitrateKbps
        let sr = sampleRate > 0 ? sampleRate : nil
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        results = []
        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved = try await FFmpegTools.convertAudio(
                        url,
                        format: format,
                        bitrateKbps: bitrate,
                        sampleRate: sr,
                        ffmpeg: ffmpeg,
                        ffprobe: ffprobe,
                        output: output,
                        tool: toolID,
                        progress: { fraction in
                            let overall = (Double(index) + fraction) / Double(files.count)
                            Task { @MainActor in self.progress = overall }
                        }
                    )
                    batch.append(FileResult(source: url, output: saved, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = batch
        }
    }
}

struct ExtractAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var format: AudioOutputFormat = .m4a
    @State private var bitrateKbps = 192
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoOnlyTypes, prompt: L("Drop videos to extract audio from"))
            Form {
                Picker(L("Audio format"), selection: $format) {
                    ForEach(AudioOutputFormat.allCases) { item in
                        Text(verbatim: item.fileExtension.uppercased()).tag(item)
                    }
                }
                if format.isLossy {
                    Picker(L("Bitrate"), selection: $bitrateKbps) {
                        Text(verbatim: "128 kbps").tag(128)
                        Text(verbatim: "192 kbps").tag(192)
                        Text(verbatim: "256 kbps").tag(256)
                        Text(verbatim: "320 kbps").tag(320)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: format.isLossy ? 130 : 80)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Extract Audio"),
                disabled: files.isEmpty,
                onRun: run,
                onStop: { task?.cancel() }
            )
            FileResultsView(results: results)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID) else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let files = self.files, format = self.format, bitrate = bitrateKbps
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        results = []
        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved = try await FFmpegTools.extractAudio(
                        url,
                        format: format,
                        bitrateKbps: bitrate,
                        ffmpeg: ffmpeg,
                        ffprobe: ffprobe,
                        output: output,
                        tool: toolID,
                        progress: { fraction in
                            let overall = (Double(index) + fraction) / Double(files.count)
                            Task { @MainActor in self.progress = overall }
                        }
                    )
                    batch.append(FileResult(source: url, output: saved, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = batch
        }
    }
}

struct CleanAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var options = AudioCleanupOptions()
    @State private var outputFormat: AudioOutputFormat = .m4a
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: mediaTypes, prompt: L("Drop audio or video files here"))
            Form {
                Toggle(L("Reduce background noise"), isOn: $options.reduceNoise)
                Toggle(L("Remove low rumble (80 Hz high-pass)"), isOn: $options.removeRumble)
                Toggle(L("Tame harsh highs (12 kHz low-pass)"), isOn: $options.tameHarshHighs)
                Toggle(L("Normalize loudness (EBU R128)"), isOn: $options.normalizeLoudness)
                Picker(L("Audio-only output format"), selection: $outputFormat) {
                    Text(verbatim: "M4A").tag(AudioOutputFormat.m4a)
                    Text(verbatim: "WAV").tag(AudioOutputFormat.wav)
                    Text(verbatim: "MP3").tag(AudioOutputFormat.mp3)
                    Text(verbatim: "FLAC").tag(AudioOutputFormat.flac)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 230)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Clean Up \(files.count) Files"),
                disabled: files.isEmpty || options.isEmpty,
                onRun: run,
                onStop: { task?.cancel() }
            )
            FileResultsView(results: results)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID) else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let files = self.files, options = self.options, format = outputFormat
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        results = []
        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved = try await FFmpegTools.cleanUpAudio(
                        url,
                        options: options,
                        outputFormat: format,
                        ffmpeg: ffmpeg,
                        ffprobe: ffprobe,
                        output: output,
                        tool: toolID,
                        progress: { fraction in
                            let overall = (Double(index) + fraction) / Double(files.count)
                            Task { @MainActor in self.progress = overall }
                        }
                    )
                    batch.append(FileResult(source: url, output: saved, error: nil))
                } catch is CancellationError {
                    break
                } catch {
                    batch.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = batch
        }
    }
}

struct DownloadVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var urlString = ""
    @State private var quality: VideoDownloadQuality = .best
    @State private var includeSubtitles = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var savedURLs: [URL] = []
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    private var isValidURL: Bool {
        (try? VideoDownloader.validateURL(urlString)) != nil
    }

    var body: some View {
        ToolPage(tool: tool) {
            TextField(L("Video URL"), text: $urlString, prompt: Text(verbatim: "https://…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(run)

            Form {
                Picker(L("Format"), selection: $quality) {
                    Text(L("Best quality (MP4)")).tag(VideoDownloadQuality.best)
                    Text(L("Up to 1080p (MP4)")).tag(VideoDownloadQuality.p1080)
                    Text(L("Up to 720p (MP4)")).tag(VideoDownloadQuality.p720)
                    Text(L("Audio only (M4A)")).tag(VideoDownloadQuality.audioM4A)
                    Text(L("Audio only (MP3)")).tag(VideoDownloadQuality.audioMP3)
                }
                Toggle(L("Also download English subtitles when available"), isOn: $includeSubtitles)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 130)

            HStack(spacing: 12) {
                if isWorking {
                    Button(L("Stop")) { task?.cancel() }
                    if progress > 0 {
                        ProgressView(value: progress).frame(width: 180)
                        Text(progress.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button(L("Download"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isValidURL)
                }
                Spacer()
                if !savedURLs.isEmpty, !isWorking {
                    Label(L("Saved \(savedURLs.count) file(s)"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(savedURLs) }
                }
            }

            if let failure { ErrorMessage(text: failure) }
            Text(L("Connects to the website you enter using yt-dlp and saves the media to \(model.outputBaseDirectory.lastPathComponent)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard isValidURL, !isWorking,
              let ytDlp = model.engines.executableURL(for: EngineCatalog.ytDlpID),
              let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID)
        else { return }
        let urlString = self.urlString, quality = self.quality, subs = includeSubtitles
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        savedURLs = []
        failure = nil
        task = Task {
            defer { isWorking = false }
            do {
                savedURLs = try await VideoDownloader.download(
                    urlString: urlString,
                    quality: quality,
                    includeSubtitles: subs,
                    ytDlp: ytDlp,
                    ffmpeg: ffmpeg,
                    output: output,
                    tool: toolID,
                    progress: { fraction in Task { @MainActor in self.progress = fraction } }
                )
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
