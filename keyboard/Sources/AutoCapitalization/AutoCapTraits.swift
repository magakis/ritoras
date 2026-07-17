import UIKit

/// Pure helper that decides whether auto-capitalization should be suppressed
/// based on the host field's text-input traits. UIKit-importing on purpose
/// (kept separate from the Foundation-only `AutoCapitalizer` so that file
/// stays unit-testable without UIKit in the test target).
enum AutoCapTraits {
    /// Returns `true` when auto-capitalization should be SILENT in this field.
    /// - Suppresses when the host explicitly sets `autocapitalizationType == .none`.
    /// - Suppresses for keyboard types where capitalization is meaningless
    ///   (URLs, emails, numeric pads, phone pads).
    /// - Is permissive when either trait is `nil` (does not suppress).
    static func shouldSuppress(
        keyboardType: UIKeyboardType?,
        autocapitalizationType: UITextAutocapitalizationType?
    ) -> Bool {
        if autocapitalizationType == .none { return true }
        switch keyboardType {
        case .URL?, .emailAddress?, .numberPad?, .phonePad?,
             .namePhonePad?, .asciiCapableNumberPad?:
            return true
        default:
            return false
        }
    }
}
