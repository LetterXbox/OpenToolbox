import Foundation

/// Localized UI string from the app's string catalog (`Resources/Localizable.xcstrings`).
///
/// Use this for every user-facing literal so strings are ready for translation:
/// `Text(L("Copy"))`, `Button(L("Format")) { … }`. English is the source language.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
