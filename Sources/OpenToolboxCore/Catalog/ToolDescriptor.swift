import Foundation

/// Sidebar grouping for tools.
public enum ToolCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case developer
    case textAndFiles
    case imagesAndPDF
    case macUtilities
    case media

    public var id: String { rawValue }

    /// English source title; also the localization key.
    public var titleKey: String {
        switch self {
        case .developer: "Developer"
        case .textAndFiles: "Text & Files"
        case .imagesAndPDF: "Images & PDF"
        case .macUtilities: "Mac Utilities"
        case .media: "Media"
        }
    }

    public var localizedTitle: String { coreLocalized(dynamicKey: titleKey) }

    /// SF Symbol name.
    public var symbolName: String {
        switch self {
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .textAndFiles: "doc.text"
        case .imagesAndPDF: "photo.on.rectangle"
        case .macUtilities: "macwindow"
        case .media: "film"
        }
    }
}

/// Whether a tool can be used in this build.
public enum ToolAvailability: String, Codable, Sendable {
    /// Implemented and usable.
    case available
    /// Listed in the catalog but not implemented yet.
    case planned
}

/// Stable identifier for a tool, for example `dev.json-formatter`.
public typealias ToolID = String

/// Static metadata describing one tool. The catalog is data so the sidebar,
/// command palette, and tool catalog all read from the same source.
public struct ToolDescriptor: Identifiable, Hashable, Sendable {
    public let id: ToolID
    public let category: ToolCategory
    /// English source title; also the localization key.
    public let titleKey: String
    /// English one-line description; also the localization key.
    public let summaryKey: String
    /// SF Symbol name.
    public let symbolName: String
    /// Extra search terms for the command palette (not shown in the UI).
    public let keywords: [String]
    /// On-demand engines this tool needs. Empty means built-in (0 MB download).
    public let requiredEngines: [EngineID]
    public let availability: ToolAvailability

    public init(
        id: ToolID,
        category: ToolCategory,
        title: String,
        summary: String,
        symbolName: String,
        keywords: [String] = [],
        requiredEngines: [EngineID] = [],
        availability: ToolAvailability = .available
    ) {
        self.id = id
        self.category = category
        self.titleKey = title
        self.summaryKey = summary
        self.symbolName = symbolName
        self.keywords = keywords
        self.requiredEngines = requiredEngines
        self.availability = availability
    }

    public var localizedTitle: String { coreLocalized(dynamicKey: titleKey) }
    public var localizedSummary: String { coreLocalized(dynamicKey: summaryKey) }

    /// `true` when the tool needs no downloaded engine.
    public var isBuiltIn: Bool { requiredEngines.isEmpty }
}
