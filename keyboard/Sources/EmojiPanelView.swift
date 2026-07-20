import UIKit

// MARK: - EmojiCell

final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "EmojiCell"

    let emojiLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 28)
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
    /// Shared panel background color — used by both EmojiPanelView and its host KeyboardView
    /// so no visible seam appears between them at the top edge.
    static let panelBackground: UIColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.15, alpha: 1)
            : UIColor(white: 0.88, alpha: 1)
    }

    /// Secondary background for search-pill, active-category highlight circle, etc.
    static let panelSecondaryBackground: UIColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.17, alpha: 1.0)
            : UIColor(white: 0.92, alpha: 1.0)
    }

    /// Adaptive color for the category-selection highlight circle in the bottom toolbar.
    /// Slightly more contrasted than panelSecondaryBackground so the active category reads clearly.
    static let categoryHighlightColor: UIColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.25, alpha: 1.0)
            : UIColor(white: 0.82, alpha: 1.0)
    }

    /// Text/icon tint for the emoji toolbar buttons (ABC, recents, categories, backspace).
    /// Cross-referenced from KeyboardView for the mode-switch key's color.
    static let modeKeyTextColor: UIColor = UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.9, alpha: 1)
            : UIColor(white: 0.2, alpha: 1)
    }

    /// Maps each category id to its SF Symbol icon name.
    static let categoryIcons: [String: String] = [
        "people": "face.smiling",
        "nature": "pawprint",
        "foods": "fork.knife",
        "activity": "figure.run",
        "places": "car.fill",
        "objects": "lightbulb",
        "symbols": "heart",
        "flags": "flag",
    ]

    static let recentsIconName = "clock"
    static let backspaceIconName = "delete.left"

    // MARK: - Callbacks

    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearchActivate: (() -> Void)?
    var onSearchDismiss: (() -> Void)?
    var onSearchReturn: (() -> Void)?
    var onBackspace: (() -> Void)?

    // MARK: - Subviews

    private let searchContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = EmojiPanelView.panelSecondaryBackground
        view.layer.cornerRadius = 20
        view.clipsToBounds = true
        return view
    }()
    private let toneButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        button.setImage(UIImage(systemName: "gearshape", withConfiguration: config), for: .normal)
        return button
    }()
    private let collectionView: UICollectionView
    private let categoryToolbar: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .center
        stack.spacing = 0
        return stack
    }()
    private let abcButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("ABC", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: EmojiPanelView.modeKeyPointSize, weight: .regular)
        return button
    }()
    private let recentsButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "recents"
        return button
    }()
    private var categoryIconButtons: [UIButton] = []
    private let backspaceButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "backspace"
        return button
    }()
    /// `nil` means "Recents" is selected.
    private var selectedCategory: String?
    private var searchDebounceWorkItem: DispatchWorkItem?
    private var currentQuery: String = ""
    private let selectionFeedback = UISelectionFeedbackGenerator()
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
    let searchField: UITextField = {
        let field = UITextField()
        field.placeholder = "Search emoji"
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

        // Transparent background — the searchContainer provides the chrome
        field.backgroundColor = .clear
        field.textColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? .white : .black
        }
        field.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? .white : UIColor(white: 0.2, alpha: 1)
        }

        // Placeholder color adapts to dark mode
        field.attributedPlaceholder = NSAttributedString(
            string: "Search emoji",
            attributes: [.foregroundColor: UIColor { tc in
                tc.userInterfaceStyle == .dark
                    ? UIColor(white: 0.6, alpha: 1)
                    : UIColor(white: 0.4, alpha: 1)
            }]
        )
        return field
    }()

    // MARK: - Data

    /// Currently displayed emojis for the selected category.
    private var allEmojis: [String] = []

    // MARK: - Layout Constants

    private static let columns: CGFloat = 8
    private static let spacing: CGFloat = 6
    private static let cellSize: CGFloat = 36
    /// Point size for text buttons in the emoji toolbar (ABC) and matching mode-switch
    /// keys on the letter keyboard (e.g. the 123 button). Cross-referenced from KeyboardView.
    static let modeKeyPointSize: CGFloat = 17
    /// Point size for SF Symbol icons in the emoji category toolbar (clock, categories, backspace).
    private static let toolbarIconPointSize: CGFloat = 14
    /// Point size for the emoji-toggle key's SF Symbol on the letter keyboard.
    /// Slightly larger than modeKeyPointSize so the smiley reads as a primary affordance.
    static let emojiToggleIconPointSize: CGFloat = 20
    /// Ordered category ids matching the toolbar icon button order.
    private static let categoryOrder: [String] = [
        "people", "nature", "foods", "activity",
        "places", "objects", "symbols", "flags",
    ]

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
        backgroundColor = Self.panelBackground
        layer.cornerRadius = 6
        clipsToBounds = true

        setupSearchPill()
        setupCategoryToolbar()
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
    }

    private func setupSearchPill() {
        addSubview(searchContainer)

        // Embed searchField inside the pill
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchContainer.addSubview(searchField)

        // Tone button as trailing accessory inside the pill
        toneButton.tintColor = UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.2, alpha: 1)
        }
        toneButton.menu = buildToneMenu()
        toneButton.showsMenuAsPrimaryAction = true
        searchContainer.addSubview(toneButton)

        NSLayoutConstraint.activate([
            searchContainer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            searchContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            searchContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            searchContainer.heightAnchor.constraint(equalToConstant: 40),

            searchField.topAnchor.constraint(equalTo: searchContainer.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchContainer.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: toneButton.leadingAnchor, constant: -4),

            toneButton.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -6),
            toneButton.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            toneButton.widthAnchor.constraint(equalToConstant: 28),
            toneButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Wire search field delegate + editingChanged target
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchFieldEditingChanged), for: .editingChanged)
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
            collectionView.topAnchor.constraint(equalTo: searchContainer.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: categoryToolbar.topAnchor),
        ])
    }

    // MARK: - Data

    func reloadData() {
        if !currentQuery.isEmpty {
            performSearch(currentQuery)
            return
        }
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
        } else {
            emptyStateLabel.isHidden = true
        }
        collectionView.reloadData()
        collectionView.setContentOffset(.zero, animated: false)
    }

    // MARK: - Category Toolbar

    private func setupCategoryToolbar() {
        categoryToolbar.backgroundColor = .clear
        addSubview(categoryToolbar)

        // Match the search-pill horizontal insets (leading 8, trailing 8).
        NSLayoutConstraint.activate([
            categoryToolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            categoryToolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            categoryToolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            categoryToolbar.heightAnchor.constraint(equalToConstant: 44),
        ])

        let iconConfig = UIImage.SymbolConfiguration(pointSize: Self.toolbarIconPointSize, weight: .regular)

        // 1. ABC — dismiss to keyboard
        abcButton.setTitleColor(Self.modeKeyTextColor, for: .normal)
        abcButton.titleLabel?.font = .systemFont(ofSize: Self.modeKeyPointSize, weight: .regular)
        abcButton.addTarget(self, action: #selector(abcTapped), for: .touchUpInside)
        categoryToolbar.addArrangedSubview(abcButton)
        abcButton.heightAnchor.constraint(equalTo: abcButton.widthAnchor).isActive = true

        // 2. Recents (clock)
        recentsButton.setImage(
            UIImage(systemName: Self.recentsIconName, withConfiguration: iconConfig),
            for: .normal
        )
        recentsButton.tintColor = Self.modeKeyTextColor
        recentsButton.addTarget(self, action: #selector(recentsTapped), for: .touchUpInside)
        categoryToolbar.addArrangedSubview(recentsButton)
        recentsButton.heightAnchor.constraint(equalTo: recentsButton.widthAnchor).isActive = true

        // 3-10. Eight category icon buttons
        for (catId, cat) in zip(Self.categoryOrder, EmojiData.categories) {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            let iconName = Self.categoryIcons[catId]!
            button.setImage(
                UIImage(systemName: iconName, withConfiguration: iconConfig),
                for: .normal
            )
            button.tintColor = Self.modeKeyTextColor
            button.accessibilityIdentifier = cat.name
            button.addTarget(self, action: #selector(categoryIconTapped(_:)), for: .touchUpInside)
            categoryToolbar.addArrangedSubview(button)
            categoryIconButtons.append(button)
            button.heightAnchor.constraint(equalTo: button.widthAnchor).isActive = true
        }

        // 11. Backspace
        backspaceButton.setImage(
            UIImage(systemName: Self.backspaceIconName, withConfiguration: iconConfig),
            for: .normal
        )
        backspaceButton.tintColor = Self.modeKeyTextColor
        backspaceButton.addTarget(self, action: #selector(backspaceTouchDown), for: .touchDown)
        backspaceButton.addTarget(self, action: #selector(backspaceTouchUp), for: .touchUpInside)
        backspaceButton.addTarget(self, action: #selector(backspaceTouchUp), for: .touchUpOutside)
        backspaceButton.addTarget(self, action: #selector(backspaceTouchUp), for: .touchCancel)
        categoryToolbar.addArrangedSubview(backspaceButton)
        backspaceButton.heightAnchor.constraint(equalTo: backspaceButton.widthAnchor).isActive = true

        updateTabSelection()
    }

    private func updateTabSelection() {
        // Clear highlight on all toolbar buttons
        recentsButton.backgroundColor = .clear
        for button in categoryIconButtons {
            button.backgroundColor = .clear
        }

        // Determine which button should be highlighted
        let targetButton: UIButton?
        if selectedCategory == nil {
            targetButton = recentsButton
        } else {
            targetButton = categoryIconButtons.first { $0.accessibilityIdentifier == selectedCategory }
        }

        // Apply circular highlight via backgroundColor + cornerRadius.
        // The SF Symbol imageView renders on top of backgroundColor natively —
        // no subview juggling, no z-order races.
        if let button = targetButton {
            button.backgroundColor = Self.categoryHighlightColor
            button.layer.cornerRadius = 22
            button.layer.masksToBounds = true
        }
    }

    // MARK: - Toolbar Tap Handlers

    @objc private func abcTapped() {
        onDismiss?()
    }

    @objc private func recentsTapped() {
        if !currentQuery.isEmpty {
            searchField.text = ""
            currentQuery = ""
            searchDebounceWorkItem?.cancel()
            searchDebounceWorkItem = nil
            onSearchDismiss?()
        }
        selectedCategory = nil
        updateTabSelection()
        reloadData()
    }

    @objc private func categoryIconTapped(_ sender: UIButton) {
        guard let categoryId = sender.accessibilityIdentifier else { return }
        if !currentQuery.isEmpty {
            searchField.text = ""
            currentQuery = ""
            searchDebounceWorkItem?.cancel()
            searchDebounceWorkItem = nil
            onSearchDismiss?()
        }
        selectedCategory = categoryId
        updateTabSelection()
        reloadData()
    }

    @objc private func backspaceTouchDown() {
        onBackspace?()
    }

    @objc private func backspaceTouchUp() {
        // Phase 4 will wire begin/end pairing for repeat-delete
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

extension EmojiPanelView: UICollectionViewDataSource {
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

extension EmojiPanelView: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let availableWidth = collectionView.bounds.width - Self.spacing * (Self.columns + 1)
        let cellWidth = floor(availableWidth / Self.columns)
        return CGSize(width: cellWidth, height: Self.cellSize)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        selectionFeedback.selectionChanged()
        collectionView.deselectItem(at: indexPath, animated: false)
        let emoji = EmojiSkinTone.applying(.current, to: allEmojis[indexPath.item])
        onSelect?(emoji)
    }
}

// MARK: - UITextFieldDelegate

extension EmojiPanelView: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        onSearchActivate?()
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        return true  // observe via .editingChanged instead
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSearchReturn?()
        return false
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        return true  // allow clear × to work; .editingChanged will fire with empty text
    }
}
