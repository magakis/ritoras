import UIKit

// MARK: - EmojiCell

final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiCell"

    let emojiLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 32)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = false
        return label
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(emojiLabel)
        NSLayoutConstraint.activate([
            emojiLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emojiLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with emoji: String) {
        emojiLabel.text = emoji
    }
}

// MARK: - EmojiPanelView

final class EmojiPanelView: UIView {
    // MARK: - Callbacks

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Subviews

    private let headerView = UIView()
    private let dismissButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("ABC", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        return button
    }()
    private let recentsLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Recents"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textAlignment = .right
        return label
    }()
    private let collectionView: UICollectionView

    // MARK: - Data

    /// Flat list: recents (if non-empty) followed by all categorized emojis.
    private var allEmojis: [String] = []

    // MARK: - Layout Constants

    private static let columns: CGFloat = 6
    private static let spacing: CGFloat = 6
    private static let cellSize: CGFloat = 44

    // MARK: - Init

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Self.spacing
        layout.minimumLineSpacing = Self.spacing
        layout.scrollDirection = .vertical
        layout.sectionInset = UIEdgeInsets(top: Self.spacing, left: Self.spacing, bottom: Self.spacing, right: Self.spacing)

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)

        super.init(frame: frame)

        setupView()
        reloadData()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Setup

    private func setupView() {
        backgroundColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor(white: 0.15, alpha: 1)
                : UIColor(white: 0.88, alpha: 1)
        }
        layer.cornerRadius = 6
        clipsToBounds = true

        setupHeader()
        setupCollectionView()

        // Wire dismiss button
        dismissButton.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
    }

    private func setupHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Dismiss button on left
        dismissButton.setTitleColor(UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        }, for: .normal)
        headerView.addSubview(dismissButton)

        // Recents label on right
        recentsLabel.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0.7, alpha: 1) : UIColor(white: 0.4, alpha: 1)
        }
        headerView.addSubview(recentsLabel)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            dismissButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            dismissButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            dismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            recentsLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            recentsLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
    }

    private func setupCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.delaysContentTouches = false
        addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Data

    func reloadData() {
        let recents = EmojiRecents.get()
        if recents.isEmpty {
            allEmojis = EmojiData.categories.flatMap { $0.emojis }
            recentsLabel.isHidden = true
        } else {
            allEmojis = recents + EmojiData.categories.flatMap { $0.emojis }
            recentsLabel.isHidden = false
        }
        collectionView.reloadData()
        // Scroll to top when reloading (recents are at the top)
        collectionView.setContentOffset(.zero, animated: false)
    }
}

// MARK: - Actions

extension EmojiPanelView {
    @objc private func dismissTapped() {
        onDismiss?()
    }
}

// MARK: - UICollectionViewDataSource

extension EmojiPanelView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        allEmojis.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier, for: indexPath) as! EmojiCell
        cell.configure(with: allEmojis[indexPath.item])
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension EmojiPanelView: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let availableWidth = collectionView.bounds.width - Self.spacing * (Self.columns + 1)
        let cellWidth = floor(availableWidth / Self.columns)
        return CGSize(width: cellWidth, height: Self.cellSize)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        let emoji = allEmojis[indexPath.item]
        onSelect?(emoji)
    }
}
