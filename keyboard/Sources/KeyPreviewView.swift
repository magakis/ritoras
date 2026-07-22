import UIKit

/// A popup character preview — a simple rounded square above the pressed key
/// showing the character. One reusable instance, recycled across key presses
/// (never per-tap allocation).
final class KeyPreviewView: UIView {

    // MARK: - Constants

    private static let cornerRadius: CGFloat = 6
    private static let glyphFontSize: CGFloat = 24
    private static let gapAboveKey: CGFloat = 4
    private static let widthFactor: CGFloat = 1.1
    private static let heightFactor: CGFloat = 1.15

    // MARK: - Subviews & Layers

    private let shapeLayer = CAShapeLayer()
    private let glyphLabel = UILabel()

    // MARK: - Dynamic Colors

    private let dynamicFillColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.18, alpha: 1)
            : UIColor(white: 0.95, alpha: 1)
    }

    private let dynamicStrokeColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.3, alpha: 1)
            : UIColor(white: 0.7, alpha: 1)
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
        isUserInteractionEnabled = false

        shapeLayer.fillColor = dynamicFillColor.resolvedColor(with: traitCollection).cgColor
        shapeLayer.strokeColor = dynamicStrokeColor.resolvedColor(with: traitCollection).cgColor
        shapeLayer.lineWidth = 0.5
        layer.addSublayer(shapeLayer)

        glyphLabel.font = .systemFont(ofSize: Self.glyphFontSize, weight: .regular)
        glyphLabel.textAlignment = .center
        glyphLabel.textColor = dynamicTextColor
        addSubview(glyphLabel)

        alpha = 0
        isHidden = true
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        shapeLayer.frame = bounds
        glyphLabel.frame = bounds
        shapeLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        shapeLayer.fillColor = dynamicFillColor.resolvedColor(with: traitCollection).cgColor
        shapeLayer.strokeColor = dynamicStrokeColor.resolvedColor(with: traitCollection).cgColor
        glyphLabel.textColor = dynamicTextColor
    }

    // MARK: - Public API

    /// Shows the popup above the given key frame, centered horizontally and
    /// positioned just above the key with a small gap.
    func show(for glyph: String, anchoredAbove keyFrame: CGRect) {
        let width = max(keyFrame.width * Self.widthFactor, 0)
        let height = max(keyFrame.height * Self.heightFactor, 0)
        let x = keyFrame.midX - width / 2
        let y = keyFrame.minY - height - Self.gapAboveKey

        frame = CGRect(x: x, y: y, width: width, height: height)
        glyphLabel.text = glyph

        isHidden = false
        transform = CGAffineTransform(scaleX: 0.8, y: 0.8)

        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            usingSpringWithDamping: 0.6,
            initialSpringVelocity: 0.8,
            options: .beginFromCurrentState,
            animations: {
                self.alpha = 1
                self.transform = .identity
            },
            completion: nil
        )
    }

    /// Fades out the popup.
    func hide() {
        UIView.animate(
            withDuration: 0.1,
            animations: {
                self.alpha = 0
            },
            completion: { _ in
                self.isHidden = true
                self.transform = .identity
            }
        )
    }
}
