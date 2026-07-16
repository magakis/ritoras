import UIKit

// MARK: - EmojiData

enum EmojiData {

    /// ~500 emojis across 8 categories.
    static let categories: [(name: String, emojis: [String])] = [
        ("Smileys & People", smileysPeople),
        ("Gestures", gestures),
        ("Hearts & Emotion", heartsEmotion),
        ("Animals & Nature", animalsNature),
        ("Food & Drink", foodDrink),
        ("Activities", activities),
        ("Travel & Places", travelPlaces),
        ("Objects", objects),
        ("Symbols", symbols),
    ]

    // MARK: - Smileys & People

    private static let smileysPeople: [String] = [
        "😀", "😃", "😄", "😁", "😅", "😂", "🤣", "😊",
        "😇", "🙂", "😉", "😌", "😍", "🥰", "😘", "😗",
        "😋", "😛", "😜", "🤪", "😝", "🤑", "🤗", "🤭",
        "🤫", "🤔", "🤐", "😐", "😑", "😶", "😏", "😒",
        "🙄", "😬", "😮", "😯", "😲", "🥺", "😢", "😭",
        "😤", "😠", "😡", "🤬", "🤯", "😳", "🥵", "🥶",
        "😱", "😨", "😰", "😥", "😓", "🤩", "😪", "😵",
        "🤤", "😴", "🥴", "🤮", "🤧", "🥳", "🥸", "🤠",
        "😎", "🤓", "🧐", "🤡", "👻", "💀", "☠️", "👽",
    ]

    // MARK: - Gestures

    private static let gestures: [String] = [
        "👍", "👎", "👊", "✊", "🤛", "🤜", "👏", "🙌",
        "👐", "🤲", "🤝", "🙏", "✌️", "🤞", "🫶", "🤟",
        "🤘", "🤙", "🖐️", "✋", "👌", "🤌", "🤏", "🫵",
        "💪", "🦵", "🦶", "👂", "🦻", "👃", "🧠", "🫀",
        "👁️", "👀", "👅", "👄", "🦷",
    ]

    // MARK: - Hearts & Emotion

    private static let heartsEmotion: [String] = [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍",
        "🤎", "💔", "❣️", "💕", "💞", "💓", "💗", "💖",
        "💘", "💝", "💟", "❤️‍🔥", "❤️‍🩹", "♥️",
    ]

    // MARK: - Animals & Nature

    private static let animalsNature: [String] = [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼",
        "🐨", "🐯", "🦁", "🐮", "🐷", "🐸", "🐵", "🐔",
        "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇", "🐺",
        "🐗", "🐴", "🦄", "🐝", "🐛", "🦋", "🐌", "🐞",
        "🐜", "🦟", "🦗", "🪳", "🪰", "🪱", "🐙", "🦑",
        "🦐", "🦞", "🦀", "🐡", "🐠", "🐟", "🐬", "🐳",
        "🐋", "🦈", "🐊", "🐍", "🦎", "🐢", "🐚", "🪸",
        "🌺", "🌸", "🌼", "🌻", "🌹", "🌷", "🌿", "🍀",
        "🌲", "🌳", "🌴", "🌵", "🌾", "🍄", "🌰", "🪴",
    ]

    // MARK: - Food & Drink

    private static let foodDrink: [String] = [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇",
        "🍓", "🫐", "🍈", "🍒", "🍑", "🥭", "🍍", "🥥",
        "🥝", "🍅", "🍆", "🥑", "🥦", "🥬", "🥒", "🌽",
        "🥕", "🧄", "🧅", "🥔", "🍠", "🫘", "🥜", "🌰",
        "🍞", "🥖", "🥨", "🧀", "🥚", "🍳", "🥞", "🧇",
        "🥓", "🥩", "🍗", "🍖", "🌭", "🍔", "🍟", "🍕",
        "🥪", "🥙", "🧆", "🌮", "🌯", "🥗", "🥘", "🫕",
        "🍜", "🍝", "🍲", "🍛", "🍣", "🍱", "🥟", "🦪",
        "🍦", "🍧", "🍨", "🍩", "🍪", "🎂", "🍰", "🧁",
        "🍫", "🍬", "🍭", "🍮", "🍯", "☕", "🍵", "🧃",
        "🥤", "🧊", "🍺", "🍻", "🥂", "🍷", "🥃", "🍸",
    ]

    // MARK: - Activities

    private static let activities: [String] = [
        "⚽", "🏀", "🏈", "⚾", "🥎", "🎾", "🏐", "🏉",
        "🥏", "🎱", "🏓", "🏸", "🏒", "🏑", "🥍", "🏏",
        "🪃", "🥅", "⛳", "🏹", "🎣", "🤿", "🥊", "🥋",
        "🎯", "🪀", "🪁", "🎿", "⛷️", "🏂", "🏋️", "🤼",
        "🤸", "🤾", "🧘", "🎪", "🎭", "🎨", "🎬", "🎤",
        "🎧", "🎼", "🎹", "🥁", "🪘", "🎷", "🎺", "🎸",
        "🎻", "🎲", "♟️", "🎮", "🕹️", "🎰", "🧩",
    ]

