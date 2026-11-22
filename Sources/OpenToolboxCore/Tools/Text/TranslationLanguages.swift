import Foundation
import Translation

public enum TranslationLanguages {
    /// Languages Apple Translation supports on this Mac, whether or not they are downloaded.
    public static func supported() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }
}
