import UIKit

final class KeyboardSettingsPanel: UIView {
    var onDismiss: (() -> Void)?
    var onLanguageChange: ((KeyboardLanguage) -> Void)?

    private let backdrop = UIView()
    private let card = UIView()
    private let scrollView = UIScrollView()
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

    func show(activeLanguage: KeyboardLanguage) {
        update(activeLanguage: activeLanguage)
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
