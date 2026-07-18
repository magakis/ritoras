import XCTest

final class AutoCorrectTraitsTests: XCTestCase {

    // MARK: - autocorrectionType

    func test_autocorrectionType_no_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: .no,
            spellCheckingType: .yes
        ))
    }

    func test_autocorrectionType_yes_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_autocorrectionType_nil_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: nil,
            spellCheckingType: .yes
        ))
    }

    // MARK: - spellCheckingType

    func test_spellCheckingType_no_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: .yes,
            spellCheckingType: .no
        ))
    }

    func test_spellCheckingType_nil_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: .yes,
            spellCheckingType: nil
        ))
    }

    // MARK: - Keyboard Types That Suppress

    func test_keyboardType_URL_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .URL,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_emailAddress_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .emailAddress,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_numberPad_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .numberPad,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_phonePad_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .phonePad,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_namePhonePad_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .namePhonePad,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_asciiCapableNumberPad_suppresses() {
        XCTAssertTrue(AutoCorrectTraits.shouldSuppress(
            keyboardType: .asciiCapableNumberPad,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    // MARK: - Keyboard Types That Do NOT Suppress

    func test_keyboardType_default_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: .default,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_asciiCapable_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: .asciiCapable,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }

    func test_keyboardType_nil_does_not_suppress() {
        XCTAssertFalse(AutoCorrectTraits.shouldSuppress(
            keyboardType: nil,
            autocorrectionType: .yes,
            spellCheckingType: .yes
        ))
    }
}
