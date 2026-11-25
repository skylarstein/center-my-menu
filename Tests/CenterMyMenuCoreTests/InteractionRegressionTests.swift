import XCTest
import CenterMyMenuCore

final class InteractionRegressionTests: XCTestCase {
    private func display(safeTop: CGFloat = 0) -> DisplayDescriptor {
        let frame = CGRect(x: -2560, y: -200, width: 2560, height: 1440)
        return DisplayDescriptor(id: "negative-origin", isBuiltIn: safeTop > 0, frame: frame,
            visibleFrame: CGRect(x: frame.minX, y: frame.minY + 50,
                                 width: frame.width, height: frame.height - 50 - max(24, safeTop)),
            safeTopInset: safeTop)
    }

    private func assertFrame(_ actual: CGRect, _ expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.000001, file: file, line: line)
    }

    func testDragKeepsOriginalPointerAnchorInsteadOfAccumulatingWindowDeltas() {
        let screen = display()
        let initial = CGRect(x: -1900, y: 900, width: 540, height: 30)
        let start = CGPoint(x: initial.minX + 9, y: initial.midY)
        let drag = PointerAnchoredDrag(frame: initial, pointer: start)
        let pointer = CGPoint(x: start.x + 137, y: start.y - 83)
        let expected = initial.offsetBy(dx: 137, dy: -83)
        for _ in 0..<2 {
            assertFrame(drag.frame(at: pointer, on: screen), expected)
        }
        XCTAssertEqual(pointer.x - drag.frame(at: pointer, on: screen).minX, 9, accuracy: 0.000001)
        XCTAssertEqual(pointer.y - drag.frame(at: pointer, on: screen).minY, 15, accuracy: 0.000001)
    }

    func testDragReturnsToOriginalAnchorAfterClampingWithoutStickyDeltas() {
        let screen = display(safeTop: 38)
        let initial = CGRect(x: -1700, y: 900, width: 640, height: 30)
        let start = CGPoint(x: initial.minX + 8, y: initial.midY)
        let drag = PointerAnchoredDrag(frame: initial, pointer: start)
        let farTopLeft = drag.frame(at: CGPoint(x: -100000, y: 100000), on: screen)
        XCTAssertEqual(farTopLeft.minX, screen.frame.minX + ControlLayout.horizontalMargin, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(farTopLeft.maxY, screen.frame.maxY - 38 - ControlLayout.belowBarGap)
        let farBottomRight = drag.frame(at: CGPoint(x: 100000, y: -100000), on: screen)
        XCTAssertLessThanOrEqual(farBottomRight.maxX, screen.frame.maxX - ControlLayout.horizontalMargin)
        XCTAssertGreaterThanOrEqual(farBottomRight.minY, screen.visibleFrame.minY + 8)
        assertFrame(drag.frame(at: start, on: screen), initial)
    }

    func testReleaseSampleAndSavedCenterUseFullDisplayNormalization() {
        let screen = display()
        let initial = CGRect(x: -1900, y: 900, width: 640, height: 30)
        let start = CGPoint(x: initial.minX + 9, y: initial.midY)
        let drag = PointerAnchoredDrag(frame: initial, pointer: start)
        let lastMotion = CGPoint(x: start.x + 40, y: start.y - 20)
        let release = CGPoint(x: start.x + 121, y: start.y - 77)
        let final = drag.frame(at: release, on: screen)
        XCTAssertNotEqual(final, drag.frame(at: lastMotion, on: screen))
        let saved = ControlLayout.storedPosition(of: final, on: screen)
        XCTAssertEqual(saved.horizontalFraction,
            Double((final.midX - screen.frame.minX) / screen.frame.width), accuracy: 0.0000001)
        XCTAssertEqual(saved.topOffset, Double(screen.frame.maxY - final.midY), accuracy: 0.0000001)
        let preferences = DisplayPreferences(mode: .toolbar, position: saved)
        assertFrame(ControlLayout.place(requestedSize: final.size, on: screen, preferences: preferences).frame, final)
        let compact = ControlLayout.place(requestedSize: CGSize(width: 54, height: 30), on: screen, preferences: preferences)
        XCTAssertEqual(compact.frame.midX, final.midX, accuracy: 0.000001)
        XCTAssertEqual(compact.frame.midY, final.midY, accuracy: 0.000001)
    }

    func testClampedFinalPositionRoundTripsAtEveryEdgeAndNotch() {
        let screen = display(safeTop: 38)
        let initial = CGRect(x: -1700, y: 900, width: 640, height: 30)
        let drag = PointerAnchoredDrag(frame: initial, pointer: CGPoint(x: initial.minX + 9, y: initial.midY))
        for point in [CGPoint(x: -100000, y: 100000), CGPoint(x: 100000, y: 100000),
                      CGPoint(x: -100000, y: -100000), CGPoint(x: 100000, y: -100000)] {
            let final = drag.frame(at: point, on: screen)
            let saved = ControlLayout.storedPosition(of: final, on: screen)
            let restored = ControlLayout.place(requestedSize: final.size, on: screen,
                preferences: DisplayPreferences(mode: .toolbar, position: saved))
            assertFrame(restored.frame, final)
            XCTAssertTrue((0...1).contains(saved.horizontalFraction))
        }
    }

    func testDefaultReadinessPollingStaysResponsiveAfterLongWaits() {
        var backoff = MenuReadinessBackoff()
        let unavailable = MenuBatch(entries: [], status: .unavailable)
        XCTAssertEqual(backoff.delay(after: unavailable), 0.25)
        for _ in 0..<3 {
            XCTAssertEqual(backoff.delay(after: unavailable), 0.5)
        }
        XCTAssertNil(backoff.delay(after: MenuBatch(entries: [MenuEntry(title: "File")])))
        XCTAssertEqual(backoff.delay(after: unavailable), 0.25)
    }

    func testReadinessBackoffCapsDelayButNeverExhaustsAttempts() {
        var backoff = MenuReadinessBackoff(initialDelay: 0.25, maximumDelay: 4)
        let unavailable = MenuBatch(entries: [], status: .unavailable)
        XCTAssertEqual(backoff.delay(after: unavailable), 0.25)
        XCTAssertEqual(backoff.delay(after: unavailable), 0.5)
        XCTAssertEqual(backoff.delay(after: unavailable), 1)
        XCTAssertEqual(backoff.delay(after: unavailable), 2)
        // Repeated capped retries remain available; identical calls need no stress loop.
        for _ in 0..<3 {
            XCTAssertEqual(backoff.delay(after: unavailable), 4)
        }
    }

    func testReadinessSuccessPermissionAndUITestModeStopAndResetBackoff() {
        var backoff = MenuReadinessBackoff(initialDelay: 0.25, maximumDelay: 4)
        let failure = MenuBatch(entries: [], status: .timedOut)
        let ready = MenuBatch(entries: [MenuEntry(title: "File", hasSubmenu: true)])
        _ = backoff.delay(after: failure)
        _ = backoff.delay(after: failure)
        XCTAssertNil(backoff.delay(after: ready))
        XCTAssertEqual(backoff.delay(after: failure), 0.25)
        XCTAssertNil(backoff.delay(after: MenuBatch(entries: [], status: .permissionRequired)))
        XCTAssertEqual(backoff.delay(after: failure), 0.25)
        XCTAssertNil(backoff.delay(after: MenuBatch(entries: [], status: .uiTestData)))
        XCTAssertNil(backoff.delay(after: MenuBatch(entries: [], status: .loading)))
    }

    func testReadinessRetriesEmptyOrTimedOutRootsButNotUsableSafetyLimitedRoots() {
        var backoff = MenuReadinessBackoff(initialDelay: 0.25, maximumDelay: 4)
        for status in [MenuLoadStatus.empty, .unavailable, .timedOut, .ok, .truncated] {
            XCTAssertNotNil(backoff.delay(after: MenuBatch(entries: [], status: status)))
        }
        let partial = [MenuEntry(title: "File", hasSubmenu: true)]
        XCTAssertNotNil(backoff.delay(after: MenuBatch(entries: partial, status: .timedOut)))
        XCTAssertNil(backoff.delay(after: MenuBatch(entries: partial, status: .truncated)))
        XCTAssertEqual(backoff.delay(after: MenuBatch(entries: [], status: .unavailable)), 0.25)
        backoff.reset()
        XCTAssertEqual(backoff.delay(after: MenuBatch(entries: [], status: .unavailable)), 0.25)
    }
}
