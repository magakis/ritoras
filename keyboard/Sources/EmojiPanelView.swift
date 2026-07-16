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
    private let toneButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "gearshape", withConfiguration: config), for: .normal)
        return button
    }()
    private let collectionView: UICollectionView
    private let categoryBar = UIScrollView()
    private var categoryButtons: [UIButton] = []
    /// `nil` means "Recents" is selected.
    private var selectedCategory: String?
    private let emptyStateLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "No recent emojis yet"
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16)
        label.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.4)
                : UIColor.black.withAlphaComponent(0.4)
        }
        label.isHidden = true
        return label
    }()

    // MARK: - Data

    /// Currently displayed emojis for the selected category.
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
        setupCategoryBar()
        setupCollectionView()

        // Empty-state label
        addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
        ])

        // Initial category: prefer Recents if non-empty, else first real category
        if EmojiRecents.get().isEmpty {
            selectedCategory = EmojiData.categories.first?.name
        }
        updateTabSelection()

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

        // Tone picker button on far right
        toneButton.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        }
        headerView.addSubview(toneButton)
        toneButton.menu = buildToneMenu()
        toneButton.showsMenuAsPrimaryAction = true

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 36),

            dismissButton.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 12),
            dismissButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            dismissButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            toneButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -12),
            toneButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
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
            collectionView.topAnchor.constraint(equalTo: categoryBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Data

    func reloadData() {
        if selectedCategory == nil {
            // Recents tab
            let recents = EmojiRecents.get()
            if recents.isEmpty {
                allEmojis = []
                emptyStateLabel.isHidden = false
                bringSubviewToFront(emptyStateLabel)
            } else {
                allEmojis = recents
                emptyStateLabel.isHidden = true
            }
        } else {
            allEmojis = EmojiData.categories.first { $0.name == selectedCategory }?.emojis ?? []
            emptyStateLabel.isHidden = true
        }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    // MARK: - Category Bar

    private func setupCategoryBar() {
        categoryBar.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.showsHorizontalScrollIndicator = false
        categoryBar.backgroundColor = .clear
        addSubview(categoryBar)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fill
        stack.alignment = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        categoryBar.addSubview(stack)

        NSLayoutConstraint.activate([
            categoryBar.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            categoryBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            categoryBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            categoryBar.heightAnchor.constraint(equalToConstant: 36),

            stack.topAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: categoryBar.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: categoryBar.frameLayoutGuide.heightAnchor),
        ])

        let recentsButton = makeCategoryButton(title: "Recents")
        stack.addArrangedSubview(recentsButton)

        for cat in EmojiData.categories {
            let button = makeCategoryButton(title: cat.name)
            stack.addArrangedSubview(button)
        }

        updateTabSelection()
    }

    private func makeCategoryButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
        categoryButtons.append(button)
        return button
    }

    @objc private func categoryTapped(_ sender: UIButton) {
        guard let index = categoryButtons.firstIndex(of: sender) else { return }

        if index == 0 {
            selectedCategory = nil
        } else {
            selectedCategory = EmojiData.categories[index - 1].name
        }

        updateTabSelection()
        reloadData()
    }

    private func updateTabSelection() {
        for (index, button) in categoryButtons.enumerated() {
            let isSelected: Bool
            if index == 0 {
                isSelected = selectedCategory == nil
            } else {
                isSelected = selectedCategory == EmojiData.categories[index - 1].name
            }

            button.backgroundColor = UIColor { tc in
                if isSelected {
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.30, alpha: 1)
                        : UIColor(white: 0.80, alpha: 1)
                } else {
                    .clear
                }
            }

            button.setTitleColor(UIColor { tc in
                if isSelected {
                    tc.userInterfaceStyle == .dark
                        ? UIColor.white
                        : UIColor.black
                } else {
                    tc.userInterfaceStyle == .dark
                        ? UIColor(white: 0.6, alpha: 1)
                        : UIColor(white: 0.4, alpha: 1)
                }
            }, for: .normal)
        }
    }

    // MARK: - Tone Menu

    private func buildToneMenu() -> UIMenu {
        let actions = EmojiSkinTone.allCases.map { tone in
            UIAction(
                title: "\(tone.sample) \(tone.displayName)",
                state: tone == EmojiSkinTone.current ? .on : .off
            ) { [weak self] _ in
                EmojiSkinTone.current = tone
                self?.collectionView.reloadData()
                self?.toneButton.menu = self?.buildToneMenu()
            }
        }
        return UIMenu(title: "", children: actions)
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
        cell.configure(with: EmojiData.applying(.current, to: allEmojis[indexPath.item]))
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
        let emoji = EmojiData.applying(.current, to: allEmojis[indexPath.item])
        onSelect?(emoji)
    }
}