    // MARK: - Travel & Places

    private static let travelPlaces: [String] = [
        "🚗", "🚕", "🚙", "🚌", "🚎", "🏎️", "🚓", "🚑",
        "🚒", "🚐", "🛻", "🚚", "🚛", "🚜", "🛵", "🏍️",
        "🛺", "🚲", "🛴", "🚨", "🚔", "🚍", "🚘", "🚖",
        "🛩️", "✈️", "🚀", "🛸", "🚁", "🛶", "⛵", "🚤",
        "🛳️", "🚂", "🚆", "🚇", "🚊", "🚝", "🚃", "🚋",
        "🏠", "🏡", "🏢", "🏬", "🏨", "🏪", "🏫", "🏛️",
        "⛪", "🕌", "🕍", "🛕", "🏗️", "🏘️", "🏔️", "⛰️",
        "🌋", "🏝️", "🏖️", "🏜️", "🌅", "🌄", "🌇", "🌆",
        "🗺️", "🗾", "🌍", "🌎", "🌏",
    ]

    // MARK: - Objects

    private static let objects: [String] = [
        "⌚", "📱", "💻", "⌨️", "🖥️", "🖨️", "🖱️", "🖲️",
        "🕹️", "🗜️", "💽", "💾", "💿", "📀", "📼", "📷",
        "📸", "📹", "🎥", "📽️", "🎞️", "📞", "☎️", "📟",
        "📠", "📺", "📻", "🎙️", "🎚️", "🎛️", "🧭", "⏱️",
        "⏲️", "⏰", "🕰️", "📡", "🔋", "🪫", "🔌", "💡",
        "🔦", "🕯️", "🪔", "🗑️", "🛢️", "💸", "💵", "💴",
        "💶", "💷", "🪙", "💰", "💳", "💎", "⚖️", "🪜",
        "🧰", "🪛", "🔧", "🔨", "⚒️", "🛠️", "⛏️", "🔩",
        "⚙️", "🧲", "🔫", "💣", "🧪", "🔬", "🔭", "📡",
        "💉", "🩸", "💊", "🩹", "🩺", "🚿", "🛁", "🪥",
        "🪒", "🧴", "🧷", "💄", "💋", "👔", "👕", "👖",
        "🧣", "🧤", "🧥", "🧦", "👗", "👘", "🩱", "🩲",
        "👙", "👚", "👛", "👜", "👝", "🎒", "🧳", "👡",
        "👠", "👟", "🥿", "👞", "👑", "🎩", "🎓", "🧢",
        "⛑️", "📿", "💍", "🐚",
    ]

    // MARK: - Symbols

    private static let symbols: [String] = [
        "✅", "❌", "❓", "❔", "❕", "❗", "‼️", "⁉️",
        "➕", "➖", "➗", "✖️", "♾️", "©️", "®️", "™️",
        "🔴", "🟠", "🟡", "🟢", "🔵", "🟣", "🟤", "⚫",
        "⚪", "🟥", "🟧", "🟨", "🟩", "🟦", "🟪", "🟫",
        "⬛", "⬜", "🔶", "🔷", "🔸", "🔹", "🔺", "🔻",
        "💠", "🔘", "🔲", "🔳", "🔈", "🔉", "🔊", "🔇",
        "📣", "📢", "🔔", "🔕", "🎵", "🎶", "💤", "💢",
        "💬", "🗯️", "💭", "♠️", "♥️", "♦️", "♣️", "🃏",
        "🀄", "🔰", "🔱", "⚜️", "💯", "🔞", "🚫", "📛",
        "🚸", "⚠️", "☢️", "☣️", "⬆️", "⬇️", "➡️", "⬅️",
        "↗️", "↘️", "↙️", "↖️", "↕️", "🔄", "◀️", "▶️",
        "⏸️", "⏯️", "⏹️", "⏺️", "⏭️", "⏮️", "⏩", "⏪",
        "🔀", "🔁", "🔂", "🆕", "🆙", "🆒", "🆓", "🆖",
        "🆗", "🆙", "🆚", "🈁", "🈂️", "🈷️", "🈶", "🈯",
        "🉐", "🈹", "🈚", "🈲", "🈺", "🈸", "🈴", "🈳",
        "㊗️", "㊙️", "🈺", "🈵",
    ]
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

    private static let skinToneCapable: Set<String> = [
        "👍", "👎", "👊", "✊", "🤛", "🤜", "👏", "🙌",
        "👐", "🤲", "🤝", "🙏", "✌️", "🤞", "🫶", "🤟",
        "🤘", "🤙", "🖐️", "✋", "👌", "🤌", "🤏", "🫵",
        "💪", "🦵", "🦶", "👂", "🦻",
    ]

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
