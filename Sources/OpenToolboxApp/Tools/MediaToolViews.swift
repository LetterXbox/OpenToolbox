import AVFoundation
import Combine
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

private func recordingSize(_ url: URL) throws -> Int? {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
}

private func isMissing(_ error: Error) -> Bool {
    let error = error as NSError
    switch error.domain {
    case NSCocoaErrorDomain:
        return error.code == CocoaError.fileReadNoSuchFile.rawValue || error.code == CocoaError.fileNoSuchFile.rawValue
    case NSPOSIXErrorDomain:
        return error.code == Int(ENOENT)
    default:
        return false
    }
}

private func removeIfEmpty(
    _ recording: URL, fileSize: (URL) throws -> Int? = recordingSize, removesFolder: Bool = true
) -> Bool {
    let isEmpty: Bool
    do {
        isEmpty = try fileSize(recording) == 0
        if isEmpty { try? FileManager.default.removeItem(at: recording) }
    } catch {
        isEmpty = isMissing(error)
    }
    if isEmpty, removesFolder { rmdir(recording.deletingLastPathComponent().path) }
    return isEmpty
}

private func saveRecording(
    _ temporary: URL, named name: String, output: OutputDirectory, tool: ToolID, store: RecordingStore,
    inStore: Bool
) -> (saved: URL?, failure: String?) {
    let outcome = store.publish(temporary, named: name, output: output, tool: tool)
    let folder = temporary.deletingLastPathComponent()
    switch outcome {
    case .saved(let url):
        if !inStore { rmdir(folder.path) }
        return (url, nil)
    case .kept(let url, let reason):
        guard url != temporary || inStore else {
            return (nil, L("The recording couldn't be saved: \(reason) It is still at \(url.path)."))
        }
        if !inStore { rmdir(folder.path) }
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
            }
            .confirmationDialog(L("Discard \(recordings.count) unsaved recordings?"), isPresented: $isConfirmingDiscard) {
                Button(L("Discard"), role: .destructive, action: discardAll)
            } message: {
                Text(L("They are deleted and can't be recovered."))
            }
        }
        if let failure { ErrorMessage(text: failure) }
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
    var isSlowToFinish = false

    fileprivate static var active: Set<ScreenRecorder> = []
    @ObservationIgnored private var closeRequested = false
    @ObservationIgnored private var session = 0

    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recording: SCRecordingOutput?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var capture: RecordingStore.Capture?
    @ObservationIgnored private var destination: (output: OutputDirectory, tool: ToolID)?

    init(store: RecordingStore = .standard()) {
        self.store = store
        super.init()
    }

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
        beginFinishing()
        let session = self.session
        stream.stopCapture { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.beginFinishing()
            }
        }
    }

    private func beginFinishing() {
        guard phase != .finishing else { return }
        phase = .finishing
        let session = self.session
        Task {
            try? await Task.sleep(for: .seconds(30))
            if self.session == session, self.phase == .finishing { self.isSlowToFinish = true }
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
            capture = destination.flatMap { store.beginCapture(for: $0.tool, extension: "mov") }
            let url = try capture?.url ?? temporaryFile(named: "recording.mov")
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = url
            recordingConfiguration.outputFileType = .mov
            recordingConfiguration.videoCodecType = .hevc
            let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addRecordingOutput(recording)
            session += 1
            self.stream = stream
            self.recording = recording
            temporary = url
            phase = .starting
            Self.active.insert(self)
            let session = self.session
            stream.startCapture { [weak self] error in
                Task { @MainActor in
                    guard let self, self.session == session else { return }
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
            tool: destination.tool, store: store, inStore: capture != nil)
        saved = result.saved
        if let message = result.failure {
            failure = message
            if closeRequested { RecordingSessions.reportUnsaved(destination.tool, message) }
        }
    }

    private func fail(_ error: Error) {
        defer { reset() }
        failure = error.localizedDescription
        guard let temporary, !removeIfEmpty(temporary, removesFolder: capture == nil), let destination else { return }
        let result = saveRecording(
            temporary, named: recordingName("Screen Recording", extension: "mov"), output: destination.output,
            tool: destination.tool, store: store, inStore: capture != nil)
        saved = result.saved
        failure = result.failure ?? L("Recording stopped early: \(error.localizedDescription) What was recorded was saved.")
        if closeRequested, let message = result.failure { RecordingSessions.reportUnsaved(destination.tool, message) }
    }

    private func reset() {
        session += 1
        isSlowToFinish = false
        stream = nil
        recording = nil
        temporary = nil
        if let capture { store.endCapture(capture) }
        capture = nil
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
            guard self.phase == .picking else { return }
            self.endPicking()
            self.fail(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let source = ObjectIdentifier(stream)
        Task { @MainActor in
            guard let current = self.stream, ObjectIdentifier(current) == source else { return }
            self.streamStopped(error)
        }
    }

    private func streamStopped(_ error: Error) {
        switch phase {
        case .recording, .finishing:
            let stopped = (error as NSError).code == SCStreamError.Code.userStopped.rawValue
            if !stopped { failure = error.localizedDescription }
            beginFinishing()
        case .starting:
            fail(error)
        case .idle, .picking:
            break
        }
    }

    static func stopAll() async -> Bool {
        for recorder in active { recorder.close() }
        let deadline = Date().addingTimeInterval(10)
        while !active.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return active.isEmpty
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let source = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard let current = self.recording, ObjectIdentifier(current) == source else { return }
            self.finish()
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let source = ObjectIdentifier(recordingOutput)
        Task { @MainActor in
            guard let current = self.recording, ObjectIdentifier(current) == source else { return }
            self.fail(error)
        }
    }
}

enum RecordingSessions {
    @MainActor static var isRecording: Bool { !ScreenRecorder.active.isEmpty || !AudioRecorder.active.isEmpty }

    /// Tells the user about a recording that wasn't saved to the output folder after its tool was closed.
    @MainActor static var onUnsaved: ((ToolID, String) -> Void)?

    @MainActor static func reportUnsaved(_ tool: ToolID, _ message: String) {
        onUnsaved?(tool, message)
    }

    @MainActor static func stopAll() async -> Bool {
        async let audio = AudioRecorder.stopAll()
        let screen = await ScreenRecorder.stopAll()
        return await audio && screen
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
                    Text(
                        recorder.isSlowToFinish
                            ? L("macOS is still finishing the recording. It will be saved when macOS is done.")
                            : L("Saving…")
                    )
                    .foregroundStyle(.secondary)
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


struct Microphone: Identifiable, Hashable {
    let id: String
    let name: String

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
@Observable
final class AudioRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case finishing
    }

    static let microphoneKey = "RecordAudioMicrophone"

    var phase: Phase = .idle
    var level: Float = 0
    var failure: String?
    var saved: URL?
    var microphones: [Microphone] = []
    var defaultMicrophone: Microphone?
    var chosenMicrophone: String? {
        didSet { defaults.set(chosenMicrophone, forKey: Self.microphoneKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var destination: (output: OutputDirectory, tool: ToolID)?
    private(set) static var active: Set<AudioRecorder> = []

    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var audioOutput: AVCaptureAudioFileOutput?
    @ObservationIgnored private var temporary: URL?
    @ObservationIgnored private var capture: RecordingStore.Capture?
    @ObservationIgnored private var closedWhileRecording = false
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored var fileSize: (URL) throws -> Int? = recordingSize

    init(defaults: UserDefaults = .standard, store: RecordingStore = .standard()) {
        self.defaults = defaults
        self.store = store
        chosenMicrophone = defaults.string(forKey: Self.microphoneKey)
        super.init()
        refreshMicrophones()
    }

    var isBusy: Bool { phase != .idle }

    var since: Date? {
        if case .recording(let since) = phase { since } else { nil }
    }

    var selection: String? {
        get { MicrophoneChoice.selection(chosen: chosenMicrophone, connected: microphones.map(\.id)) }
        set { chosenMicrophone = newValue }
    }

    var isChosenMicrophoneMissing: Bool { chosenMicrophone != nil && selection == nil }

    func refreshMicrophones() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        microphones = discovery.devices.map(Microphone.init)
        defaultMicrophone = AVCaptureDevice.default(for: .audio).map(Microphone.init)
    }

    func requestStart(output: OutputDirectory, tool: ToolID) {
        guard phase == .idle else { return }
        failure = nil
        saved = nil
        phase = .starting
        Self.active.insert(self)
        let generation = self.generation
        Task { await start(generation, output: output, tool: tool) }
    }

    private func abandonStart(_ message: String) {
        failure = message
        phase = .idle
        Self.active.remove(self)
    }

    private func start(_ requested: Int, output: OutputDirectory, tool: ToolID) async {
        guard requested == generation else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard requested == generation else { return }
        guard granted else {
            abandonStart(L("Allow OpenToolbox in System Settings → Privacy & Security → Microphone to record."))
            return
        }
        refreshMicrophones()
        guard !microphones.isEmpty else {
            abandonStart(L("No microphone found. Connect one, or choose an input in System Settings → Sound."))
            return
        }
        guard
            let id = MicrophoneChoice.device(
                chosen: chosenMicrophone, connected: microphones.map(\.id), systemDefault: defaultMicrophone?.id),
            let device = AVCaptureDevice(uniqueID: id)
        else {
            abandonStart(L("macOS has no default microphone right now. Choose one from the Microphone menu."))
            return
        }
        let session = AVCaptureSession()
        let fileOutput = AVCaptureAudioFileOutput()
        fileOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ]
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(fileOutput) else {
                abandonStart(L("Recording couldn't start. Check that a microphone is connected."))
                return
            }
            session.addInput(input)
            session.addOutput(fileOutput)
        } catch {
            abandonStart(error.localizedDescription)
            return
        }
        let handoff = Handoff(value: session)
        await Task.detached { handoff.value.startRunning() }.value
        guard requested == generation else {
            Self.stopRunning(session)
            return
        }
        guard session.isRunning else {
            Self.stopRunning(session)
            abandonStart(L("Recording couldn't start. Check that a microphone is connected."))
            return
        }
        let capture = store.beginCapture(for: tool, extension: "m4a")
        let url: URL
        do {
            url = try capture?.url ?? temporaryFile(named: "recording.m4a")
        } catch {
            Self.stopRunning(session)
            abandonStart(error.localizedDescription)
            return
        }
        adopt(fileOutput, session: session, temporary: url, capture: capture, destination: (output, tool))
        fileOutput.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateLevel()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func adopt(
        _ output: AVCaptureAudioFileOutput, session: AVCaptureSession?, temporary: URL,
        capture: RecordingStore.Capture? = nil, destination: (output: OutputDirectory, tool: ToolID)
    ) {
        self.session = session
        audioOutput = output
        self.temporary = temporary
        self.capture = capture
        self.destination = destination
        Self.active.insert(self)
        phase = .recording(since: Date())
    }

    private func updateLevel() {
        guard let channels = audioOutput?.connections.first?.audioChannels, !channels.isEmpty else { return }
        let power = channels.map(\.averagePowerLevel).max() ?? -60
        level = max(0, min(1, (power + 60) / 60))
    }

    func close() {
        generation += 1
        if phase == .starting {
            phase = .idle
            Self.active.remove(self)
        } else {
            if phase != .idle { closedWhileRecording = true }
            stop()
        }
    }

    func stop() {
        guard case .recording = phase, let audioOutput else { return }
        phase = .finishing
        meterTask?.cancel()
        meterTask = nil
        level = 0
        audioOutput.stopRecording()
    }

    private func finish(problem: String?) {
        defer { reset() }
        guard let temporary, let destination else { return }
        guard !removeIfEmpty(temporary, fileSize: fileSize, removesFolder: capture == nil) else {
            failure = problem.map { L("Recording failed: \($0)") } ?? L("Nothing was recorded.")
            return
        }
        let result = saveRecording(
            temporary, named: recordingName("Recording", extension: "m4a"), output: destination.output,
            tool: destination.tool, store: store, inStore: capture != nil)
        saved = result.saved
        if let message = result.failure {
            failure = [problem, message].compactMap { $0 }.joined(separator: " ")
            if closedWhileRecording { RecordingSessions.reportUnsaved(destination.tool, message) }
        } else if let problem {
            failure = L("Recording stopped early: \(problem) What was recorded was saved.")
        }
    }

    private func reset() {
        if let session { Self.stopRunning(session) }
        session = nil
        audioOutput = nil
        temporary = nil
        if let capture { store.endCapture(capture) }
        capture = nil
        closedWhileRecording = false
        destination = nil
        meterTask?.cancel()
        meterTask = nil
        level = 0
        phase = .idle
        Self.active.remove(self)
    }

    private static func stopRunning(_ session: AVCaptureSession) {
        let handoff = Handoff(value: session)
        Task.detached { handoff.value.stopRunning() }
    }

    static func stopAll() async -> Bool {
        for recorder in Array(active) { recorder.close() }
        let deadline = Date().addingTimeInterval(10)
        while !active.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return active.isEmpty
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let source = ObjectIdentifier(output)
        let problem = error?.localizedDescription
        Task { @MainActor in self.finished(source, problem: problem) }
    }

    func finished(_ source: ObjectIdentifier, problem: String?) {
        guard let audioOutput, ObjectIdentifier(audioOutput) == source else { return }
        finish(problem: problem)
    }
}

struct RecordAudioView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var recorder = AudioRecorder()

    private var deviceChanges: some Publisher<Notification, Never> {
        let center = NotificationCenter.default
        return center.publisher(for: AVCaptureDevice.wasConnectedNotification)
            .merge(with: center.publisher(for: AVCaptureDevice.wasDisconnectedNotification))
            .merge(with: center.publisher(for: NSApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)
    }

    var body: some View {
        @Bindable var recorder = recorder
        ToolPage(tool: tool) {
            if recorder.microphones.isEmpty {
                Text(L("No microphone found. Connect one, or choose an input in System Settings → Sound."))
                    .foregroundStyle(.secondary)
            } else {
                Picker(L("Microphone"), selection: $recorder.selection) {
                    Text(recorder.defaultMicrophone.map { L("System Default (\($0.name))") } ?? L("System Default"))
                        .tag(String?.none)
                    Divider()
                    ForEach(recorder.microphones) { microphone in
                        Text(microphone.name).tag(String?.some(microphone.id))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(recorder.isBusy)
                if recorder.isChosenMicrophoneMissing {
                    Text(
                        recorder.defaultMicrophone == nil
                            ? L("The microphone you chose isn't connected. Choose another one.")
                            : L("The microphone you chose isn't connected, so the system default is used."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 14) {
                switch recorder.phase {
                case .idle, .starting:
                    Button(L("Record"), systemImage: "record.circle") {
                        recorder.requestStart(output: model.outputDirectory, tool: tool.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.phase == .starting)
                case .recording(let since):
                    Button(L("Stop and Save"), systemImage: "stop.fill", action: recorder.stop)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    ElapsedText(since: since)
                    ProgressView(value: Double(recorder.level))
                        .frame(width: 160)
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
            Text(L("Recordings are saved as AAC audio in \(model.outputBaseDirectory.lastPathComponent)."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onReceive(deviceChanges) { _ in recorder.refreshMicrophones() }
        .onDisappear { recorder.close() }
        .reportsActivity(recorder.isBusy)
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
                Text(L("WAV, AIFF and CAF keep their format and encoding; other formats are saved as AAC"))
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
