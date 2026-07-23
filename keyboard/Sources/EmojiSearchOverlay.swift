import UIKit

// MARK: - EmojiSearchOverlay

final class EmojiSearchOverlay: UIView {

    // MARK: - Public API

    static let overlayHeight: CGFloat = 80

    let searchField: UITextField = {
        let field = UITextField()
        field.placeholder = "Describe an Emoji"
        field.font = .systemFont(ofSize: 15)
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.adjustsFontSizeToFitWidth = false
        field.translatesAutoresizingMaskIntoConstraints = false

        // Magnifying glass icon as left view (UISearchBar-style)
        let iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        iconView.contentMode = .scaleAspectFit
        iconView.frame = CGRect(x: 8, y: 5, width: 14, height: 14)
        iconView.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0.7, alpha: 1) : UIColor(white: 0.4, alpha: 1)
        }
        let leftContainer = UIView(frame: CGRect(x: 0, y: 0, width: 28, height: 24))
        leftContainer.addSubview(iconView)
        field.leftView = leftContainer
        field.leftViewMode = .always

        // Transparent background — the search pill provides the chrome
        field.backgroundColor = .clear
        field.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? .white : .black
        }
        field.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? .white : UIColor(white: 0.2, alpha: 1)
        }

        // Placeholder color adapts to dark mode
        field.attributedPlaceholder = NSAttributedString(
            string: "Describe an Emoji",
            attributes: [.foregroundColor: UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(white: 0.6, alpha: 1)
                    : UIColor(white: 0.4, alpha: 1)
            }]
        )
        return field
    }()

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    // MARK: - Private Subviews

    private let searchContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = EmojiPanelView.panelSecondaryBackground
        view.layer.cornerRadius = 20
        view.clipsToBounds = true
        return view
    }()

    private let collectionView: UICollectionView

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

    private let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        button.setTitleColor(EmojiPanelView.modeKeyTextColor, for: .normal)
        return button
    }()

    // MARK: - State

    private var allEmojis: [String] = []
    private var currentQuery: String = ""
    private var searchDebounceWorkItem: DispatchWorkItem?
    private let selectionFeedback = UISelectionFeedbackGenerator()

    // MARK: - Init

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 0
        layout.sectionInset = .zero
        layout.itemSize = CGSize(width: 40, height: 40)

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
        backgroundColor = .clear

        setupSearchPill()
        setupCollectionView()
        setupEmptyState()
    }

    private func setupSearchPill() {
        addSubview(searchContainer)
        addSubview(cancelButton)

        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchContainer.addSubview(searchField)

        // Internal vertical constraints — .defaultHigh so external height=0 wins cleanly
        let pillTop = searchContainer.topAnchor.constraint(equalTo: topAnchor)
        pillTop.priority = .defaultHigh
        let pillHeight = searchContainer.heightAnchor.constraint(equalToConstant: 40)
        pillHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            pillTop,
            pillHeight,
            searchContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchContainer.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -6),

            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -8),

            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        searchField.addTarget(self, action: #selector(searchFieldEditingChanged), for: .editingChanged)
    }

    private func setupCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.delaysContentTouches = false
        addSubview(collectionView)

        // Internal vertical constraints — .defaultHigh so external height=0 wins cleanly
        let cvTop = collectionView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor)
        cvTop.priority = .defaultHigh
        let cvBottom = collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        cvBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            cvTop,
            cvBottom,
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func setupEmptyState() {
        addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
        ])
    }

    // MARK: - Public API

    /// Called on entry: seed recents + refresh display.
    func activate() {
        reloadData()
    }

    /// Called on exit: clear query + results.
    func deactivate() {
        currentQuery = ""
        searchField.text = ""
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        allEmojis = []
        collectionView.reloadData()
        emptyStateLabel.isHidden = true
    }

    /// Drive results externally (optional; field edits also drive internally).
    func setQuery(_ text: String) {
        searchField.text = text
        performSearch(text)
    }

    // MARK: - Data

    private func reloadData() {
        if !currentQuery.isEmpty {
            performSearch(currentQuery)
            return
        }
        let recents = EmojiRecents.get()
        if recents.isEmpty {
            allEmojis = []
            emptyStateLabel.text = "No recent emojis yet"
            emptyStateLabel.isHidden = false
            bringSubviewToFront(emptyStateLabel)
        } else {
            allEmojis = recents
            emptyStateLabel.isHidden = true
        }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    private func performSearch(_ rawQuery: String) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        currentQuery = trimmed
        if trimmed.isEmpty {
            emptyStateLabel.isHidden = true
            reloadData()
            return
        }
        let lower = trimmed.lowercased()
        let tokens = lower.split(separator: " ").map(String.init)
        let matches = EmojiData.searchable.filter { entry in
            let nameLower = entry.name.lowercased()
            let keywordsLower = entry.keywords.map { $0.lowercased() }
            return tokens.allSatisfy { token in
                nameLower.contains(token) || keywordsLower.contains { $0.contains(token) }
            }
        }
        allEmojis = matches.map(\.char)
        if matches.isEmpty {
            emptyStateLabel.text = "No results for \"\(trimmed)\""
            emptyStateLabel.isHidden = false
            bringSubviewToFront(emptyStateLabel)
        } else {
            emptyStateLabel.isHidden = true
        }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }
}

// MARK: - Actions

extension EmojiSearchOverlay {
    @objc private func cancelTapped() {
        onDismiss?()
    }

    @objc private func searchFieldEditingChanged() {
        searchDebounceWorkItem?.cancel()
        let query = searchField.text ?? ""
        let workItem = DispatchWorkItem { [weak self] in
            self?.performSearch(query)
        }
        searchDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }
}

// MARK: - UICollectionViewDataSource

extension EmojiSearchOverlay: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        allEmojis.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier, for: indexPath) as! EmojiCell
        cell.configure(with: EmojiSkinTone.applying(.current, to: allEmojis[indexPath.item]))
        return cell
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension EmojiSearchOverlay: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectionFeedback.selectionChanged()
        collectionView.deselectItem(at: indexPath, animated: false)
        let emoji = EmojiSkinTone.applying(.current, to: allEmojis[indexPath.item])
        EmojiRecents.add(emoji)
        onSelect?(emoji)
    }
}
