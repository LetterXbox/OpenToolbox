import AVFoundation
import OpenToolboxCore
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

/// Carries a framework object that isn't marked Sendable across a callback boundary.
/// The object is only used again on the main actor.
private struct Handoff<Value>: @unchecked Sendable {
    let value: Value
}

private func temporaryFile(named name: String) throws -> URL {
    let folder = try FileManager.default.url(
        for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL.temporaryDirectory, create: true)
    return folder.appending(path: name)
}

/// Moves a finished recording into the output folder and removes its temporary folder.
private func publishRecording(_ temporary: URL, named name: String, output: OutputDirectory, tool: ToolID) throws -> URL {
    defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
    return try output.writeNewFile(for: tool, preferredName: name) {
        try FileManager.default.moveItem(at: temporary, to: $0)
    }
}

private func recordingName(_ prefix: String, extension ext: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return "\(prefix) \(formatter.string(from: Date())).\(ext)"
}

private struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.5)) { context in
            Text(MediaTime.format(context.date.timeIntervalSince(since).rounded(.down)))
                .font(.title2.monospacedDigit())
        }
    }
}

// MARK: - Record Screen

@MainActor
@Observable
final class ScreenRecorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    enum Phase: Equatable {
        case idle
        case picking
        case recording(since: Date)
        case finishing
    }

    var phase: Phase = .idle
    var showsCursor = true
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var failure: String?
    var saved: URL?

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recording: SCRecordingOutput?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var destination: (output: OutputDirectory, tool: ToolID)?

    var isBusy: Bool { phase != .idle }

    func choose(output: OutputDirectory, tool: ToolID) {
        failure = nil
        saved = nil
        destination = (output, tool)
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        phase = .picking
        picker.present()
    }

    func stop() {
        guard case .recording = phase, let stream else { return }
        phase = .finishing
        stream.stopCapture { [weak self] error in
            Task { @MainActor in
                if let error { self?.fail(error) }
            }
        }
    }

    private func endPicking() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func start(_ filter: SCContentFilter) {
        endPicking()
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int(filter.contentRect.width * scale) / 2 * 2)
        configuration.height = max(2, Int(filter.contentRect.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = capturesSystemAudio
        configuration.captureMicrophone = capturesMicrophone
        do {
            let url = try temporaryFile(named: "recording.mov")
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = url
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .hevc
            let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addRecordingOutput(recording)
            self.stream = stream
            self.recording = recording
            temporary = url
            stream.startCapture { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.fail(error)
                    } else {
                        self.phase = .recording(since: Date())
                    }
                }
            }
        } catch {
            fail(error)
        }
    }

    private func finish() {
        defer { reset() }
        guard let temporary, let destination else { return }
        do {
            saved = try publishRecording(
                temporary, named: recordingName("Screen Recording", extension: "mov"), output: destination.output,
                tool: destination.tool)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func fail(_ error: Error) {
        if let temporary { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        failure = error.localizedDescription
        reset()
    }

    private func reset() {
        stream = nil
        recording = nil
        temporary = nil
        phase = .idle
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?
    ) {
        let handoff = Handoff(value: filter)
        Task { @MainActor in
            guard self.phase == .picking else { return }
            self.start(handoff.value)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in
            guard self.phase == .picking else { return }
            self.endPicking()
            self.phase = .idle
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.endPicking()
            self.fail(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            if self.phase != .idle { self.fail(error) }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
}

struct RecordScreenView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var recorder = ScreenRecorder()

    var body: some View {
        @Bindable var recorder = recorder
        ToolPage(tool: tool) {
            Form {
                Toggle(L("Show the pointer"), isOn: $recorder.showsCursor)
                Toggle(L("Record sound from the Mac"), isOn: $recorder.capturesSystemAudio)
                Toggle(L("Record the microphone"), isOn: $recorder.capturesMicrophone)
            }
            .formStyle(.grouped)
            .frame(maxWidth: 480, maxHeight: 160)
            .disabled(recorder.isBusy)

            HStack(spacing: 12) {
                switch recorder.phase {
                case .idle:
                    Button(L("Choose What to Record…"), systemImage: "record.circle") {
                        recorder.choose(output: model.outputDirectory, tool: tool.id)
                    }
                    .buttonStyle(.borderedProminent)
                case .picking:
                    ProgressView().controlSize(.small)
                    Text(L("Choose a screen, window, or app to start recording.")).foregroundStyle(.secondary)
                case .recording(let since):
                    Button(L("Stop Recording"), systemImage: "stop.fill", action: recorder.stop)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    ElapsedText(since: since)
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text(L("Saving…")).foregroundStyle(.secondary)
                }
                Spacer()
                if let saved = recorder.saved, recorder.phase == .idle {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure = recorder.failure { ErrorMessage(text: failure) }
            Text(L("macOS shows a recording indicator in the menu bar while OpenToolbox records."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .reportsActivity(recorder.isBusy)
    }
}

// MARK: - Record Audio

@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    var since: Date?
    var level: Float = 0
    var failure: String?
    var saved: URL?

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    var isRecording: Bool { since != nil }

    var inputName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    func start() async {
        failure = nil
        saved = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            failure = L("Allow OpenToolbox in System Settings → Privacy & Security → Microphone to record.")
            return
        }
        do {
            let url = try temporaryFile(named: "recording.m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                failure = L("Recording couldn't start. Check that a microphone is connected.")
                return
            }
            self.recorder = recorder
            temporary = url
            since = Date()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.updateLevel()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func updateLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (power + 60) / 60))
    }

    func stop(output: OutputDirectory, tool: ToolID) {
        guard let recorder, let temporary else { return }
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        self.recorder = nil
        self.temporary = nil
        since = nil
        level = 0
        do {
            saved = try publishRecording(
                temporary, named: recordingName("Recording", extension: "m4a"), output: output, tool: tool)
        } catch {
            failure = error.localizedDescription
        }
    }

    func discard() {
        recorder?.stop()
        meterTask?.cancel()
        if let temporary { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        recorder = nil
        temporary = nil
        since = nil
        level = 0
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.discard()
            self.failure = message ?? L("Recording stopped because of an error.")
        }
    }
}

struct RecordAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var recorder = AudioRecorder()

    var body: some View {
        ToolPage(tool: tool) {
            if let name = recorder.inputName {
                LabeledContent(L("Microphone"), value: name)
                    .frame(maxWidth: 480)
            } else {
                Text(L("No microphone found. Connect one, or choose an input in System Settings → Sound."))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                if let since = recorder.since {
                    Button(L("Stop and Save"), systemImage: "stop.fill") {
                        recorder.stop(output: model.outputDirectory, tool: tool.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    ElapsedText(since: since)
                    ProgressView(value: Double(recorder.level))
                        .frame(width: 160)
                } else {
                    Button(L("Record"), systemImage: "record.circle") {
                        Task { await recorder.start() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
                if let saved = recorder.saved, !recorder.isRecording {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure = recorder.failure { ErrorMessage(text: failure) }
            Text(L("Recordings are saved as AAC audio in \(model.outputBaseDirectory.lastPathComponent)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onDisappear { if recorder.isRecording { recorder.stop(output: model.outputDirectory, tool: tool.id) } }
        .reportsActivity(recorder.isRecording)
    }
}

// MARK: - Trim Audio

struct TrimAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var duration: Double?
    @State private var start = 0.0
    @State private var end = 0.0
    @State private var startText = "0:00"
    @State private var endText = "0:00"
    @State private var player: AVAudioPlayer?
    @State private var isProcessing = false
    @State private var results: [FileResult] = []
    @State private var failure: String?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.audio], allowsMultiple: false, prompt: L("Drop an audio file"))
            if let duration {
                Form {
                    LabeledContent(L("Length"), value: MediaTime.format(duration))
                    timeRow(L("Start"), value: $start, text: $startText, range: 0...duration)
                    timeRow(L("End"), value: $end, text: $endText, range: 0...duration)
                    LabeledContent(L("Kept"), value: MediaTime.format(max(0, end - start)))
                }
                .formStyle(.grouped)
                .frame(maxWidth: 620, maxHeight: 250)
            }
            if let failure { ErrorMessage(text: failure) }
            HStack {
                Button(player?.isPlaying == true ? L("Stop") : L("Play Selection"), action: togglePlayback)
                    .disabled(duration == nil || end <= start)
                Button(L("Trim and Save"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(duration == nil || end <= start || isProcessing)
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Text(L("WAV, AIFF and CAF stay lossless; other formats are saved as AAC"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .onChange(of: files) { load() }
        .onDisappear { player?.stop() }
        .reportsActivity(isProcessing)
    }

    private func timeRow(_ title: String, value: Binding<Double>, text: Binding<String>, range: ClosedRange<Double>)
        -> some View
    {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range) { editing in
                    if !editing { text.wrappedValue = MediaTime.format(value.wrappedValue) }
                }
                TextField(title, text: text)
                    .labelsHidden()
                    .frame(width: 90)
                    .onSubmit {
                        if let parsed = MediaTime.parse(text.wrappedValue) {
                            value.wrappedValue = min(max(parsed, range.lowerBound), range.upperBound)
                        }
                        text.wrappedValue = MediaTime.format(value.wrappedValue)
                    }
            }
        }
    }

    private func load() {
        player?.stop()
        player = nil
        results = []
        failure = nil
        duration = nil
        guard let url = files.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let length = try AudioTrimmer.duration(of: url)
            duration = length
            start = 0
            end = length
            startText = MediaTime.format(0)
            endText = MediaTime.format(length)
        } catch {
            failure = error.localizedDescription
        }
    }

    private func togglePlayback() {
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
            return
        }
        guard let url = files.first, let audio = try? AVAudioPlayer(contentsOf: url) else { return }
        audio.currentTime = start
        audio.play()
        player = audio
        let stopAt = end, startedAt = start
        Task {
            try? await Task.sleep(for: .seconds(max(0, stopAt - startedAt)))
            if player === audio {
                audio.stop()
                player = nil
            }
        }
    }

    private func run() {
        let files = self.files, start = self.start, end = self.end
        let output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        Task {
            results = await processFiles(files) { url in
                try AudioTrimmer.trim(url, start: start, end: end, output: output, tool: toolID)
            }
            isProcessing = false
        }
    }
}

// MARK: - Extract Frames

struct ExtractFramesView: View {
    enum Mode: Hashable { case every, count, times }

    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var mode: Mode = .count
    @State private var interval = 5.0
    @State private var count = 10
    @State private var timesText = ""
    @State private var format: ImageFormat = .jpeg
    @State private var limitsSize = false
    @State private var longEdge = 1920
    @State private var isProcessing = false
    @State private var progress = 0.0
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    private var selection: FrameSelection? {
        switch mode {
        case .every: return interval > 0 ? .every(interval) : nil
        case .count: return count > 0 ? .count(count) : nil
        case .times:
            let parsed = timesText.split(whereSeparator: { $0 == "," || $0.isNewline }).map {
                MediaTime.parse(String($0))
            }
            guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
            return .times(parsed.compactMap { $0 })
        }
    }

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.movie], prompt: L("Drop videos here"))
            Form {
                Picker(L("Frames"), selection: $mode) {
                    Text(L("Spread evenly")).tag(Mode.count)
                    Text(L("Every few seconds")).tag(Mode.every)
                    Text(L("At set times")).tag(Mode.times)
                }
                switch mode {
                case .count:
                    Stepper(value: $count, in: 1...FrameExtractor.maximumFrames) { Text(L("\(count) frames")) }
                case .every:
                    LabeledContent(L("Every")) {
                        HStack {
                            TextField(L("Seconds"), value: $interval, format: .number).frame(width: 70)
                            Text(L("seconds")).foregroundStyle(.secondary)
                        }
                    }
                case .times:
                    TextField(L("Times"), text: $timesText, prompt: Text(verbatim: "0:05, 1:30, 2:10.5"))
                }
                Picker(L("Format"), selection: $format) {
                    ForEach([ImageFormat.jpeg, .png, .heic].filter { ImageFormat.writable.contains($0) }) { format in
                        Text(verbatim: format.displayName).tag(format)
                    }
                }
                Toggle(L("Limit the longest edge"), isOn: $limitsSize)
                if limitsSize {
                    TextField(L("Pixels"), value: $longEdge, format: .number)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 560, maxHeight: 280)

            HStack {
                if isProcessing {
                    Button(L("Stop")) { task?.cancel() }
                    ProgressView(value: progress).frame(width: 160)
                } else {
                    Button(L("Save Frames"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty || selection == nil)
                }
                Spacer()
                Text(L("Saved to \(model.outputBaseDirectory.lastPathComponent) · originals are not changed"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isProcessing)
    }

    private func run() {
        guard let selection else { return }
        let files = self.files, format = self.format, longEdge = limitsSize ? max(longEdge, 16) : nil
        let output = model.outputDirectory, toolID = tool.id
        isProcessing = true
        progress = 0
        results = []
        task = Task {
            defer { isProcessing = false }
            var collected: [FileResult] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let fileCount = Double(files.count)
                do {
                    let saved = try await FrameExtractor.extract(
                        url, selection: selection, format: format, longEdge: longEdge, output: output, tool: toolID
                    ) { fraction in
                        Task { @MainActor in progress = (Double(index) + fraction) / fileCount }
                    }
                    collected += saved.map { FileResult(source: url, output: $0, error: nil) }
                } catch is CancellationError {
                    break
                } catch {
                    collected.append(FileResult(source: url, output: nil, error: error.localizedDescription))
                }
            }
            results = collected
        }
    }
}
