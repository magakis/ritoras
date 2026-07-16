import UIKit

// MARK: - Key Action

enum KeyAction: Hashable {
    case insertText(String)
    case backspace
    case shift
    case shiftLock
    case toggleNumber
    case toggleLetters
    case toggleSymbols
    case mic
    case space
    case emoji
    case globe
    case `return`
}

// MARK: - Key Definition

struct KeyDefinition {
    let label: String
    let shiftedLabel: String?
    let action: KeyAction
    let widthWeight: CGFloat
}

// MARK: - Layout Mode

enum KeyboardLayoutMode: Equatable {
    case letters
    case numbers
    case symbols
}

// MARK: - Keyboard Layout

enum KeyboardLayout {

    // MARK: - Letter Rows

    static let letterRows: [[KeyDefinition]] = [
        // Row 1: q w e r t y u i o p
        [
            KeyDefinition(label: "q", shiftedLabel: "Q", action: .insertText("q"), widthWeight: 1),
            KeyDefinition(label: "w", shiftedLabel: "W", action: .insertText("w"), widthWeight: 1),
            KeyDefinition(label: "e", shiftedLabel: "E", action: .insertText("e"), widthWeight: 1),
            KeyDefinition(label: "r", shiftedLabel: "R", action: .insertText("r"), widthWeight: 1),
            KeyDefinition(label: "t", shiftedLabel: "T", action: .insertText("t"), widthWeight: 1),
            KeyDefinition(label: "y", shiftedLabel: "Y", action: .insertText("y"), widthWeight: 1),
            KeyDefinition(label: "u", shiftedLabel: "U", action: .insertText("u"), widthWeight: 1),
            KeyDefinition(label: "i", shiftedLabel: "I", action: .insertText("i"), widthWeight: 1),
            KeyDefinition(label: "o", shiftedLabel: "O", action: .insertText("o"), widthWeight: 1),
            KeyDefinition(label: "p", shiftedLabel: "P", action: .insertText("p"), widthWeight: 1),
        ],

        // Row 2: a s d f g h j k l
        [
            KeyDefinition(label: "a", shiftedLabel: "A", action: .insertText("a"), widthWeight: 1),
            KeyDefinition(label: "s", shiftedLabel: "S", action: .insertText("s"), widthWeight: 1),
            KeyDefinition(label: "d", shiftedLabel: "D", action: .insertText("d"), widthWeight: 1),
            KeyDefinition(label: "f", shiftedLabel: "F", action: .insertText("f"), widthWeight: 1),
            KeyDefinition(label: "g", shiftedLabel: "G", action: .insertText("g"), widthWeight: 1),
            KeyDefinition(label: "h", shiftedLabel: "H", action: .insertText("h"), widthWeight: 1),
            KeyDefinition(label: "j", shiftedLabel: "J", action: .insertText("j"), widthWeight: 1),
            KeyDefinition(label: "k", shiftedLabel: "K", action: .insertText("k"), widthWeight: 1),
            KeyDefinition(label: "l", shiftedLabel: "L", action: .insertText("l"), widthWeight: 1),
        ],

        // Row 3: shift z x c v b n m backspace
        [
            KeyDefinition(label: "⇧", shiftedLabel: "⇪", action: .shift, widthWeight: 1.5),
            KeyDefinition(label: "z", shiftedLabel: "Z", action: .insertText("z"), widthWeight: 1),
            KeyDefinition(label: "x", shiftedLabel: "X", action: .insertText("x"), widthWeight: 1),
            KeyDefinition(label: "c", shiftedLabel: "C", action: .insertText("c"), widthWeight: 1),
            KeyDefinition(label: "v", shiftedLabel: "V", action: .insertText("v"), widthWeight: 1),
            KeyDefinition(label: "b", shiftedLabel: "B", action: .insertText("b"), widthWeight: 1),
            KeyDefinition(label: "n", shiftedLabel: "N", action: .insertText("n"), widthWeight: 1),
            KeyDefinition(label: "m", shiftedLabel: "M", action: .insertText("m"), widthWeight: 1),
            KeyDefinition(label: "⌫", shiftedLabel: nil, action: .backspace, widthWeight: 1.5),
        ],

        // Row 4: 123 emoji mic space return
        [
            KeyDefinition(label: "123", shiftedLabel: nil, action: .toggleNumber, widthWeight: 1.5),
            KeyDefinition(label: "☺", shiftedLabel: nil, action: .emoji, widthWeight: 1.5),
            KeyDefinition(label: "", shiftedLabel: nil, action: .mic, widthWeight: 1.5),
            KeyDefinition(label: "space", shiftedLabel: nil, action: .space, widthWeight: 4.0),
            KeyDefinition(label: "return", shiftedLabel: nil, action: .return, widthWeight: 1.8),
        ],
    ]

