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
}

// MARK: - KeyButton

private class KeyButton: UIButton {
    let keyDefinition: KeyDefinition

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
        titleLabel?.font = .systemFont(ofSize: 18, weight: .regular)
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

        configureSpecialKeyImage()
        if title(for: .normal) == nil {
            setTitle(keyDefinition.label, for: .normal)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: keyDefinition.widthWeight, height: UIView.noIntrinsicMetric)
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.5 : 1.0
        }
    }

    private func configureSpecialKeyImage() {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        switch keyDefinition.action {
        case .backspace:
            setImage(UIImage(systemName: "delete.left", withConfiguration: config), for: .normal)
            setTitle(nil, for: .normal)
        case .shift, .shiftLock:
            let name = keyDefinition.action == .shiftLock ? "shift.fill" : "shift"
            setImage(UIImage(systemName: name, withConfiguration: config), for: .normal)
            setTitle(nil, for: .normal)
        case .mic:
            setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
            setTitle(nil, for: .normal)
            tintColor = .white
        case .return:
            setImage(UIImage(systemName: "return.left", withConfiguration: config), for: .normal)
            setTitle(nil, for: .normal)
        default:
            break
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

// MARK: - FloatingStrip

private class FloatingStrip: UIView {
    var globeTapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let globeButton = UIButton(type: .system)
        globeButton.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        globeButton.setImage(UIImage(systemName: "globe", withConfiguration: config), for: .normal)
        globeButton.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.7, alpha: 1)
                : UIColor(white: 0.3, alpha: 1)
        }
        globeButton.addTarget(self, action: #selector(globeButtonTapped), for: .touchUpInside)
        addSubview(globeButton)

        NSLayoutConstraint.activate([
            globeButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            globeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func globeButtonTapped() {
        globeTapped?()
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
    private let bottomActionRow = UIStackView()
    private let floatingStrip = FloatingStrip()

    // Key references
    private weak var micKeyButton: KeyButton?
    private weak var emojiKeyButton: KeyButton?

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
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1)
                : UIColor(white: 0.92, alpha: 1)
        }

        setupSuggestionBar()
        setupLetterRegion()
        setupEmojiPanel()
        setupFloatingStrip()
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

        // Bottom action row (Row 4) — always visible, sits between letter rows and floating strip
        bottomActionRow.axis = .horizontal
        bottomActionRow.distribution = .fillProportionally
        bottomActionRow.alignment = .fill
        bottomActionRow.spacing = 6
        bottomActionRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomActionRow)
    }

    private func setupEmojiPanel() {
        // EmojiPanelView is lazily initialized. Just add it to the hierarchy.
        // Its callbacks are wired in the lazy initializer.
        addSubview(emojiPanelView)
    }

    private func setupFloatingStrip() {
        floatingStrip.translatesAutoresizingMaskIntoConstraints = false
        floatingStrip.globeTapped = { [weak self] in
            guard let self = self else { return }
            self.delegate?.keyboardView(self, didPerform: .globe)
        }
        addSubview(floatingStrip)
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
            emojiPanelView.bottomAnchor.constraint(equalTo: bottomActionRow.topAnchor, constant: -6),

            // Bottom action row (Row 4) — always visible
            bottomActionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            bottomActionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            bottomActionRow.bottomAnchor.constraint(equalTo: floatingStrip.topAnchor, constant: -6),
            bottomActionRow.heightAnchor.constraint(equalToConstant: 48),

            // FloatingStrip — bottom
            floatingStrip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            floatingStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            floatingStrip.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
            floatingStrip.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    // MARK: - Key Rows

    private func rebuildKeyRows() {
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bottomActionRow.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let rows = KeyboardLayout.rows(for: currentLayoutMode)

        for (rowIndex, rowDefs) in rows.enumerated() {
            let isLastRow = rowIndex == rows.count - 1
            let targetStack = isLastRow ? bottomActionRow : keyStack

            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.distribution = .fillProportionally
            rowStack.alignment = .fill
            rowStack.spacing = 6
            rowStack.translatesAutoresizingMaskIntoConstraints = false

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
                default:
                    break
                }

                rowStack.addArrangedSubview(button)
            }

            targetStack.addArrangedSubview(rowStack)
        }

        // Re-apply mic state after rebuild
        let micState = delegate?.keyboardViewMicState(self) ?? .idle
        setMicState(micState)

        // Re-apply shift labels
        updateKeyButtonLabels()
    }

    private func updateKeyButtonLabels() {
        for rowStack in keyStack.arrangedSubviews {
            guard let stack = rowStack as? UIStackView else { continue }
            for case let button as KeyButton in stack.arrangedSubviews {
                button.updateLabel(for: currentShiftState)
            }
        }
    }

    // MARK: - Actions

    @objc private func keyTapped(_ sender: KeyButton) {
        delegate?.keyboardView(self, didPerform: sender.keyDefinition.action)
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
    }

    func refreshSuggestions() {
        let suggestions = delegate?.keyboardViewNeedsSuggestions(self) ?? []
        suggestionBar.update(with: suggestions)
    }

    func reloadEmojiPanel() {
        emojiPanelView.reloadData()
    }
}
