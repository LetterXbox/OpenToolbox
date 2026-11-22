import AVFoundation
import OpenToolboxCore
import SwiftUI
@preconcurrency import Translation
import UniformTypeIdentifiers

/// A text area with a heading and an optional trailing control.
private struct TextPane<Accessory: View>: View {
    let title: String
    @Binding var text: String
    var isEditable = true
    @ViewBuilder var accessory: Accessory

    var body: some View {
        Pane(title, accessory: { accessory }) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .disabled(!isEditable)
        }
    }
}

private func languageName(_ language: Locale.Language) -> String {
    Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
        ?? Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
        ?? language.minimalIdentifier
}

// MARK: - Translate

struct TranslateView: View {
    let tool: ToolDescriptor
    @State private var input = ""
    @State private var output = ""
    @State private var source: Locale.Language?
    @State private var target = Locale.current.language
    @State private var languages: [Locale.Language] = []
    @State private var configuration: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var failure: String?
    @State private var note: String?

    var body: some View {
        ToolPage(tool: tool) {
            HStack {
                Picker(L("From"), selection: $source) {
                    Text(L("Detect language")).tag(Locale.Language?.none)
                    ForEach(languages, id: \.self) { language in
                        Text(languageName(language)).tag(Optional(language))
                    }
                }
                .frame(maxWidth: 260)
                Button(L("Swap"), systemImage: "arrow.left.arrow.right") {
                    guard let from = source else { return }
                    source = target
                    target = from
                    swap(&input, &output)
                }
                .labelStyle(.iconOnly)
                .disabled(source == nil)
                Picker(L("To"), selection: $target) {
                    ForEach(languages, id: \.self) { language in
                        Text(languageName(language)).tag(language)
                    }
                }
                .frame(maxWidth: 260)
                Spacer()
                Button(L("Translate"), action: translate)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTranslating)
                if isTranslating { ProgressView().controlSize(.small) }
            }
            if let failure { ErrorMessage(text: failure) }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                TextPane(title: L("Text"), text: $input) {
                    Button(L("Clear")) {
                        input = ""
                        output = ""
                    }
                    .buttonStyle(.borderless)
                }
                TextPane(title: L("Translation"), text: $output) {
                    Button(L("Copy")) { Clipboard.copy(output) }
                        .buttonStyle(.borderless)
                        .disabled(output.isEmpty)
                }
            }
            Text(L("Translation runs on this Mac. macOS may download a language the first time you use it."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .task {
            let supported = await TranslationLanguages.supported()
            languages = supported.sorted { languageName($0) < languageName($1) }
            if !languages.contains(target), let english = languages.first(where: { $0.minimalIdentifier == "en" }) {
                target = english
            }
        }
        .translationTask(configuration) { session in
            await run(session)
        }
        .reportsActivity(isTranslating)
    }

    private func translate() {
        failure = nil
        note = nil
        isTranslating = true
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    private func run(_ session: TranslationSession) async {
        do {
            let (text, detected) = try await Self.translate(input, with: session)
            output = text
            if source == nil, let detected { note = L("Detected \(languageName(detected)).") }
        } catch {
            failure = L("The text couldn't be translated: \(error.localizedDescription)")
        }
        isTranslating = false
    }

    /// Translates paragraph by paragraph so blank lines between them are kept.
    @concurrent
    nonisolated private static func translate(_ input: String, with session: TranslationSession) async throws
        -> (String, Locale.Language?)
    {
        let paragraphs = input.components(separatedBy: "\n\n")
        let requests = paragraphs.enumerated().compactMap { index, paragraph in
            paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : TranslationSession.Request(sourceText: paragraph, clientIdentifier: String(index))
        }
        let responses = try await session.translations(from: requests)
        var translated = paragraphs.map { _ in "" }
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id), translated.indices.contains(index) {
                translated[index] = response.targetText
            }
        }
        return (translated.joined(separator: "\n\n"), responses.first?.sourceLanguage)
    }
}

// MARK: - Text to Speech

