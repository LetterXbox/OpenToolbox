import Foundation

/// Which tools the user has enabled.
///
/// Built-in tools are enabled by default. Tools that need an on-demand engine
/// are disabled by default so nothing is downloaded until the user opts in.
public struct ToolPreferences: Codable, Equatable, Sendable {
    /// Explicit user choices; tools without an entry use the default.
    public private(set) var overrides: [ToolID: Bool]

    public init(overrides: [ToolID: Bool] = [:]) {
        self.overrides = overrides
    }

    public static func isEnabledByDefault(_ tool: ToolDescriptor) -> Bool {
        tool.isBuiltIn
    }

    public func isEnabled(_ tool: ToolDescriptor) -> Bool {
        overrides[tool.id] ?? Self.isEnabledByDefault(tool)
    }

    public mutating func setEnabled(_ enabled: Bool, for tool: ToolDescriptor) {
        if enabled == Self.isEnabledByDefault(tool) {
            overrides[tool.id] = nil
        } else {
            overrides[tool.id] = enabled
        }
    }

    public mutating func setEnabled(_ enabled: Bool, for tools: some Sequence<ToolDescriptor>) {
        for tool in tools where tool.availability == .available {
            setEnabled(enabled, for: tool)
        }
    }

    /// Enabled tools from `tools`, keeping catalog order.
    public func enabledTools(from tools: [ToolDescriptor] = ToolCatalog.all) -> [ToolDescriptor] {
        tools.filter(isEnabled)
    }
}
