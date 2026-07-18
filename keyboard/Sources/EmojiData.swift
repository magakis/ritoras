import Foundation

// MARK: - EmojiData

enum EmojiData {

    /// ~1,870 emojis across 8 categories, sourced from @emoji-mart/data@1.2.1 (Emoji 15.1).
    static let categories: [(name: String, emojis: [String])] = {
        let file = loadCached()
        return file.categories.map { ($0.name, $0.emojis.map(\.char)) }
    }()

    /// All emoji entries flat-mapped across categories, for search.
    static let searchable: [EmojiEntry] = {
        loadCached().categories.flatMap { $0.emojis }
    }()

    /// Set of base emoji characters that support skin-tone modification.
    /// Phase 4 will replace EmojiSkinTone.skinToneCapable with this.
    static let skinToneCapable: Set<String> = {
        Set(loadCached().skinToneCapable)
    }()

    // MARK: - Models

    struct EmojiEntry: Decodable {
        let char: String
        let name: String
        let keywords: [String]
    }

    struct EmojiCategory: Decodable {
        let id: String
        let name: String
        let emojis: [EmojiEntry]
    }

    private struct EmojiDataFile: Decodable {
        let categories: [EmojiCategory]
        let skinToneCapable: [String]
    }

    // MARK: - Cache

    private static var _cached: EmojiDataFile?

    private static func loadCached() -> EmojiDataFile {
        if let cached = _cached { return cached }
        do {
            let file = try EmojiDataLoader.load()
            _cached = file
            return file
        } catch {
            let fallback = makeFallback()
            _cached = fallback
            return fallback
        }
    }

    // MARK: - Fallback

    /// Hardcoded minimal subset used when the bundled emojis.json cannot be parsed.
    private static func makeFallback() -> EmojiDataFile {
        func e(_ char: String) -> EmojiEntry {
            EmojiEntry(char: char, name: "", keywords: [])
        }

        let peopleBody = EmojiCategory(
            id: "people", name: "People & Body",
            emojis: (smileysPeople + gestures + heartsEmotion).map(e)
        )
        let animalsNature = EmojiCategory(
            id: "nature", name: "Animals & Nature",
            emojis: fallbackAnimalsNature.map(e)
        )
        let foods = EmojiCategory(
            id: "foods", name: "Food & Drink",
            emojis: fallbackFoodDrink.map(e)
        )
        let activity = EmojiCategory(
            id: "activity", name: "Activities",
            emojis: fallbackActivities.map(e)
        )
        let places = EmojiCategory(
            id: "places", name: "Travel & Places",
            emojis: fallbackTravelPlaces.map(e)
        )
        let objects = EmojiCategory(
            id: "objects", name: "Objects",
            emojis: fallbackObjects.map(e)
        )
        let symbols = EmojiCategory(
            id: "symbols", name: "Symbols",
            emojis: fallbackSymbols.map(e)
        )
        let flags = EmojiCategory(
            id: "flags", name: "Flags",
            emojis: fallbackFlags.map(e)
        )

        let skinToneCapable: [String] = [
            "👍", "👎", "👊", "✊", "🤛", "🤜", "👏", "🙌",
            "👐", "🤲", "🤝", "🙏", "✌️", "🤞", "🫶", "🤟",
            "🤘", "🤙", "🖐️", "✋", "👌", "🤌", "🤏", "🫵",
            "💪", "🦵", "🦶", "👂", "🦻",
        ]

        return EmojiDataFile(
            categories: [peopleBody, animalsNature, foods, activity, places, objects, symbols, flags],
            skinToneCapable: skinToneCapable
        )
    }

    // MARK: - Fallback data — ~50 emojis per category, reused from the old hardcoded arrays.

    private static let smileysPeople: [String] = [
        "😀", "😃", "😄", "😁", "😅", "😂", "🤣", "😊",
        "😇", "🙂", "😉", "😌", "😍", "🥰", "😘", "😗",
        "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
        "🤫", "🤔", "🤐",
    ]

    private static let gestures: [String] = [
        "👍", "👎", "👊", "✊", "🤛", "🤜", "👏", "🙌",
        "👐", "🤲", "🤝", "🙏", "✌️",
    ]