@MainActor
@Observable
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, voice: String?, rate: Float) {
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(SpeechSynthesis.utterance(text, voice: voice, rate: rate))
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

struct TextToSpeechView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var text = ""
    @State private var voices: [SpeechVoice] = []
    @State private var voice: String?
    @State private var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @State private var player = SpeechPlayer()
    @State private var isSaving = false
    @State private var saved: URL?
    @State private var failure: String?

    var body: some View {
        ToolPage(tool: tool) {
            HStack {
                Picker(L("Voice"), selection: $voice) {
                    ForEach(voices) { voice in
                        Text(verbatim: "\(voice.name) — \(voice.languageName)\(voice.isEnhanced ? " ★" : "")")
                            .tag(Optional(voice.id))
                    }
                }
                .frame(maxWidth: 380)
                LabeledContent(L("Speed")) {
                    Slider(
                        value: $rate,
                        in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)
                    )
                    .frame(width: 160)
                }
                Spacer()
            }
            TextPane(title: L("Text"), text: $text) { EmptyView() }
            HStack {
                Button(player.isSpeaking ? L("Stop") : L("Speak"), systemImage: player.isSpeaking ? "stop.fill" : "play.fill") {
                    if player.isSpeaking {
                        player.stop()
                    } else {
                        player.speak(text, voice: voice, rate: Float(rate))
                    }
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L("Save as Audio"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                if let saved {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                }
            }
            if let failure { ErrorMessage(text: failure) }
            Text(L("More voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            guard voices.isEmpty else { return }
            voices = SpeechSynthesis.voices()
            voice = SpeechSynthesis.defaultVoiceID() ?? voices.first?.id
        }
        .onDisappear { player.stop() }
        .reportsActivity(isSaving)
    }

    private func save() {
        let text = self.text, voice = self.voice, rate = Float(self.rate)
        let output = model.outputDirectory, toolID = tool.id
        isSaving = true
        failure = nil
        saved = nil
        Task {
            defer { isSaving = false }
            do {
                let folder = try FileManager.default.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL.temporaryDirectory,
                    create: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let temporary = folder.appending(path: "speech.m4a")
                try await SpeechSynthesis.export(text, voice: voice, rate: rate, to: temporary)
                let name = String(text.prefix(40)).components(separatedBy: .newlines).first ?? ""
                saved = try output.writeNewFile(for: toolID, preferredName: (name.isEmpty ? "Speech" : name) + ".m4a") {
                    try FileManager.default.copyItem(at: temporary, to: $0)
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Transcribe

struct TranscribeView: View {
    @Environment(AppModel.self) private var model
    let tool: ToolDescriptor
    @State private var files: [URL] = []
    @State private var locales: [Locale] = []
    @State private var localeID = Locale.current.identifier
    @State private var format: TranscriptFormat = .text
    @State private var isWorking = false
    @State private var progress = ""
    @State private var transcript = ""
    @State private var results: [FileResult] = []
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            FileDropList(files: $files, allowedTypes: [.audio, .movie], prompt: L("Drop audio or video files"))
            HStack {
                Picker(L("Language"), selection: $localeID) {
                    ForEach(locales, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                .frame(maxWidth: 320)
                Picker(L("Save as"), selection: $format) {
                    Text(L("Text")).tag(TranscriptFormat.text)
                    Text(L("Subtitles (SRT)")).tag(TranscriptFormat.srt)
                    Text(L("Subtitles (WebVTT)")).tag(TranscriptFormat.vtt)
                }
                .fixedSize()
                Spacer()
            }
            HStack {
                if isWorking {
                    Button(L("Stop")) { task?.cancel() }
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                } else {
                    Button(L("Transcribe \(files.count) Files"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(files.isEmpty)
                }
                Spacer()
                Text(L("Audio stays on this Mac"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            FileResultsView(results: results)
            if !transcript.isEmpty {
                TextPane(title: L("Transcript"), text: $transcript, isEditable: false) {
                    Button(L("Copy")) { Clipboard.copy(transcript) }.buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            guard locales.isEmpty else { return }
            locales = Transcriber.supportedLocales()
            if !locales.contains(where: { $0.identifier == localeID }) {
                let language = Locale.current.language.languageCode?.identifier
                localeID =
                    locales.first { $0.language.languageCode?.identifier == language }?.identifier
                    ?? locales.first?.identifier ?? localeID
            }
        }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func run() {
        let files = self.files, format = self.format, locale = Locale(identifier: localeID)
        let output = model.outputDirectory, toolID = tool.id
        isWorking = true
        results = []
        transcript = ""
        task = Task {
            defer { isWorking = false }
            guard await Transcriber.requestAuthorization() else {
                results = files.map {
                    FileResult(source: $0, output: nil, error: TranscriptionError.notAuthorized.localizedDescription)
                }
                return
            }
            var collected: [FileResult] = []
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                progress = L("File \(index + 1) of \(files.count)")
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do {
                    let segments = try await Transcriber.transcribe(url, locale: locale)
                    let text = Transcript.render(segments, as: format)
                    let saved = try output.writeOutput(forSource: url, tool: toolID, newExtension: format.fileExtension) {
                        try Data(text.utf8).write(to: $0)
                    }
                    transcript = Transcript.render(segments, as: .text)
                    collected.append(FileResult(source: url, output: saved, error: nil))
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

// MARK: - Summarize

struct SummarizeView: View {
    let tool: ToolDescriptor
    @State private var input = ""
    @State private var summary = ""
    @State private var style: SummaryStyle = .paragraph
    @State private var isWorking = false
    @State private var failure: String?
    @State private var availability = Summarizer.availability
    @State private var isImporterPresented = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        ToolPage(tool: tool) {
            if let message = availability.message {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker(L("Style"), selection: $style) {
                    Text(L("Paragraph")).tag(SummaryStyle.paragraph)
                    Text(L("Bullet points")).tag(SummaryStyle.bullets)
                    Text(L("One sentence")).tag(SummaryStyle.oneLine)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Button(L("Open Document…")) { isImporterPresented = true }
                Spacer()
                if isWorking {
                    Button(L("Stop")) { task?.cancel() }
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("Summarize"), action: run)
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || availability != .available)
                }
            }
            if let failure { ErrorMessage(text: failure) }
            HStack(spacing: 14) {
                TextPane(title: L("Text"), text: $input) {
                    Text(L("\(input.count) characters")).font(.callout).foregroundStyle(.secondary)
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    load(url)
                    return true
                }
                TextPane(title: L("Summary"), text: $summary) {
                    Button(L("Copy")) { Clipboard.copy(summary) }
                        .buttonStyle(.borderless)
                        .disabled(summary.isEmpty)
                }
            }
            Text(L("Summaries are written on this Mac by Apple Intelligence and can contain mistakes."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: DocumentText.readableTypes) { result in
            if case .success(let url) = result { load(url) }
        }
        .onAppear { availability = Summarizer.availability }
        .onDisappear { task?.cancel() }
        .reportsActivity(isWorking)
    }

    private func load(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            input = try DocumentText.read(url)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func run() {
        let text = input, style = self.style
        isWorking = true
        failure = nil
        task = Task {
            defer { isWorking = false }
            do {
                summary = try await Summarizer.summarize(text, style: style)
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