    // MARK: - Number Rows

    static let numberRows: [[KeyDefinition]] = [
        // Row 1: 1 2 3 4 5 6 7 8 9 0
        (1...9).map { KeyDefinition(label: "\($0)", shiftedLabel: nil, action: .insertText("\($0)"), widthWeight: 1) }
        + [KeyDefinition(label: "0", shiftedLabel: nil, action: .insertText("0"), widthWeight: 1)],

        // Row 2: - / : ; ( ) $ & @ "
        [
            KeyDefinition(label: "-", shiftedLabel: nil, action: .insertText("-"), widthWeight: 1),
            KeyDefinition(label: "/", shiftedLabel: nil, action: .insertText("/"), widthWeight: 1),
            KeyDefinition(label: ":", shiftedLabel: nil, action: .insertText(":"), widthWeight: 1),
            KeyDefinition(label: ";", shiftedLabel: nil, action: .insertText(";"), widthWeight: 1),
            KeyDefinition(label: "(", shiftedLabel: nil, action: .insertText("("), widthWeight: 1),
            KeyDefinition(label: ")", shiftedLabel: nil, action: .insertText(")"), widthWeight: 1),
            KeyDefinition(label: "$", shiftedLabel: nil, action: .insertText("$"), widthWeight: 1),
            KeyDefinition(label: "&", shiftedLabel: nil, action: .insertText("&"), widthWeight: 1),
            KeyDefinition(label: "@", shiftedLabel: nil, action: .insertText("@"), widthWeight: 1),
            KeyDefinition(label: "\"", shiftedLabel: nil, action: .insertText("\""), widthWeight: 1),
        ],

        // Row 3: #+= . , ? ! ' backspace
        [
            KeyDefinition(label: "#+=", shiftedLabel: nil, action: .toggleSymbols, widthWeight: 1.5),
            KeyDefinition(label: ".", shiftedLabel: nil, action: .insertText("."), widthWeight: 1),
            KeyDefinition(label: ",", shiftedLabel: nil, action: .insertText(","), widthWeight: 1),
            KeyDefinition(label: "?", shiftedLabel: nil, action: .insertText("?"), widthWeight: 1),
            KeyDefinition(label: "!", shiftedLabel: nil, action: .insertText("!"), widthWeight: 1),
            KeyDefinition(label: "'", shiftedLabel: nil, action: .insertText("'"), widthWeight: 1),
            KeyDefinition(label: "⌫", shiftedLabel: nil, action: .backspace, widthWeight: 1.5),
        ],

        // Row 4: ABC emoji mic space return
        [
            KeyDefinition(label: "ABC", shiftedLabel: nil, action: .toggleLetters, widthWeight: 1.5),
            KeyDefinition(label: "☺", shiftedLabel: nil, action: .emoji, widthWeight: 1.5),
            KeyDefinition(label: "", shiftedLabel: nil, action: .mic, widthWeight: 1.5),
            KeyDefinition(label: "space", shiftedLabel: nil, action: .space, widthWeight: 4.0),
            KeyDefinition(label: "return", shiftedLabel: nil, action: .return, widthWeight: 1.8),
        ],
    ]

    // MARK: - Symbol Rows

