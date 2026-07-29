import SwiftUI

struct DictionaryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var words: [String] = []
    @State private var searchText = ""
    @State private var presentingEditor = false
    @State private var editingWord: String? = nil
    @State private var showClearConfirmation = false
    @State private var learnedWordsObserver: DarwinObserverToken?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if words.isEmpty {
                    Spacer()
                    Text("No words in your personal dictionary yet.\nTap + to add one.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else {
                    List {
                        ForEach(filteredWords, id: \.self) { word in
                            Button {
                                editingWord = word
                                presentingEditor = true
                            } label: {
                                HStack {
                                    Text(word)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                        .onDelete(perform: delete)
                    }
                }

                diagnosticFooter
            }
            .navigationTitle("Personal Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        editingWord = nil
                        presentingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                if !words.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Clear All") {
                            showClearConfirmation = true
                        }
                    }
                }
            }
            .sheet(isPresented: $presentingEditor) {
                DictionaryEditorView(word: editingWord) { result in
                    applyEditorResult(result)
                    presentingEditor = false
                }
            }
            .confirmationDialog(
                "Clear all words?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All", role: .destructive) {
                    LearnedWordsStore.shared.clear()
                    refresh()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear {
            refresh()
            learnedWordsObserver = DarwinNotifier.observe(
                SharedConfig.Defaults.darwinLearnedWordsChangedNotificationName
            ) {
                DispatchQueue.main.async {
                    LearnedWordsStore.shared.reload()
                    words = LearnedWordsStore.shared.allWordsMostRecentFirst()
                }
            }
        }
        .onDisappear {
            learnedWordsObserver = nil
        }
    }

    // MARK: - Diagnostic Footer

    /// Small unobtrusive footer showing app-group resolver diagnostics.
    /// Enables on-device verification of the app-group container state
    /// without device logs (SideStore entitlement-rewriting diagnostic).
    @ViewBuilder
    private var diagnosticFooter: some View {
        let resolvedId = AppGroupResolver.shared.resolvedIdentifier
        let containerOk = AppGroupResolver.shared.containerAvailable
        let wordCount = LearnedWordsStore.shared.allWordsMostRecentFirst().count

        VStack(alignment: .leading, spacing: 1) {
            Text("App Group: \(resolvedId)")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("Container: \(containerOk ? "Available" : "Unavailable")")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("Learned words: \(wordCount)")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Derived

    private var filteredWords: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return words }
        return words.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: - Mutations

    private func refresh() {
        LearnedWordsStore.shared.reload()
        words = LearnedWordsStore.shared.allWordsMostRecentFirst()
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = offsets.map { filteredWords[$0] }
        for word in toRemove {
            LearnedWordsStore.shared.remove(word)
        }
        refresh()
    }

    private func applyEditorResult(_ result: DictionaryEditorResult) {
        switch result {
        case .add(let newWord):
            LearnedWordsStore.shared.add(newWord)
        case .edit(let oldWord, let newWord):
            // No-op edit (Save with no change): don't remove+re-add, which would
            // reorder the word to the top of the most-recent-first list.
            guard newWord.lowercased() != oldWord.lowercased() else { break }
            LearnedWordsStore.shared.remove(oldWord)
            LearnedWordsStore.shared.add(newWord)
        case .none:
            break
        }
        refresh()
    }
}

// MARK: - Editor

private struct DictionaryEditorView: View {
    let word: String?
    let onComplete: (DictionaryEditorResult) -> Void

    @State private var text: String = ""
    @Environment(\.dismiss) private var dismiss

    private var isValidEntry: Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Single words only — SymSpell matches single tokens, so a multi-word
        // entry (e.g. "New York") could never be suggested and would be inert.
        return !trimmed.contains(where: { $0.isWhitespace })
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("Word", text: $text)
                    .textInputAutocapitalization(.none)
                    .autocorrectionDisabled()
                if !isValidEntry && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Single words only")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(word == nil ? "Add Word" : "Edit Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onComplete(.none)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard isValidEntry else { return }
                        if let existing = word {
                            onComplete(.edit(oldWord: existing, newWord: trimmed))
                        } else {
                            onComplete(.add(newWord: trimmed))
                        }
                        dismiss()
                    }
                    .disabled(!isValidEntry)
                }
            }
        }
        .onAppear {
            text = word ?? ""
        }
    }
}

// MARK: - Editor Result

private enum DictionaryEditorResult {
    case none
    case add(newWord: String)
    case edit(oldWord: String, newWord: String)
}
