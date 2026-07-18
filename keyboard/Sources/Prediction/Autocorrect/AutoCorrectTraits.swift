import UIKit

/// Pure helper that decides whether autocorrect-on-space should be suppressed
/// based on the host field's text-input traits. UIKit-importing on purpose
/// (kept separate from the Foundation-only `AutocorrectController` so that
/// file stays unit-testable without UIKit in the test target).
enum AutoCorrectTraits {
    /// Returns `true` when autocorrect should be SILENT in this field.
    /// - Suppresses when the host explicitly sets `autocorrectionType == .no`
    ///   or `spellCheckingType == .no`.
    /// - Suppresses for keyboard types where correction is meaningless
    ///   (URLs, emails, numeric pads, phone pads).
    /// - Is permissive when either trait is `nil` (does not suppress).
    static func shouldSuppress(
        keyboardType: UIKeyboardType?,
        autocorrectionType: UITextAutocorrectionType?,
        spellCheckingType: UITextSpellCheckingType?
    ) -> Bool {
        if autocorrectionType == .no { return true }
        if spellCheckingType == .no { return true }
        switch keyboardType {
        case .URL?, .emailAddress?, .numberPad?, .phonePad?,
             .namePhonePad?, .asciiCapableNumberPad?:
            return true
        default:
            return false
        }
    }
}
