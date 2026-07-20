import XCTest

final class HapticsManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        #if DEBUG
        HapticsManager.shared._testResetCounters()
        HapticsManager.shared._testSetEnabled(true)
        #endif
    }

    func test_tapImpact_increments_impactCounter() {
        #if DEBUG
        HapticsManager.shared.tapImpact()
        XCTAssertEqual(HapticsManager.shared.impactCallCount, 1)
        #else
        throw XCTSkip("DEBUG-only test hooks disabled in Release")
        #endif
    }

    func test_disabled_tapImpact_is_noop() {
        #if DEBUG
        HapticsManager.shared._testSetEnabled(false)
        HapticsManager.shared.tapImpact()
        XCTAssertEqual(HapticsManager.shared.impactCallCount, 0)
        #endif
    }

    func test_tapSelection_routes_to_selectionCounter() {
        #if DEBUG
        HapticsManager.shared.tapSelection()
        XCTAssertEqual(HapticsManager.shared.selectionCallCount, 1)
        #endif
    }

    func test_disabled_tapSelection_is_noop() {
        #if DEBUG
        HapticsManager.shared._testSetEnabled(false)
        HapticsManager.shared.tapSelection()
        XCTAssertEqual(HapticsManager.shared.selectionCallCount, 0)
        #endif
    }

    func test_prepareImpact_increments_prepareCounter() {
        #if DEBUG
        HapticsManager.shared.prepareImpact()
        XCTAssertEqual(HapticsManager.shared.prepareCallCount, 1)
        #endif
    }

    func test_disabled_prepareImpact_is_noop() {
        #if DEBUG
        HapticsManager.shared._testSetEnabled(false)
        HapticsManager.shared.prepareImpact()
        XCTAssertEqual(HapticsManager.shared.prepareCallCount, 0)
        #endif
    }

    func test_tapSuccessNotification_routes_to_notificationCounter() {
        #if DEBUG
        HapticsManager.shared.tapSuccessNotification()
        XCTAssertEqual(HapticsManager.shared.notificationCallCount, 1)
        #endif
    }

    func test_reloadEnabledFromAppGroup_reads_app_group() {
        #if DEBUG
        let key = SharedConfig.Defaults.hapticsEnabledKey
        let suite = UserDefaults(suiteName: SharedConfig.Defaults.appGroupId)
        let original = suite?.object(forKey: key) as? Bool
        defer {
            if let original = original {
                suite?.set(original, forKey: key)
            } else {
                suite?.removeObject(forKey: key)
            }
        }
        suite?.set(false, forKey: key)
        HapticsManager.shared.reloadEnabledFromAppGroup()
        XCTAssertFalse(HapticsManager.shared.isEnabled)
        #endif
    }
}
