import UIKit

// MARK: - State Machine

enum KeyboardState: Equatable {
    case idle
    case recording
    case transcribing
    case error(String)
}

// MARK: - Delegate

protocol KeyboardViewDelegate: AnyObject {
    func keyboardViewDidTapMicButton(_ view: KeyboardView)
}

// MARK: - KeyboardView

class KeyboardView: UIView {

    weak var delegate: KeyboardViewDelegate?

    // MARK: - UI Elements

    private let micButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)
        button.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
        button.tintColor = .systemBlue
        button.backgroundColor = UIColor.systemGray5
        button.layer.cornerRadius = 50
        button.clipsToBounds = true
        return button
    }()

    private let stateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.font = UIFont.systemFont(ofSize: 16)
        label.textColor = .darkGray
        label.numberOfLines = 0
        label.text = "Tap to start recording"
        return label
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .large)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private let fullAccessBanner: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        view.layer.cornerRadius = 8
        view.isHidden = true
        return view
    }()

    private let fullAccessLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Enable Full Access in Settings → General → Keyboard → Ritoras → Allow Full Access"
        label.font = UIFont.systemFont(ofSize: 12)
        label.textColor = .systemOrange
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        backgroundColor = UIColor.systemGray6

        addSubview(micButton)
        addSubview(stateLabel)
        addSubview(activityIndicator)
        addSubview(fullAccessBanner)
        fullAccessBanner.addSubview(fullAccessLabel)

        micButton.addTarget(self, action: #selector(micButtonTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            // Mic button — centered vertically with a slight upward offset
            micButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            micButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            micButton.widthAnchor.constraint(equalToConstant: 100),
            micButton.heightAnchor.constraint(equalToConstant: 100),

            // State label — below mic button
            stateLabel.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: 16),
            stateLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            stateLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

            // Activity indicator — centered on mic button
            activityIndicator.centerXAnchor.constraint(equalTo: micButton.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: micButton.centerYAnchor),

            // Full Access banner — top of view
            fullAccessBanner.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            fullAccessBanner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            fullAccessBanner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            // Full Access label — inside the banner
            fullAccessLabel.topAnchor.constraint(equalTo: fullAccessBanner.topAnchor, constant: 8),
            fullAccessLabel.leadingAnchor.constraint(equalTo: fullAccessBanner.leadingAnchor, constant: 8),
            fullAccessLabel.trailingAnchor.constraint(equalTo: fullAccessBanner.trailingAnchor, constant: -8),
            fullAccessLabel.bottomAnchor.constraint(equalTo: fullAccessBanner.bottomAnchor, constant: -8),
        ])
    }

    // MARK: - Actions

    @objc private func micButtonTapped() {
        delegate?.keyboardViewDidTapMicButton(self)
    }

    // MARK: - State Configuration

    func configure(for state: KeyboardState) {
        let config = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        switch state {
        case .idle:
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
            micButton.tintColor = .systemBlue
            micButton.backgroundColor = UIColor.systemGray5
            micButton.isEnabled = true
            micButton.isHidden = false
            stateLabel.text = "Tap to start recording"
            stateLabel.textColor = .darkGray
            activityIndicator.stopAnimating()

        case .recording:
            micButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: config), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = .systemRed
            micButton.isEnabled = true
            micButton.isHidden = false
            stateLabel.text = "Recording… tap to stop"
            stateLabel.textColor = .systemRed
            activityIndicator.stopAnimating()

        case .transcribing:
            micButton.isHidden = true
            stateLabel.text = "Transcribing…"
            stateLabel.textColor = .darkGray
            activityIndicator.startAnimating()

        case .error(let message):
            micButton.setImage(UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: config), for: .normal)
            micButton.tintColor = .white
            micButton.backgroundColor = .systemRed
            micButton.isEnabled = true
            micButton.isHidden = false
            stateLabel.text = message
            stateLabel.textColor = .systemRed
            activityIndicator.stopAnimating()
        }
    }

    func showFullAccessBanner(_ show: Bool) {
        fullAccessBanner.isHidden = !show
    }
}