    static let symbolRows: [[KeyDefinition]] = [
        // Row 1: [ ] { } # % ^ * + =
        [
            KeyDefinition(label: "[", shiftedLabel: nil, action: .insertText("["), widthWeight: 1),
            KeyDefinition(label: "]", shiftedLabel: nil, action: .insertText("]"), widthWeight: 1),
            KeyDefinition(label: "{", shiftedLabel: nil, action: .insertText("{"), widthWeight: 1),
            KeyDefinition(label: "}", shiftedLabel: nil, action: .insertText("}"), widthWeight: 1),
            KeyDefinition(label: "#", shiftedLabel: nil, action: .insertText("#"), widthWeight: 1),
            KeyDefinition(label: "%", shiftedLabel: nil, action: .insertText("%"), widthWeight: 1),
            KeyDefinition(label: "^", shiftedLabel: nil, action: .insertText("^"), widthWeight: 1),
            KeyDefinition(label: "*", shiftedLabel: nil, action: .insertText("*"), widthWeight: 1),
            KeyDefinition(label: "+", shiftedLabel: nil, action: .insertText("+"), widthWeight: 1),
            KeyDefinition(label: "=", shiftedLabel: nil, action: .insertText("="), widthWeight: 1),
        ],

        // Row 2: _ \ | ~ < > € £ ¥ •
        [
            KeyDefinition(label: "_", shiftedLabel: nil, action: .insertText("_"), widthWeight: 1),
            KeyDefinition(label: "\\", shiftedLabel: nil, action: .insertText("\\"), widthWeight: 1),
            KeyDefinition(label: "|", shiftedLabel: nil, action: .insertText("|"), widthWeight: 1),
            KeyDefinition(label: "~", shiftedLabel: nil, action: .insertText("~"), widthWeight: 1),
            KeyDefinition(label: "<", shiftedLabel: nil, action: .insertText("<"), widthWeight: 1),
            KeyDefinition(label: ">", shiftedLabel: nil, action: .insertText(">"), widthWeight: 1),
            KeyDefinition(label: "€", shiftedLabel: nil, action: .insertText("€"), widthWeight: 1),
            KeyDefinition(label: "£", shiftedLabel: nil, action: .insertText("£"), widthWeight: 1),
            KeyDefinition(label: "¥", shiftedLabel: nil, action: .insertText("¥"), widthWeight: 1),
            KeyDefinition(label: "•", shiftedLabel: nil, action: .insertText("•"), widthWeight: 1),
        ],

        // Row 3: 123 . , ? ! ' backspace
        [
            KeyDefinition(label: "123", shiftedLabel: nil, action: .toggleNumber, widthWeight: 1.5),
            KeyDefinition(label: ".", shiftedLabel: nil, action: .insertText("."), widthWeight: 1),
            KeyDefinition(label: ",", shiftedLabel: nil, action: .insertText(","), widthWeight: 1),
            KeyDefinition(label: "?", shiftedLabel: nil, action: .insertText("?"), widthWeight: 1),
            KeyDefinition(label: "!", shiftedLabel: nil, action: .insertText("!"), widthWeight: 1),
            KeyDefinition(label: "'", shiftedLabel: nil, action: .insertText("'"), widthWeight: 1),
            KeyDefinition(label: "⌫", shiftedLabel: nil, action: .backspace, widthWeight: 1.5),
        ],

        // Row 4: ABC emoji mic space return
        [
            KeyDefinition(label: "ABC", shiftedLabel: nil, action: .toggleLetters, widthWeight: 1.5),
            KeyDefinition(label: "☺", shiftedLabel: nil, action: .emoji, widthWeight: 1.5),
            KeyDefinition(label: "", shiftedLabel: nil, action: .mic, widthWeight: 1.5),
            KeyDefinition(label: "space", shiftedLabel: nil, action: .space, widthWeight: 4.0),
            KeyDefinition(label: "return", shiftedLabel: nil, action: .return, widthWeight: 1.8),
        ],
    ]

    // MARK: - Helpers

    static func rows(for mode: KeyboardLayoutMode) -> [[KeyDefinition]] {
        switch mode {
        case .letters:
            return letterRows
        case .numbers:
            return numberRows
        case .symbols:
            return symbolRows
        }
    }
}
