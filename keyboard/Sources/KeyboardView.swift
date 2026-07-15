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
}

// MARK: - KeyboardView

class KeyboardView: UIView {
    weak var delegate: KeyboardViewDelegate?

    private let micButton = UIButton(type: .system)
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

        // Mic button — large, centered
        micButton.translatesAutoresizingMaskIntoConstraints = false
        micButton.layer.cornerRadius = 35  // half of 70pt diameter
        micButton.clipsToBounds = true
        micButton.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        addSubview(micButton)

        // Hint label — below mic button
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

        // Layout constraints
        NSLayoutConstraint.activate([
            // Mic button — centered horizontally, with padding from top
            micButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            micButton.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            micButton.widthAnchor.constraint(equalToConstant: 70),
            micButton.heightAnchor.constraint(equalToConstant: 70),

            // Hint label — below mic button
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 8),

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
        let largeConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .medium)

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
}
