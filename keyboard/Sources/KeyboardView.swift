import UIKit

// MARK: - Keyboard State

enum KeyboardState: Equatable {
    case idle
    case openingApp
    case recording
    case waiting
    case inserting
    case error(String)

    /// Lean state tag for crash-survival logs (avoids large .error(msg) strings under Jetsam cap)
    static func shortTag(_ s: KeyboardState) -> String {
        switch s {
        case .idle: return "idle"
        case .openingApp: return "openingApp"
        case .recording: return "recording"
        case .waiting: return "waiting"
        case .inserting: return "inserting"
        case .error: return "error"
        }
    }
}

// MARK: - Shift State

enum ShiftState: Equatable {
    case lower
    case upper
    case locked
}

// MARK: - UI Mode

/// The keyboard SURFACE currently shown to the user. Owned by
/// `KeyboardViewController.uiMode`. Orthogonal to `KeyboardLayoutMode`.
///   - `.letters`     → letter/number/symbol key grid (see KeyboardLayoutMode)
///   - `.emoji`       → emoji panel grid (EmojiPanelView)
///   - `.emojiSearch` → search overlay (EmojiSearchOverlay) over the panel
/// These two mode systems are NOT kept in sync; a `.letters`-surface keystroke
/// can briefly coincide with a stale `.emoji`/`.emojiSearch` value during async
/// search-field focus transitions. Emoji-recents recording therefore happens at
/// the picker tap handlers, not here.
enum UIMode: Equatable {
    case letters
    case emoji
    case emojiSearch
}

// MARK: - Suggestion Input Snapshot

struct SuggestionInputSnapshot {
    let currentWord: String
    let lookupWord: String
    let previousWord: String?
    let previousWord2: String?
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardView(_ view: KeyboardView, didPerform action: KeyAction)
    func keyboardView(_ view: KeyboardView, didTapSuggestion text: String)
    func keyboardView(_ view: KeyboardView, didLongPressSuggestion text: String)
    func keyboardViewSuggestionSnapshot(_ view: KeyboardView) -> SuggestionInputSnapshot?
    func keyboardViewPredictionEngine(_ view: KeyboardView) -> PredictionEngine?
    func keyboardViewMicState(_ view: KeyboardView) -> KeyboardState
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView)
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView)
    func keyboardViewDidRequestCancelDictation(_ view: KeyboardView)
    func keyboardContextToken(_ view: KeyboardView) -> UInt64
}

extension KeyboardViewDelegate {
    func keyboardViewBackspaceDidBegin(_ view: KeyboardView) {}
    func keyboardViewBackspaceDidEnd(_ view: KeyboardView) {}
    func keyboardView(_ view: KeyboardView, didLongPressSuggestion text: String) {}
    func keyboardViewDidRequestCancelDictation(_ view: KeyboardView) {}
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

    /// Set true when the 3s cancel long-press fires on the mic button, so the
    /// trailing touchUpInside can be suppressed (prevents a cancel + stop).
    var micLongPressDidFire = false

    /// Called whenever isHighlighted transitions. KeyboardView uses this to show/hide
    /// the character preview popup without needing touch-event wiring.
    var onHighlightChange: ((KeyButton, Bool) -> Void)?

    /// Manually managed pressed state for dead-zone touches where hitTest routes
    /// the touch to this key but isHighlighted doesn't fire because the touch is
    /// outside the key's bounds. The container (KeyboardView) sets this in hitTest.
    private(set) var isPressedViaHitTest = false {
        didSet {
            guard isPressedViaHitTest != oldValue else { return }
            updatePressVisuals()
        }
    }

