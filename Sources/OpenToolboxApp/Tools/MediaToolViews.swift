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

private func saveRecording(
    _ temporary: URL, named name: String, output: OutputDirectory, tool: ToolID
) -> (saved: URL?, failure: String?) {
    let outcome = RecordingStore.standard().publish(temporary, named: name, output: output, tool: tool)
    let folder = temporary.deletingLastPathComponent()
    switch outcome {
    case .saved(let url):
        try? FileManager.default.removeItem(at: folder)
        return (url, nil)
    case .kept(let url, let reason):
        guard url != temporary else {
            return (nil, L("The recording couldn't be saved: \(reason) It is still at \(url.path)."))
        }
        try? FileManager.default.removeItem(at: folder)
        return (nil, L("The recording couldn't be saved to the output folder: \(reason) It is kept below until you save it."))
    }
}

private struct UnsavedRecordingsView: View {
    static let tools: [ToolID] = ["media.record-screen", "media.record-audio"]

    let output: OutputDirectory
    @State private var recordings: [RecordingStore.Entry] = []
    @State private var failure: String?
    @State private var isConfirmingDiscard = false

    var body: some View {
        if !recordings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("\(recordings.count) recordings haven't been saved yet"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Button(L("Save to Output Folder"), action: saveAll)
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(recordings.map(\.url)) }
                    Button(L("Discard…"), role: .destructive) { isConfirmingDiscard = true }
                }
                if let failure { ErrorMessage(text: failure) }
            }
            .confirmationDialog(L("Discard \(recordings.count) unsaved recordings?"), isPresented: $isConfirmingDiscard) {
                Button(L("Discard"), role: .destructive, action: discardAll)
            } message: {
                Text(L("They are deleted and can't be recovered."))
            }
        }
        Color.clear.frame(height: 0)
            .onAppear(perform: reload)
            .onReceive(NotificationCenter.default.publisher(for: RecordingStore.didChange)) { _ in reload() }
    }

    private func reload() {
        recordings = RecordingStore.standard().recordings(of: Self.tools)
    }

    private func saveAll() {
        let store = RecordingStore.standard()
        var problems: [String] = []
        for entry in recordings {
            do {
                let result = try store.save(entry, output: output)
                if let cleanup = result.cleanupFailure {
                    problems.append(
                        L("\(result.url.lastPathComponent) was saved, but its kept copy couldn't be removed: \(cleanup)"))
                }
            } catch {
                problems.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        reload()
    }

    private func discardAll() {
        let store = RecordingStore.standard()
        var problems: [String] = []
        for entry in recordings {
            do {
                try store.discard(entry)
            } catch {
                problems.append("\(entry.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        failure = problems.isEmpty ? nil : problems.joined(separator: "\n")
        reload()
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


@MainActor
@Observable
final class ScreenRecorder: NSObject, SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate {
    enum Phase: Equatable {
        case idle
        case picking
        case starting
        case recording(since: Date)
        case finishing
    }

    var phase: Phase = .idle
    var showsCursor = true
    var capturesSystemAudio = true
    var capturesMicrophone = false
    var failure: String?
    var saved: URL?

    fileprivate static var active: Set<ScreenRecorder> = []
    @ObservationIgnored private var closeRequested = false

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recording: SCRecordingOutput?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var destination: (output: OutputDirectory, tool: ToolID)?

    var isBusy: Bool { phase != .idle }

    func choose(output: OutputDirectory, tool: ToolID) {
        failure = nil
        saved = nil
        closeRequested = false
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

    func close() {
        closeRequested = true
        switch phase {
        case .picking:
            endPicking()
            phase = .idle
        case .recording:
            stop()
        case .idle, .starting, .finishing:
            break
        }
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
            phase = .starting
            Self.active.insert(self)
            stream.startCapture { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.fail(error)
                    } else {
                        self.phase = .recording(since: Date())
                        if self.closeRequested { self.stop() }
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
        let result = saveRecording(
            temporary, named: recordingName("Screen Recording", extension: "mov"), output: destination.output,
            tool: destination.tool)
        saved = result.saved
        if let message = result.failure { failure = message }
    }

    private func fail(_ error: Error) {
        defer { reset() }
        failure = error.localizedDescription
        guard let temporary else { return }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, let destination else {
            try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
            return
        }
        let result = saveRecording(
            temporary, named: recordingName("Screen Recording", extension: "mov"), output: destination.output,
            tool: destination.tool)
        saved = result.saved
        failure = result.failure ?? L("Recording stopped early: \(error.localizedDescription) What was recorded was saved.")
    }

    private func reset() {
        stream = nil
        recording = nil
        temporary = nil
        phase = .idle
        Self.active.remove(self)
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
        Task { @MainActor in self.streamStopped(error) }
    }

    private func streamStopped(_ error: Error) {
        switch phase {
        case .recording, .finishing:
            phase = .finishing
            let stopped = (error as NSError).code == SCStreamError.Code.userStopped.rawValue
            if !stopped { failure = error.localizedDescription }
            Task {
                try? await Task.sleep(for: .seconds(5))
                if self.phase == .finishing { self.fail(error) }
            }
        case .starting:
            fail(error)
        case .idle, .picking:
            break
        }
    }

    static func stopAll() async {
        for recorder in active { recorder.close() }
        let deadline = Date().addingTimeInterval(10)
        while !active.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish() }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.fail(error) }
    }
}

enum RecordingSessions {
    @MainActor static var isRecording: Bool { !ScreenRecorder.active.isEmpty || !AudioRecorder.active.isEmpty }

    @MainActor static func stopAll() async {
        AudioRecorder.stopAll()
        await ScreenRecorder.stopAll()
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
                case .starting:
                    ProgressView().controlSize(.small)
                    Text(L("Starting…")).foregroundStyle(.secondary)
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
            UnsavedRecordingsView(output: model.outputDirectory)
            Text(L("macOS shows a recording indicator in the menu bar while OpenToolbox records."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onDisappear { recorder.close() }
        .reportsActivity(recorder.isBusy)
    }
}


@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    var since: Date?
    var isRequestingAccess = false
    var level: Float = 0
    var failure: String?
    var saved: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var destination: (output: OutputDirectory, tool: ToolID)?
    fileprivate static var active: Set<AudioRecorder> = []

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var meterTask: Task<Void, Never>?

    var isRecording: Bool { since != nil }

    var inputName: String? { AVCaptureDevice.default(for: .audio)?.localizedName }

    func requestStart(output: OutputDirectory, tool: ToolID) {
        let generation = self.generation
        Task { await start(generation, output: output, tool: tool) }
    }

    private func start(_ requested: Int, output: OutputDirectory, tool: ToolID) async {
        guard requested == generation, !isRequestingAccess, !isRecording else { return }
        failure = nil
        saved = nil
        isRequestingAccess = true
        let granted = await AVAudioApplication.requestRecordPermission()
        isRequestingAccess = false
        guard requested == generation else { return }
        guard granted else {
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
            destination = (output, tool)
            Self.active.insert(self)
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

    func close(output: OutputDirectory, tool: ToolID) {
        generation += 1
        if isRecording { stop(output: output, tool: tool) }
    }

    static func stopAll() {
        for recorder in active {
            guard let destination = recorder.destination else { continue }
            recorder.stop(output: destination.output, tool: destination.tool)
        }
    }

    func stop(output: OutputDirectory, tool: ToolID) {
        guard let recorder, let temporary else { return }
        recorder.stop()
        meterTask?.cancel()
        meterTask = nil
        self.recorder = nil
        self.temporary = nil
        Self.active.remove(self)
        since = nil
        level = 0
        let result = saveRecording(
            temporary, named: recordingName("Recording", extension: "m4a"), output: output, tool: tool)
        saved = result.saved
        if let message = result.failure { failure = message }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            guard let destination = self.destination else { return }
            self.stop(output: destination.output, tool: destination.tool)
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
                        recorder.requestStart(output: model.outputDirectory, tool: tool.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.isRequestingAccess)
                }
                Spacer()
                if let saved = recorder.saved, !recorder.isRecording {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure = recorder.failure { ErrorMessage(text: failure) }
            UnsavedRecordingsView(output: model.outputDirectory)
            Text(L("Recordings are saved as AAC audio in \(model.outputBaseDirectory.lastPathComponent)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onDisappear { recorder.close(output: model.outputDirectory, tool: tool.id) }
        .reportsActivity(recorder.isRecording)
    }
}


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
                    LabeledContent(L("Kept"), value: pendingRange.map { MediaTime.format($0.end - $0.start) } ?? "—")
                }
                .formStyle(.grouped)
                .frame(maxWidth: 620, maxHeight: 250)
            }
            if let failure { ErrorMessage(text: failure) }
            HStack {
                Button(player?.isPlaying == true ? L("Stop") : L("Play Selection"), action: togglePlayback)
                    .disabled(player?.isPlaying != true && pendingRange == nil)
                Button(L("Trim and Save"), action: run)
                    .buttonStyle(.borderedProminent)
                    .disabled(pendingRange == nil || isProcessing)
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
                        if let parsed = fieldValue(text.wrappedValue, current: value.wrappedValue) {
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

    private func fieldValue(_ text: String, current: Double) -> Double? {
        if text == MediaTime.format(current) { return current }
        guard let duration, let parsed = MediaTime.parse(text) else { return nil }
        return min(max(parsed, 0), duration)
    }

    private var pendingRange: (start: Double, end: Double)? {
        guard duration != nil, let first = fieldValue(startText, current: start),
            let last = fieldValue(endText, current: end), last > first
        else { return nil }
        return (first, last)
    }

    private func commitTimes() -> Bool {
        guard let range = pendingRange else {
            failure = L("Check the times: the end must come after the start, for example 0:05 to 1:30.")
            return false
        }
        start = range.start
        end = range.end
        startText = MediaTime.format(start)
        endText = MediaTime.format(end)
        failure = nil
        return true
    }

    private func togglePlayback() {
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
            return
        }
        guard commitTimes() else { return }
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
        guard commitTimes() else { return }
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