    private static let heartsEmotion: [String] = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
        "🤎", "💔",
    ]

    private static let fallbackAnimalsNature: [String] = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
        "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
        "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇", "🐺",
        "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞",
        "🐜", "🦟", "🦗", "🪳", "🪰", "🪱", "🐙", "🦑",
        "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳",
        "🐋", "🦈",
    ]

    private static let fallbackFoodDrink: [String] = [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇",
        "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥",
        "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌽",
        "🥕", "🧄", "🧅", "🥔", "🍠", "🫘", "🥜", "🌰",
        "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🥞", "🧇",
        "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", "🍟", "🍕",
        "🥪", "🥙",
    ]

    private static let fallbackActivities: [String] = [
        "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉",
        "🥏", "🎱", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏",
        "🪃", "🥅", "⛳", "🏹", "🎣", "🤿", "🥊", "🥋",
        "🎯", "🪀", "🪁", "🎿", "⛷️", "🏂", "🏋️", "🤼",
        "🤸", "🤾", "🧘", "🎪", "🎭", "🎨", "🎬", "🎤",
        "🎧", "🎼", "🎹", "🥁", "🪘", "🎷", "🎺", "🎸",
        "🎻", "🎲",
    ]

    private static let fallbackTravelPlaces: [String] = [
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑",
        "🚒", "🚐", "🛻", "🚚", "🚛", "🚜", "🛵", "🏍️",
        "🛺", "🚲", "🛴", "🚨", "🚔", "🚍", "🚘", "🚖",
        "🛩️", "✈️", "🚀", "🛸", "🚁", "🛶", "⛵", "🚤",
        "🛳️", "🚂", "🚆", "🚇", "🚊", "🚝", "🚃", "🚋",
        "🏠", "🏡", "🏢", "🏬", "🏨", "🏪", "🏫", "🏛️",
        "⛪", "🕌",
    ]

    private static let fallbackObjects: [String] = [
        "⌚", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🖲️",
        "🕹️", "🗜️", "💽", "💾", "💿", "📀", "📼", "📷",
        "📸", "📹", "🎥", "📽️", "🎞️", "📞", "☎️", "📟",
        "📠", "📺", "📻", "🎙️", "🎚️", "🎛️", "🧭", "⏱️",
        "⏲️", "⏰", "🕰️", "📡", "🔋", "🪫", "🔌", "💡",
        "🔦", "🕯️", "🪔", "🗑️", "🛢️", "💸", "💵", "💴",
        "💶", "💷",
    ]

    private static let fallbackSymbols: [String] = [
        "✅", "❌", "❓", "❔", "❕", "❗", "‼️", "⁉️",
        "➕", "➖", "➗", "✖️", "♾️", "©️", "®️", "™️",
        "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "🟤", "⚫",
        "⚪", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "🟫",
        "⬛", "⬜", "🔶", "🔷", "🔸", "🔹", "🔺", "🔻",
        "💠", "🔘", "🔲", "🔳", "🔈", "🔉", "🔊", "🔇",
        "📣", "📢",
    ]

    private static let fallbackFlags: [String] = [
        "🏳️", "🏴", "🏁", "🚩", "🎌", "🏴‍☠️",
        "🇺🇸", "🇬🇧", "🇨🇦", "🇫🇷", "🇩🇪", "🇮🇹", "🇪🇸",
        "🇵🇹", "🇳🇱", "🇧🇪", "🇨🇭", "🇦🇹", "🇸🇪", "🇳🇴",
        "🇩🇰", "🇫🇮", "🇮🇪", "🇬🇷", "🇵🇱", "🇨🇿", "🇭🇺",
        "🇷🇴", "🇧🇬", "🇷🇺", "🇯🇵", "🇨🇳", "🇮🇳", "🇧🇷",
        "🇦🇺", "🇳🇿", "🇿🇦", "🇲🇽", "🇦🇷", "🇰🇷",
    ]
}

// MARK: - EmojiDataLoader

enum EmojiDataLoader {
    private static let resourceName = "emojis"
    private static let resourceExtension = "json"

    /// Returns the URL for the bundled emoji dataset in the keyboard extension's bundle.
    static func bundledURL() -> URL? {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension)
    }

    /// Loads and parses the emoji dataset from a URL.
    /// - Parameter url: URL to the emojis.json file.
    /// - Returns: Parsed EmojiDataFile.
    static func load() throws -> EmojiDataFile {
        guard let url = bundledURL() else {
            throw EmojiDataError.bundledFileNotFound
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EmojiDataFile.self, from: data)
    }

    enum EmojiDataError: Error, LocalizedError {
        case bundledFileNotFound
        case parseFailed(Error)

        var errorDescription: String? {
            switch self {
            case .bundledFileNotFound:
                return "emojis.json not found in bundle. Ensure it is included in Copy Bundle Resources."
            case .parseFailed(let error):
                return "emojis.json parse failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - EmojiRecents

enum EmojiRecents {
    private static let storageKey = "ritoras_emoji_recents"
    private static let maxRecents = 12

    static func get() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }

    static func add(_ emoji: String) {
        var recents = get()
        // Remove existing occurrence so we can move it to front
        if let index = recents.firstIndex(of: emoji) {
            recents.remove(at: index)
        }
        recents.insert(emoji, at: 0)
        // Cap at max
        if recents.count > maxRecents {
            recents = Array(recents.prefix(maxRecents))
        }
        UserDefaults.standard.set(recents, forKey: storageKey)
    }
}

// MARK: - EmojiSkinTone

enum EmojiSkinTone: String, CaseIterable {
    case none = ""
    case light = "\u{1F3FB}"
    case lightMedium = "\u{1F3FC}"
    case medium = "\u{1F3FD}"
    case mediumDark = "\u{1F3FE}"
    case dark = "\u{1F3FF}"

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .lightMedium: return "Light Medium"
        case .medium: return "Medium"
        case .mediumDark: return "Medium Dark"
        case .dark: return "Dark"
        }
    }

    var sample: String {
        "👍" + rawValue
    }

    // MARK: - Persistence (mirrors EmojiRecents pattern)

    private static let storageKey = "ritoras_emoji_skin_tone"

    static var current: EmojiSkinTone {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey) else { return .light }
            return EmojiSkinTone(rawValue: raw) ?? .light
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }

    // MARK: - Application

    private static var skinToneCapable: Set<String> { EmojiData.skinToneCapable }

    static func applying(_ tone: EmojiSkinTone, to base: String) -> String {
        guard tone != .none, skinToneCapable.contains(base) else {
            return base
        }
        var modified = base
        // Strip trailing VS16 (U+FE0F) if present so modifier appends cleanly
        if modified.unicodeScalars.last == "\u{FE0F}" {
            modified = String(modified.unicodeScalars.dropLast())
        }
        return modified + tone.rawValue
    }
}
