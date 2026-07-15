import UIKit

// MARK: - Keyboard State

enum KeyboardState: Equatable {
    case idle
    case openingApp
    case waiting
    case inserting
    case error(String)
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardViewDidTapMicButton(_ view: KeyboardView)
    func keyboardViewDidTapSwitchButton(_ view: KeyboardView)
}

// MARK: - KeyboardView

class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private let micButton = UIButton(type: .system)
    private let switchButton = UIButton(type: .system)
    private let buttonStack = UIStackView()
    private let hintLabel = UILabel()
    private let stateLabel = UILabel()

    // Track if full access banner is shown
    private let fullAccessBanner = UIView()
    private var hasFullAccess = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Background — light gray, matches iOS keyboard appearance
        // Use a solid color (not blur) to avoid rendering issues in keyboard extensions
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.18, alpha: 1)
                : UIColor(white: 0.92, alpha: 1)
        }

        // Mic button — 60pt diameter
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.layer.cornerRadius = 30
        micButton.clipsToBounds = true
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        // Switch keyboard button — 44pt, globe icon
        switchButton.translatesAutoresizingMaskIntoConstraints = false
        switchButton.layer.cornerRadius = 22
        switchButton.clipsToBounds = true
        switchButton.backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.35, alpha: 1)
                : .systemGray4
        }
        switchButton.tintColor = .label
        switchButton.setImage(UIImage(systemName: "globe", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)), for: .normal)
        switchButton.addTarget(self, action: #selector(switchTapped), for: .touchUpInside)

        // Button stack — mic + switch side by side
        buttonStack.axis = .horizontal
        buttonStack.spacing = 16
        buttonStack.alignment = .center
        buttonStack.addArrangedSubview(micButton)
        buttonStack.addArrangedSubview(switchButton)
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonStack)

        // Hint label — below button stack
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 13, weight: .regular)
        hintLabel.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.6, alpha: 1)
                : UIColor(white: 0.4, alpha: 1)
        }
        hintLabel.textAlignment = .center
        addSubview(hintLabel)

        // State label — shows status messages
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        stateLabel.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.7, alpha: 1)
                : UIColor(white: 0.3, alpha: 1)
        }
        stateLabel.textAlignment = .center
        stateLabel.isHidden = true
        addSubview(stateLabel)

        // Layout constraints — compact
        NSLayoutConstraint.activate([
            // Button stack — centered horizontally, close to top
            buttonStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            buttonStack.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),

            // Mic button size
            micButton.widthAnchor.constraint(equalToConstant: 60),
            micButton.heightAnchor.constraint(equalToConstant: 60),

            // Switch button size
            switchButton.widthAnchor.constraint(equalToConstant: 44),
            switchButton.heightAnchor.constraint(equalToConstant: 44),

            // Hint label — below button stack
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 6),

            // State label — below hint
            stateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 4),
        ])

        configure(for: .idle)
    }

    func updateFullAccess(_ hasAccess: Bool) {
        hasFullAccess = hasAccess
        if !hasAccess {
            // Show a banner prompting to enable Full Access
            fullAccessBanner.isHidden = false
        }
        configure(for: .idle)
    }

    func configure(for state: KeyboardState) {
        let largeConfig = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)

        switch state {
        case .idle:
            micButton.isHidden = false
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: largeConfig), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
                    : UIColor(red: 0.0, green: 0.45, blue: 0.9, alpha: 1)
            }
            micButton.isEnabled = true
            hintLabel.text = hasFullAccess ? "Tap to dictate" : "Enable Full Access to dictate"
            hintLabel.isHidden = false
            stateLabel.isHidden = true

        case .openingApp:
            micButton.isHidden = false
            micButton.setImage(UIImage(systemName: "arrow.up.right.square.fill", withConfiguration: largeConfig), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(white: 0.3, alpha: 1)
                    : UIColor(white: 0.7, alpha: 1)
            }
            micButton.isEnabled = false
            hintLabel.text = "Opening Ritoras..."
            hintLabel.isHidden = false
            stateLabel.isHidden = true

        case .waiting:
            micButton.isHidden = false
            micButton.setImage(UIImage(systemName: "ellipsis.circle.fill", withConfiguration: largeConfig), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(white: 0.3, alpha: 1)
                    : UIColor(white: 0.7, alpha: 1)
            }
            micButton.isEnabled = false
            hintLabel.text = "Dictating..."
            hintLabel.isHidden = false
            stateLabel.isHidden = true

        case .inserting:
            micButton.isHidden = false
            micButton.setImage(UIImage(systemName: "checkmark.circle.fill", withConfiguration: largeConfig), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1)
                    : UIColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1)
            }
            micButton.isEnabled = false
            hintLabel.text = "Inserted!"
            hintLabel.isHidden = false
            stateLabel.isHidden = true

        case .error(let message):
            micButton.isHidden = false
            micButton.setImage(UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: largeConfig), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = .systemRed
            micButton.isEnabled = true
            hintLabel.text = "Tap to try again"
            hintLabel.isHidden = false
            stateLabel.text = message
            stateLabel.isHidden = false
            stateLabel.numberOfLines = 2
        }
    }

    @objc private func micTapped() {
        delegate?.keyboardViewDidTapMicButton(self)
    }

    @objc private func switchTapped() {
        delegate?.keyboardViewDidTapSwitchButton(self)
    }
}
