import UIKit

struct KeyboardSettingsPanelModel {
    let localOverride: Bool?
    let appGroupEnabled: Bool
    let effectiveEnabled: Bool
    let nextBranch: String
    let buildIdentity: String
    let resolverStrategy: String
    let containerAvailable: Bool
    let hasFullAccess: Bool
    let microphonePermission: String
}

final class KeyboardSettingsPanel: UIView {
    var onDismiss: (() -> Void)?
    var onModeChange: ((Bool?) -> Void)?

    private let backdrop = UIView()
    private let card = UIView()
    private let stack = UIStackView()
    private let modeControl = UISegmentedControl(items: ["Unset", "On", "Off"])
    private let modeSummaryLabel = UILabel()
    private let branchLabel = UILabel()
    private let buildLabel = UILabel()
    private let groupLabel = UILabel()
    private let permissionLabel = UILabel()

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
        let preferredCardWidth = card.widthAnchor.constraint(equalTo: widthAnchor, constant: -24)
        preferredCardWidth.priority = .defaultHigh

        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

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

        modeControl.selectedSegmentTintColor = EmojiPanelView.categoryHighlightColor
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        modeControl.heightAnchor.constraint(equalToConstant: 32).isActive = true

        configureDetailLabel(modeSummaryLabel, weight: .medium)
        modeSummaryLabel.numberOfLines = 2
        modeSummaryLabel.lineBreakMode = .byWordWrapping
        configureDetailLabel(branchLabel)
        branchLabel.numberOfLines = 2
        branchLabel.lineBreakMode = .byWordWrapping

        let divider = UIView()
        divider.backgroundColor = EmojiPanelView.categoryHighlightColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let diagnosticsTitle = UILabel()
        diagnosticsTitle.text = "Diagnostics"
        diagnosticsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        diagnosticsTitle.textColor = .secondaryLabel

        configureDetailLabel(buildLabel)
        configureDetailLabel(groupLabel)
        configureDetailLabel(permissionLabel)

        let arrangedSubviews: [UIView] = [
            header, modeControl, modeSummaryLabel, branchLabel, divider, diagnosticsTitle,
            buildLabel, groupLabel, permissionLabel
        ]
        arrangedSubviews.forEach { stack.addArrangedSubview($0) }

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
            preferredCardWidth,

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    private func configureDetailLabel(_ label: UILabel, weight: UIFont.Weight = .regular) {
        label.font = .systemFont(ofSize: 12, weight: weight)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingTail
    }

    func show(model: KeyboardSettingsPanelModel) {
        let wasHidden = isHidden
        switch model.localOverride {
        case nil: modeControl.selectedSegmentIndex = 0
        case .some(true): modeControl.selectedSegmentIndex = 1
        case .some(false): modeControl.selectedSegmentIndex = 2
        }
        let localDescription = model.localOverride == nil
            ? "unset (follows Group)"
            : modeLabel(model.localOverride)
        modeSummaryLabel.text = "Local: \(localDescription); Group: \(model.appGroupEnabled ? "on" : "off"); Effective: \(model.effectiveEnabled ? "on" : "off")"
        branchLabel.text = "Next mic: \(model.nextBranch)"
        buildLabel.text = "Build: \(model.buildIdentity)"
        groupLabel.text = "App Group: \(model.resolverStrategy) · \(model.containerAvailable ? "available" : "unavailable")"
        permissionLabel.text = "Full Access: \(model.hasFullAccess ? "yes" : "no") · Mic: \(model.microphonePermission)"
        guard wasHidden else { return }
        isHidden = false
        alpha = 0
        UIView.animate(withDuration: 0.12, delay: 0, options: .beginFromCurrentState) {
            self.alpha = 1
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

    private func modeLabel(_ override: Bool?) -> String {
        guard let override else { return "unset" }
        return override ? "on" : "off"
    }

    @objc private func modeChanged() {
        switch modeControl.selectedSegmentIndex {
        case 0: onModeChange?(nil)
        case 1: onModeChange?(true)
        case 2: onModeChange?(false)
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
