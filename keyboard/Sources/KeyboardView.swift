import UIKit

// MARK: - Keyboard State

enum KeyboardState: Equatable {
    case idle
    case openingApp
    case waiting
    case waitingConfirm
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
    case emojiSearch
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didPerform action: KeyAction)
    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String)
    func keyboardViewNeedsSuggestions(_ view: KeyboardView) -> [String]
    func keyboardViewMicState(_ view: KeyboardView) -> KeyboardState
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView)
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView)
    func keyboardContextToken(_ view: KeyboardView) -> UInt64
}

extension KeyboardViewDelegate {
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView) {}
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView) {}
    func keyboardContextToken(_ view: KeyboardView) -> UInt64 { return 0 }
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
            let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
            setImage(UIImage(systemName: "face.smiling", withConfiguration: smileConfig), for: .normal)
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
    // Row 2's first and last keys MUST keep identical geometry across letters/numbers/symbols.
    // All current edge keys (⇧, #+=, 123, ⌫) declare widthWeight 1.5; do not change one without the others.
    private static let edgeKeyWidthWeight: CGFloat = 1.5

    enum LayoutMode {
        case letterPitch      // shared 10-key pitch, shorter rows centered (staggered QWERTY look) — rows 0,1
        case edgeAnchored     // first & last keys pinned to fixed geometry, middle keys fill the gap — row 2
        case proportional     // fill full row width by weight — bottom action row
    }

    private let layoutMode: LayoutMode

    /// - Parameters:
    ///   - keys: The key buttons, in left-to-right order.
    ///   - spacing: Horizontal gap between keys (points).
    ///   - layoutMode: Layout strategy for the row.
    ///     `.letterPitch`: keys sized off a shared 10-key pitch so every weight-1 key
    ///       has identical width across every row, with shorter rows centered
    ///       (the native iOS staggered look) — rows 0,1.
    ///     `.edgeAnchored`: first & last keys pinned to fixed geometry matching the
    ///       10-key pitch width, middle keys fill the gap — row 2 (backspace row).
    ///     `.proportional`: keys fill the full row width proportionally to their
    ///       weight — bottom action row.
    init(keys: [KeyButton], spacing: CGFloat = 6, layoutMode: LayoutMode) {
        self.keys = keys
        self.spacing = spacing
        self.layoutMode = layoutMode
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

        switch layoutMode {
        case .letterPitch:
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

        case .edgeAnchored:
            // Pin first & last keys to the exact geometry the letters-mode row 2 produces
            // (pitch from the 10-key formula, inset matching a centered 10.0-weight row),
            // then distribute the middle keys equally across the remaining gap.
            guard keys.count >= 2 else {
                // Degenerate: fall back to plain letter-pitch centering.
                let pitch = (width - spacing * 9) / 10
                let keyWidths = keys.map { pitch * $0.keyDefinition.widthWeight }
                let contentWidth = keyWidths.reduce(0, +) + totalSpacing
                let inset = max(0, (width - contentWidth) / 2)
                var x = inset
                for (i, key) in keys.enumerated() {
                    key.frame = CGRect(x: x, y: 0, width: keyWidths[i], height: height)
                    x += keyWidths[i] + spacing
                }
                return
            }
            let pitch = (width - spacing * 9) / 10
            let edgeWidth = pitch * Self.edgeKeyWidthWeight
            let inset = spacing / 2
            // First key: flush-left at the letters-mode position.
            keys.first!.frame = CGRect(x: inset, y: 0, width: edgeWidth, height: height)
            // Last key (backspace): flush-right, mirroring first.
            keys.last!.frame = CGRect(x: width - inset - edgeWidth, y: 0, width: edgeWidth, height: height)
            // Middle keys fill the gap between the two anchors.
            let middle = Array(keys.dropFirst().dropLast())
            if !middle.isEmpty {
                let gapStart = inset + edgeWidth + spacing
                let gapEnd = width - inset - edgeWidth - spacing
                let gap = max(0, gapEnd - gapStart)
                let m = CGFloat(middle.count)
                let middleWidth = max(0, (gap - spacing * (m - 1)) / m)
                var mx = gapStart
                for key in middle {
                    key.frame = CGRect(x: mx, y: 0, width: middleWidth, height: height)
                    mx += middleWidth + spacing
                }
            }

        case .proportional:
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
    /// Injected on every refreshSuggestions call and read by the suggestion-tap closure.
    private var suggestionCache = SuggestionDisplayCache()
    private let letterRegionContainer = UIView()
    private let keyStack = UIStackView()
    /// Internal so KeyboardViewController can route keystrokes to searchField in .emojiSearch mode.
    lazy var emojiPanelView: EmojiPanelView = {
        let panel = EmojiPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onSelect = { [weak self] emoji in
            guard let self = self else { return }
            self.delegate?.keyboardView(self, didPerform: .insertText(emoji))
        }
        panel.onDismiss = { [weak self] in
            self?.apply(mode: .letters)
        }
        panel.onBackspace = { [weak self] in
            guard let self else { return }
            self.delegate?.keyboardViewBackspaceDidBegin(self)
            self.delegate?.keyboardViewBackspaceDidEnd(self)
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

    /// Active only in `.emojiSearch` mode — pins the emoji panel's bottom edge
    /// to the letter region's top edge, preventing overlap.
    private var emojiSearchOverlapConstraint: NSLayoutConstraint?

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
        backgroundColor = EmojiPanelView.panelBackground

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
            let liveToken = self.delegate?.keyboardContextToken(self) ?? 0
            guard let suggestion = decideSuggestionTap(cache: self.suggestionCache, liveToken: liveToken, index: index) else {
                FileLogger.shared.debug(.keyboard, "suggestion cache stale tap ignored", payload: ["idx": index, "cacheToken": self.suggestionCache.token, "liveToken": liveToken])
                return
            }
            self.delegate?.keyboardView(self, didTapSuggestion: suggestion)
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
        let emojiPanelBottom = emojiPanelView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6)
        emojiPanelBottom.priority = .defaultHigh

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
            emojiPanelView.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            emojiPanelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            emojiPanelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            emojiPanelBottom,

            // Bottom action row (Row 4) — always visible, pinned to the bottom
            bottomActionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bottomActionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bottomActionRow.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
            bottomActionRow.heightAnchor.constraint(equalToConstant: 48),
        ])

        // Overlap constraint for .emojiSearch mode — pins panel bottom to letter region top
        emojiSearchOverlapConstraint = emojiPanelView.bottomAnchor.constraint(equalTo: letterRegionContainer.topAnchor)
        emojiSearchOverlapConstraint?.priority = .required
        emojiSearchOverlapConstraint?.isActive = false
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
                    if !emojiPanelView.isHidden {
                        button.setTitle("ABC", for: .normal)
                        button.setImage(nil, for: .normal)
                    } else {
                        let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
                        button.setImage(UIImage(systemName: "face.smiling", withConfiguration: smileConfig), for: .normal)
                        button.setTitle(nil, for: .normal)
                    }
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

            // Mode-switch keys (bottom row: 123 / ABC, backspace row: #+= / 123) use
            // the same 17pt font as the emoji toolbar's ABC text for visual consistency.
            if isLastRow, let modeSwitch = buttons.first {
                modeSwitch.titleLabel?.font = .systemFont(ofSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
            }
            if rowIndex == rows.count - 2, let modeSwitch = buttons.first,
               modeSwitch.keyDefinition.action == .toggleNumber || modeSwitch.keyDefinition.action == .toggleSymbols {
                modeSwitch.titleLabel?.font = .systemFont(ofSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
            }

            // Row 2 (the backspace row, directly above the action row) is edge-anchored so
            // ⇧/#+=/123 and ⌫ land on identical pixel positions across all three layout modes.
            // The top two rows keep centered letter-pitch (staggered look); the action row fills proportionally.
            let layoutMode: KeyboardRowView.LayoutMode
            if isLastRow {
                layoutMode = .proportional
            } else if rowIndex == rows.count - 2 {
                layoutMode = .edgeAnchored
            } else {
                layoutMode = .letterPitch
            }
            let rowView = KeyboardRowView(keys: buttons, layoutMode: layoutMode)
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
            micButton.isEnabled = true

        case .waitingConfirm:
            micButton.applyMicStyle(
                icon: "questionmark.circle.fill",
                backgroundColor: .systemOrange
            )
            micButton.tintColor = .white
            micButton.isEnabled = true

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
        let showEmojiPanel = (mode == .emoji || mode == .emojiSearch)
        let showLetters    = (mode == .letters || mode == .emojiSearch)
        let showBottomRow  = showLetters
        let showSuggestBar = (mode == .letters)

        suggestionBar.isHidden = !showSuggestBar
        letterRegionContainer.isHidden = !showLetters
        bottomActionRow.isHidden = !showBottomRow
        emojiPanelView.isHidden = !showEmojiPanel
        if showEmojiPanel {
            emojiKeyButton?.setTitle("ABC", for: .normal)
            emojiKeyButton?.setImage(nil, for: .normal)
        } else {
            let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
            emojiKeyButton?.setImage(UIImage(systemName: "face.smiling", withConfiguration: smileConfig), for: .normal)
            emojiKeyButton?.setTitle(nil, for: .normal)
        }

        // Toggle the overlap constraint — active only in .emojiSearch
        emojiSearchOverlapConstraint?.isActive = (mode == .emojiSearch)

        if mode == .emojiSearch {
            // Defensive: ensure keyStack has rows (today this is a no-op since keyStack
            // is populated at startup, but protects against future regressions)
            if keyStack.arrangedSubviews.isEmpty {
                rebuildKeyRows()
            }
            // Force layout: when letterRegionContainer was hidden during .emoji mode,
            // its subviews' layoutSubviews didn't fire. Triggering a layout pass now
            // propagates fresh frames down to the KeyboardRowView instances.
            letterRegionContainer.setNeedsLayout()
            letterRegionContainer.layoutIfNeeded()
        }

        if showEmojiPanel { reloadEmojiPanel() }
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
        let token = delegate?.keyboardContextToken(self) ?? 0
        suggestionCache.update(suggestions, token: token)
        suggestionBar.update(with: suggestions)
    }

    func reloadEmojiPanel() {
        emojiPanelView.reloadData()
    }
}
