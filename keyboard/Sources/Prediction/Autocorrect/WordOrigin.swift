import Foundation

/// Tracks whether a word's origin is user-typed or came from a suggestion/autocorrect.
/// LOCKED origins never get re-corrected by AutocorrectController.
enum WordOrigin: Equatable {
    /// Chars entered one-by-one; re-evaluatable on separator press.
    case typing
    /// User explicitly tapped a suggestion in the bar — LOCKED.
    case suggestionTap
    /// Autocorrect was just applied on this word — LOCKED.
    case autocorrectApplied
}

/// Lightweight state holder for tracking the current word's origin.
struct WordOriginTracker {
    private(set) var current: WordOrigin = .typing

    mutating func markSuggestionTap() { current = .suggestionTap }
    mutating func markAutocorrectApplied() { current = .autocorrectApplied }
    mutating func resetToTyping() { current = .typing }
}
