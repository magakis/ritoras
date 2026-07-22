import UIKit

/// A popup character preview — a rounded-rect bubble with a tapered stem
/// pointing downward, used to show the pressed key's character above the key.
/// One reusable instance, recycled across key presses (never per-tap allocation).
final class KeyPreviewView: UIView {

    // MARK: - Constants

    private static let bubbleWidth: CGFloat = 32
    private static let bubbleHeight: CGFloat = 61
    private static let cornerRadius: CGFloat = 7
    private static let stemWidth: CGFloat = 30
    private static let stemHeight: CGFloat = 11
    private static let glyphFontSize: CGFloat = 28

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

        glyphLabel.font = .systemFont(ofSize: Self.glyphFontSize, weight: .bold)
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
        glyphLabel.frame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: bounds.height - Self.stemHeight
        )
        shapeLayer.path = bubblePath(in: bounds)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        shapeLayer.fillColor = dynamicFillColor.resolvedColor(with: traitCollection).cgColor
        shapeLayer.strokeColor = dynamicStrokeColor.resolvedColor(with: traitCollection).cgColor
        glyphLabel.textColor = dynamicTextColor
    }

    // MARK: - Path

    /// Creates the combined bubble + stem path.
    /// The bubble is a rounded rectangle at the top, the stem is a triangle
    /// below it that tapers to a point, pointing down toward the key.
    private func bubblePath(in rect: CGRect) -> CGPath {
        let bubbleRect = CGRect(
            x: 0,
            y: 0,
            width: rect.width,
            height: rect.height - Self.stemHeight
        )
        let path = UIBezierPath(roundedRect: bubbleRect, cornerRadius: Self.cornerRadius)

        let stemTop = bubbleRect.maxY
        let centerX = rect.midX
        let stemHalf = Self.stemWidth / 2

        path.move(to: CGPoint(x: centerX - stemHalf, y: stemTop))
        path.addLine(to: CGPoint(x: centerX, y: stemTop + Self.stemHeight))
        path.addLine(to: CGPoint(x: centerX + stemHalf, y: stemTop))
        path.close()

        return path.cgPath
    }

    // MARK: - Public API

    /// Shows the popup above the given key frame, with the stem pointing down
    /// at the key's top edge. Scales and fades in with a spring animation.
    func show(for glyph: String, anchoredAbove keyFrameInHost: CGRect, in host: UIView) {
        let ourWidth = Self.bubbleWidth
        let ourHeight = Self.bubbleHeight + Self.stemHeight
        let ourX = keyFrameInHost.midX - ourWidth / 2
        let ourY = keyFrameInHost.minY - ourHeight

        frame = CGRect(x: ourX, y: ourY, width: ourWidth, height: ourHeight)
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
