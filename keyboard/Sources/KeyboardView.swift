import UIKit

// MARK: - Keyboard State

enum KeyboardState: Equatable {
    case idle
    case openingApp
    case waiting
    case inserting
    case error(String)
}

// MARK: - Shift State

enum ShiftState: Equatable {
    case lower
    case upper
    case locked
}

// MARK: - UI Mode

enum UIMode: Equatable {
    case letters
    case emoji
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didPerform action: KeyAction)
    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String)
    func keyboardViewNeedsSuggestions(_ view: KeyboardView) -> [String]
    func keyboardViewMicState(_ view: KeyboardView) -> KeyboardState
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView)
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView)
}

extension KeyboardViewDelegate {
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView) {}
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView) {}
}

// MARK: - KeyButton

private class KeyButton: UIButton {
    let keyDefinition: KeyDefinition

    /// Set true when a long-press gesture fires on this button, so the subsequent
    /// touchUpInside can be suppressed (prevents a long-press + tap double-fire).
    var shiftLongPressDidFire = false

    /// Set true on touch-down so the trailing touchUpInside can be suppressed
    /// (prevents a duplicate backspace when Phase 4 handles it on touch-down).
    var backspaceSuppressTap = false

    /// Thin underline shown beneath the shift icon when Caps Lock is engaged,
    /// matching the native iOS keyboard's caps-lock affordance.
    private let capsLockUnderline: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = 1
        return view
    }()

    init(definition: KeyDefinition) {
        self.keyDefinition = definition
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        layer.cornerRadius = 6
        clipsToBounds = true
        titleLabel?.font = .systemFont(ofSize: 24, weight: .regular)
        titleLabel?.textAlignment = .center
        contentHorizontalAlignment = .center
        contentVerticalAlignment = .center

        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.28, alpha: 1)
                : UIColor(white: 0.82, alpha: 1)
        }
        setTitleColor(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor.white
                : UIColor.black
        }, for: .normal)

        tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.7, alpha: 1)
                : UIColor(white: 0.3, alpha: 1)
        }

        // Keys are positioned by manual frame math in KeyboardRowView.layoutSubviews
        // (NOT UIStackView.fillProportionally, which squashes the last key whenever
        // spacing is non-zero). No intrinsicContentSize override is needed.
        addSubview(capsLockUnderline)
        configureContent()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Position the caps-lock underline at the bottom-center of the key.
        let lineWidth: CGFloat = 12
        let lineHeight: CGFloat = 2
        capsLockUnderline.frame = CGRect(
            x: (bounds.width - lineWidth) / 2,
            y: bounds.height - 9,
            width: lineWidth,
            height: lineHeight
        )
    }

    /// Updates the shift key's icon (outline → filled) and shows the caps-lock
    /// underline when locked. Only affects shift keys.
    func updateShiftVisual(_ state: ShiftState) {
        guard keyDefinition.action == .shift else { return }
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
        switch state {
        case .lower:
            setImage(UIImage(systemName: "shift", withConfiguration: config), for: .normal)
            capsLockUnderline.backgroundColor = .clear
        case .upper:
            setImage(UIImage(systemName: "shift.fill", withConfiguration: config), for: .normal)
            capsLockUnderline.backgroundColor = .clear
        case .locked:
            setImage(UIImage(systemName: "shift.fill", withConfiguration: config), for: .normal)
            capsLockUnderline.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
            }
        }
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.5 : 1.0
        }
    }

    /// Sets EITHER an SF Symbol image OR a text title — never both — based on the key's action.
    private func configureContent() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        switch keyDefinition.action {
        case .backspace:
            setImage(UIImage(systemName: "delete.left", withConfiguration: config), for: .normal)
        case .shift, .shiftLock:
            let name = keyDefinition.action == .shiftLock ? "shift.fill" : "shift"
            setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
        case .mic:
            setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
            tintColor = .white
        case .return:
            setImage(UIImage(systemName: "return.left", withConfiguration: config), for: .normal)
        case .globe:
            setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        case .emoji:
            setTitle("☺", for: .normal)
        default:
            setTitle(keyDefinition.label, for: .normal)
        }
    }

    func updateLabel(for shiftState: ShiftState) {
        guard case .insertText = keyDefinition.action else { return }
        let isShifted = shiftState != .lower
        let label = isShifted ? (keyDefinition.shiftedLabel ?? keyDefinition.label) : keyDefinition.label
        setTitle(label, for: .normal)
    }

    func applyMicStyle(icon: String?, backgroundColor color: UIColor?) {
        if let iconName = icon {
            let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            setImage(UIImage(systemName: iconName, withConfiguration: config), for: .normal)
        }
        if let color = color {
            self.backgroundColor = color
        }
    }
}

