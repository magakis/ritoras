import UIKit

// MARK: - State Machine

enum KeyboardState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardViewDidTapMicButton(_ view: KeyboardView)
    func keyboardView(_ view: KeyboardView, didTapKeyAction action: KeyAction)
    func keyboardView(_ view: KeyboardView, didTapSuggestion word: String)
}

// MARK: - KeyboardView

class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    // MARK: - Suggestion Bar

    private let suggestionBar: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        return stack
    }()

    private var suggestionButtons: [UIButton] = []

    // MARK: - Key Rows

    private let keyRowsStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 4
        return stack
    }()

    // Keep references to row stacks and all key buttons for dynamic updates
    private var rowStacks: [UIStackView] = []
    private var keyButtons: [KeyAction: UIButton] = [:]
    private var micButton: UIButton?

    // MARK: - Current Layout Mode

    private var currentLayoutMode: KeyboardLayoutMode = .letters
    private var isShifted: Bool = false
    private var isCapsLock: Bool = false
    private var isRecording: Bool = false
    private var isTranscribing: Bool = false

    // MARK: - Suggestion Bar Constraints

    private var suggestionBarTopConstraint: NSLayoutConstraint?
    private var suggestionBarTopNormal: NSLayoutConstraint?

    // MARK: - Full Access Banner

    private let fullAccessBanner: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        view.layer.cornerRadius = 8
        view.isHidden = true
        return view
    }()

    private let fullAccessLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Enable Full Access in Settings → General → Keyboard → Ritoras → Allow Full Access"
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .systemOrange
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = UIColor.systemGray6

        // Full Access banner
        addSubview(fullAccessBanner)
        fullAccessBanner.addSubview(fullAccessLabel)

        NSLayoutConstraint.activate([
            fullAccessBanner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4),
            fullAccessBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            fullAccessBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            fullAccessLabel.topAnchor.constraint(equalTo: fullAccessBanner.topAnchor, constant: 6),
            fullAccessLabel.leadingAnchor.constraint(equalTo: fullAccessBanner.leadingAnchor, constant: 8),
            fullAccessLabel.trailingAnchor.constraint(equalTo: fullAccessBanner.trailingAnchor, constant: -8),
            fullAccessLabel.bottomAnchor.constraint(equalTo: fullAccessBanner.bottomAnchor, constant: -6),
        ])

        // Suggestion bar
        setupSuggestionBar()

        // Key rows
        keyRowsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyRowsStack)

        // Build the default letter layout
        rebuildKeyRows()

        suggestionBarTopConstraint = suggestionBar.topAnchor.constraint(equalTo: fullAccessBanner.bottomAnchor, constant: 4)
        suggestionBarTopNormal = suggestionBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 4)

        suggestionBarTopNormal?.isActive = true

        NSLayoutConstraint.activate([
            suggestionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            suggestionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            suggestionBar.heightAnchor.constraint(equalToConstant: 40),

            keyRowsStack.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: 4),
            keyRowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            keyRowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            keyRowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    // MARK: - Suggestion Bar Setup

    private func setupSuggestionBar() {
        suggestionBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        suggestionButtons.removeAll()

        for _ in 0..<3 {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            button.setTitleColor(.darkGray, for: .normal)
            button.backgroundColor = UIColor.systemGray5
            button.layer.cornerRadius = 6
            button.clipsToBounds = true
            button.addTarget(self, action: #selector(suggestionTapped(_:)), for: .touchUpInside)
            suggestionBar.addArrangedSubview(button)
            suggestionButtons.append(button)
        }

        addSubview(suggestionBar)
    }

    // MARK: - Key Rows

    private func rebuildKeyRows() {
        // Clear existing
        keyRowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowStacks.removeAll()
        keyButtons.removeAll()
        micButton = nil

        let rows = KeyboardLayout.rows(for: currentLayoutMode)

        for rowDef in rows {
            let rowStack = UIStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.axis = .horizontal
            rowStack.distribution = .fill
            rowStack.spacing = 4
            rowStack.alignment = .fill

            let totalWeight = rowDef.reduce(0) { $0 + $1.widthWeight }

            for keyDef in rowDef {
                let button = createKeyButton(for: keyDef)
                rowStack.addArrangedSubview(button)

                // Proportional width
                let proportion = keyDef.widthWeight / totalWeight
                let widthConstraint = button.widthAnchor.constraint(
                    equalTo: rowStack.widthAnchor,
                    multiplier: proportion
                )
                widthConstraint.priority = .required
                widthConstraint.isActive = true

                // Store references for dynamic updates
                if case .mic = keyDef.action {
                    micButton = button
                }
                keyButtons[keyDef.action] = button
            }

            keyRowsStack.addArrangedSubview(rowStack)
            rowStacks.append(rowStack)
        }
    }

    private func createKeyButton(for keyDef: KeyDefinition) -> UIButton {
        let button = KeyButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.keyDefinition = keyDef
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18)
        button.setTitleColor(.darkText, for: .normal)
        button.backgroundColor = UIColor.white
        button.layer.cornerRadius = 6
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

        // Apply label based on shift state
        updateButtonLabel(button, for: keyDef)

        return button
    }

    private func updateButtonLabel(_ button: UIButton, for keyDef: KeyDefinition) {
        if keyDef.action == .mic {
            // Mic button labels are set by configure(for:)
            return
        }

        if keyDef.action == .shift {
            if isCapsLock {
                button.setTitle(keyDef.shiftedLabel ?? keyDef.label, for: .normal)
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
            } else if isShifted {
                button.setTitle(keyDef.label, for: .normal)
                button.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.2)
            } else {
                button.setTitle(keyDef.label, for: .normal)
                button.backgroundColor = UIColor.white
            }
            return
        }

        if isShifted || isCapsLock, let shifted = keyDef.shiftedLabel {
            button.setTitle(shifted, for: .normal)
        } else {
            button.setTitle(keyDef.label, for: .normal)
        }
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: UIButton) {
        guard let keyButton = sender as? KeyButton,
              let keyDef = keyButton.keyDefinition else { return }

        delegate?.keyboardView(self, didTapKeyAction: keyDef.action)
    }

    @objc private func suggestionTapped(_ sender: UIButton) {
        guard let title = sender.title(for: .normal), !title.isEmpty else { return }
        delegate?.keyboardView(self, didTapSuggestion: title)
    }

    // MARK: - Public Configuration

    /// Updates the mic button state and suggestion bar labels.
    func configure(for state: KeyboardState) {
        // Update mic button
        guard let micBtn = micButton else { return }

        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)

        switch state {
        case .idle:
            micBtn.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
            micBtn.setTitle(nil, for: .normal)
            micBtn.tintColor = .systemBlue
            micBtn.backgroundColor = UIColor.white
            micBtn.isEnabled = true
            isRecording = false
            isTranscribing = false

        case .recording:
            micBtn.setImage(UIImage(systemName: "stop.circle.fill", withConfiguration: config), for: .normal)
            micBtn.setTitle(nil, for: .normal)
            micBtn.tintColor = .white
            micBtn.backgroundColor = .systemRed
            micBtn.isEnabled = true
            isRecording = true
            isTranscribing = false

        case .transcribing:
            micBtn.setImage(nil, for: .normal)
            micBtn.setTitle("...", for: .normal)
            micBtn.tintColor = .darkGray
            micBtn.backgroundColor = UIColor.systemGray4
            micBtn.isEnabled = false
            isRecording = false
            isTranscribing = true

        case .error:
            let errConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            micBtn.setImage(UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: errConfig), for: .normal)
            micBtn.setTitle(nil, for: .normal)
            micBtn.tintColor = .white
            micBtn.backgroundColor = .systemRed
            micBtn.isEnabled = true
            isRecording = false
            isTranscribing = false
        }
    }

    /// Updates the suggestion bar with new word predictions.
    func updateSuggestions(_ suggestions: [String]) {
        for (index, button) in suggestionButtons.enumerated() {
            if index < suggestions.count {
                let word = suggestions[index]
                button.setTitle(word, for: .normal)
                button.alpha = 1.0
                button.isEnabled = true
            } else {
                button.setTitle(nil, for: .normal)
                button.alpha = 0.0
                button.isEnabled = false
            }
        }
    }

    /// Updates shift state display in letter layout.
    func setShiftState(shifted: Bool, capsLock: Bool) {
        isShifted = shifted
        isCapsLock = capsLock

        guard currentLayoutMode == .letters else { return }

        // Update all letter key labels
        for (action, button) in keyButtons {
            guard case .insertText(let char) = action else { continue }
            if let keyButton = button as? KeyButton, let keyDef = keyButton.keyDefinition {
                if shifted || capsLock, let shifted = keyDef.shiftedLabel {
                    button.setTitle(shifted, for: .normal)
                } else {
                    button.setTitle(keyDef.label, for: .normal)
                }
            }
        }

        // Update shift button
        if let shiftButton = keyButtons[.shift] {
            if capsLock {
                shiftButton.setTitle("⇪", for: .normal)
                shiftButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.3)
            } else if shifted {
                shiftButton.setTitle("⇧", for: .normal)
                shiftButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.2)
            } else {
                shiftButton.setTitle("⇧", for: .normal)
                shiftButton.backgroundColor = UIColor.white
            }
        }
    }

    /// Switches the entire keyboard layout.
    func setLayoutMode(_ mode: KeyboardLayoutMode) {
        guard mode != currentLayoutMode else { return }
        currentLayoutMode = mode

        rebuildKeyRows()

        // If switching to letters, restore shift state
        if mode == .letters {
            setShiftState(shifted: isShifted, capsLock: isCapsLock)
        }
    }

    func showFullAccessBanner(_ show: Bool) {
        fullAccessBanner.isHidden = !show
        suggestionBarTopConstraint?.isActive = show
        suggestionBarTopNormal?.isActive = !show
    }
}

// MARK: - Key Button Subclass

private class KeyButton: UIButton {
    var keyDefinition: KeyDefinition?
}
