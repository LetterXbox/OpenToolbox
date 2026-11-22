import AppKit
import OpenToolboxCore
import SwiftUI

/// Runs `work` off the main actor. Cancelling the calling task (for example a `.task(id:)`
/// whose input changed) cancels `work` too, so it can stop early via `Task.isCancelled`.
func runOffMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    let task = Task.detached(priority: .userInitiated) { work() }
    return await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Equality by exact UTF-8 bytes. Swift's `==` treats canonically equivalent strings
/// (`é` and `e` + combining acute) as equal even though their indices differ.
func sameBytes(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// Short pause before recomputing from typed input, so work runs once typing settles.
/// Returns `false` when the input changed again during the pause.
func debounce() async -> Bool {
    (try? await Task.sleep(for: .milliseconds(200))) != nil
}

/// Standard page layout for a tool: header plus content.
struct ToolPage<Content: View>: View {
    let tool: ToolDescriptor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbolName)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.localizedTitle).font(.title2.weight(.semibold))
                    Text(tool.localizedSummary).foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A titled region with an optional trailing accessory.
struct Pane<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory
            }
            content
        }
    }
}

extension Pane where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Editable monospaced text area.
struct CodeEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Read-only, selectable monospaced output.
struct CodeOutput: View {
    let text: String
    var placeholder: String = ""

    var body: some View {
        ScrollView {
            Group {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary)
                } else {
                    Text(text).textSelection(.enabled)
                }
            }
            .font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

struct CopyButton: View {
    let text: String
    var label: String? = nil

    var body: some View {
        Button {
            Clipboard.copy(text)
        } label: {
            Label(label ?? L("Copy"), systemImage: "doc.on.doc")
        }
        .disabled(text.isEmpty)
    }
}

/// Icon-only copy button for table rows.
struct InlineCopyButton: View {
    let text: String

    var body: some View {
        Button {
            Clipboard.copy(text)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L("Copy"))
        .disabled(text.isEmpty)
    }
}

struct ErrorMessage: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}

enum Clipboard {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func string() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