// MARK: - KeyboardRowView

/// A single keyboard row that positions its keys via manual frame math in
/// layoutSubviews. This deliberately avoids UIStackView.fillProportionally, which
/// has a well-documented bug: it assigns the last arranged subview the
/// lowest-priority proportional constraint, so the final key (P, L) gets squashed
/// whenever spacing is non-zero.
private class KeyboardRowView: UIView {
    let keys: [KeyButton]
    private let spacing: CGFloat
    private let uniformLetterPitch: Bool

    /// - Parameters:
    ///   - keys: The key buttons, in left-to-right order.
    ///   - spacing: Horizontal gap between keys (points).
    ///   - uniformLetterPitch: When true, keys are sized off a shared letter "pitch"
    ///     (= rowWidth / 10) so every weight-1 key has identical width across every
    ///     row, with shorter rows centered (the native iOS staggered look). When
    ///     false, keys fill the full row width proportionally to their weight
    ///     (used for the bottom action row).
    init(keys: [KeyButton], spacing: CGFloat = 6, uniformLetterPitch: Bool) {
        self.keys = keys
        self.spacing = spacing
        self.uniformLetterPitch = uniformLetterPitch
        super.init(frame: .zero)
        keys.forEach {
            // Manual frame layout: neutralize autoresizing so set frames stick exactly.
            $0.autoresizingMask = []
            addSubview($0)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !keys.isEmpty else { return }

        let width = bounds.width
        let height = bounds.height
        let n = CGFloat(keys.count)
        let totalSpacing = spacing * (n - 1)

        if uniformLetterPitch {
            // Letter pitch derived from a 10-key row. This guarantees every weight-1
            // key is the SAME width regardless of which row it is in. Rows with fewer
            // keys (e.g. 9-key row 2) end up narrower than the full width and are
            // centered, producing the native staggered QWERTY look.
            let pitch = (width - spacing * 9) / 10
            let keyWidths = keys.map { pitch * $0.keyDefinition.widthWeight }
            let contentWidth = keyWidths.reduce(0, +) + totalSpacing
            let inset = max(0, (width - contentWidth) / 2)
            var x = inset
            for (i, key) in keys.enumerated() {
                key.frame = CGRect(x: x, y: 0, width: keyWidths[i], height: height)
                x += keyWidths[i] + spacing
            }
        } else {
            // Fill the entire row proportionally to weight (bottom action row).
            let totalWeight = keys.reduce(0.0) { $0 + $1.keyDefinition.widthWeight }
            guard totalWeight > 0 else { return }
            let unit = (width - totalSpacing) / totalWeight
            var x: CGFloat = 0
            for key in keys {
                let w = unit * key.keyDefinition.widthWeight
                key.frame = CGRect(x: x, y: 0, width: w, height: height)
                x += w + spacing
            }
        }
    }
}

// MARK: - SuggestionBar

private class SuggestionBar: UIView {
    var suggestionTapped: ((Int) -> Void)?

