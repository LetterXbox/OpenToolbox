import OpenToolboxCore
import SwiftUI

struct JWTDecoderView: View {
    let tool: ToolDescriptor
    @State private var token = ""

    private var decoded: Result<DecodedJWT, Error>? {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let token = self.token
        return Result { try JWTDecoder.decode(token) }
    }

    var body: some View {
        let decoded = self.decoded
        let jwt = try? decoded?.get()
        ToolPage(tool: tool) {
            Pane(L("Token")) {
                Button(L("Paste")) { token = Clipboard.string() ?? token }
            } content: {
                CodeEditor(text: $token)
                    .frame(minHeight: 80, maxHeight: 140)
            }

            if case .failure(let error)? = decoded {
                ErrorMessage(text: error.localizedDescription)
            }

            if let jwt {
                HStack(spacing: 12) {
                    if let algorithm = jwt.algorithm {
                        Badge(text: L("Algorithm: \(algorithm)"), tint: .blue)
                    }
                    switch jwt.validity() {
                    case .expired: Badge(text: L("Expired"), tint: .red)
                    case .notYetValid: Badge(text: L("Not yet valid"), tint: .orange)
                    case .invalidTimeClaim: Badge(text: L("Invalid exp or nbf claim"), tint: .orange)
                    case .valid: Badge(text: L("Not expired"), tint: .green)
                    case .noTimeLimit: EmptyView()
                    }
                    Label(L("Signature not verified"), systemImage: "exclamationmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(L("Decoding only reads the token. It does not prove who issued it."))
                    Spacer()
                }

                if !jwt.timeClaims.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(jwt.timeClaims) { claim in
                            GridRow {
                                Text(verbatim: claim.name)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(claim.date.formatted(date: .abbreviated, time: .standard))
                                Text(claim.date, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                Pane(L("Header")) {
                    CopyButton(text: jwt?.prettyHeader ?? "")
                } content: {
                    CodeOutput(text: jwt?.prettyHeader ?? "")
                }
                Pane(L("Payload")) {
                    CopyButton(text: jwt?.prettyPayload ?? "")
                } content: {
                    CodeOutput(text: jwt?.prettyPayload ?? "")
                }
            }
        }
    }
}
