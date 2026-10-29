import UIKit

final class KeyboardSettingsPanel: UIView {
    var onDismiss: (() -> Void)?
    var onLanguageChange: ((KeyboardLanguage) -> Void)?
    var onLLMCleanupPreferencesChange: ((LLMCleanupPreferences) -> Void)?

    private let backdrop = UIView()
    private let card = UIView()
    private let scrollView = UIScrollView()
    private let stylingControl = UIButton(type: .system)
    private let structureControl = UIButton(type: .system)
    private let contextControl = UIButton(type: .system)
    private let languageControl = UISegmentedControl(items: [
        KeyboardLanguage.english.shortLabel,
        KeyboardLanguage.greek.shortLabel,
    ])

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        isHidden = true

        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backdropTapped)))
        addSubview(backdrop)

        card.backgroundColor = EmojiPanelView.panelBackground
        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let titleLabel = UILabel()
        titleLabel.text = "Keyboard Settings"
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .label

        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = EmojiPanelView.modeKeyTextColor
        closeButton.accessibilityLabel = "Close keyboard settings"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let header = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        header.axis = .horizontal
        header.alignment = .center
        header.distribution = .fill

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = true

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let languageLabel = UILabel()
        languageLabel.text = "Keyboard language"
        languageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        languageLabel.textColor = .secondaryLabel

        languageControl.selectedSegmentTintColor = EmojiPanelView.categoryHighlightColor
        languageControl.accessibilityLabel = "Keyboard language"
        languageControl.addTarget(self, action: #selector(languageChanged), for: .valueChanged)
        contentStack.addArrangedSubview(languageLabel)
        contentStack.addArrangedSubview(languageControl)

        let cleanupLabel = UILabel()
        cleanupLabel.text = "LLM Cleanup"
        cleanupLabel.font = .systemFont(ofSize: 13, weight: .medium)
        cleanupLabel.textColor = .secondaryLabel
        contentStack.addArrangedSubview(cleanupLabel)

        configureMenuControl(stylingControl, accessibilityLabel: "Cleanup styling")
        configureMenuControl(structureControl, accessibilityLabel: "Cleanup structure")
        configureMenuControl(contextControl, accessibilityLabel: "Cleanup context")
        contentStack.addArrangedSubview(makeCleanupRow(title: "Styling", control: stylingControl))
        contentStack.addArrangedSubview(makeCleanupRow(title: "Structure", control: structureControl))
        contentStack.addArrangedSubview(makeCleanupRow(title: "Context", control: contextControl))

        let panelStack = UIStackView(arrangedSubviews: [header, scrollView])
        panelStack.axis = .vertical
        panelStack.alignment = .fill
        panelStack.spacing = 8
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(panelStack)

        let preferredWidth = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = card.heightAnchor.constraint(equalTo: heightAnchor, constant: -16)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            card.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            card.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            preferredWidth,
            preferredHeight,

            panelStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            panelStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            panelStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            panelStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),

            closeButton.heightAnchor.constraint(equalToConstant: 32),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    func show(
        activeLanguage: KeyboardLanguage,
        cleanupPreferences: LLMCleanupPreferences
    ) {
        update(activeLanguage: activeLanguage)
        update(cleanupPreferences: cleanupPreferences)
        guard isHidden else { return }
        isHidden = false
        alpha = 0
        UIView.animate(withDuration: 0.12, delay: 0, options: .beginFromCurrentState) {
            self.alpha = 1
        }
    }

    func update(activeLanguage: KeyboardLanguage) {
        switch activeLanguage {
        case .english: languageControl.selectedSegmentIndex = 0
        case .greek: languageControl.selectedSegmentIndex = 1
        }
    }

    private func configureMenuControl(_ control: UIButton, accessibilityLabel: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "chevron.down")
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.contentInsets = .zero
        control.configuration = configuration
        control.contentHorizontalAlignment = .right
        control.showsMenuAsPrimaryAction = true
        control.tintColor = EmojiPanelView.categoryHighlightColor
        control.accessibilityLabel = accessibilityLabel
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func makeCleanupRow(title: String, control: UIButton) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        row.spacing = 8
        return row
    }

    private func update(cleanupPreferences: LLMCleanupPreferences) {
        configureMenu(
            for: stylingControl,
            options: LLMCleanupStyling.allCases,
            selection: cleanupPreferences.styling,
            displayName: { $0.displayName }
        ) { [weak self] _ in
            self?.cleanupPreferenceSelectionChanged()
        }
        configureMenu(
            for: structureControl,
            options: LLMCleanupStructure.allCases,
            selection: cleanupPreferences.structure,
            displayName: { $0.displayName }
        ) { [weak self] _ in
            self?.cleanupPreferenceSelectionChanged()
        }
        configureMenu(
            for: contextControl,
            options: LLMCleanupContext.allCases,
            selection: cleanupPreferences.context,
            displayName: { $0.displayName }
        ) { [weak self] _ in
            self?.cleanupPreferenceSelectionChanged()
        }
    }

    private func configureMenu<Value: Equatable>(
        for control: UIButton,
        options: [Value],
        selection: Value,
        displayName: @escaping (Value) -> String,
        onSelection: @escaping (Value) -> Void
    ) {
        let selectedIndex = options.firstIndex(of: selection) ?? 0
        control.tag = selectedIndex

        var configuration = control.configuration ?? .plain()
        configuration.title = displayName(selection)
        control.configuration = configuration
        control.menu = UIMenu(
            title: "",
            options: .singleSelection,
            children: options.enumerated().map { index, option in
                UIAction(
                    title: displayName(option),
                    state: index == selectedIndex ? .on : .off
                ) { [weak control] _ in
                    guard let control else { return }
                    control.tag = index
                    var configuration = control.configuration ?? .plain()
                    configuration.title = displayName(option)
                    control.configuration = configuration
                    onSelection(option)
                }
            }
        )
    }

    private func cleanupPreferenceSelectionChanged() {
        let preferences = LLMCleanupPreferences(
            styling: LLMCleanupStyling.allCases[stylingControl.tag],
            structure: LLMCleanupStructure.allCases[structureControl.tag],
            context: LLMCleanupContext.allCases[contextControl.tag]
        )
        update(cleanupPreferences: preferences)
        onLLMCleanupPreferencesChange?(preferences)
    }

    func dismiss() {
        UIView.animate(withDuration: 0.1, animations: {
            self.alpha = 0
        }, completion: { _ in
            self.isHidden = true
            self.alpha = 1
        })
    }

    @objc private func languageChanged() {
        switch languageControl.selectedSegmentIndex {
        case 0: onLanguageChange?(.english)
        case 1: onLanguageChange?(.greek)
        default: break
        }
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    @objc private func backdropTapped() {
        onDismiss?()
    }
}
