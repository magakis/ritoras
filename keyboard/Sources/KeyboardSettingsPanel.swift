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
    let localServerOverride: String?
    let effectiveServerURL: String
    let effectiveServerSource: String
}

final class KeyboardSettingsPanel: UIView, UITextFieldDelegate {
    var onDismiss: (() -> Void)?
    var onModeChange: ((Bool?) -> Void)?
    var onServerURLSave: ((String?) -> Void)?
    var onServerEditingChanged: ((Bool) -> Void)?

    private let backdrop = UIView()
    private let card = UIView()
    private let stack = UIStackView()
    private let modeControl = UISegmentedControl(items: ["Unset", "On", "Off"])
    private let modeSummaryLabel = UILabel()
    private let branchLabel = UILabel()
    private let buildLabel = UILabel()
    private let groupLabel = UILabel()
    private let permissionLabel = UILabel()
    private let serverURLField = UITextField()
    private let serverURLErrorLabel = UILabel()
    private let effectiveServerLabel = UILabel()

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
        stack.spacing = 1
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
        modeControl.heightAnchor.constraint(equalToConstant: 28).isActive = true

        configureDetailLabel(modeSummaryLabel, weight: .medium)
        modeSummaryLabel.numberOfLines = 1
        modeSummaryLabel.lineBreakMode = .byTruncatingTail
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

        serverURLField.placeholder = "Server URL override (http:// or https://)"
        serverURLField.font = .systemFont(ofSize: 12)
        serverURLField.borderStyle = .roundedRect
        serverURLField.autocapitalizationType = .none
        serverURLField.autocorrectionType = .no
        serverURLField.spellCheckingType = .no
        serverURLField.keyboardType = .URL
        serverURLField.returnKeyType = .done
        serverURLField.clearButtonMode = .whileEditing
        serverURLField.delegate = self
        serverURLField.addTarget(self, action: #selector(serverEditingChanged), for: .editingDidBegin)
        serverURLField.addTarget(self, action: #selector(serverEditingEnded), for: .editingDidEnd)

        let saveServerButton = UIButton(type: .system)
        saveServerButton.setTitle("Save", for: .normal)
        saveServerButton.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        saveServerButton.addTarget(self, action: #selector(saveServerURLTapped), for: .touchUpInside)

        let serverInputRow = UIStackView(arrangedSubviews: [serverURLField, saveServerButton])
        serverInputRow.axis = .horizontal
        serverInputRow.alignment = .center
        serverInputRow.distribution = .fill
        serverInputRow.spacing = 6
        serverInputRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        saveServerButton.setContentHuggingPriority(.required, for: .horizontal)

        serverURLErrorLabel.font = .systemFont(ofSize: 10)
        serverURLErrorLabel.textColor = .systemRed
        serverURLErrorLabel.numberOfLines = 1
        serverURLErrorLabel.isHidden = true
        configureDetailLabel(effectiveServerLabel)
        effectiveServerLabel.numberOfLines = 2
        effectiveServerLabel.font = .systemFont(ofSize: 10)

        let arrangedSubviews: [UIView] = [
            header, modeControl, modeSummaryLabel, branchLabel, divider, diagnosticsTitle,
            buildLabel, groupLabel, permissionLabel, serverInputRow,
            serverURLErrorLabel, effectiveServerLabel
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

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    private func configureDetailLabel(_ label: UILabel, weight: UIFont.Weight = .regular) {
        label.font = .systemFont(ofSize: 11, weight: weight)
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
        modeSummaryLabel.text = "Local \(localDescription) · Group \(model.appGroupEnabled ? "on" : "off") · Effective \(model.effectiveEnabled ? "on" : "off")"
        branchLabel.text = "Next mic: \(model.nextBranch)"
        buildLabel.text = "Build: \(model.buildIdentity)"
        groupLabel.text = "App Group: \(model.resolverStrategy) · \(model.containerAvailable ? "available" : "unavailable")"
        permissionLabel.text = "Full Access: \(model.hasFullAccess ? "yes" : "no") · Mic: \(model.microphonePermission)"
        effectiveServerLabel.text = "Effective server: \(model.effectiveServerURL) · Source: \(model.effectiveServerSource)"
        if wasHidden {
            serverURLField.text = model.localServerOverride
            serverURLErrorLabel.text = nil
            serverURLErrorLabel.isHidden = true
        }
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

    func insertServerURLText(_ text: String) {
        serverURLField.insertText(text)
    }

    func deleteServerURLBackward() {
        serverURLField.deleteBackward()
    }

    var hasServerURLText: Bool {
        !(serverURLField.text?.isEmpty ?? true)
    }

    func resignServerURLField() {
        serverURLField.resignFirstResponder()
    }

    private func saveServerURL() {
        let input = (serverURLField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            serverURLField.text = ""
            serverURLErrorLabel.text = nil
            serverURLErrorLabel.isHidden = true
            serverURLField.resignFirstResponder()
            onServerURLSave?(nil)
            return
        }
        guard let normalizedURL = Self.normalizeServerBaseURL(input) else {
            serverURLErrorLabel.text = "Enter a valid http:// or https:// server URL."
            serverURLErrorLabel.isHidden = false
            return
        }
        serverURLField.text = normalizedURL
        serverURLErrorLabel.text = nil
        serverURLErrorLabel.isHidden = true
        serverURLField.resignFirstResponder()
        onServerURLSave?(normalizedURL)
    }

    func commitServerURLInput() {
        saveServerURL()
    }

    private static func normalizeServerBaseURL(_ input: String) -> String? {
        guard var components = URLComponents(string: input),
              let rawScheme = components.scheme?.lowercased(),
              rawScheme == "http" || rawScheme == "https",
              let host = components.host,
              !host.isEmpty else { return nil }
        components.scheme = rawScheme
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        guard let url = components.url else { return nil }
        return url.absoluteString
    }

    @objc private func modeChanged() {
        serverURLField.resignFirstResponder()
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

    @objc private func saveServerURLTapped() {
        saveServerURL()
    }

    @objc private func serverEditingChanged() {
        onServerEditingChanged?(true)
    }

    @objc private func serverEditingEnded() {
        onServerEditingChanged?(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        saveServerURL()
        return false
    }

    @objc private func backdropTapped() {
        onDismiss?()
    }
}