    private let stack = UIStackView()
    private var segments: [UIButton] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.25, alpha: 1)
                : UIColor(white: 0.78, alpha: 1)
        }

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for i in 0..<3 {
            let segment = UIButton(type: .system)
            segment.tag = i
            segment.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            segment.titleLabel?.adjustsFontSizeToFitWidth = true
            segment.titleLabel?.minimumScaleFactor = 0.6
            segment.setTitleColor(UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor.white
                    : UIColor.black
            }, for: .normal)
            segment.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(white: 0.18, alpha: 1)
                    : UIColor(white: 0.92, alpha: 1)
            }
            segment.addTarget(self, action: #selector(segmentTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(segment)
            segments.append(segment)
        }
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        suggestionTapped?(sender.tag)
    }

    func update(with suggestions: [String]) {
        for (i, segment) in segments.enumerated() {
            if i < suggestions.count {
                segment.setTitle(suggestions[i], for: .normal)
                segment.isEnabled = true
            } else {
                segment.setTitle("", for: .normal)
                segment.isEnabled = false
            }
        }
    }
}

// MARK: - KeyboardView

class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    // Subviews
    private let suggestionBar = SuggestionBar()
    private let letterRegionContainer = UIView()
    private let keyStack = UIStackView()
    private lazy var emojiPanelView: EmojiPanelView = {
        let panel = EmojiPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onSelect = { [weak self] emoji in
            guard let self = self else { return }
            self.delegate?.keyboardView(self, didPerform: .insertText(emoji))
        }
        panel.onDismiss = { [weak self] in
            self?.apply(mode: .letters)
        }
        return panel
    }()
    private let bottomActionRow = UIView()

    // Key references
    private weak var micKeyButton: KeyButton?
    private weak var emojiKeyButton: KeyButton?
    private weak var shiftKeyButton: KeyButton?
    private weak var bottomRowView: KeyboardRowView?

    // State tracking
    private var hasFullAccess = false
    private var currentShiftState: ShiftState = .lower
    private var currentLayoutMode: KeyboardLayoutMode = .letters

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    // MARK: - Setup

    private func setupView() {
        backgroundColor = .clear

        setupSuggestionBar()
        setupLetterRegion()
        setupEmojiPanel()
        setupConstraints()

        rebuildKeyRows()
        apply(mode: .letters)
    }

    private func setupSuggestionBar() {
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.layer.cornerRadius = 6
        suggestionBar.clipsToBounds = true
        suggestionBar.suggestionTapped = { [weak self] index in
            guard let self = self else { return }
            let suggestions = self.delegate?.keyboardViewNeedsSuggestions(self) ?? []
            guard index < suggestions.count else { return }
            self.delegate?.keyboardView(self, didTapSuggestion: suggestions[index])
        }
        addSubview(suggestionBar)
    }

    private func setupLetterRegion() {
        letterRegionContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(letterRegionContainer)

        keyStack.axis = .vertical
        keyStack.distribution = .fillEqually
        keyStack.alignment = .fill
        keyStack.spacing = 6
        keyStack.translatesAutoresizingMaskIntoConstraints = false
        letterRegionContainer.addSubview(keyStack)

        NSLayoutConstraint.activate([
            keyStack.topAnchor.constraint(equalTo: letterRegionContainer.topAnchor),
            keyStack.leadingAnchor.constraint(equalTo: letterRegionContainer.leadingAnchor),
            keyStack.trailingAnchor.constraint(equalTo: letterRegionContainer.trailingAnchor),
            keyStack.bottomAnchor.constraint(equalTo: letterRegionContainer.bottomAnchor),
        ])

        // Bottom action row (Row 4) — a plain container; the actual keys are laid out
        // by a KeyboardRowView pinned inside it (manual frame math, no fillProportionally).
        bottomActionRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomActionRow)
    }

    private func setupEmojiPanel() {
        // EmojiPanelView is lazily initialized. Just add it to the hierarchy.
        // Its callbacks are wired in the lazy initializer.
        addSubview(emojiPanelView)
    }

    private func setupConstraints() {
        NSLayoutConstraint.activate([
            // SuggestionBar — top (hidden in emoji mode)
            suggestionBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            suggestionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            suggestionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            suggestionBar.heightAnchor.constraint(equalToConstant: 40),

            // Letter region container — middle (rows 1–3)
            letterRegionContainer.topAnchor.constraint(equalTo: suggestionBar.bottomAnchor, constant: 6),
            letterRegionContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            letterRegionContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            letterRegionContainer.bottomAnchor.constraint(equalTo: bottomActionRow.topAnchor, constant: -6),

            // Emoji panel — replaces suggestion bar + letter region in emoji mode
            emojiPanelView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 6),
            emojiPanelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            emojiPanelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            emojiPanelView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),

            // Bottom action row (Row 4) — always visible, pinned to the bottom
            bottomActionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bottomActionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bottomActionRow.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bottomActionRow.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    // MARK: - Key Rows

    private func rebuildKeyRows() {
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bottomRowView?.removeFromSuperview()
        bottomRowView = nil
        shiftKeyButton = nil

        let rows = KeyboardLayout.rows(for: currentLayoutMode)

        for (rowIndex, rowDefs) in rows.enumerated() {
            let isLastRow = rowIndex == rows.count - 1

            // Build the key buttons for this row.
            var buttons: [KeyButton] = []
            buttons.reserveCapacity(rowDefs.count)
            for def in rowDefs {
                let button = KeyButton(definition: def)
                button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)

                switch def.action {
                case .mic:
                    micKeyButton = button
                case .emoji:
                    emojiKeyButton = button
                    let isEmoji = !emojiPanelView.isHidden
                    button.setTitle(isEmoji ? "ABC" : "☺", for: .normal)
                case .shift:
                    shiftKeyButton = button
                    // Long-press the shift key → Caps Lock (like the native keyboard).
                    button.addTarget(self, action: #selector(shiftTouchDown(_:)), for: .touchDown)
                    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(shiftLongPressed(_:)))
                    longPress.minimumPressDuration = 0.4
                    button.addGestureRecognizer(longPress)
                case .backspace:
                    button.addTarget(self, action: #selector(backspaceTouchDown(_:)), for: .touchDown)
                    button.addTarget(self, action: #selector(backspaceTouchUp(_:)), for: .touchUpInside)
                    button.addTarget(self, action: #selector(backspaceTouchUp(_:)), for: .touchUpOutside)
                    button.addTarget(self, action: #selector(backspaceTouchUp(_:)), for: .touchCancel)
                default:
                    break
                }

                buttons.append(button)
            }

            // Letter rows (0–2) use a shared letter pitch so every letter key is the
            // same width across all rows, with shorter rows centered (native stagger).
            // The bottom action row fills its width proportionally to weight.
            let rowView = KeyboardRowView(keys: buttons, uniformLetterPitch: !isLastRow)
            rowView.translatesAutoresizingMaskIntoConstraints = false

            if isLastRow {
                bottomActionRow.addSubview(rowView)
                NSLayoutConstraint.activate([
                    rowView.topAnchor.constraint(equalTo: bottomActionRow.topAnchor),
                    rowView.leadingAnchor.constraint(equalTo: bottomActionRow.leadingAnchor),
                    rowView.trailingAnchor.constraint(equalTo: bottomActionRow.trailingAnchor),
                    rowView.bottomAnchor.constraint(equalTo: bottomActionRow.bottomAnchor),
                ])
                bottomRowView = rowView
            } else {
                keyStack.addArrangedSubview(rowView)
            }
        }

        // Re-apply mic state after rebuild
        let micState = delegate?.keyboardViewMicState(self) ?? .idle
        setMicState(micState)

        // Re-apply shift labels
        updateKeyButtonLabels()
    }

    private func updateKeyButtonLabels() {
        for case let rowView as KeyboardRowView in keyStack.arrangedSubviews {
            for button in rowView.keys {
                button.updateLabel(for: currentShiftState)
            }
        }
        if let bottomRow = bottomRowView {
            for button in bottomRow.keys {
                button.updateLabel(for: currentShiftState)
            }
        }
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: KeyButton) {
        // Suppress the tap that follows a long-press (e.g. shift caps-lock).
        if sender.shiftLongPressDidFire {
            sender.shiftLongPressDidFire = false
            return
        }
        if sender.backspaceSuppressTap {
            sender.backspaceSuppressTap = false
            return
        }
        delegate?.keyboardView(self, didPerform: sender.keyDefinition.action)
    }

    /// Resets the long-press flag at the start of each touch on the shift key.
    @objc private func shiftTouchDown(_ sender: KeyButton) {
        sender.shiftLongPressDidFire = false
    }

    /// Long-pressing the shift key engages Caps Lock (like the native keyboard).
    @objc private func shiftLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? KeyButton else { return }
        button.shiftLongPressDidFire = true
        delegate?.keyboardView(self, didPerform: .shiftLock)
    }

    /// Touch-down on backspace sets the suppression flag and signals the controller
    /// to begin the repeat sequence (single delete immediately, repeated deletes in Phase 4).
    @objc private func backspaceTouchDown(_ sender: KeyButton) {
        sender.backspaceSuppressTap = true
        delegate?.keyboardViewBackspaceDidBegin(self)
    }

    /// Touch-up (including outside or cancelled) signals the controller to stop repeating.
    @objc private func backspaceTouchUp(_ sender: KeyButton) {
        delegate?.keyboardViewBackspaceDidEnd(self)
    }

    // MARK: - Public API

    func configure(for state: KeyboardState) {
        setMicState(state)
    }

    func updateFullAccess(_ hasAccess: Bool) {
        hasFullAccess = hasAccess
    }

    func setMicState(_ state: KeyboardState) {
        guard let micButton = micKeyButton else { return }

        switch state {
        case .idle:
            micButton.applyMicStyle(
                icon: "mic.fill",
                backgroundColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
                        : UIColor(red: 0.0, green: 0.45, blue: 0.9, alpha: 1)
                }
            )
            micButton.tintColor = .white
            micButton.isEnabled = true

        case .openingApp:
            micButton.applyMicStyle(
                icon: "arrow.up.right.square.fill",
                backgroundColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.3, alpha: 1)
                        : UIColor(white: 0.7, alpha: 1)
                }
            )
            micButton.tintColor = .white
            micButton.isEnabled = false

        case .waiting:
            micButton.applyMicStyle(
                icon: "ellipsis.circle.fill",
                backgroundColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.3, alpha: 1)
                        : UIColor(white: 0.7, alpha: 1)
                }
            )
            micButton.tintColor = .white
            micButton.isEnabled = false

        case .inserting:
            micButton.applyMicStyle(
                icon: "checkmark.circle.fill",
                backgroundColor: UIColor { tc in
                    tc.userInterfaceStyle == .dark
                        ? UIColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)
                        : UIColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1)
                }
            )
            micButton.tintColor = .white
            micButton.isEnabled = false

        case .error:
            micButton.applyMicStyle(
                icon: "exclamationmark.circle.fill",
                backgroundColor: .systemRed
            )
            micButton.tintColor = .white
            micButton.isEnabled = true
        }
    }

    func apply(mode: UIMode) {
        let isEmoji = mode == .emoji
        suggestionBar.isHidden = isEmoji
        letterRegionContainer.isHidden = isEmoji
        bottomActionRow.isHidden = isEmoji
        emojiPanelView.isHidden = !isEmoji
        emojiKeyButton?.setTitle(isEmoji ? "ABC" : "☺", for: .normal)

        if isEmoji {
            reloadEmojiPanel()
        }
    }

    func apply(shift: ShiftState, layoutMode: KeyboardLayoutMode) {
        let layoutChanged = layoutMode != currentLayoutMode
        currentShiftState = shift
        currentLayoutMode = layoutMode

        if layoutChanged {
            rebuildKeyRows()
        } else {
            updateKeyButtonLabels()
        }

        updateShiftVisual()
    }

    private func updateShiftVisual() {
        shiftKeyButton?.updateShiftVisual(currentShiftState)
    }

    func refreshSuggestions() {
        let suggestions = delegate?.keyboardViewNeedsSuggestions(self) ?? []
        suggestionBar.update(with: suggestions)
    }

    func reloadEmojiPanel() {
        emojiPanelView.reloadData()
    }
}
