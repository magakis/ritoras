import UIKit

/// Small horizontal accent-picker strip shown above a Greek vowel key on
/// long-press (Apple-style). One reusable instance, recycled across shows —
/// never per-open allocated (48 MB Jetsam discipline, mirroring the single
/// KeyPreviewView / LanguageMenuView pattern).
final class AccentPickerView: UIView {

    // MARK: - Callbacks

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Constants

    /// Lowercase variant sets per base Greek key. ι and υ carry the dialytika
    /// forms (ϊ/ΐ, ϋ/ΰ) exactly like the system keyboard. Uppercase variants
    /// are derived by uppercasing when the shift key is active; final sigma
    /// remains lowercase so it remains available from the shifted sigma key.
    static let variants: [String: [String]] = [
        "α": ["α", "ά"],
        "ε": ["ε", "έ"],
        "η": ["η", "ή"],
        "ι": ["ι", "ί", "ϊ", "ΐ"],
        "ο": ["ο", "ό"],
        "σ": ["σ", "ς"],
        "υ": ["υ", "ύ", "ϋ", "ΰ"],
        "ω": ["ω", "ώ"],
    ]

    private static let buttonSize: CGFloat = 42
    private static let buttonSpacing: CGFloat = 2
    private static let stripPadding: CGFloat = 6
    private static let stripCornerRadius: CGFloat = 8
    private static let buttonCornerRadius: CGFloat = 6
    private static let gapAboveKey: CGFloat = 4
    private static let glyphFontSize: CGFloat = 24
    /// Maximum number of variant buttons (ι/υ carry 4; all others carry 2).
    private static let maxVariantCount = 4

    // MARK: - Subviews

    /// Transparent full-keyboard touch catcher — taps outside the strip dismiss.
    private let backdrop = UIView()
    /// Rounded container holding the variant buttons.
    private let strip = UIView()
    /// Up to 4 variant buttons, created once and relabeled/hidden per show —
    /// no per-open allocation.
    private var variantButtons: [UIButton] = []

    // MARK: - Dynamic Colors

    private let dynamicStripColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
    }

    private let dynamicButtonColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.28, alpha: 1)
            : UIColor(white: 0.82, alpha: 1)
    }

    private let dynamicTextColor = UIColor { tc in
        tc.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
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

        backdrop.backgroundColor = .clear
        let backdropTap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
        backdrop.addGestureRecognizer(backdropTap)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        strip.backgroundColor = dynamicStripColor
        strip.layer.cornerRadius = Self.stripCornerRadius
        strip.clipsToBounds = true
        addSubview(strip)

        for _ in 0..<Self.maxVariantCount {
            let button = UIButton(type: .system)
            button.titleLabel?.font = .systemFont(ofSize: Self.glyphFontSize, weight: .regular)
            button.titleLabel?.textAlignment = .center
            button.setTitleColor(dynamicTextColor, for: .normal)
            button.backgroundColor = dynamicButtonColor
            button.layer.cornerRadius = Self.buttonCornerRadius
            button.addTarget(self, action: #selector(variantTapped(_:)), for: .touchUpInside)
            strip.addSubview(button)
            variantButtons.append(button)
        }

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Actions

    @objc private func backdropTapped() {
        onDismiss?()
    }

    @objc private func variantTapped(_ sender: UIButton) {
        guard let variant = sender.title(for: .normal), !variant.isEmpty else { return }
        onSelect?(variant)
    }

    // MARK: - Public API

    /// Shows the strip above `keyFrame` (in the containing view's coordinate
    /// space), offering the base key plus its variants. When
    /// `shifted` is true the variants are uppercased (Ά Έ Ή Ί Ό Ύ Ώ, Ϊ/Ϋ).
    /// The picker view covers the whole keyboard so taps outside the strip
    /// land on the backdrop and dismiss it.
    func show(for base: String, anchoredAbove keyFrame: CGRect, shifted: Bool) {
        guard let lowercase = Self.variants[base], !lowercase.isEmpty else { return }
        let variants = shifted
            ? lowercase.map { $0 == "ς" ? $0 : $0.uppercased() }
            : lowercase
        let count = variants.count

        for (index, button) in variantButtons.enumerated() {
            if index < count {
                button.setTitle(variants[index], for: .normal)
                button.isHidden = false
            } else {
                button.isHidden = true
            }
        }

        let buttonCount = CGFloat(count)
        let stripWidth = Self.stripPadding * 2 + buttonCount * Self.buttonSize
            + (buttonCount - 1) * Self.buttonSpacing
        let stripHeight = Self.stripPadding * 2 + Self.buttonSize

        let containerWidth = superview?.bounds.width ?? 0
        let clampedX = min(max(keyFrame.midX - stripWidth / 2, Self.stripPadding),
                           max(containerWidth - stripWidth - Self.stripPadding, Self.stripPadding))
        let stripY = max(keyFrame.minY - stripHeight - Self.gapAboveKey, 0)

        frame = superview?.bounds ?? .zero
        strip.frame = CGRect(x: clampedX, y: stripY, width: stripWidth, height: stripHeight)

        var buttonX = Self.stripPadding
        for button in variantButtons where !button.isHidden {
            button.frame = CGRect(x: buttonX, y: Self.stripPadding,
                                  width: Self.buttonSize, height: Self.buttonSize)
            buttonX += Self.buttonSize + Self.buttonSpacing
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

    /// Fades out and hides the strip.
    func hide() {
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
