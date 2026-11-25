import XCTest
import CenterMyMenuCore

final class CenterMyMenuCoreTests: XCTestCase {
    private func display(_ id: String = "external", builtIn: Bool = false,
                         frame: CGRect = CGRect(x: 0, y: 0, width: 3440, height: 1440),
                         safeTop: CGFloat = 0, autoHidden: Bool = false) -> DisplayDescriptor {
        let topGap: CGFloat = autoHidden ? 0 : max(24, safeTop)
        return DisplayDescriptor(id: id, isBuiltIn: builtIn, frame: frame,
                                 visibleFrame: CGRect(x: frame.minX, y: frame.minY + 50,
                                                      width: frame.width, height: frame.height - 50 - topGap),
                                 safeTopInset: safeTop)
    }

    func testNegativeOriginScreenCentersInItsOwnCoordinateSpace() {
        let screen = display(frame: CGRect(x: -3440, y: 200, width: 3440, height: 1440))
        let result = ControlLayout.place(requestedSize: CGSize(width: 580, height: 30), on: screen,
                                         preferences: DisplayPreferences(mode: .toolbar))
        XCTAssertEqual(result.frame.midX, -1720, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result.frame.maxY, screen.frame.maxY)
        XCTAssertGreaterThanOrEqual(result.frame.minX, screen.frame.minX)
        XCTAssertLessThanOrEqual(result.frame.maxX, screen.frame.maxX)
    }

    func testDefaultControlOverlaysTopCenter() {
        let screen = display()
        let overlay = ControlLayout.place(requestedSize: CGSize(width: 54, height: 30), on: screen,
                                          preferences: DisplayPreferences(mode: .compactIcon))
        XCTAssertEqual(overlay.frame.midX, screen.frame.midX, accuracy: 0.01)
        XCTAssertEqual(overlay.frame.maxY, screen.frame.maxY, accuracy: 0.01)
    }

    func testNotchConstrainsBothDefaultAndDraggedControlsBelowSafeArea() {
        let screen = display("laptop", builtIn: true,
                             frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeTop: 38)
        var preferences = DisplayPreferences(mode: .toolbar)
        let automatic = ControlLayout.place(requestedSize: CGSize(width: 600, height: 30), on: screen, preferences: preferences)
        XCTAssertLessThanOrEqual(automatic.frame.maxY, screen.frame.maxY - 38 - ControlLayout.belowBarGap)
        preferences.position = StoredPosition(horizontalFraction: 0.5, topOffset: 0)
        let dragged = ControlLayout.place(requestedSize: CGSize(width: 600, height: 30), on: screen, preferences: preferences)
        XCTAssertLessThanOrEqual(dragged.frame.maxY, screen.frame.maxY - 38 - ControlLayout.belowBarGap)
    }

