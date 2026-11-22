import CoreFoundation
import Foundation

public enum HiddenSettingValue: Equatable, Sendable {
    case boolean(Bool)
    case seconds(Double)
    case text(String)
}

public enum HiddenSettingKind: Equatable, Sendable {
    case boolean
    case seconds
    case choice([String])
    case directory

    public func decode(_ preference: Any?) -> HiddenSettingValue? {
        if let number = preference as? NSNumber {
            let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
            switch self {
            case .boolean where isBoolean || number.doubleValue == 0 || number.doubleValue == 1:
                return .boolean(number.boolValue)
            case .seconds where !isBoolean && number.doubleValue.isFinite && number.doubleValue >= 0:
                return .seconds(number.doubleValue)
            default:
                return nil
            }
        }
        guard let text = preference as? String else { return nil }
        switch self {
        case .choice(let choices) where choices.contains(text):
            return .text(text)
        case .directory where Self.absolutePath(text) != nil:
            return .text(text)
        default:
            return nil
        }
    }

    fileprivate static func absolutePath(_ path: String) -> String? {
        guard !path.utf8.contains(0) else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? expanded : nil
    }
}

public struct HiddenSetting: Identifiable, Sendable {
    public enum RelaunchTarget: String, Sendable {
        case finder = "Finder"
        case dock = "Dock"
        case systemUIServer = "SystemUIServer"
    }

    public struct Reading: Sendable {
        public let value: HiddenSettingValue?
        public let hasUserOverride: Bool
        public let hasUnrecognizedValue: Bool
    }

    public let domain: String
    public let key: String
    public let title: String
    public let explanation: String
    public let kind: HiddenSettingKind
    /// nil means that macOS supplies its own default (such as Dock timing).
    public let defaultValue: HiddenSettingValue?
    public let relaunchTarget: RelaunchTarget

    public var id: String { "\(domain)/\(key)" }

    /// These user preferences are shared with Finder, Dock, and macOS screenshot tools.
    /// Resetting deletes the user override so macOS can choose the effective value.
    public static let all: [HiddenSetting] = [
        .init(domain: "com.apple.finder", key: "AppleShowAllFiles",
              title: coreLocalized("Show hidden files"),
              explanation: coreLocalized("Show files and folders that Finder normally hides."),
              kind: .boolean, defaultValue: .boolean(false), relaunchTarget: .finder),
        .init(domain: "com.apple.finder", key: "ShowPathbar",
              title: coreLocalized("Show the path bar"),
              explanation: coreLocalized("Show the current folder’s location at the bottom of Finder windows."),
              kind: .boolean, defaultValue: .boolean(false), relaunchTarget: .finder),
        .init(domain: "com.apple.finder", key: "ShowStatusBar",
              title: coreLocalized("Show the status bar"),
              explanation: coreLocalized("Show item counts and available space at the bottom of Finder windows."),
              kind: .boolean, defaultValue: .boolean(false), relaunchTarget: .finder),
        .init(domain: "NSGlobalDomain", key: "AppleShowAllExtensions",
              title: coreLocalized("Show all filename extensions"),
              explanation: coreLocalized("Show filename extensions even for files whose extensions are hidden."),
              kind: .boolean, defaultValue: .boolean(false), relaunchTarget: .finder),
        .init(domain: "com.apple.dock", key: "autohide-delay",
              title: coreLocalized("Dock auto-hide delay"),
              explanation: coreLocalized("Set how long the pointer must rest at the screen edge before an auto-hidden Dock appears."),
              kind: .seconds, defaultValue: nil, relaunchTarget: .dock),
        .init(domain: "com.apple.dock", key: "autohide-time-modifier",
              title: coreLocalized("Dock auto-hide animation duration"),
              explanation: coreLocalized("Set the duration of the hide and show animation when Dock auto-hide is enabled."),
              kind: .seconds, defaultValue: nil, relaunchTarget: .dock),
        .init(domain: "com.apple.screencapture", key: "type",
              title: coreLocalized("Screenshot format"),
              explanation: coreLocalized("Choose the file format macOS uses when it saves a screenshot."),
              kind: .choice(["png", "jpg", "heic", "tiff", "gif", "pdf"]),
              defaultValue: .text("png"), relaunchTarget: .systemUIServer),
        .init(domain: "com.apple.screencapture", key: "disable-shadow",
              title: coreLocalized("Disable screenshot shadows"),
              explanation: coreLocalized("Exclude the shadow from screenshots of individual windows."),
              kind: .boolean, defaultValue: .boolean(false), relaunchTarget: .systemUIServer),
        .init(domain: "com.apple.screencapture", key: "location",
              title: coreLocalized("Screenshot location"),
              explanation: coreLocalized("Enter the full path of the folder where macOS should save screenshots."),
              kind: .directory, defaultValue: .text("~/Desktop"), relaunchTarget: .systemUIServer),
    ]

    public func read() -> Reading {
        let application = domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : domain as CFString
        let preferenceKey = key as CFString
        CFPreferencesAppSynchronize(application)
        let userValue = CFPreferencesCopyValue(
            preferenceKey, application, kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        // Reading the global domain directly also avoids a same-key override from this app.
        let effective = domain == "NSGlobalDomain" ? userValue : CFPreferencesCopyAppValue(preferenceKey, application)
        let value = kind.decode(effective)
        return Reading(value: value, hasUserOverride: userValue != nil, hasUnrecognizedValue: effective != nil && value == nil)
    }

    public func defaultsArguments(for value: HiddenSettingValue?) -> [String]? {
        guard let value else { return ["delete", domain, key] }
        let writeArguments = ["write", domain, key]
        switch (kind, value) {
        case (.boolean, .boolean(let enabled)):
            return writeArguments + ["-bool", enabled ? "true" : "false"]
        case (.seconds, .seconds(let seconds)) where seconds.isFinite && seconds >= 0:
            return writeArguments + ["-float", String(seconds)]
        case (.choice(let choices), .text(let text)) where choices.contains(text):
            return writeArguments + ["-string", text]
        case (.directory, .text(let path)):
            guard let path = HiddenSettingKind.absolutePath(path) else { return nil }
            return writeArguments + ["-string", path]
        default:
            return nil
        }
    }

    @MainActor
    public func apply(_ value: HiddenSettingValue?) async throws {
        guard let arguments = defaultsArguments(for: value) else { throw InvalidValue() }
        if kind == .directory, let path = arguments.last, value != nil {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw InvalidDirectory()
            }
        }
        if value == nil, !read().hasUserOverride { return }
        _ = try await MacUtilityCommand.run("/usr/bin/defaults", arguments: arguments)
    }

    @MainActor
    public func relaunch() async throws {
        _ = try await MacUtilityCommand.run("/usr/bin/killall", arguments: [relaunchTarget.rawValue])
    }

    private struct InvalidValue: LocalizedError {
        var errorDescription: String? { coreLocalized("Enter a valid value for this setting.") }
    }

    private struct InvalidDirectory: LocalizedError {
        var errorDescription: String? { coreLocalized("Choose an existing folder for screenshots.") }
    }
}
