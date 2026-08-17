import Foundation

/// The keyboard's active language. Single source of truth shared by the
/// container app (settings UI) and the keyboard extension (runtime switch of
/// `primaryLanguage`). Persisted in the App Group under
/// `SharedConfig.Defaults.keyboardLanguageKey`.
enum KeyboardLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case greek = "el"

    /// BCP-47 tag applied to `UIInputViewController.primaryLanguage`
    /// at runtime (supersedes the plist's `PrimaryLanguage`).
    var bcp47Tag: String {
        switch self {
        case .english: return "en-US"
        case .greek: return "el"
        }
    }

    /// Tag passed to `UITextChecker` spell-check APIs.
    var appleSpellTag: String {
        switch self {
        case .english: return "en-US"
        case .greek: return "el"
        }
    }

    /// User-facing name shown in Settings.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .greek: return "Ελληνικά"
        }
    }

    /// Compact label for space-constrained surfaces.
    var shortLabel: String {
        switch self {
        case .english: return "EN"
        case .greek: return "EL"
        }
    }

    /// Language code sent as the dictation `language` form field. English omits
    /// the field (nil), preserving the pre-Greek English request wire format.
    var dictationLanguageField: String? { self == .english ? nil : rawValue }
}
