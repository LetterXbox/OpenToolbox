import Foundation

public enum PrivacyPermissionError: Error, Equatable, LocalizedError {
    case notAnApp(String)
    case invalidIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .notAnApp(let name): coreLocalized("“\(name)” is not an app with a bundle identifier.")
        case .invalidIdentifier(let identifier): coreLocalized("“\(identifier)” is not a valid bundle identifier.")
        }
    }
}

/// A privacy permission that `tccutil` can reset.
public struct PrivacyService: Hashable, Sendable, Identifiable {
    /// The name `tccutil` uses.
    public let id: String
    public let titleKey: String

    public var localizedTitle: String { coreLocalized(dynamicKey: titleKey) }

    public static let all = PrivacyService(id: "All", titleKey: "All permissions")

    public static let services: [PrivacyService] = [
        all,
        PrivacyService(id: "Accessibility", titleKey: "Accessibility"),
        PrivacyService(id: "AppleEvents", titleKey: "Automation"),
        PrivacyService(id: "Calendar", titleKey: "Calendars"),
        PrivacyService(id: "Camera", titleKey: "Camera"),
        PrivacyService(id: "AddressBook", titleKey: "Contacts"),
        PrivacyService(id: "SystemPolicyDesktopFolder", titleKey: "Desktop Folder"),
        PrivacyService(id: "SystemPolicyDocumentsFolder", titleKey: "Documents Folder"),
        PrivacyService(id: "SystemPolicyDownloadsFolder", titleKey: "Downloads Folder"),
        PrivacyService(id: "SystemPolicyAllFiles", titleKey: "Full Disk Access"),
        PrivacyService(id: "ListenEvent", titleKey: "Input Monitoring"),
        PrivacyService(id: "MediaLibrary", titleKey: "Media & Apple Music"),
        PrivacyService(id: "Microphone", titleKey: "Microphone"),
        PrivacyService(id: "SystemPolicyNetworkVolumes", titleKey: "Network Volumes"),
        PrivacyService(id: "Photos", titleKey: "Photos"),
        PrivacyService(id: "Reminders", titleKey: "Reminders"),
        PrivacyService(id: "SystemPolicyRemovableVolumes", titleKey: "Removable Volumes"),
        PrivacyService(id: "ScreenCapture", titleKey: "Screen & System Audio Recording"),
        PrivacyService(id: "SpeechRecognition", titleKey: "Speech Recognition"),
    ]
}

/// An app whose permissions can be reset.
public struct PrivacyApp: Equatable, Sendable {
    public let name: String
    public let bundleIdentifier: String
    public let url: URL

    public init(url: URL) throws {
        let name = FileManager.default.displayName(atPath: url.path)
        guard let identifier = Bundle(url: url)?.bundleIdentifier else { throw PrivacyPermissionError.notAnApp(name) }
        try PrivacyPermissions.validate(identifier)
        self.name = name
        self.bundleIdentifier = identifier
        self.url = url
    }
}

/// Resets privacy permissions with macOS's `tccutil`, so the app asks again next time.
public enum PrivacyPermissions {
    static let tccutil = "/usr/bin/tccutil"

    static func validate(_ identifier: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !identifier.isEmpty, !identifier.hasPrefix("-"), identifier.count <= 255,
            identifier.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { throw PrivacyPermissionError.invalidIdentifier(identifier) }
    }

    static func arguments(service: PrivacyService, bundleIdentifier: String) throws -> [String] {
        try validate(bundleIdentifier)
        return ["reset", service.id, bundleIdentifier]
    }

    @MainActor
    public static func reset(_ service: PrivacyService, for app: PrivacyApp) async throws {
        _ = try await MacUtilityCommand.run(
            tccutil, arguments: try arguments(service: service, bundleIdentifier: app.bundleIdentifier))
    }
}
