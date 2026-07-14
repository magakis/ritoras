import UIKit

class KeyboardViewController: UIInputViewController {

    private var statusLabel: UILabel!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Absolute minimal setup — just a label, no audio, no network, no state machine.
        statusLabel = UILabel()
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = UIFont.systemFont(ofSize: 16)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])

        let heightConstraint = view.heightAnchor.constraint(equalToConstant: 250)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        view.backgroundColor = UIColor.systemGray6

        updateStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateStatus()
    }

    private func updateStatus() {
        let fullAccess = hasFullAccess
        statusLabel.text = """
            Ritoras keyboard loaded ✓
            Full Access: \(fullAccess ? "YES" : "NO")

            Tap anywhere on this text.
            """
        statusLabel.textColor = fullAccess ? .systemGreen : .systemOrange
    }
}
