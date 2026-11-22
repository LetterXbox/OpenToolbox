import Foundation

/// Looks up a localized string in the Core string catalog (`Resources/Localizable.xcstrings`).
///
/// English is the source language; untranslated keys fall back to the key itself.
func coreLocalized(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

/// Looks up a runtime key (for example a catalog title stored as data) in the Core string catalog.
func coreLocalized(dynamicKey key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
