import UIKit

/// A lightweight language picker overlay: a dimmed backdrop over the whole
/// keyboard with a centered list of languages (one row per KeyboardLanguage),
/// the active language marked with a checkmark. Dark-mode aware via dynamic
/// colors. One reusable instance is held by KeyboardView and recycled across
/// shows — never per-open allocated (48 MB Jetsam discipline, mirroring the
/// single KeyPreviewView pattern).
final class LanguageMenuView: UIView {

    // MARK: - Callbacks

    var onSelect: ((KeyboardLanguage) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Constants

    private static let rowHeight: CGFloat = 44
    private static let panelCornerRadius: CGFloat = 14
    private static let panelHorizontalPadding: CGFloat = 12
    private static let panelVerticalPadding: CGFloat = 8
    private static let checkmarkSpacing: CGFloat = 12

    // MARK: - Subviews

    private let dimmedView = UIView()
    private let menuPanel = UIView()
    private let rowsStack = UIStackView()
    private var rowCheckmarks: [UIImageView] = []

    // MARK: - Dynamic Colors

    private let dynamicBackdropColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.5)
            : UIColor.black.withAlphaComponent(0.25)
    }

    private let dynamicPanelColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.22, alpha: 1)
            : UIColor(white: 0.97, alpha: 1)
    }

    private let dynamicTextColor = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
    }

    private let dynamicTintColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.7, alpha: 1)
            : UIColor(white: 0.3, alpha: 1)
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isHidden = true

        dimmedView.backgroundColor = dynamicBackdropColor
        let backdropTap = UITapGestureRecognizer(target: self, action: #selector(dimmedTapped))
        dimmedView.addGestureRecognizer(backdropTap)
        dimmedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimmedView)

        menuPanel.backgroundColor = dynamicPanelColor
        menuPanel.layer.cornerRadius = Self.panelCornerRadius
        menuPanel.clipsToBounds = true
        menuPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(menuPanel)

        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        menuPanel.addSubview(rowsStack)

        for (index, language) in KeyboardLanguage.allCases.enumerated() {
            let row = makeRow(for: language, index: index)
            rowsStack.addArrangedSubview(row)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }

        NSLayoutConstraint.activate([
            dimmedView.topAnchor.constraint(equalTo: topAnchor),
            dimmedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimmedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimmedView.bottomAnchor.constraint(equalTo: bottomAnchor),

            menuPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            menuPanel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rowsStack.topAnchor.constraint(equalTo: menuPanel.topAnchor, constant: Self.panelVerticalPadding),
            rowsStack.leadingAnchor.constraint(equalTo: menuPanel.leadingAnchor, constant: Self.panelHorizontalPadding),
            rowsStack.trailingAnchor.constraint(equalTo: menuPanel.trailingAnchor, constant: -Self.panelHorizontalPadding),
            rowsStack.bottomAnchor.constraint(equalTo: menuPanel.bottomAnchor, constant: -Self.panelVerticalPadding),
        ])
    }

    private func makeRow(for language: KeyboardLanguage, index: Int) -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .fill
        row.spacing = Self.checkmarkSpacing
        row.isUserInteractionEnabled = true
        row.tag = index

        let label = UILabel()
        label.text = language.displayName
        label.font = .systemFont(ofSize: 17, weight: .regular)
        label.textColor = dynamicTextColor
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(label)

        let checkmark = UIImageView(image: UIImage(systemName: "checkmark"))
        checkmark.tintColor = dynamicTintColor
        checkmark.isHidden = true
        row.addArrangedSubview(checkmark)
        rowCheckmarks.append(checkmark)

        let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
        row.addGestureRecognizer(tap)

        return row
    }

    // MARK: - Actions

    @objc private func dimmedTapped() {
        onDismiss?()
    }

    @objc private func rowTapped(_ gesture: UITapGestureRecognizer) {
        guard let row = gesture.view else { return }
        let languages = KeyboardLanguage.allCases
        let index = row.tag
        guard index >= 0, index < languages.count else { return }
        onSelect?(languages[index])
    }

    // MARK: - Public API

    /// Shows the overlay, marking `activeLanguage` with a checkmark.
    func show(activeLanguage: KeyboardLanguage) {
        let languages = KeyboardLanguage.allCases
        for (index, checkmark) in rowCheckmarks.enumerated() {
            checkmark.isHidden = index >= languages.count || languages[index] != activeLanguage
        }
        isHidden = false
        alpha = 0
        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: .beginFromCurrentState,
            animations: { self.alpha = 1 },
            completion: nil
        )
    }

    /// Fades out the overlay and hides it.
    func dismiss() {
        UIView.animate(
            withDuration: 0.1,
            animations: { self.alpha = 0 },
            completion: { _ in
                self.isHidden = true
                self.alpha = 1
            }
        )
    }
}
