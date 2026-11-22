import Foundation
import PDFKit

public enum PDFPasswordError: Error, Equatable, LocalizedError {
    case emptyPassword
    case passwordsDiffer
    case notProtected(String)
    case wrongPassword(String)
    case needsOwnerPassword(String)

    public var errorDescription: String? {
        switch self {
        case .emptyPassword: coreLocalized("Enter a password.")
        case .passwordsDiffer: coreLocalized("The passwords don't match.")
        case .notProtected(let name): coreLocalized("“\(name)” has no password.")
        case .wrongPassword(let name): coreLocalized("The password for “\(name)” is not correct.")
        case .needsOwnerPassword(let name):
            coreLocalized("“\(name)” opened, but removing its restrictions needs the owner password.")
        }
    }
}

public struct PDFProtection: Equatable, Sendable {
    /// Needed to open the PDF.
    public var openPassword: String
    /// Needed to change the restrictions. When empty, the open password is used.
    public var ownerPassword: String
    public var allowsPrinting: Bool
    public var allowsCopying: Bool
    public var allowsEditing: Bool

    public init(
        openPassword: String, ownerPassword: String = "", allowsPrinting: Bool = true, allowsCopying: Bool = true,
        allowsEditing: Bool = true
    ) {
        self.openPassword = openPassword
        self.ownerPassword = ownerPassword
        self.allowsPrinting = allowsPrinting
        self.allowsCopying = allowsCopying
        self.allowsEditing = allowsEditing
    }

    /// PDFKit imports the permission flags as an enumeration, so they are combined as raw bits.
    var permissions: UInt {
        var granted: [PDFAccessPermissions] = [.allowsContentAccessibility]
        if allowsPrinting { granted += [.allowsLowQualityPrinting, .allowsHighQualityPrinting] }
        if allowsCopying { granted.append(.allowsContentCopying) }
        if allowsEditing {
            granted += [.allowsDocumentChanges, .allowsDocumentAssembly, .allowsCommenting, .allowsFormFieldEntry]
        }
        return granted.reduce(0) { $0 | $1.rawValue }
    }
}

/// Adds and removes PDF passwords. Results are new files; inputs are not modified.
public enum PDFSecurity {
    public static func protect(_ source: URL, with protection: PDFProtection, output: OutputDirectory, tool: ToolID)
        throws -> URL
    {
        guard !protection.openPassword.isEmpty else { throw PDFPasswordError.emptyPassword }
        let document = try PDFTools.open(source)
        let owner = protection.ownerPassword.isEmpty ? protection.openPassword : protection.ownerPassword
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: protection.openPassword,
            .ownerPasswordOption: owner,
            .accessPermissionsOption: protection.permissions,
        ]
        let base = source.deletingPathExtension().lastPathComponent
        return try output.writeNewFile(for: tool, preferredName: base + " protected.pdf") { url in
            guard document.pageCount > 0 else { throw PDFToolError.empty }
            guard document.write(to: url, withOptions: options) else { throw PDFToolError.writeFailed }
        }
    }

    /// Writes an unprotected copy. A PDF that only restricts printing or copying needs its owner password.
    public static func removePassword(_ source: URL, password: String, output: OutputDirectory, tool: ToolID) throws
        -> URL
    {
        let name = source.lastPathComponent
        guard let document = PDFDocument(url: source) else { throw PDFToolError.unreadable(name) }
        guard document.isEncrypted else { throw PDFPasswordError.notProtected(name) }
        guard !password.isEmpty else { throw PDFPasswordError.emptyPassword }
        guard document.unlock(withPassword: password) else { throw PDFPasswordError.wrongPassword(name) }
        guard document.permissionsStatus == .owner || !hasRestrictions(document) else {
            throw PDFPasswordError.needsOwnerPassword(name)
        }
        let copy = PDFTools.extract(Array(0..<document.pageCount), from: document)
        if let attributes = document.documentAttributes { copy.documentAttributes = attributes }
        let base = source.deletingPathExtension().lastPathComponent
        return try output.writeNewFile(for: tool, preferredName: base + " unlocked.pdf") {
            try PDFTools.write(copy, to: $0)
        }
    }

    static func hasRestrictions(_ document: PDFDocument) -> Bool {
        !(document.allowsPrinting && document.allowsCopying && document.allowsDocumentChanges
            && document.allowsDocumentAssembly && document.allowsCommenting && document.allowsFormFieldEntry)
    }
}