    func testOversizedToolbarFitsAndSignalsHorizontalScrolling() {
        let screen = display(frame: CGRect(x: -1280, y: -200, width: 1280, height: 900))
        let result = ControlLayout.place(requestedSize: CGSize(width: 10000, height: 30), on: screen,
                                         preferences: DisplayPreferences(mode: .toolbar))
        XCTAssertTrue(result.hasHorizontalOverflow)
        XCTAssertEqual(result.frame.width, 1280 - 2 * ControlLayout.horizontalMargin, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(result.frame.minX, screen.frame.minX)
        XCTAssertLessThanOrEqual(result.frame.maxX, screen.frame.maxX)
    }

    func testToolbarWidthChangesPreserveDefaultAndDraggedCenter() {
        let screen = display()
        for position: StoredPosition? in [nil, StoredPosition(horizontalFraction: 0.35, topOffset: 180)] {
            let preferences = DisplayPreferences(mode: .toolbar, position: position)
            let small = ControlLayout.place(requestedSize: CGSize(width: 250, height: 30), on: screen, preferences: preferences)
            let large = ControlLayout.place(requestedSize: CGSize(width: 1000, height: 30), on: screen, preferences: preferences)
            XCTAssertEqual(small.frame.midX, large.frame.midX, accuracy: 0.01)
            XCTAssertEqual(small.frame.midY, large.frame.midY, accuracy: 0.01)
        }
    }

    func testDragClampsEveryEdgeAndRoundTripsSavedCenter() {
        let screen = display(frame: CGRect(x: -1800, y: -1000, width: 1800, height: 1000))
        let offscreen = DisplayPreferences(mode: .toolbar,
            position: StoredPosition(horizontalFraction: -2, topOffset: 5000))
        let result = ControlLayout.place(requestedSize: CGSize(width: 500, height: 30), on: screen, preferences: offscreen)
        XCTAssertGreaterThanOrEqual(result.frame.minX, screen.frame.minX)
        XCTAssertGreaterThanOrEqual(result.frame.minY, screen.visibleFrame.minY)
        let saved = ControlLayout.storedPosition(of: result.frame, on: screen)
        let restored = ControlLayout.place(requestedSize: result.frame.size, on: screen,
            preferences: DisplayPreferences(mode: .toolbar, position: saved))
        XCTAssertEqual(result.frame, restored.frame)
    }

    func testAutoHiddenMenuBarStillUsesTopCenter() {
        let screen = display(autoHidden: true)
        let result = ControlLayout.place(requestedSize: CGSize(width: 54, height: 30), on: screen,
            preferences: DisplayPreferences(mode: .compactIcon))
        XCTAssertEqual(result.frame.maxY, screen.frame.maxY, accuracy: 0.01)
    }

    func testActiveDisplayFollowsActivityAndFallsBackWhenDisconnected() {
        let laptop = display("laptop", builtIn: true)
        let external = display("external")
        var configuration = Configuration()
        configuration.displayScope = .active
        XCTAssertEqual(configuration.targetDisplays(in: [external, laptop], activeDisplayID: laptop.id), [laptop])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, external], activeDisplayID: external.id), [external])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop], activeDisplayID: external.id), [laptop])
        XCTAssertTrue(configuration.targetDisplays(in: [], activeDisplayID: nil).isEmpty)
    }

    func testAllDisplaysShareModeButPreserveIndependentPositionsAcrossReconnect() {
        let a = display("a"), b = display("b")
        var configuration = Configuration()
        configuration.displayScope = .all
        configuration.mode = .toolbar
        let saved = StoredPosition(horizontalFraction: 0.2, topOffset: 100)
        configuration.positions[a.id] = saved
        XCTAssertEqual(configuration.targetDisplays(in: [a, b], activeDisplayID: b.id), [a, b])
        XCTAssertEqual(configuration.profile(for: a), DisplayPreferences(mode: .toolbar, position: saved))
        XCTAssertEqual(configuration.profile(for: b), DisplayPreferences(mode: .toolbar))
        XCTAssertEqual(configuration.targetDisplays(in: [b], activeDisplayID: b.id), [b])
        XCTAssertEqual(configuration.positions[a.id], saved)
        configuration.mode = .statusOnly
        for display in [a, b] { XCTAssertFalse(configuration.profile(for: display).showsFloatingControl) }
        configuration.mode = .compactIcon
        XCTAssertEqual(configuration.profile(for: a).position, saved)
        XCTAssertEqual(configuration.profile(for: b).mode, .compactIcon)
    }

    func testResetClearsOnlyTargetDisplayPositions() {
        let a = display("a"), b = display("b")
        var configuration = Configuration()
        configuration.displayScope = .active
        let position = StoredPosition(horizontalFraction: 0.2, topOffset: 100)
        configuration.positions = [a.id: position, b.id: position, "disconnected": position]
        configuration.resetPositions(for: configuration.targetDisplays(in: [a, b], activeDisplayID: b.id).map(\.id))
        XCTAssertEqual(configuration.positions, [a.id: position, "disconnected": position])
        configuration.displayScope = .all
        configuration.resetPositions(for: configuration.targetDisplays(in: [a, b], activeDisplayID: b.id).map(\.id))
        XCTAssertEqual(configuration.positions, ["disconnected": position])
    }

    func testWidestUsesLogicalWorkspaceAndStableTiesAcrossReconnect() {
        let laptop = DisplayDescriptor(id: "laptop", isBuiltIn: true,
            frame: CGRect(x: -1728, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: -1728, y: 0, width: 1728, height: 1090))
        let wide = DisplayDescriptor(id: "wide", isBuiltIn: false,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 5120, height: 1415))
        let tie = DisplayDescriptor(id: "wide-z", isBuiltIn: false, frame: wide.frame, visibleFrame: wide.visibleFrame)
        let configuration = Configuration()
        XCTAssertEqual(configuration.displayScope, .widest)
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, wide], activeDisplayID: laptop.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [tie, laptop, wide], activeDisplayID: tie.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [wide, laptop, tie], activeDisplayID: laptop.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop], activeDisplayID: wide.id), [laptop])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, wide], activeDisplayID: laptop.id), [wide])
        XCTAssertTrue(configuration.targetDisplays(in: [], activeDisplayID: nil).isEmpty)
    }

    func testBuiltInExclusionFiltersAllAndIsDisabledByDefault() {
        let laptop = display("laptop", builtIn: true,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1440))
        let a = display("a"), b = display("b")
        let screens = [b, laptop, a]
        var configuration = Configuration()
        XCTAssertFalse(configuration.neverShowOnBuiltInDisplay)
        XCTAssertFalse(Configuration.uiTest().neverShowOnBuiltInDisplay)
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: a.id), [laptop])
        configuration.displayScope = .active
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: laptop.id), [laptop])
        configuration.displayScope = .all
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: laptop.id), screens)
        configuration.neverShowOnBuiltInDisplay = true
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: laptop.id), [b, a])
        configuration.neverShowOnBuiltInDisplay = false
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: laptop.id), screens)
    }

    func testBuiltInExclusionWidestChoosesEligibleExternalWithStableTies() {
        let laptop = display("laptop", builtIn: true,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1440))
        let wide = display("external-a"), tie = display("external-z")
        let narrow = display("narrow", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var configuration = Configuration()
        configuration.neverShowOnBuiltInDisplay = true
        XCTAssertEqual(configuration.targetDisplays(in: [tie, laptop, narrow, wide], activeDisplayID: laptop.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [wide, narrow, laptop, tie], activeDisplayID: tie.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, narrow, tie], activeDisplayID: laptop.id), [tie])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, narrow], activeDisplayID: laptop.id), [narrow])
        XCTAssertEqual(configuration.targetDisplays(in: [tie, laptop, wide], activeDisplayID: laptop.id), [wide])
    }

    func testBuiltInExclusionActiveDistinguishesExcludedFromUnknown() {
        let laptop = display("laptop", builtIn: true,
            frame: CGRect(x: 0, y: 0, width: 5120, height: 1440))
        let wide = display("wide")
        let narrow = display("narrow", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        var configuration = Configuration()
        configuration.neverShowOnBuiltInDisplay = true
        configuration.displayScope = .active
        let screens = [laptop, narrow, wide]
        XCTAssertTrue(configuration.targetDisplays(in: screens, activeDisplayID: laptop.id).isEmpty)
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: narrow.id), [narrow])
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: wide.id), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: nil), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: screens, activeDisplayID: "unknown"), [wide])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, narrow], activeDisplayID: wide.id), [narrow])
    }

    func testBuiltInExclusionReturnsNoTargetsWithoutExternalDisplays() {
        let laptop = display("laptop", builtIn: true)
        var configuration = Configuration()
        configuration.neverShowOnBuiltInDisplay = true
        for scope in DisplayScope.allCases {
            configuration.displayScope = scope
            for activeID: String? in [nil, laptop.id, "disconnected"] {
                XCTAssertTrue(configuration.targetDisplays(in: [laptop], activeDisplayID: activeID).isEmpty, scope.rawValue)
                XCTAssertTrue(configuration.targetDisplays(in: [], activeDisplayID: activeID).isEmpty, scope.rawValue)
            }
        }
    }

    func testBuiltInExclusionRetainsPositionsAcrossReconnectAndResetsOnlyEligibleTargets() {
        let laptop = display("laptop", builtIn: true), a = display("a"), b = display("b")
        var configuration = Configuration()
        configuration.neverShowOnBuiltInDisplay = true
        configuration.positions = [
            laptop.id: StoredPosition(horizontalFraction: 0.2, topOffset: 100),
            a.id: StoredPosition(horizontalFraction: 0.4, topOffset: 140),
            b.id: StoredPosition(horizontalFraction: 0.6, topOffset: 180),
            "disconnected": StoredPosition(horizontalFraction: 0.8, topOffset: 220)
        ]
        let saved = configuration.positions
        configuration.displayScope = .active
        configuration.resetPositions(for: configuration.targetDisplays(in: [laptop, a, b], activeDisplayID: laptop.id).map(\.id))
        XCTAssertEqual(configuration.positions, saved)
        configuration.displayScope = .all
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, a, b], activeDisplayID: laptop.id), [a, b])
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, b], activeDisplayID: a.id), [b])
        XCTAssertTrue(configuration.targetDisplays(in: [laptop], activeDisplayID: a.id).isEmpty)
        XCTAssertEqual(configuration.positions, saved)
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, a, b], activeDisplayID: laptop.id), [a, b])
        for screen in [laptop, a, b] {
            XCTAssertEqual(configuration.profile(for: screen).position, saved[screen.id])
        }
        configuration.resetPositions(for: configuration.targetDisplays(in: [laptop, a, b], activeDisplayID: laptop.id).map(\.id))
        XCTAssertEqual(configuration.positions, saved.filter { $0.key == laptop.id || $0.key == "disconnected" })
        configuration.neverShowOnBuiltInDisplay = false
        XCTAssertEqual(configuration.targetDisplays(in: [laptop, a, b], activeDisplayID: laptop.id), [laptop, a, b])
        XCTAssertEqual(configuration.profile(for: laptop).position, saved[laptop.id])
    }

    func testHierarchyNormalizationPreservesOrderAndMetadata() {
        let disabled = MenuEntry(title: "Save", isEnabled: false, shortcut: MenuShortcut(key: "s"))
        let branch = MenuEntry(title: "More", state: .mixed, hasSubmenu: true)
        let normalized = MenuMapping.normalized([.separator(), disabled, .separator(), .separator(), branch, .separator()])
        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized.first, disabled)
        XCTAssertTrue(normalized[1].isSeparator)
        XCTAssertEqual(normalized.last, branch)
        XCTAssertEqual(MenuMapping.title("Apple", isTopLevel: true), "")
        XCTAssertEqual(MenuMapping.title(nil, isTopLevel: true, isAppleMenu: true), "")
        XCTAssertEqual(MenuMapping.title("Apple", isTopLevel: false), "Apple")
    }

    func testSettingsSurviveReloadWithoutMixingDisplayPositions() {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults)
        store.value.displayScope = .all
        store.value.mode = .toolbar
        store.value.fontSize = 18
        store.value.positions["ultrawide"] = StoredPosition(horizontalFraction: 0.6, topOffset: 100)
        store.value.positions["laptop"] = StoredPosition(horizontalFraction: 0.3, topOffset: 80)
        let restored = ConfigurationStore(defaults: defaults)
        XCTAssertEqual(restored.value, store.value)
        XCTAssertNotEqual(restored.value.positions["ultrawide"], restored.value.positions["laptop"])
    }

    func testThemeSurvivesReload() {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults)
        for theme in AppTheme.allCases {
            store.value.theme = theme
            XCTAssertEqual(ConfigurationStore(defaults: defaults).value.theme, theme)
        }
    }

    func testSavedConfigurationContainsOnlyCurrentSettings() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConfigurationStore(defaults: defaults)
        store.value.theme = .dark
        let data = try XCTUnwrap(defaults.data(forKey: "CenterMyMenu.configuration.v1"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(saved.keys), ["theme", "fontSize", "displayScope", "mode", "positions", "hideInFullScreen", "neverShowOnBuiltInDisplay"])
        XCTAssertEqual(Configuration().mode, .toolbar)
        XCTAssertEqual(saved["mode"] as? String, "toolbar")
        XCTAssertEqual(saved["neverShowOnBuiltInDisplay"] as? Bool, false)
        XCTAssertEqual(ConfigurationStore(defaults: defaults).value, store.value)
    }

    func testFullScreenPreferencePreservesPreviousSettings() throws {
        let previous = Data(#"{"theme":"dark","fontSize":18,"displayScope":"all","mode":"toolbar","positions":{"screen":{"horizontalFraction":0.7,"topOffset":250}}}"#.utf8)
        var value = try JSONDecoder().decode(Configuration.self, from: previous)
        XCTAssertTrue(value.hideInFullScreen)
        XCTAssertEqual(value.theme, .dark)
        XCTAssertEqual(value.positions["screen"], StoredPosition(horizontalFraction: 0.7, topOffset: 250))
        value.hideInFullScreen = false
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(restored, value)
        XCTAssertFalse(restored.profile(for: display("screen")).hideInFullScreen)
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: previous) as? [String: Any])
        invalid["hideInFullScreen"] = "yes"
        var expected = value
        expected.hideInFullScreen = true
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self,
            from: JSONSerialization.data(withJSONObject: invalid)), expected)
    }

    func testBuiltInExclusionPreservesOlderSettingsAndRoundTrips() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = Data(#"""
        {
            "theme": "dark", "fontSize": 18, "displayScope": "all",
            "mode": "compactIcon", "hideInFullScreen": false,
            "positions": {
                "laptop": {"horizontalFraction": 0.3, "topOffset": 80},
                "external": {"horizontalFraction": 0.7, "topOffset": 160},
                "disconnected": {"horizontalFraction": 0.5, "topOffset": 200}
            }
        }
        """#.utf8)
        var expected = Configuration()
        expected.theme = .dark
        expected.fontSize = 18
        expected.displayScope = .all
        expected.mode = .compactIcon
        expected.hideInFullScreen = false
        expected.positions = [
            "laptop": StoredPosition(horizontalFraction: 0.3, topOffset: 80),
            "external": StoredPosition(horizontalFraction: 0.7, topOffset: 160),
            "disconnected": StoredPosition(horizontalFraction: 0.5, topOffset: 200)
        ]
        defaults.set(previous, forKey: "CenterMyMenu.configuration.v1")
        let store = ConfigurationStore(defaults: defaults)
        XCTAssertEqual(store.value, expected)
        XCTAssertFalse(store.value.neverShowOnBuiltInDisplay)
        XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), previous)
        for enabled in [true, false] {
            store.value.neverShowOnBuiltInDisplay = enabled
            expected.neverShowOnBuiltInDisplay = enabled
            XCTAssertEqual(store.value, expected)
            XCTAssertEqual(ConfigurationStore(defaults: defaults).value, expected)
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self,
                from: JSONEncoder().encode(store.value)), expected)
        }
    }

    func testMalformedBuiltInExclusionDefaultsWithoutLosingOtherSettings() throws {
        var expected = Configuration()
        expected.theme = .light
        expected.fontSize = 20
        expected.displayScope = .active
        expected.mode = .compactIcon
        expected.hideInFullScreen = false
        expected.positions = ["laptop": StoredPosition(horizontalFraction: 0.25, topOffset: 90),
                              "disconnected": StoredPosition(horizontalFraction: 0.75, topOffset: 190)]
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? [String: Any])
        let invalidValues: [Any] = [NSNull(), "true", 1, ["unexpected"], ["enabled": true]]
        for invalid in invalidValues {
            fields["neverShowOnBuiltInDisplay"] = invalid
            let restored = try JSONDecoder().decode(Configuration.self,
                from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertFalse(restored.neverShowOnBuiltInDisplay)
            XCTAssertEqual(restored, expected)
        }
    }

    func testMissingSettingsDefaultOnlyTheMissingField() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var complete = Configuration()
        complete.theme = .dark
        complete.fontSize = 18
        complete.displayScope = .all
        complete.mode = .compactIcon
        complete.positions = ["screen": StoredPosition(horizontalFraction: 0.7, topOffset: 250)]
        complete.hideInFullScreen = false
        complete.neverShowOnBuiltInDisplay = true
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as? [String: Any])
        for key in fields.keys {
            var incomplete = fields
            incomplete.removeValue(forKey: key)
            var expected = complete
            switch key {
            case "theme": expected.theme = .system
            case "fontSize": expected.fontSize = Configuration.defaultFontSize
            case "displayScope": expected.displayScope = .widest
            case "mode": expected.mode = .toolbar
            case "positions": expected.positions = [:]
            case "hideInFullScreen": expected.hideInFullScreen = true
            case "neverShowOnBuiltInDisplay": expected.neverShowOnBuiltInDisplay = false
            default: XCTFail("Unexpected setting: \(key)"); continue
            }
            let data = try JSONSerialization.data(withJSONObject: incomplete)
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data), expected, key)
            defaults.set(data, forKey: "CenterMyMenu.configuration.v1")
            XCTAssertEqual(ConfigurationStore(defaults: defaults).value, expected, key)
            XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), data, key)
        }
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data("{}".utf8)), Configuration())
    }

    func testMenuFontSizeIsSharedAcrossDisplaysAndBoundedWhenRestored() throws {
        var configuration = Configuration()
        configuration.fontSize = 20
        XCTAssertEqual(configuration.profile(for: display("one")).fontSize, 20)
        XCTAssertEqual(configuration.profile(for: display("two")).fontSize, 20)
        configuration.fontSize = Int.max
        XCTAssertEqual(configuration.fontSize, 20)
        configuration.fontSize = Int.min
        XCTAssertEqual(configuration.fontSize, 11)
        for (saved, expected) in [(-100, 11), (18, 18), (1000, 20)] {
            let data = Data("{\"theme\":\"dark\",\"displayScope\":\"all\",\"mode\":\"toolbar\",\"positions\":{},\"fontSize\":\(saved)}".utf8)
            let restored = try JSONDecoder().decode(Configuration.self, from: data)
            XCTAssertEqual(restored.fontSize, expected)
            XCTAssertEqual(restored.theme, .dark)
        }
    }

    func testUnsupportedSettingValuesDefaultOnlyTheInvalidField() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var complete = Configuration()
        complete.theme = .dark
        complete.fontSize = 18
        complete.displayScope = .all
        complete.mode = .compactIcon
        complete.positions = ["screen": StoredPosition(horizontalFraction: 0.7, topOffset: 250)]
        complete.hideInFullScreen = false
        complete.neverShowOnBuiltInDisplay = true
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(complete)) as? [String: Any])
        for key in fields.keys {
            var settings = fields
            settings[key] = "unsupported-test-value"
            var expected = complete
            switch key {
            case "theme": expected.theme = .system
            case "fontSize": expected.fontSize = Configuration.defaultFontSize
            case "displayScope": expected.displayScope = .widest
            case "mode": expected.mode = .toolbar
            case "positions": expected.positions = [:]
            case "hideInFullScreen": expected.hideInFullScreen = true
            case "neverShowOnBuiltInDisplay": expected.neverShowOnBuiltInDisplay = false
            default: XCTFail("Unexpected setting: \(key)"); continue
            }
            let data = try JSONSerialization.data(withJSONObject: settings)
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data), expected, key)
            defaults.set(data, forKey: "CenterMyMenu.configuration.v1")
            XCTAssertEqual(ConfigurationStore(defaults: defaults).value, expected, key)
            XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), data, key)
        }
    }

    func testMalformedDisplayPositionsPreserveOtherPositionsAndSettings() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = Data(#"""
        {
            "theme": "dark",
            "fontSize": 18,
            "displayScope": "all",
            "mode": "compactIcon",
            "hideInFullScreen": false,
            "positions": {
                "a": {"horizontalFraction": 0.25, "topOffset": 80},
                "b": {"horizontalFraction": 0.75, "topOffset": 120, "futureField": true},
                "wrong-type": "invalid",
                "missing-coordinate": {"horizontalFraction": 0.5},
                "invalid-coordinate": {"horizontalFraction": 0.5, "topOffset": "invalid"},
                "null": null
            }
        }
        """#.utf8)
        var expected = Configuration()
        expected.theme = .dark
        expected.fontSize = 18
        expected.displayScope = .all
        expected.mode = .compactIcon
        expected.hideInFullScreen = false
        expected.positions = [
            "a": StoredPosition(horizontalFraction: 0.25, topOffset: 80),
            "b": StoredPosition(horizontalFraction: 0.75, topOffset: 120)
        ]
        let restored = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertEqual(restored, expected)
        XCTAssertNil(restored.profile(for: display("invalid-coordinate")).position)
        defaults.set(data, forKey: "CenterMyMenu.configuration.v1")
        XCTAssertEqual(ConfigurationStore(defaults: defaults).value, expected)
        XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), data)
    }

    func testUnknownSettingsFieldsAreIgnoredWithoutRewritingStorage() throws {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var configuration = Configuration()
        configuration.theme = .dark
        configuration.fontSize = 18
        let data = try JSONEncoder().encode(configuration)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fields["unsupported-test-field"] = true
        let saved = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: saved), configuration)
        defaults.set(saved, forKey: "CenterMyMenu.configuration.v1")
        XCTAssertEqual(ConfigurationStore(defaults: defaults).value, configuration)
        XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), saved)
    }

    func testUnreadableSavedSettingsArePreservedAndUITestModeDoesNotWritePreferences() {
        let suite = "io.github.skylarstein.centermymenu.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for invalid: Any in [Data("invalid JSON".utf8), Data("[]".utf8), Data("null".utf8), "invalid stored type"] {
            defaults.set(invalid, forKey: "CenterMyMenu.configuration.v1")
            XCTAssertEqual(ConfigurationStore(defaults: defaults).value, Configuration())
            if let bytes = invalid as? Data {
                XCTAssertEqual(defaults.object(forKey: "CenterMyMenu.configuration.v1") as? Data, bytes)
            } else {
                XCTAssertEqual(defaults.object(forKey: "CenterMyMenu.configuration.v1") as? String, invalid as? String)
            }
        }
        let saved = ConfigurationStore(defaults: defaults)
        saved.value.theme = .dark
        let before = defaults.data(forKey: "CenterMyMenu.configuration.v1")
        XCTAssertNotNil(before)
        let testStore = ConfigurationStore(defaults: nil, initial: .uiTest())
        testStore.value.displayScope = .all
        XCTAssertEqual(defaults.data(forKey: "CenterMyMenu.configuration.v1"), before)
        XCTAssertEqual(ConfigurationStore(defaults: defaults).value, saved.value)
    }

    func testCommandRetainsOriginalProviderAndTargetAfterAppSwitch() {
        var original: FakeSession? = FakeSession(pid: 101, bundleID: "test.original")
        weak let retained = original
        let entryID = UUID()
        let command = MenuCommand(entryID: entryID, session: original!)
        let replacement = FakeSession(pid: 202, bundleID: "test.replacement")
        original = nil
        XCTAssertNotNil(retained)
        var error: String? = "Previous failure"
        var completions = 0
        command.execute { error = $0; completions += 1 }
        XCTAssertEqual(completions, 1)
        XCTAssertNil(error)
        XCTAssertEqual(retained?.actions, [CapturedMenuAction(target: retained!.identity, entryID: entryID)])
        XCTAssertTrue(replacement.actions.isEmpty)
        XCTAssertNotEqual(command.action.target, replacement.identity)
    }
}

private final class FakeSession: MenuSession {
    let identity: AppIdentity
    let applicationName = "Fake"
    var actions: [CapturedMenuAction] = []

    init(pid: Int32, bundleID: String) {
        identity = AppIdentity(processIdentifier: pid, bundleIdentifier: bundleID, launchTime: 100)
    }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        completion(MenuBatch(entries: []))
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        guard action.target == identity else { completion("Wrong target"); return }
        actions.append(action)
        completion(nil)
    }
}
