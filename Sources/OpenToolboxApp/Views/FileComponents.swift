import AppKit
import CoreGraphics
import OpenToolboxCore
import SwiftUI
import UniformTypeIdentifiers

/// A CGImage that can cross into and out of background tasks. CGImage is immutable.
struct ImageBox: @unchecked Sendable {
    let cgImage: CGImage
}

/// Drop zone plus a removable list of chosen files.
struct FileDropList: View {
    @Binding var files: [URL]
    let allowedTypes: [UTType]
    var allowsMultiple = true
    var prompt: String = L("Drop files here")

    @State private var isImporterPresented = false
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(prompt).foregroundStyle(.secondary)
                    Button(allowsMultiple ? L("Choose Files…") : L("Choose File…")) { isImporterPresented = true }
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                List {
                    ForEach(files, id: \.self) { url in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                files.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(L("Remove from list"))
                        }
                    }
                    .onMove { source, destination in files.move(fromOffsets: source, toOffset: destination) }
                }
                .frame(minHeight: 110, maxHeight: 220)
                HStack {
                    Button(L("Add…")) { isImporterPresented = true }
                    Button(L("Clear")) { files = [] }
                    Spacer()
                    Text(L("\(files.count) files")).foregroundStyle(.secondary)
                }
            }
        }
        .padding(files.isEmpty ? 0 : 8)
        .background(
            (isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: files.isEmpty ? [5] : []))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(
            isPresented: $isImporterPresented, allowedContentTypes: allowedTypes, allowsMultipleSelection: allowsMultiple
        ) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private func add(_ urls: [URL]) {
        let acceptsAnyItem = allowedTypes.contains(.item)
        let accepted = urls.filter { url in
            guard url.isFileURL else { return false }
            if acceptsAnyItem { return true }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
                ?? UTType(filenameExtension: url.pathExtension)
            return allowedTypes.contains { type?.conforms(to: $0) ?? false }
        }
        if allowsMultiple {
            files.append(contentsOf: accepted.filter { !files.contains($0) })
        } else if let first = accepted.first {
            files = [first]
        }
    }
}

/// Outcome of processing one input file.
struct FileResult: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    let output: URL?
    let error: String?
}

/// Runs `work` for each file off the main actor, collecting outputs and errors.
func processFiles(
    _ files: [URL],
    work: @escaping @Sendable (URL) throws -> URL
) async -> [FileResult] {
    await Task.detached(priority: .userInitiated) {
        files.map { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                return FileResult(source: url, output: try work(url), error: nil)
            } catch {
                return FileResult(source: url, output: nil, error: error.localizedDescription)
            }
        }
    }.value
}

/// Summary of a batch with Show in Finder.
struct FileResultsView: View {
    let results: [FileResult]

    var body: some View {
        if !results.isEmpty {
            let outputs = results.compactMap(\.output)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if outputs.count == results.count {
                        Label(L("Saved \(outputs.count) files"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            L("Saved \(outputs.count) of \(results.count) files"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                    Spacer()
                    if !outputs.isEmpty {
                        Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                    }
                }
                ForEach(results.filter { $0.error != nil }) { result in
                    ErrorMessage(text: "\(result.source.lastPathComponent): \(result.error ?? "")")
                        .font(.callout)
                }
            }
        }
    }
}

/// Image preview over a checkerboard so transparency is visible.
struct ImagePreview: View {
    let image: CGImage

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .background(Checkerboard().clipped())
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 10
            for row in 0..<Int(size.height / tile + 1) {
                for column in 0..<Int(size.width / tile + 1) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)),
                        with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

/// Writes an image to the tool's dated output folder and returns its URL.
func saveImage(
    _ box: ImageBox, named baseName: String, format: ImageFormat = .png, output: OutputDirectory, tool: ToolID
) throws -> URL {
    try output.writeNewFile(for: tool, preferredName: "\(baseName).\(format.fileExtension)") {
        try ImageProcessor.write(box.cgImage, to: $0, format: format)
    }
}
