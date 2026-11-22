import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

struct HashGeneratorView: View {
    enum Source: Hashable { case text, file }

    let tool: ToolDescriptor
    @State private var source: Source = .text
    @State private var text = ""
    @State private var fileURL: URL?
    @State private var fileHashes: [HashAlgorithm: String] = [:]
    @State private var fileError: String?
    @State private var isHashingFile = false
    @State private var isImporterPresented = false
    @State private var uppercase = false
    @State private var expected = ""

    private var hashes: [HashAlgorithm: String] {
        switch source {
        case .text:
            guard !text.isEmpty else { return [:] }
            let data = Data(text.utf8)
            return Dictionary(uniqueKeysWithValues: HashAlgorithm.allCases.map { ($0, HashGenerator.hash(data, algorithm: $0)) })
        case .file:
            return fileHashes
        }
    }

    var body: some View {
        let hashes = self.hashes
        ToolPage(tool: tool) {
            HStack(spacing: 16) {
                Picker(L("Source"), selection: $source) {
                    Text(L("Text")).tag(Source.text)
                    Text(L("File")).tag(Source.file)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle(L("Uppercase"), isOn: $uppercase)
                Spacer()
            }

            switch source {
            case .text:
                Pane(L("Text")) {
                    CodeEditor(text: $text)
                        .frame(minHeight: 120, maxHeight: 220)
                }
            case .file:
                fileDropZone
            }

            Pane(L("Digests")) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(HashAlgorithm.allCases) { algorithm in
                        let value = hashes[algorithm].map { uppercase ? $0.uppercased() : $0 } ?? ""
                        GridRow {
                            HStack(spacing: 4) {
                                Text(algorithm.displayName).fontWeight(.medium)
                                if algorithm.isCryptographicallyBroken {
                                    Image(systemName: "exclamationmark.shield")
                                        .foregroundStyle(.orange)
                                        .help(L("Fine for checksums, but not secure against deliberate tampering."))
                                }
                            }
                            Text(value.isEmpty ? "—" : value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(matchColor(value))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            InlineCopyButton(text: value)
                        }
                    }
                }
            }

            Pane(L("Compare")) {
                TextField(L("Paste an expected hash to compare"), text: $expected)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if !expected.trimmingCharacters(in: .whitespaces).isEmpty, !hashes.isEmpty {
                    if let match = hashes.first(where: { HashGenerator.matches($0.value, expected: expected) }) {
                        Label(L("Matches \(match.key.displayName)"), systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(L("No digest matches"), systemImage: "xmark.seal.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { hashFile(url) }
        }
    }

    private var fileDropZone: some View {
        VStack(spacing: 8) {
            if isHashingFile {
                ProgressView()
            } else if let fileURL {
                Label(fileURL.lastPathComponent, systemImage: "doc")
                    .font(.headline)
            } else {
                Image(systemName: "arrow.down.doc")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(L("Drop a file here"))
                    .foregroundStyle(.secondary)
            }
            Button(L("Choose File…")) { isImporterPresented = true }
            if let fileError {
                ErrorMessage(text: fileError)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.secondary)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            hashFile(url)
            return true
        }
    }

    private func matchColor(_ value: String) -> Color {
        guard !value.isEmpty, !expected.trimmingCharacters(in: .whitespaces).isEmpty else { return .primary }
        return HashGenerator.matches(value, expected: expected) ? .green : .primary
    }

    private func hashFile(_ url: URL) {
        fileURL = url
        fileHashes = [:]
        fileError = nil
        isHashingFile = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try HashGenerator.hashFile(at: url, algorithms: HashAlgorithm.allCases)
                }.value
                if fileURL == url { fileHashes = result }
            } catch {
                if fileURL == url { fileError = error.localizedDescription }
            }
            if fileURL == url { isHashingFile = false }
        }
    }
}