    /// Apple-style key-press highlight: a dynamic color that adapts to
    /// light/dark mode. Used when isHighlighted=true.
    private static let highlightBackgroundColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.45, alpha: 1)
            : UIColor(white: 0.62, alpha: 1)
    }

    /// Thin underline shown beneath the shift icon when Caps Lock is engaged,
    /// matching the native iOS keyboard's caps-lock affordance.
    private let capsLockUnderline: UIView = {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.layer.cornerRadius = 1
        return view
    }()

    /// The resting (non-pressed) background color. Restored when isHighlighted
    /// transitions to false. Must be kept in sync whenever backgroundColor is
    /// overridden outside of highlight (e.g. applyMicStyle).
    private var restingBackgroundColor: UIColor = .clear

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

        let resting = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.28, alpha: 1)
                : UIColor(white: 0.82, alpha: 1)
        }
        backgroundColor = resting
        restingBackgroundColor = resting
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
            updatePressVisuals()
        }
    }

    /// Unified visual update that checks both standard isHighlighted and the
    /// container-managed isPressedViaHitTest flag. This ensures dead-zone touches
    /// (routed via hitTest but outside the key's bounds) still trigger the
    /// highlight and onHighlightChange callback.
    private func updatePressVisuals() {
        let pressed = isHighlighted || isPressedViaHitTest
        backgroundColor = pressed ? Self.highlightBackgroundColor : restingBackgroundColor
        alpha = 1.0
        onHighlightChange?(self, pressed)
    }

    /// Called by KeyboardView in hitTest when routing a dead-zone touch to this key.
    func setPressedViaHitTest() {
        isPressedViaHitTest = true
    }

    /// Called by KeyboardView when the touch ends (via keyTouchEnded).
    func clearPressedViaHitTest() {
        isPressedViaHitTest = false
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
            let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.emojiToggleIconPointSize, weight: .regular)
            setImage(UIImage(systemName: "face.smiling", withConfiguration: smileConfig), for: .normal)
        case .space:
            let spaceConfig = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            setImage(UIImage(systemName: "space", withConfiguration: spaceConfig), for: .normal)
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
            self.restingBackgroundColor = color
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
    var suggestionLongPressed: ((Int) -> Void)?
    var languageTapped: (() -> Void)?

    private let stack = UIStackView()
    private var segments: [UIButton] = []
    private let languageButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Transparent so the KeyboardView's panelBackground shows through; the
        // individual suggestion segments still draw their own tile backgrounds.
        backgroundColor = .clear

        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .fill
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        languageButton.translatesAutoresizingMaskIntoConstraints = false
        languageButton.setTitle(KeyboardLanguage.english.shortLabel, for: .normal)
        languageButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        languageButton.setTitleColor(UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor.white
                : UIColor.black
        }, for: .normal)
        languageButton.backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1)
                : UIColor(white: 0.92, alpha: 1)
        }
        languageButton.addTarget(self, action: #selector(languageButtonTapped), for: .touchUpInside)
        addSubview(languageButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: languageButton.leadingAnchor, constant: -1),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            languageButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            languageButton.topAnchor.constraint(equalTo: topAnchor),
            languageButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            languageButton.widthAnchor.constraint(equalToConstant: 40),
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
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(segmentLongPressed(_:)))
            longPress.minimumPressDuration = 0.4
            longPress.allowableMovement = 10
            segment.addGestureRecognizer(longPress)
            stack.addArrangedSubview(segment)
            segments.append(segment)
        }
    }

    @objc private func segmentTapped(_ sender: UIButton) {
        suggestionTapped?(sender.tag)
    }

    @objc private func segmentLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton else { return }
        suggestionLongPressed?(button.tag)
    }

    @objc private func languageButtonTapped() {
        languageTapped?()
    }

    func updateLanguage(_ language: KeyboardLanguage) {
        languageButton.setTitle(language.shortLabel, for: .normal)
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

    /// Called when the emoji panel's ABC button is tapped; the controller sets this to route through uiMode.
    var onReturnToLetters: (() -> Void)?

    /// Called when the suggestion bar's language button is tapped; the controller presents the language picker.
    var languageTapped: (() -> Void)?

    // Subviews
    private var _suggestionBar: SuggestionBar?
    private var suggestionBar: SuggestionBar {
        if let v = _suggestionBar { return v }
        let v = SuggestionBar()
        _suggestionBar = v
        return v
    }
    /// Injected on every refreshSuggestions call and read by the suggestion-tap closure.
    private var suggestionCache = SuggestionDisplayCache()
    private var _letterRegionContainer: UIView?
    private var letterRegionContainer: UIView {
        if let v = _letterRegionContainer { return v }
        let v = UIView()
        _letterRegionContainer = v
        return v
    }
    private var _keyStack: UIStackView?
    private var keyStack: UIStackView {
        if let v = _keyStack { return v }
        let v = UIStackView()
        _keyStack = v
        return v
    }
    /// Internal so KeyboardViewController can route keystrokes to searchField in .emojiSearch mode.
    private var _emojiPanelView: EmojiPanelView?
    var emojiPanelView: EmojiPanelView {
        if let v = _emojiPanelView { return v }
        let panel = EmojiPanelView(frame: .zero)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.onSelect = { [weak self] emoji in
            guard let self = self else { return }
            self.delegate?.keyboardView(self, didPerform: .insertText(emoji))
        }
        panel.onDismiss = { [weak self] in
            self?.onReturnToLetters?() // route through uiMode so the toggle state stays in sync with the view
        }
        panel.onBackspace = { [weak self] in
            guard let self else { return }
            self.delegate?.keyboardViewBackspaceDidBegin(self)
            self.delegate?.keyboardViewBackspaceDidEnd(self)
        }
        _emojiPanelView = panel
        return panel
    }
    /// Overlay for emoji search — visible only in .emojiSearch mode, above the
    /// suggestion bar. Closures are wired by KeyboardViewController.
    private var _emojiSearchOverlay: EmojiSearchOverlay?
    var emojiSearchOverlay: EmojiSearchOverlay {
        if let v = _emojiSearchOverlay { return v }
        let v = EmojiSearchOverlay()
        v.translatesAutoresizingMaskIntoConstraints = false
        _emojiSearchOverlay = v
        return v
    }
    private var _bottomActionRow: UIView?
    private var bottomActionRow: UIView {
        if let v = _bottomActionRow { return v }
        let v = UIView()
        _bottomActionRow = v
        return v
    }

    /// Single reusable character preview popup — recycled across key presses.
    /// Never per-tap allocated. See 48 MB Jetsam constraint.
    private var _keyPreview: KeyPreviewView?
    private var keyPreview: KeyPreviewView {
        if let v = _keyPreview { return v }
        let v = KeyPreviewView()
        _keyPreview = v
        return v
    }

    /// Single reusable language picker overlay — recycled across shows. Never
    /// per-open allocated. See 48 MB Jetsam constraint.
    private var _languageMenu: LanguageMenuView?
    var languageMenu: LanguageMenuView {
        if let v = _languageMenu { return v }
        let v = LanguageMenuView()
        v.translatesAutoresizingMaskIntoConstraints = false
        _languageMenu = v
        return v
    }

    // Key references
    private weak var micKeyButton: KeyButton?
    private weak var emojiKeyButton: KeyButton?
    private weak var shiftKeyButton: KeyButton?
    private weak var bottomRowView: KeyboardRowView?
    /// Tracks the key that was manually pressed via hitTest routing (dead-zone
    /// touches). Cleared when the touch ends via keyTouchEnded.
    private var hitTestPressedKey: KeyButton?
    private var allKeyButtons: [KeyButton] = []

    // State tracking
    private var hasFullAccess = false
    private var currentShiftState: ShiftState = .lower
    private var currentLayoutMode: KeyboardLayoutMode = .letters
    private(set) var currentLanguage: KeyboardLanguage = .english

    /// The 3s cancel-progress ring on the mic button. Only populated while the
    /// finger is held down; removed on every touch-up and on the long-press fire.
    private var micProgressRing: CAShapeLayer?

    /// Height constraint for emojiSearchOverlay — 0 when hidden, overlayHeight when active.
    private var emojiSearchOverlayHeightConstraint: NSLayoutConstraint?

    // Suggestion lookup concurrency
    private let suggestionLookupQueue = DispatchQueue(
        label: "com.ritoras.suggestion.lookup",
        qos: .userInitiated
    )
    private var suggestionLookupWorkItem: DispatchWorkItem?

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
        // Allow the key preview popup to extend above/over sibling keys.
        // Top-edge clipping at the UIWindow level is accepted.
        clipsToBounds = false

        setupSuggestionBar()
        setupLetterRegion()
        setupEmojiPanel()

        addSubview(emojiSearchOverlay)
        bringSubviewToFront(emojiSearchOverlay)

        addSubview(languageMenu)
        bringSubviewToFront(languageMenu)

        setupConstraints()

        addSubview(keyPreview)
        bringSubviewToFront(keyPreview)

        rebuildKeyRows()
        apply(mode: .letters)

    }

    private func setupSuggestionBar() {
        suggestionBar.translatesAutoresizingMaskIntoConstraints = false
        suggestionBar.suggestionTapped = { [weak self] index in
            guard let self = self else { return }
            let liveToken = self.delegate?.keyboardContextToken(self) ?? 0
            guard let suggestion = decideSuggestionTap(cache: self.suggestionCache, liveToken: liveToken, index: index) else {
                FileLogger.shared.debug(.keyboard, "suggestion cache stale tap ignored", payload: ["idx": index, "cacheToken": self.suggestionCache.token, "liveToken": liveToken])
                return
            }
            self.delegate?.keyboardView(self, didTapSuggestion: suggestion)
        }
        suggestionBar.suggestionLongPressed = { [weak self] index in
            guard let self = self else { return }
            let liveToken = self.delegate?.keyboardContextToken(self) ?? 0
            guard let suggestion = decideSuggestionTap(cache: self.suggestionCache, liveToken: liveToken, index: index) else {
                FileLogger.shared.debug(.keyboard, "suggestion cache stale long-press ignored", payload: ["idx": index, "cacheToken": self.suggestionCache.token, "liveToken": liveToken])
                return
            }
            self.delegate?.keyboardView(self, didLongPressSuggestion: suggestion)
        }
        suggestionBar.languageTapped = { [weak self] in
            guard let self = self else { return }
            self.languageTapped?()
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
        let emojiPanelBottom = emojiPanelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        emojiPanelBottom.priority = .defaultHigh

        // Create overlay height constraint (0 = hidden, overlayHeight when active)
        emojiSearchOverlayHeightConstraint = emojiSearchOverlay.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            // Emoji search overlay — pinned to the very top; 0 when inactive
            emojiSearchOverlay.topAnchor.constraint(equalTo: topAnchor),
            emojiSearchOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            emojiSearchOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            emojiSearchOverlayHeightConstraint!,

            // SuggestionBar — pinned to the overlay's bottom; when overlay height is 0
            // this is equivalent to topAnchor, preserving the current layout.
            suggestionBar.topAnchor.constraint(equalTo: emojiSearchOverlay.bottomAnchor, constant: 0),
            suggestionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            suggestionBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            suggestionBar.heightAnchor.constraint(equalToConstant: 36),

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
            bottomActionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            bottomActionRow.heightAnchor.constraint(equalToConstant: 48),

            // Language picker overlay — covers the whole keyboard when shown
            languageMenu.topAnchor.constraint(equalTo: topAnchor),
            languageMenu.leadingAnchor.constraint(equalTo: leadingAnchor),
            languageMenu.trailingAnchor.constraint(equalTo: trailingAnchor),
            languageMenu.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Key Rows

    private func rebuildKeyRows() {
        keyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        bottomRowView?.removeFromSuperview()
        bottomRowView = nil
        shiftKeyButton = nil

        let rows = KeyboardLayout.rows(for: currentLayoutMode, language: currentLanguage)

        for (rowIndex, rowDefs) in rows.enumerated() {
            let isLastRow = rowIndex == rows.count - 1

            // Build the key buttons for this row.
            var buttons: [KeyButton] = []
            buttons.reserveCapacity(rowDefs.count)
            for def in rowDefs {
                let button = KeyButton(definition: def)
                button.addTarget(self, action: #selector(keyTapped(_:)), for: [.touchUpInside, .touchUpOutside])
                // Clear hit-test pressed state when touch ends (regardless of location)
                button.addTarget(self, action: #selector(keyTouchEnded(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])

                switch def.action {
                case .mic:
                    micKeyButton = button
                    // Single-tap → stop (fires through keyTapped → handleMicButtonTap);
                    // 3s long-press → cancel. Touch-down/up drive the progress ring.
                    button.addTarget(self, action: #selector(micTouchDown(_:)), for: .touchDown)
                    button.addTarget(self, action: #selector(micTouchUp(_:)),
                                     for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
                    let lp = UILongPressGestureRecognizer(target: self, action: #selector(micLongPressed(_:)))
                    lp.minimumPressDuration = 3.0
                    lp.allowableMovement = 40   // default 10 is too tight for a 3s hold — finger drift would silently fail
                    button.addGestureRecognizer(lp)
                case .emoji:
                    emojiKeyButton = button
                    if !emojiPanelView.isHidden {
                        button.setTitle("ABC", for: .normal)
                        button.setImage(nil, for: .normal)
                    } else {
                        let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.emojiToggleIconPointSize, weight: .regular)
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

                // Wire character preview popup to highlight changes.
                button.onHighlightChange = { [weak self] kb, highlighted in
                    guard let self = self else { return }
                    if highlighted {
                        guard case .insertText = kb.keyDefinition.action,
                              self.emojiPanelView.isHidden else { return }
                        let glyph: String
                        if self.currentShiftState != .lower, let shifted = kb.keyDefinition.shiftedLabel {
                            glyph = shifted
                        } else {
                            glyph = kb.keyDefinition.label
                        }
                        let keyFrame = kb.convert(kb.bounds, to: self)
                        self.keyPreview.show(for: glyph, anchoredAbove: keyFrame)
                        self.bringSubviewToFront(self.keyPreview)
                    } else {
                        self.keyPreview.hide()
                    }
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

        // Rebuild hit-test key cache
        allKeyButtons = []
        for case let rowView as KeyboardRowView in keyStack.arrangedSubviews {
            allKeyButtons.append(contentsOf: rowView.keys)
        }
        if let bottomRow = bottomRowView {
            allKeyButtons.append(contentsOf: bottomRow.keys)
        }

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
        if sender.micLongPressDidFire {
            sender.micLongPressDidFire = false
            return
        }
        switch sender.keyDefinition.action {
        case .insertText, .space, .return:
            DispatchQueue.main.async { HapticsManager.shared.tapImpact() }
        case .shift, .shiftLock,
             .toggleNumber, .toggleLetters, .toggleSymbols,
             .emoji, .globe:
            DispatchQueue.main.async { HapticsManager.shared.tapSelection() }
        case .backspace, .mic:
            break  // handled at dedicated touch-down sites
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
        HapticsManager.shared.tapSelection()
        delegate?.keyboardView(self, didPerform: .shiftLock)
    }

    /// Touch-down on the mic button. If dictation is active, starts the 3s
    /// progress ring (a plain start-dictation tap in .idle shows no ring).
    @objc private func micTouchDown(_ sender: KeyButton) {
        sender.micLongPressDidFire = false
        let micState = delegate?.keyboardViewMicState(self)
        guard micState == .recording || micState == .waiting else { return }
        startMicHoldProgress(on: sender)
    }

    /// Touch-up (including outside/cancelled) clears the progress ring. Fires
    /// before keyTapped, so a quick tap removes the ring and the single-tap
    /// stop path runs normally.
    @objc private func micTouchUp(_ sender: KeyButton) {
        cancelMicHoldProgress(on: sender)
    }

    /// 3s long-press on the mic button cancels dictation.
    @objc private func micLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? KeyButton else { return }
        let micState = delegate?.keyboardViewMicState(self)
        cancelMicHoldProgress(on: button)
        guard micState == .recording || micState == .waiting else { return }
        button.micLongPressDidFire = true
        HapticsManager.shared.tapCancelWarning()
        delegate?.keyboardViewDidRequestCancelDictation(self)
    }

    // MARK: - Mic Hold Progress Ring

    /// Starts a 3s circular progress ring on the mic button. White stroke is
    /// high-contrast on BOTH the red recording background (.systemRed) and the
    /// light/dark gray waiting background.
    private func startMicHoldProgress(on button: KeyButton) {
        guard button.bounds.width > 0, button.bounds.height > 0 else { return }
        cancelMicHoldProgress(on: button)
        let ring = CAShapeLayer()
        let radius = min(button.bounds.width, button.bounds.height) / 2 - 4
        ring.path = UIBezierPath(
            arcCenter: CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            radius: radius,
            startAngle: -CGFloat.pi / 2,
            endAngle: 3 * CGFloat.pi / 2,
            clockwise: true
        ).cgPath
        ring.lineWidth = 3
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        ring.strokeEnd = 0
        button.layer.addSublayer(ring)
        micProgressRing = ring
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = 3.0
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        ring.add(animation, forKey: "micHoldProgress")
        ring.strokeEnd = 1.0
    }

    /// Removes the progress ring if one is active. Safe to call with no ring.
    private func cancelMicHoldProgress(on button: KeyButton) {
        micProgressRing?.removeFromSuperlayer()
        micProgressRing = nil
    }

    /// Touch-down on backspace sets the suppression flag and signals the controller
    /// to begin the repeat sequence (single delete immediately, repeated deletes in Phase 4).
    @objc private func backspaceTouchDown(_ sender: KeyButton) {
        sender.backspaceSuppressTap = true
        DispatchQueue.main.async {
            HapticsManager.shared.prepareImpact()
            HapticsManager.shared.tapImpact()
        }
        delegate?.keyboardViewBackspaceDidBegin(self)
    }

    /// Touch-up (including outside or cancelled) signals the controller to stop repeating.
    @objc private func backspaceTouchUp(_ sender: KeyButton) {
        delegate?.keyboardViewBackspaceDidEnd(self)
    }

    /// Clears the hit-test pressed state when a touch ends, regardless of whether
    /// it ended inside or outside the key bounds.
    @objc private func keyTouchEnded(_ sender: KeyButton) {
        sender.clearPressedViaHitTest()
        if hitTestPressedKey === sender {
            hitTestPressedKey = nil
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }

        // When the language picker overlay is visible it owns all touches: skip
        // key-region dead-zone routing so taps on the dimmed backdrop dismiss
        // the menu instead of pressing the keys beneath it.
        if !languageMenu.isHidden {
            return super.hitTest(point, with: event)
        }

        let inKeyRegion = point.y >= letterRegionContainer.frame.minY &&
                          point.y <= bottomActionRow.frame.maxY

        if inKeyRegion {
            // Skip nearest-key routing when letter region is hidden (emoji mode)
            guard !letterRegionContainer.isHidden else {
                return super.hitTest(point, with: event)
            }

            // Direct hit on a key button — fast path
            if let hit = super.hitTest(point, with: event), hit is KeyButton {
                return hit
            }

            // Dead-zone elimination: find the nearest visible key
            var nearestKey: KeyButton?
            var nearestDistance: CGFloat = .greatestFiniteMagnitude
            for key in allKeyButtons {
                guard !key.isHidden, key.alpha > 0.01, key.isUserInteractionEnabled else { continue }
                let frameInSelf = key.convert(key.bounds, to: self)
                let dist = frameEdgeDistance(from: point, to: frameInSelf)
                if dist < nearestDistance {
                    nearestDistance = dist
                    nearestKey = key
                }
            }

            if let nearestKey = nearestKey {
                // Clear previous manually-pressed key
                hitTestPressedKey?.clearPressedViaHitTest()
                // Set the new one
                nearestKey.setPressedViaHitTest()
                hitTestPressedKey = nearestKey
                return nearestKey
            }

            // No visible keys (e.g. emoji mode) — defer to normal hit-testing
            return super.hitTest(point, with: event)
        }

        // Outside key region — normal hit-testing (suggestion bar, emoji panel, etc.)
        return super.hitTest(point, with: event)
    }

    /// Returns 0 if `point` is inside `rect`, else the Euclidean distance from
    /// `point` to the nearest point on `rect`'s perimeter.
    private func frameEdgeDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        if dx == 0 && dy == 0 { return 0 }
        return hypot(dx, dy)
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

        case .recording:
            micButton.applyMicStyle(
                icon: "circle.fill",
                backgroundColor: .systemRed
            )
            micButton.tintColor = .white
            micButton.isEnabled = true

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
        let inSearch         = (mode == .emojiSearch)
        let showEmojiPanel   = (mode == .emoji)
        let showLetters      = (mode == .letters || mode == .emojiSearch)
        let showBottomRow    = showLetters
        let showSuggestBar   = (mode == .letters || mode == .emojiSearch)
        let showOverlay      = inSearch

        // Dismiss key preview popup when switching to emoji/emojiSearch mode.
        if inSearch || showEmojiPanel { keyPreview.hide() }

        suggestionBar.isHidden = !showSuggestBar
        letterRegionContainer.isHidden = !showLetters
        bottomActionRow.isHidden = !showBottomRow
        emojiPanelView.isHidden = !showEmojiPanel
        emojiSearchOverlay.isHidden = !showOverlay
        emojiSearchOverlayHeightConstraint?.constant = showOverlay ? EmojiSearchOverlay.overlayHeight : 0

        if showEmojiPanel {
            emojiKeyButton?.setTitle("ABC", for: .normal)
            emojiKeyButton?.setImage(nil, for: .normal)
        } else {
            let smileConfig = UIImage.SymbolConfiguration(pointSize: EmojiPanelView.emojiToggleIconPointSize, weight: .regular)
            emojiKeyButton?.setImage(UIImage(systemName: "face.smiling", withConfiguration: smileConfig), for: .normal)
            emojiKeyButton?.setTitle(nil, for: .normal)
        }

        if inSearch {
            emojiSearchOverlay.activate()
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
        } else {
            emojiSearchOverlay.deactivate()
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

    /// Switches the key grid's language and returns to the letters layout
    /// (Apple behavior: a language switch drops back to the letter surface).
    /// The controller mirrors this with its own `layoutMode = .letters`.
    func setLanguage(_ language: KeyboardLanguage) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        currentLayoutMode = .letters
        rebuildKeyRows()
        suggestionBar.updateLanguage(language)
    }

    func refreshSuggestions() {
        let token = delegate?.keyboardContextToken(self) ?? 0

        guard let snapshot = delegate?.keyboardViewSuggestionSnapshot(self),
              let engine = delegate?.keyboardViewPredictionEngine(self) else {
            // Wrong target or engine not ready — clear synchronously, no hop needed.
            suggestionLookupWorkItem?.cancel()
            suggestionLookupWorkItem = nil
            suggestionCache.update([], token: token)
            suggestionBar.update(with: [])
            return
        }

        // Capture the last-shown suggestion set synchronously (main thread)
        // before the async lookup hop. The sticky-rescue pass in the engine
        // uses it to keep long completions visible as the user types.
        let previousDisplayed = suggestionCache.displayed

        // Cancel any in-flight lookup before issuing a new one.
        // Guarantees at most one lookup in flight (48 MB Jetsam: no parallel
        // SymSpell result sets).
        suggestionLookupWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self, weak engine] in
            guard let self = self, let engine = engine else { return }
            let suggestions = engine.suggestions(
                forCurrentWord: snapshot.currentWord,
                lookupWord: snapshot.lookupWord,
                previousWord: snapshot.previousWord,
                previousWord2: snapshot.previousWord2,
                limit: 3,
                previousSuggestions: previousDisplayed
            )
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Liveness gate: if the keyboard is no longer in a window,
                // the textDocumentProxy is dead — reading it via keyboardContextToken
                // (which reads documentContextBeforeInput) would crash with SIGSEGV.
                if self.window == nil {
                    return
                }
                let liveToken = self.delegate?.keyboardContextToken(self) ?? 0
                // Stale-result guard: if the user typed more while the lookup was
                // in flight, the live token will differ from the captured one.
                // Drop the stale result — it must not overwrite fresh state.
                if !shouldApplyLookupResult(capturedToken: token, liveToken: liveToken) {
                    return
                }
                self.suggestionCache.update(suggestions, token: token)
                self.suggestionBar.update(with: suggestions)
            }
        }
        suggestionLookupWorkItem = workItem
        suggestionLookupQueue.async(execute: workItem)
    }

    /// Releases the engine-capturing suggestion work item. Called by the VC on
    /// keyboard hide so the prediction engine (captured strongly inside the
    /// work item's closure) is freed along with the VC's own engine property.
    func cancelSuggestionLookup() {
        let hadWorkItem = suggestionLookupWorkItem != nil
        suggestionLookupWorkItem?.cancel()
        suggestionLookupWorkItem = nil
        FileLogger.shared.debug(.keyboard, "suggestion lookup shed",
            payload: ["hadWorkItem": hadWorkItem])
    }

    func reloadEmojiPanel() {
        emojiPanelView.reloadData()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // iOS re-attaches the SAME KeyboardView instance on the next show, and
            // setupView() runs only once (in init). Shredding the UIKit hierarchy
            // here would leave a permanently empty frame after one app switch, so
            // the subview tree is intentionally KEPT. The in-flight suggestion
            // lookup is cancelled defensively in case this detach fires on a path
            // where viewWillDisappear did not — idempotent, and the work item is
            // also liveness-gated (self.window == nil) and cancelled from the
            // controller's viewWillDisappear teardown.
            cancelSuggestionLookup()
            FileLogger.shared.info(.keyboard, "KeyboardView detached from window",
                payload: ["footprint": MemoryMonitor.currentFootprint()])
        } else {
            FileLogger.shared.info(.keyboard, "KeyboardView didMoveToWindow",
                payload: ["hasWindow": true])
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        super.willMove(toSuperview: newSuperview)
        FileLogger.shared.debug(.keyboard, "KeyboardView willMove(toSuperview:)",
            payload: ["removed": newSuperview == nil])
    }

    deinit {
        FileLogger.shared.info(.keyboard, "KeyboardView deinit",
            payload: ["hadPendingWorkItem": suggestionLookupWorkItem != nil])
    }
}
