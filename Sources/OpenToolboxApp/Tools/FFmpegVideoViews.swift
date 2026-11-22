import AppKit
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

private var videoTypes: [UTType] {
    var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    for ext in ["mkv", "webm", "avi", "m4v", "mov", "mp4", "ts", "flv"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

private var audioTypes: [UTType] {
    var types: [UTType] = [.audio, .mp3, .wav, .aiff]
    for ext in ["m4a", "flac", "ogg", "opus", "aac", "caf"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

private var subtitleTypes: [UTType] {
    var types: [UTType] = [.plainText]
    for ext in ["srt", "ass", "ssa", "vtt"] {
        if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
}

struct CompressVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var quality: VideoCompressionQuality = .balanced
    @State private var codec: VideoCodecChoice = .h264
    @State private var maxResolution: VideoResolutionPreset = .original
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos here"))
            Form {
                Picker(L("Quality"), selection: $quality) {
                    Text(L("High quality")).tag(VideoCompressionQuality.high)
                    Text(L("Balanced")).tag(VideoCompressionQuality.balanced)
                    Text(L("Smallest file")).tag(VideoCompressionQuality.small)
                }
                Picker(L("Codec"), selection: $codec) {
                    Text(verbatim: "H.264 (MP4)").tag(VideoCodecChoice.h264)
                    Text(verbatim: "HEVC / H.265 (MP4)").tag(VideoCodecChoice.hevc)
                }
                Picker(L("Max resolution"), selection: $maxResolution) {
                    Text(L("Keep original")).tag(VideoResolutionPreset.original)
                    Text(verbatim: "1080p").tag(VideoResolutionPreset.p1080)
                    Text(verbatim: "720p").tag(VideoResolutionPreset.p720)
                    Text(verbatim: "480p").tag(VideoResolutionPreset.p480)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 170)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Compress \(files.count) Videos"),
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
        let files = self.files, quality = self.quality, codec = self.codec, maxRes = self.maxResolution
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
                    let saved = try await FFmpegTools.compressVideo(
                        url,
                        quality: quality,
                        codec: codec,
                        maxResolution: maxRes,
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

struct ConvertVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var format: VideoContainerFormat = .mp4
    @State private var quality: VideoCompressionQuality = .high
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos here"))
            Form {
                Picker(L("Format"), selection: $format) {
                    ForEach(VideoContainerFormat.allCases) { item in
                        Text(verbatim: item.fileExtension.uppercased()).tag(item)
                    }
                }
                Picker(L("Quality"), selection: $quality) {
                    Text(L("High quality")).tag(VideoCompressionQuality.high)
                    Text(L("Balanced")).tag(VideoCompressionQuality.balanced)
                    Text(L("Smallest file")).tag(VideoCompressionQuality.small)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 130)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Convert \(files.count) Videos"),
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
        let files = self.files, format = self.format, quality = self.quality
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
                    let saved = try await FFmpegTools.convertVideo(
                        url,
                        format: format,
                        quality: quality,
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

struct ResizeVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var preset: VideoResolutionPreset = .p1080
    @State private var customWidth = 1280
    @State private var customHeight = 0
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos here"))
            Form {
                Picker(L("Resolution"), selection: $preset) {
                    Text(verbatim: "4K (2160p)").tag(VideoResolutionPreset.p2160)
                    Text(verbatim: "1080p").tag(VideoResolutionPreset.p1080)
                    Text(verbatim: "720p").tag(VideoResolutionPreset.p720)
                    Text(verbatim: "480p").tag(VideoResolutionPreset.p480)
                    Text(verbatim: "360p").tag(VideoResolutionPreset.p360)
                    Text(L("Custom")).tag(VideoResolutionPreset.original)
                }
                if preset == .original {
                    TextField(L("Width (0 = auto)"), value: $customWidth, format: .number)
                    TextField(L("Height (0 = auto)"), value: $customHeight, format: .number)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: preset == .original ? 170 : 80)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Resize \(files.count) Videos"),
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
        let files = self.files, preset = self.preset
        let width = customWidth > 0 ? customWidth : nil
        let height = customHeight > 0 ? customHeight : nil
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
                    let saved = try await FFmpegTools.resizeVideo(
                        url,
                        preset: preset,
                        customWidth: width,
                        customHeight: height,
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

struct CropRotateVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var aspect: VideoCropAspect = .none
    @State private var cropX = 0
    @State private var cropY = 0
    @State private var cropWidth = 1280
    @State private var cropHeight = 720
    @State private var rotation: VideoRotation = .none
    @State private var flipHorizontal = false
    @State private var flipVertical = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos here"))
            Form {
                Picker(L("Crop"), selection: $aspect) {
                    Text(L("None")).tag(VideoCropAspect.none)
                    Text(verbatim: "16:9").tag(VideoCropAspect.ratio16x9)
                    Text(verbatim: "9:16").tag(VideoCropAspect.ratio9x16)
                    Text(verbatim: "1:1").tag(VideoCropAspect.ratio1x1)
                    Text(verbatim: "4:3").tag(VideoCropAspect.ratio4x3)
                    Text(L("Custom")).tag(VideoCropAspect.custom)
                }
                if aspect == .custom {
                    HStack {
                        TextField(L("X"), value: $cropX, format: .number)
                        TextField(L("Y"), value: $cropY, format: .number)
                        TextField(L("Width"), value: $cropWidth, format: .number)
                        TextField(L("Height"), value: $cropHeight, format: .number)
                    }
                }
                Picker(L("Rotate"), selection: $rotation) {
                    Text(L("None")).tag(VideoRotation.none)
                    Text(L("90° clockwise")).tag(VideoRotation.clockwise90)
                    Text(L("180°")).tag(VideoRotation.rotate180)
                    Text(L("270° clockwise")).tag(VideoRotation.clockwise270)
                }
                Toggle(L("Flip horizontally"), isOn: $flipHorizontal)
                Toggle(L("Flip vertically"), isOn: $flipVertical)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: aspect == .custom ? 250 : 210)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Apply to \(files.count) Videos"),
                disabled: files.isEmpty || (aspect == .none && rotation == .none && !flipHorizontal && !flipVertical),
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
        let files = self.files, aspect = self.aspect, rotation = self.rotation
        let flipH = flipHorizontal, flipV = flipVertical
        let rect = aspect == .custom ? (x: cropX, y: cropY, width: cropWidth, height: cropHeight) : nil
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
                    let saved = try await FFmpegTools.cropAndRotateVideo(
                        url,
                        aspect: aspect,
                        customRect: rect,
                        rotation: rotation,
                        flipHorizontal: flipH,
                        flipVertical: flipV,
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

struct TrimVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var startText = "0:00"
    @State private var endText = "0:10"
    @State private var duration: Double?
    @State private var accurateReencode = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, allowsMultiple: false, prompt: L("Drop a video here"))
            Form {
                if let duration {
                    LabeledContent(L("Length"), value: MediaTime.format(duration))
                }
                TextField(L("Start"), text: $startText, prompt: Text(verbatim: "0:00"))
                TextField(L("End"), text: $endText, prompt: Text(verbatim: "0:10"))
                Toggle(L("Frame-accurate re-encode (slower, exact cut)"), isOn: $accurateReencode)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 190)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Trim Video"),
                disabled: files.isEmpty || MediaTime.parse(startText) == nil || MediaTime.parse(endText) == nil,
                saved: saved,
                onRun: run,
                onStop: { task?.cancel() }
            )
            if let failure { ErrorMessage(text: failure) }
        }
        .onChange(of: files) { loadDuration() }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func loadDuration() {
        duration = nil
        saved = nil
        failure = nil
        guard let url = files.first, let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID) else { return }
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let info = try? await FFmpegTools.probe(url, ffprobe: ffprobe), let length = info.durationSeconds {
                duration = length
                startText = "0:00"
                endText = MediaTime.format(length)
            }
        }
    }

    private func run() {
        guard let url = files.first,
              let start = MediaTime.parse(startText),
              let end = MediaTime.parse(endText),
              let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID)
        else { return }
        let accurate = accurateReencode, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        saved = nil
        failure = nil
        task = Task {
            defer { isWorking = false }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                saved = try await FFmpegTools.trimVideo(
                    url,
                    startSeconds: start,
                    endSeconds: end,
                    accurateReencode: accurate,
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

struct MergeVideosView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var reencodeToMatch = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop two or more videos in order"))
            Form {
                Toggle(L("Re-encode to match resolution and audio (for clips with different formats)"), isOn: $reencodeToMatch)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 520, maxHeight: 80)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Merge \(files.count) Videos"),
                disabled: files.count < 2,
                saved: saved,
                onRun: run,
                onStop: { task?.cancel() }
            )
            if let failure { ErrorMessage(text: failure) }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard files.count >= 2, let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID) else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let files = self.files, reencode = reencodeToMatch, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        saved = nil
        failure = nil
        task = Task {
            defer { isWorking = false }
            let accessed = files.map { ($0, $0.startAccessingSecurityScopedResource()) }
            defer { for (url, ok) in accessed where ok { url.stopAccessingSecurityScopedResource() } }
            do {
                saved = try await FFmpegTools.mergeVideos(
                    files,
                    reencodeToMatch: reencode,
                    ffmpeg: ffmpeg,
                    ffprobe: ffprobe,
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

struct MuteVideoView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var isWorking = false
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos to mute"))
            actionBar(
                isWorking: isWorking,
                progress: nil,
                buttonTitle: L("Mute \(files.count) Videos"),
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
        let files = self.files, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        results = []
        task = Task {
            defer { isWorking = false }
            var batch: [FileResult] = []
            for url in files {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let saved = try await FFmpegTools.muteVideo(url, ffmpeg: ffmpeg, output: output, tool: toolID)
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

struct ReplaceAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var videos: [URL] = []
    @State private var audios: [URL] = []
    @State private var loopAudioToFit = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Video")).font(.headline)
                    FileDropList(files: $videos, allowedTypes: videoTypes, allowsMultiple: false, prompt: L("Drop video"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("New audio")).font(.headline)
                    FileDropList(files: $audios, allowedTypes: audioTypes, allowsMultiple: false, prompt: L("Drop audio"))
                }
            }
            Form {
                Toggle(L("Loop audio if it is shorter than the video"), isOn: $loopAudioToFit)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 80)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Replace Audio"),
                disabled: videos.isEmpty || audios.isEmpty,
                saved: saved,
                onRun: run,
                onStop: { task?.cancel() }
            )
            if let failure { ErrorMessage(text: failure) }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let video = videos.first, let audio = audios.first,
              let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID)
        else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let loop = loopAudioToFit, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        saved = nil
        failure = nil
        task = Task {
            defer { isWorking = false }
            let okV = video.startAccessingSecurityScopedResource()
            let okA = audio.startAccessingSecurityScopedResource()
            defer {
                if okV { video.stopAccessingSecurityScopedResource() }
                if okA { audio.stopAccessingSecurityScopedResource() }
            }
            do {
                saved = try await FFmpegTools.replaceAudio(
                    video: video,
                    audio: audio,
                    loopAudioToFit: loop,
                    ffmpeg: ffmpeg,
                    ffprobe: ffprobe,
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

struct ChangeVideoSpeedView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var speed = 1.5
    @State private var muteAudio = false
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, prompt: L("Drop videos here"))
            Form {
                LabeledContent(L("Speed")) {
                    HStack {
                        Slider(value: $speed, in: 0.25...4.0, step: 0.25)
                        Text(String(format: "%.2gx", speed))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                Toggle(L("Mute audio"), isOn: $muteAudio)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 130)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Change Speed"),
                disabled: files.isEmpty || abs(speed - 1.0) < 0.01,
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
        let files = self.files, speed = self.speed, mute = muteAudio
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
                    let saved = try await FFmpegTools.changeVideoSpeed(
                        url,
                        speed: speed,
                        muteAudio: mute,
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

struct VideoToGIFView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var files: [URL] = []
    @State private var fps = 12
    @State private var width = 480
    @State private var startText = ""
    @State private var endText = ""
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: videoTypes, allowsMultiple: false, prompt: L("Drop a video here"))
            Form {
                Stepper(L("Frame rate: \(fps) fps"), value: $fps, in: 1...30)
                TextField(L("Width (px)"), value: $width, format: .number)
                TextField(L("Start time (optional)"), text: $startText, prompt: Text(verbatim: "0:00"))
                TextField(L("End time (optional)"), text: $endText, prompt: Text(verbatim: "0:05"))
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 200)

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Create GIF"),
                disabled: files.isEmpty,
                saved: saved,
                onRun: run,
                onStop: { task?.cancel() }
            )
            if let failure { ErrorMessage(text: failure) }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let url = files.first, let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID) else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let start = startText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : MediaTime.parse(startText)
        let end = endText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : MediaTime.parse(endText)
        if !startText.trimmingCharacters(in: .whitespaces).isEmpty, start == nil {
            failure = MediaToolError.invalidRange.localizedDescription
            return
        }
        if !endText.trimmingCharacters(in: .whitespaces).isEmpty, end == nil {
            failure = MediaToolError.invalidRange.localizedDescription
            return
        }
        let fps = self.fps, width = self.width, output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        saved = nil
        failure = nil
        task = Task {
            defer { isWorking = false }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                saved = try await FFmpegTools.videoToGIF(
                    url,
                    fps: fps,
                    width: width,
                    startSeconds: start,
                    endSeconds: end,
                    ffmpeg: ffmpeg,
                    ffprobe: ffprobe,
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

struct BurnSubtitlesView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor

    @State private var videos: [URL] = []
    @State private var subtitles: [URL] = []
    @State private var isWorking = false
    @State private var progress: Double = 0
    @State private var saved: URL?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Video")).font(.headline)
                    FileDropList(files: $videos, allowedTypes: videoTypes, allowsMultiple: false, prompt: L("Drop video"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Subtitles")).font(.headline)
                    FileDropList(
                        files: $subtitles,
                        allowedTypes: subtitleTypes,
                        allowsMultiple: false,
                        prompt: L("Drop .srt, .ass, or .vtt")
                    )
                }
            }

            actionBar(
                isWorking: isWorking,
                progress: progress,
                buttonTitle: L("Burn In Subtitles"),
                disabled: videos.isEmpty || subtitles.isEmpty,
                saved: saved,
                onRun: run,
                onStop: { task?.cancel() }
            )
            if let failure { ErrorMessage(text: failure) }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        guard let video = videos.first, let sub = subtitles.first,
              let ffmpeg = model.engines.executableURL(for: EngineCatalog.ffmpegID)
        else { return }
        let ffprobe = model.engines.executableURL(for: EngineCatalog.ffprobeID)
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        progress = 0
        saved = nil
        failure = nil
        task = Task {
            defer { isWorking = false }
            let okV = video.startAccessingSecurityScopedResource()
            let okS = sub.startAccessingSecurityScopedResource()
            defer {
                if okV { video.stopAccessingSecurityScopedResource() }
                if okS { sub.stopAccessingSecurityScopedResource() }
            }
            do {
                saved = try await FFmpegTools.burnInSubtitles(
                    video: video,
                    subtitles: sub,
                    ffmpeg: ffmpeg,
                    ffprobe: ffprobe,
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

@MainActor
@ViewBuilder
func actionBar(
    isWorking: Bool,
    progress: Double?,
    buttonTitle: String,
    disabled: Bool,
    saved: URL? = nil,
    onRun: @escaping () -> Void,
    onStop: @escaping () -> Void
) -> some View {
    HStack(spacing: 12) {
        if isWorking {
            Button(L("Stop"), action: onStop)
            if let progress, progress > 0 {
                ProgressView(value: progress)
                    .frame(width: 180)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        } else {
            Button(buttonTitle, action: onRun)
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
        Spacer()
        if let saved, !isWorking {
            Label(L("Saved \(saved.lastPathComponent)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        }
    }
}
