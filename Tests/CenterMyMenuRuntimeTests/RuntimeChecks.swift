import AppKit
import ApplicationServices
import Darwin
import CenterMyMenuCore

// Explicit developer-only launch modes. No normal startup paths use this runner.
@MainActor
final class RuntimeChecks {
    private var checks: [[String: Any]] = []
    private var details: [String: Any] = [:]
    private var output: URL!
    private var mode = ""
    private var finished = false

    #if QA_CHECKS
    private var screenshots = false
    private let visualFontSizes = [Configuration.fontSizes.lowerBound, Configuration.defaultFontSize, Configuration.fontSizes.upperBound]

    // Test Host writes enter/exit events to outputPath + ".host.fullscreen.jsonl".
    // Exercise production updates and toggles in a real Space without AX or capture.
    func startFullScreenCheck(outputPath: String) {
        Task { @MainActor in
            guard let display = ConnectedDisplay.current().first(where: { $0.screen == NSScreen.main }) else { exit(1) }
            let control = FloatingControl()
            let position = StoredPosition(horizontalFraction: 0.4, topOffset: 160)
            let hostURL = URL(fileURLWithPath: outputPath + ".host.fullscreen.jsonl")
            var rows: [[String: Any]] = []
            var originalFrame: NSRect?
            let start = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - start < 25 {
                let events = (try? String(contentsOf: hostURL, encoding: .utf8))?.split(separator: "\n")
                    .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? []
                let entered = events.first { $0["event"] as? String == "entered" }?["uptime"] as? Double
                let exited = events.contains { $0["event"] as? String == "exited" }
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = entered.map { now - $0 } ?? 0
                let hide = exited || !(entered != nil && elapsed >= 3 && elapsed < 6)
                control.update(display: display,
                    preferences: DisplayPreferences(mode: .toolbar, position: position, hideInFullScreen: hide),
                    snapshot: nil, uiTestMode: true)
                guard let panel = self.floatingPanel() else { exit(1) }
                if originalFrame == nil { originalFrame = panel.frame }
                let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]]
                rows.append(["uptime": now, "hide": hide,
                             "onScreen": info?.first?[kCGWindowIsOnscreen as String] as? Bool ?? false,
                             "frameUnchanged": panel.frame == originalFrame])
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let frame = display.screen.frame
            let report: [String: Any] = ["displayFrame": [frame.minX, frame.minY, frame.width, frame.height], "samples": rows]
            control.stop()
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Could not write full-screen check results.\n".utf8))
                exit(1)
            }
            NSApp.terminate(nil)
        }
    }

    func startUISmoke(directory: String, screenshots: Bool, interactionChecksPassed: Bool, settingsOnly: Bool = false) {
        self.screenshots = screenshots
        if !settingsOnly { check("interaction_regressions", interactionChecksPassed) }
        details["settingsOnly"] = settingsOnly
        details["screenshotsRequested"] = screenshots
        // Deterministic appearance belongs only to this explicit QA process.
        NSApp.appearance = NSAppearance(named: .aqua)
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        output = folder.appendingPathComponent("report.json")
        mode = "ui_smoke"
        armWatchdog()
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !settingsOnly {
                    await checkUI(folder: folder)
                    await checkBuiltInDisplayExclusion()
                    await checkStatusMenuIsolation()
                    await checkMenuPlacement(folder: folder)
                    await checkStatusMenuPlacement(folder: folder)
                }
                await checkSettingsLayouts(folder: folder)
                finish()
            } catch {
                check("output_directory", false)
                finish()
            }
        }
    }

    #endif

    func startFixture(outputPath: String, recordPath: String?) {
        output = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        mode = "fixture_check"
        details["targetBundleIdentifier"] = "io.github.skylarstein.centermymenu.testhost"
        details["accessibilityTrusted"] = AXIsProcessTrusted()
        guard AXIsProcessTrusted() else {
            details["reason"] = "Grant Accessibility to this bundled Center My Menu app, then rerun. This check never prompts."
            finish(status: "permission_required", code: 2)
            return
        }
        armWatchdog()
        Task { @MainActor in
            await checkFixture(recordPath: recordPath)
            finish()
        }
    }

    private func armWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, !self.finished else { return }
            self.check("runtime_check_finished_within_deadline", false)
            self.finish(status: "timed_out", code: 1)
        }
    }

    private func check(_ name: String, _ passed: Bool, detail: String? = nil) {
        var item: [String: Any] = ["name": name, "status": passed ? "passed" : "failed"]
        if let detail { item["detail"] = detail }
        checks.append(item)
    }

    private func skip(_ name: String, _ reason: String) {
        checks.append(["name": name, "status": "skipped", "detail": reason])
    }

    private func finish(status: String? = nil, code: Int32? = nil) {
        guard !finished else { return }
        finished = true
        let failures = checks.filter { $0["status"] as? String == "failed" }.count
        let result = status ?? (failures == 0 ? "passed" : "failed")
        let report: [String: Any] = [
            "mode": mode, "status": result, "checks": checks, "details": details,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
            "failedCheckCount": failures,
            "scope": mode == "ui_smoke" ? "Own AppKit views and test menus only; no desktop capture or external menu actions."
                : "Only the Center My Menu Test Host application; no unrelated app commands."
        ]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: output, options: .atomic)
            FileHandle.standardOutput.write(data)
            exit(code ?? (failures == 0 ? 0 : 1))
        } catch {
            FileHandle.standardError.write(Data("Could not write runtime-check report.\n".utf8))
            exit(1)
        }
    }

    private func pause(_ seconds: Double = 0.12) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func waitFor(seconds: Double = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            await pause(0.03)
        }
        return true
    }

    private func load(_ session: MenuSession, parent: UUID? = nil) async -> MenuBatch {
        await withCheckedContinuation { continuation in
            session.loadChildren(of: parent) { continuation.resume(returning: $0) }
        }
    }

    #if QA_CHECKS
    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func floatingPanel() -> NSWindow? {
        // NSApp.windows enumerates only this process's windows, not other apps.
        NSApp.windows.first { $0 is NSPanel && $0.title == "Center My Menu" }
    }

    private func captureCheck(_ name: String, _ view: NSView, to url: URL) {
        guard screenshots else { return }
        check(name, capture(view, to: url))
    }

    private func capture(_ view: NSView, to url: URL) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return false }
        // A neutral in-window material avoids sampling a desktop backdrop in artifacts.
        let effects = descendants(of: view).compactMap { $0 as? NSVisualEffectView }
        let modes = effects.map(\.blendingMode)
        for effect in effects { effect.blendingMode = .withinWindow }
        defer { for (effect, mode) in zip(effects, modes) { effect.blendingMode = mode } }
        view.layoutSubtreeIfNeeded()
        for child in descendants(of: view) { child.needsDisplay = true }
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        // cacheDisplay excludes the NSWindow background. Composite its transparent
        // controls/text onto a neutral opaque surface so PNG viewers agree on color.
        guard let flattened = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: flattened) else { return false }
        let size = NSSize(width: CGFloat(bitmap.pixelsWide), height: CGFloat(bitmap.pixelsHigh))
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(origin: .zero, size: size)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            rect.fill()
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = flattened.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: url, options: .atomic); return true }
        catch { return false }
    }

    private func checkUI(folder: URL) async {
        details["captureMethod"] = "NSView.cacheDisplay in the effective appearance, composited onto the native window background; no desktop backdrop."
        details["preferences"] = "In-memory UI test configuration."
        let displays = ConnectedDisplay.current()
        guard let display = displays.first(where: { !$0.descriptor.isBuiltIn }) ?? displays.first else {
            check("display_available", false)
            return
        }
        let expiredQueue = DispatchQueue(label: "io.github.skylarstein.centermymenu.qa.expired-read")
        expiredQueue.async { Thread.sleep(forTimeInterval: 1.1) }
        let expiredSession = AXMenuSession(application: NSRunningApplication.current, queue: expiredQueue)
        let expiredBatch = await load(expiredSession)
        check("queued_ax_read_expires_before_permission_or_ax_work", expiredBatch.status == .timedOut)

        let session = TestMenuSession()
        let batch = await load(session)
        check("test_root_loaded", batch.status == .uiTestData && !batch.entries.isEmpty)
        let snapshot = MenuSnapshot(session: session, batch: batch)
        let floating = FloatingControl()
        var positionSaveCount = 0
        floating.onPositionChange = { _, _ in positionSaveCount += 1 }
        defer { floating.stop() }
        let toolbar = DisplayPreferences(mode: .toolbar, position: StoredPosition(horizontalFraction: 0.5, topOffset: 60))
        floating.update(display: display, preferences: toolbar, snapshot: snapshot, uiTestMode: true)
        await pause()
        guard var panel = floatingPanel(), let view = panel.contentView else {
            check("floating_panel_available", false)
            return
        }
        check("panel_nonactivating", panel.styleMask.contains(.nonactivatingPanel) && !panel.canBecomeKey && !panel.canBecomeMain)
        check("toolbar_within_display", display.descriptor.frame.insetBy(dx: -1, dy: -1).contains(panel.frame))
        check("toolbar_below_notch_safe_area", panel.frame.maxY <= display.descriptor.frame.maxY - display.descriptor.safeTopInset + 0.5)
        let titles = descendants(of: view).compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty }
        check("toolbar_heading_order", titles == batch.entries.filter { !$0.isSeparator }.map(\.title))
        captureCheck("toolbar_png", view, to: folder.appendingPathComponent("toolbar.png"))

        checkHeadingTracking(floating: floating, display: display, preferences: toolbar,
                             snapshot: snapshot, panel: panel)
        checkNativeTracking(session: session, anchor: panel.frame)

        let frame = display.descriptor.frame
        let narrowDescriptor = DisplayDescriptor(id: "runtime-check-narrow", isBuiltIn: false,
            frame: CGRect(x: frame.minX, y: frame.minY, width: min(260, frame.width), height: frame.height),
            visibleFrame: CGRect(x: frame.minX, y: display.descriptor.visibleFrame.minY,
                                 width: min(260, frame.width), height: display.descriptor.visibleFrame.height))
        let narrow = ConnectedDisplay(screen: display.screen, displayID: display.displayID,
                                      descriptor: narrowDescriptor)
        floating.update(display: narrow, preferences: toolbar, snapshot: snapshot, uiTestMode: true)
        await pause()
        if let content = panel.contentView,
           let scroll = descendants(of: content).compactMap({ $0 as? NSScrollView }).first,
           let document = scroll.documentView {
            let maximum = max(0, document.bounds.width - scroll.contentView.bounds.width)
            let offset = min(100, maximum)
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            floating.update(display: narrow, preferences: toolbar, snapshot: snapshot, uiTestMode: true)
            await pause()
            let refreshed = panel.contentView.flatMap { descendants(of: $0).compactMap { $0 as? NSScrollView }.first }
            check("narrow_toolbar_overflows", maximum > 0)
            check("toolbar_scroll_position_retained", refreshed.map { abs($0.contentView.bounds.minX - offset) < 1 } ?? false)
            if let content = panel.contentView {
                captureCheck("overflow_toolbar_png", content, to: folder.appendingPathComponent("toolbar-overflow.png"))
                if let arrow = descendants(of: content).compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Scroll headings right" }) {
                    let priorOffset = refreshed?.contentView.bounds.minX ?? 0
                    checkButtonTracking(name: "overflow_button", button: arrow, panel: panel) {
                        floating.update(display: narrow, preferences: toolbar, snapshot: snapshot, uiTestMode: true)
                    }
                    let afterScroll = panel.contentView.flatMap { descendants(of: $0).compactMap { $0 as? NSScrollView }.first }
                    check("overflow_button_scroll_survives_pending_update", (afterScroll?.contentView.bounds.minX ?? 0) > priorOffset)
                } else { check("overflow_button_available", false) }
            }
        } else { check("narrow_toolbar_scroll_view", false) }

        floating.update(display: display, preferences: DisplayPreferences(mode: .compactIcon, position: StoredPosition(horizontalFraction: 0.5, topOffset: 60)),
                        snapshot: snapshot, uiTestMode: true)
        await pause()
        if let content = panel.contentView {
            check("compact_icon_width", abs(panel.frame.width - 54) < 1)
            captureCheck("compact_png", content, to: folder.appendingPathComponent("compact.png"))
            if let button = descendants(of: content).compactMap({ $0 as? NSButton }).first {
                var invocations = 0
                var attachedAtAction = false
                floating.onRootMenu = { anchor in invocations += 1; attachedAtAction = anchor.window === panel }
                checkButtonTracking(name: "compact_button", button: button, panel: panel) { floating.hide() }
                check("compact_button_action_keeps_anchor", invocations == 1 && attachedAtAction)
                check("compact_button_pending_hide_applied", !panel.isVisible)
                floating.onRootMenu = nil
                floating.update(display: display, preferences: DisplayPreferences(mode: .compactIcon, position: StoredPosition(horizontalFraction: 0.5, topOffset: 60)),
                                snapshot: snapshot, uiTestMode: true)
            } else { check("compact_button_available", false) }
        } else { check("compact_content_available", false) }
        let savedFullScreenPosition = StoredPosition(horizontalFraction: 0.3, topOffset: 170)
        floating.update(display: display,
                        preferences: DisplayPreferences(mode: .toolbar, position: savedFullScreenPosition),
                        snapshot: snapshot, uiTestMode: true)
        let frameBeforePolicyChange = panel.frame
        check("fullscreen_default_opts_out_of_fullscreen_spaces",
              panel.collectionBehavior.contains(.fullScreenNone)
                && !panel.collectionBehavior.contains(.fullScreenAuxiliary))
        floating.update(display: display,
                        preferences: DisplayPreferences(mode: .toolbar, position: savedFullScreenPosition,
                                                        hideInFullScreen: false),
                        snapshot: snapshot, uiTestMode: true)
        if let replacement = floatingPanel() { panel = replacement }
        check("fullscreen_opt_out_restores_auxiliary_behavior",
              panel.collectionBehavior.contains(.fullScreenAuxiliary)
                && !panel.collectionBehavior.contains(.fullScreenNone))
        check("fullscreen_policy_preserves_dragged_position", panel.frame == frameBeforePolicyChange)
        floating.update(display: display,
                        preferences: DisplayPreferences(mode: .toolbar, position: savedFullScreenPosition),
                        snapshot: snapshot, uiTestMode: true)
        if let replacement = floatingPanel() { panel = replacement }
        check("button_clicks_do_not_save_drag_position", positionSaveCount == 0)
        floating.onPositionChange = nil

        let settingsStore = ConfigurationStore(defaults: nil, initial: .uiTest())
        let settings = SettingsWindowController(store: settingsStore, uiTestMode: true)
        settings.onPreferencesChanged = { [weak settings] in
            floating.update(display: display, preferences: settingsStore.value.profile(for: display.descriptor),
                            snapshot: snapshot, uiTestMode: true)
            settings?.refresh(displays: displays, trusted: false, notice: nil)
        }
        settings.refresh(displays: displays, trusted: false,
                         notice: nil)
        guard let window = settings.window, let settingsView = window.contentView else {
            check("settings_window_available", false)
            return
        }
        let noticeField = descendants(of: settingsView).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "operationNotice" }
        check("settings_nil_notice_is_hidden", noticeField?.isHidden == true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await pause()
        captureCheck("settings_png", settingsView, to: folder.appendingPathComponent("settings.png"))
        settings.refresh(displays: displays, trusted: true, notice: nil)
        await pause()
        captureCheck("settings_accessibility_enabled_png", settingsView, to: folder.appendingPathComponent("settings-accessibility-enabled.png"))
        let pickers = descendants(of: settingsView).compactMap { $0 as? NSPopUpButton }
        if let modePicker = pickers.first(where: { $0.accessibilityIdentifier() == "presentationModePicker" }) {
            for _ in 0..<5 {
                window.performClose(nil)
                settings.refresh(displays: displays, trusted: true, notice: nil)
                settings.showWindow(nil)
                window.makeKeyAndOrderFront(nil)
                await pause()
            }
            check("settings_open_close_preserves_toolbar", settingsStore.value.mode == .toolbar)
            for delta: Int32 in [1, -1] {
                if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: delta, wheel2: 0, wheel3: 0),
                   let event = NSEvent(cgEvent: cgEvent) {
                    modePicker.scrollWheel(with: event)
                }
                check("settings_scroll_\(delta)_preserves_toolbar", settingsStore.value.mode == .toolbar)
            }
        }
        if let sizePicker = pickers.first(where: { $0.accessibilityIdentifier() == "fontSizePicker" }) {
            for size in [11, 20, Configuration.defaultFontSize] {
                sizePicker.selectItem(at: size - Configuration.fontSizes.lowerBound)
                _ = sizePicker.sendAction(sizePicker.action, to: sizePicker.target)
                check("font_size_\(size)_saved_from_picker", settingsStore.value.fontSize == size)
                var preferences = settingsStore.value.profile(for: display.descriptor)
                preferences.position = StoredPosition(horizontalFraction: 0.5, topOffset: 80)
                floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
                await pause()
                if let content = panel.contentView {
                    let buttons = descendants(of: content).compactMap { $0 as? NSButton }.filter { !$0.title.isEmpty }
                    check("font_size_\(size)_toolbar_labels", !buttons.isEmpty && buttons.allSatisfy {
                        $0.font?.pointSize == CGFloat(size) && $0.frame.height >= $0.intrinsicContentSize.height
                    })
                    captureCheck("font_size_\(size)_toolbar_png", content, to: folder.appendingPathComponent("toolbar-size-\(size).png"))
                }
                let adapter = NativeMenuAdapter(session: session, fontSize: size) { _ in }
                let root = adapter.makeMenu()
                let rootReady = await prepare(root)
                check("font_size_\(size)_root_menu", rootReady && root.font.pointSize == CGFloat(size))
                if let file = root.items.first(where: { $0.title == "File" })?.submenu {
                    let fileReady = await prepare(file)
                    check("font_size_\(size)_dropdown_menu", fileReady && file.font.pointSize == CGFloat(size))
                    if let nested = file.items.compactMap(\.submenu).first {
                        let nestedReady = await prepare(nested)
                        check("font_size_\(size)_nested_menu", nestedReady && nested.font.pointSize == CGFloat(size))
                    } else { check("font_size_\(size)_nested_menu", false) }
                } else { check("font_size_\(size)_dropdown_menu", false) }
                adapter.invalidate()
            }
        } else { check("font_size_picker_available", false) }
        if let toggle = descendants(of: settingsView).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == "hideInFullScreen" }) {
            check("settings_fullscreen_hiding_defaults_on", toggle.state == .on)
            let savedPositions = settingsStore.value.positions
            toggle.performClick(nil)
            check("settings_fullscreen_hiding_can_disable", !settingsStore.value.hideInFullScreen)
            toggle.performClick(nil)
            check("settings_fullscreen_hiding_restores_without_position_changes",
                  settingsStore.value.hideInFullScreen && settingsStore.value.positions == savedPositions)
        } else { check("settings_fullscreen_toggle_available", false) }
        if let replacement = floatingPanel() { panel = replacement }
        if let scope = pickers.first(where: { $0.accessibilityIdentifier() == "displayScopePicker" }),
           let mode = pickers.first(where: { $0.accessibilityIdentifier() == "presentationModePicker" }),
           let reset = descendants(of: settingsView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Reset to Top Center" }) {
            scope.selectItem(at: DisplayScope.allCases.firstIndex(of: .all)!)
            _ = scope.sendAction(scope.action, to: scope.target)
            check("settings_all_displays_updates_configuration", settingsStore.value.displayScope == .all)
            settingsStore.value.positions[display.descriptor.id] = StoredPosition(horizontalFraction: 0.3, topOffset: 150)
            settingsStore.value.positions["qa-disconnected"] = StoredPosition(horizontalFraction: 0.7, topOffset: 90)
            reset.performClick(nil)
            check("settings_reset_clears_connected_display_positions",
                  settingsStore.value.positions[display.descriptor.id] == nil && settingsStore.value.positions["qa-disconnected"] != nil)
            mode.selectItem(at: PresentationMode.allCases.firstIndex(of: .statusOnly)!)
            _ = mode.sendAction(mode.action, to: mode.target)
            check("settings_status_only_updates_global_mode", settingsStore.value.mode == .statusOnly && !reset.isEnabled)
            mode.selectItem(at: PresentationMode.allCases.firstIndex(of: .toolbar)!)
            _ = mode.sendAction(mode.action, to: mode.target)
            await pause()
            captureCheck("settings_all_displays_png", settingsView, to: folder.appendingPathComponent("settings-all-displays.png"))
            scope.selectItem(at: 0)
            _ = scope.sendAction(scope.action, to: scope.target)
            check("settings_widest_display_updates_configuration", settingsStore.value.displayScope == .widest && reset.isEnabled)
            scope.selectItem(at: DisplayScope.allCases.firstIndex(of: .active)!)
            _ = scope.sendAction(scope.action, to: scope.target)
            check("settings_active_display_updates_configuration", settingsStore.value.displayScope == .active)
            await pause()
            captureCheck("settings_active_display_png", settingsView, to: folder.appendingPathComponent("settings-active-display.png"))
        } else { check("simplified_settings_controls_available", false) }
        if let picker = descendants(of: settingsView).compactMap({ $0 as? NSPopUpButton })
            .first(where: { $0.accessibilityIdentifier() == "themePicker" }) {
            let previousAppearance = NSApp.appearance
            defer { NSApp.appearance = previousAppearance }
            for theme in [AppTheme.dark, .light, .system] {
                picker.selectItem(at: AppTheme.allCases.firstIndex(of: theme)!)
                _ = picker.sendAction(picker.action, to: picker.target)
                await pause()
                let expected: NSAppearance.Name = theme == .dark ? .darkAqua : theme == .light ? .aqua
                    : NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
                check("theme_\(theme.rawValue)_saved_from_picker", settingsStore.value.theme == theme)
                check("theme_\(theme.rawValue)_settings_appearance",
                      window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
                check("theme_\(theme.rawValue)_floating_appearance",
                      panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
                check("theme_\(theme.rawValue)_leaves_app_appearance_unchanged", NSApp.appearance === previousAppearance)
                if theme == .system {
                    check("theme_system_clears_window_overrides", window.appearance == nil && panel.appearance == nil)
                }
                captureCheck("settings_theme_\(theme.rawValue)_png", settingsView, to: folder.appendingPathComponent("settings-theme-\(theme.rawValue).png"))
                if let content = panel.contentView {
                    captureCheck("floating_theme_\(theme.rawValue)_png", content, to: folder.appendingPathComponent("floating-theme-\(theme.rawValue).png"))
                }
            }
        } else { check("theme_picker_available", false) }
        let longNotice = String(repeating: "A longer test notice wraps within the settings window. ", count: 12)
        settings.refresh(displays: displays, trusted: false, notice: longNotice)
        await pause()
        settingsView.layoutSubtreeIfNeeded()
        check("settings_notice_rendered", noticeField?.isHidden == false && noticeField?.stringValue == longNotice)
        captureCheck("settings_overflow_png", settingsView, to: folder.appendingPathComponent("settings-overflow.png"))
        if let scroll = descendants(of: settingsView).compactMap({ $0 as? NSScrollView }).first,
           let document = scroll.documentView {
            document.layoutSubtreeIfNeeded()
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause()
            details["settingsDocumentHeight"] = Double(document.bounds.height)
            details["settingsViewportHeight"] = Double(scroll.contentView.bounds.height)
            check("settings_overflow_is_scrollable", maximum > 0 && scroll.contentView.bounds.minY > 0)
            check("settings_bottom_is_reachable", scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2)
            captureCheck("settings_bottom_png", settingsView, to: folder.appendingPathComponent("settings-bottom.png"))
        } else { check("settings_scroll_view", false) }
        settings.refresh(displays: displays, trusted: false, notice: nil)
        check("settings_notice_clears", noticeField?.isHidden == true && noticeField?.stringValue.isEmpty == true)
    }

    private func checkBuiltInDisplayExclusion() async {
        let connected = ConnectedDisplay.current()
        let actualID = ConnectedDisplay.activeID(in: connected)
        guard let actual = connected.first(where: { $0.descriptor.id == actualID }) else {
            check("built_in_exclusion_test_display_available", false)
            return
        }
        // Synthetic identities share one real screen. Only our own panels and
        // Settings controls are exercised; no display configuration is changed.
        func simulated(_ id: String, builtIn: Bool) -> ConnectedDisplay {
            let source = actual.descriptor
            var workspace = source.visibleFrame
            if !builtIn { workspace.size.width = max(1, workspace.width - 100) }
            return ConnectedDisplay(screen: actual.screen, displayID: builtIn ? actual.displayID : 0,
                descriptor: DisplayDescriptor(id: "qa-exclusion-\(id)", isBuiltIn: builtIn,
                    frame: source.frame, visibleFrame: workspace, safeTopInset: source.safeTopInset))
        }
        let builtIn = simulated("built-in", builtIn: true)
        let a = simulated("external-a", builtIn: false), z = simulated("external-z", builtIn: false)
        let allDisplays = [builtIn, a, z]
        var screens = allDisplays
        var activeID: String? = builtIn.descriptor.id
        let session = TestMenuSession()
        let batch = await load(session)
        let snapshot = MenuSnapshot(session: session, batch: batch)
        let store = ConfigurationStore(defaults: nil, initial: .uiTest())
        store.value.displayScope = .all
        store.value.positions = [
            builtIn.descriptor.id: StoredPosition(horizontalFraction: 0.4, topOffset: 100),
            a.descriptor.id: StoredPosition(horizontalFraction: 0.3, topOffset: 140),
            z.descriptor.id: StoredPosition(horizontalFraction: 0.7, topOffset: 180),
            "qa-disconnected": StoredPosition(horizontalFraction: 0.6, topOffset: 210)
        ]
        let original = store.value
        let group = FloatingControls()
        let settings = SettingsWindowController(store: store, uiTestMode: true)
        let controller = AppController(options: LaunchOptions(uiTestMode: true), store: store)
        let statusItem = controller.installStatusItem()
        defer {
            settings.onPreferencesChanged = nil
            settings.close()
            NSStatusBar.system.removeStatusItem(statusItem)
            group.stop()
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("CenterMyMenu.Floating.qa-exclusion-") == true {
                window.title = "Center My Menu Display Exclusion QA"
            }
        }
        func render() {
            group.update(displays: screens, activeDisplayID: activeID, configuration: store.value,
                         snapshot: snapshot, uiTestMode: true)
        }
        let notice = "Display exclusion QA notice."
        func refresh() {
            render()
            settings.refresh(displays: screens, trusted: false, notice: notice)
        }
        var changes = 0
        settings.onPreferencesChanged = { [weak settings] in
            changes += 1
            render()
            settings?.refresh(displays: screens, trusted: false, notice: notice)
        }
        func panel(_ display: ConnectedDisplay) -> NSWindow? {
            NSApp.windows.first {
                $0.identifier?.rawValue == "CenterMyMenu.Floating.\(display.descriptor.id)" && $0.isVisible
            }
        }
        func visibleIDs() -> Set<String> {
            Set(allDisplays.filter { panel($0) != nil }.map { $0.descriptor.id })
        }
        func select(_ picker: NSPopUpButton, _ index: Int) {
            picker.selectItem(at: index)
            _ = picker.sendAction(picker.action, to: picker.target)
        }
        refresh()
        guard let window = settings.window, let content = window.contentView else {
            check("built_in_exclusion_settings_available", false)
            return
        }
        let views = descendants(of: content)
        let buttons = views.compactMap { $0 as? NSButton }
        let pickers = views.compactMap { $0 as? NSPopUpButton }
        let fields = views.compactMap { $0 as? NSTextField }
        guard let toggle = buttons.first(where: { $0.accessibilityIdentifier() == "neverShowOnBuiltInDisplay" }),
              let scope = pickers.first(where: { $0.accessibilityIdentifier() == "displayScopePicker" }),
              let mode = pickers.first(where: { $0.accessibilityIdentifier() == "presentationModePicker" }),
              let reset = buttons.first(where: { $0.title == "Reset to Top Center" }),
              let explanation = fields.first(where: { $0.accessibilityIdentifier() == "displayRoutingNote" }),
              let operationNotice = fields.first(where: { $0.accessibilityIdentifier() == "operationNotice" }) else {
            check("built_in_exclusion_controls_available", false)
            return
        }
        window.orderFrontRegardless()
        let allIDs = Set(allDisplays.map { $0.descriptor.id })
        let externalIDs = Set([a.descriptor.id, z.descriptor.id])
        let builtInFrame = panel(builtIn)?.frame, externalFrame = panel(a)?.frame
        check("built_in_exclusion_defaults_off_and_preserves_all_routing",
              toggle.title == "Never show on built-in display" && toggle.state == .off
                && !store.value.neverShowOnBuiltInDisplay && visibleIDs() == allIDs)
        toggle.performClick(nil)
        var enabled = original
        enabled.neverShowOnBuiltInDisplay = true
        check("built_in_exclusion_toggle_uses_preferences_callback",
              changes == 1 && toggle.state == .on && store.value == enabled)
        check("built_in_exclusion_all_routes_toolbar_only_to_externals",
              visibleIDs() == externalIDs && reset.isEnabled
                && explanation.stringValue.contains("all external displays"))

        select(mode, PresentationMode.allCases.firstIndex(of: .compactIcon)!)
        check("built_in_exclusion_also_filters_compact_controls",
              store.value.mode == .compactIcon && visibleIDs() == externalIDs
                && abs((panel(a)?.frame.width ?? 0) - 54) < 1
                && abs((panel(z)?.frame.width ?? 0) - 54) < 1)
        select(scope, DisplayScope.allCases.firstIndex(of: .widest)!)
        check("built_in_exclusion_widest_ignores_wider_built_in",
              builtIn.descriptor.visibleFrame.width > a.descriptor.visibleFrame.width
                && visibleIDs() == Set([a.descriptor.id])
                && explanation.stringValue.contains("external display"))
        screens = [z, builtIn, a]
        refresh()
        check("built_in_exclusion_widest_tie_is_stable", visibleIDs() == Set([a.descriptor.id]))
        select(scope, DisplayScope.allCases.firstIndex(of: .active)!)
        check("built_in_exclusion_active_excluded_notice_and_reset",
              visibleIDs().isEmpty && !reset.isEnabled
                && explanation.stringValue.contains("active built-in display is excluded")
                && explanation.stringValue.contains("rather than moving to another display")
                && explanation.stringValue.contains("status icon"))
        reset.performClick(nil)
        check("built_in_exclusion_active_excluded_reset_preserves_positions", store.value.positions == original.positions)

        // Explicit synthetic IDs exercise routing without changing the resolver.
        activeID = nil
        render()
        check("built_in_exclusion_unknown_active_uses_eligible_widest", visibleIDs() == Set([a.descriptor.id]))
        activeID = "qa-unknown"
        render()
        check("built_in_exclusion_missing_active_id_uses_eligible_widest", visibleIDs() == Set([a.descriptor.id]))
        activeID = z.descriptor.id
        render()
        check("built_in_exclusion_known_external_active_is_respected", visibleIDs() == Set([z.descriptor.id]))
        activeID = builtIn.descriptor.id
        screens = [builtIn]
        refresh()
        check("built_in_exclusion_no_external_notice_and_reset",
              visibleIDs().isEmpty && !reset.isEnabled
                && explanation.stringValue.contains("No eligible external display is connected")
                && explanation.stringValue.contains("status icon"))
        let (statusMenu, adapter) = controller.makeStatusMenu(for: session)
        check("built_in_exclusion_keeps_regular_status_menu_access",
              statusItem.isVisible && !statusItem.behavior.contains(.removalAllowed)
                && statusMenu.item(withTitle: "UI Test App")?.submenu != nil
                && statusMenu.item(withTitle: "Settings…")?.action != nil
                && statusMenu.item(withTitle: "Quit Center My Menu")?.action != nil)
        adapter.invalidate()
        select(mode, PresentationMode.allCases.firstIndex(of: .statusOnly)!)
        check("built_in_exclusion_hidden_mode_remains_available",
              store.value.mode == .statusOnly && visibleIDs().isEmpty && !reset.isEnabled
                && toggle.isEnabled && toggle.state == .on
                && explanation.stringValue == "Menus remain available from the status icon.")

        select(mode, PresentationMode.allCases.firstIndex(of: .toolbar)!)
        select(scope, DisplayScope.allCases.firstIndex(of: .all)!)
        screens = allDisplays
        refresh()
        check("built_in_exclusion_reconnection_restores_saved_external_position",
              visibleIDs() == externalIDs && store.value.positions == original.positions
                && externalFrame != nil && panel(a)?.frame == externalFrame)
        reset.performClick(nil)
        var retainedPositions = original.positions
        retainedPositions.removeValue(forKey: a.descriptor.id)
        retainedPositions.removeValue(forKey: z.descriptor.id)
        check("built_in_exclusion_reset_only_clears_eligible_targets",
              store.value.positions == retainedPositions && reset.isEnabled)
        toggle.performClick(nil)
        check("built_in_exclusion_disable_restores_built_in_position",
              !store.value.neverShowOnBuiltInDisplay && toggle.state == .off
                && visibleIDs() == allIDs && builtInFrame != nil && panel(builtIn)?.frame == builtInFrame
                && store.value.positions == retainedPositions
                && explanation.stringValue.contains("all displays"))
        let callbacksBeforeRefresh = changes
        store.value.neverShowOnBuiltInDisplay = true
        refresh()
        check("built_in_exclusion_refresh_synchronizes_checkbox_without_callback",
              toggle.state == .on && changes == callbacksBeforeRefresh && visibleIDs() == externalIDs)
        check("built_in_exclusion_keeps_operation_notice",
              !operationNotice.isHidden && operationNotice.stringValue == notice)
    }

    private func checkStatusMenuIsolation() async {
        let previousAppearance = NSApp.appearance
        NSApp.appearance = nil
        defer { NSApp.appearance = previousAppearance }
        guard let display = ConnectedDisplay.current().first else {
            check("status_menu_display_available", false)
            return
        }
        let store = ConfigurationStore(defaults: nil, initial: .uiTest())
        let controller = AppController(options: LaunchOptions(uiTestMode: true), store: store)
        let settings = SettingsWindowController(store: store, uiTestMode: true)
        let floating = FloatingControl()
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer {
            NSStatusBar.system.removeStatusItem(statusItem)
            settings.window?.orderOut(nil)
            floating.stop()
        }
        guard let statusButton = statusItem.button else {
            check("status_menu_button_available", false)
            return
        }
        statusButton.title = "QA"
        let session = TestMenuSession()
        let batch = await load(session)
        let snapshot = MenuSnapshot(session: session, batch: batch)
        let native = NSMenu(title: "Native baseline")
        native.addItem(withTitle: "Native baseline", action: nil, keyEquivalent: "")

        func observe(_ menu: NSMenu, in button: NSView, floating: Bool = false) -> NSAppearance.Name? {
            let probe = MenuPlacementProbe(menu: menu)
            let timer = Timer(timeInterval: 0.04, target: probe,
                selector: #selector(MenuPlacementProbe.sample(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            if floating {
                let location = MenuPopupPlacement.location(below: button)
                _ = menu.popUp(positioning: nil, at: location, in: button)
            } else {
                statusItem.menu = menu
                statusButton.performClick(nil)
                statusItem.menu = nil
            }
            timer.invalidate()
            return probe.appearance
        }
        let nativeAppearance = observe(native, in: statusButton)
        check("status_menu_native_baseline_observed", nativeAppearance != nil)
        for theme in AppTheme.allCases {
            for size in [Configuration.defaultFontSize, Configuration.fontSizes.upperBound] {
                store.value.theme = theme
                store.value.fontSize = size
                settings.refresh(displays: [display], trusted: true, notice: nil)
                floating.update(display: display, preferences: store.value.profile(for: display.descriptor),
                                snapshot: snapshot, uiTestMode: true)
                let (menu, adapter) = controller.makeStatusMenu(for: session)
                var tree = [menu]
                var ready = true
                var index = 0
                while index < tree.count {
                    let current = tree[index]
                    if current.delegate != nil {
                        let loaded = await prepare(current)
                        ready = ready && loaded
                    }
                    tree.append(contentsOf: current.items.compactMap(\.submenu))
                    index += 1
                }
                let prefix = "status_menu_\(theme.rawValue)_\(size)"
                check("\(prefix)_entire_tree_native_font", ready && tree.count >= 4
                    && tree.allSatisfy { $0.font.isEqual(native.font) })
                check("\(prefix)_native_items", tree.allSatisfy {
                    $0.items.allSatisfy { $0.view == nil && $0.attributedTitle == nil }
                })
                check("\(prefix)_no_application_appearance_override", NSApp.appearance == nil)
                if size == Configuration.fontSizes.upperBound {
                    // Compare after the status window and local theme updates have settled.
                    await pause()
                    let baseline = observe(native, in: statusButton)
                    let actual = observe(menu, in: statusButton)
                    check("\(prefix)_native_popup_appearance", actual == baseline && baseline != nil,
                          detail: "Native: \(String(describing: baseline)); status: \(String(describing: actual))")
                    if let appMenu = menu.items.compactMap(\.submenu).first {
                        let submenuAppearance = observe(appMenu, in: statusButton)
                        check("\(prefix)_native_submenu_appearance", submenuAppearance == baseline && baseline != nil,
                              detail: "Native: \(String(describing: baseline)); submenu: \(String(describing: submenuAppearance))")
                    }
                    if let panel = floatingPanel(), let content = panel.contentView,
                       let button = descendants(of: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "File" }) {
                        let styledAdapter = NativeMenuAdapter(session: session, fontSize: size) { _ in }
                        let styled = styledAdapter.makeMenu()
                        let expected = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                        check("floating_menu_\(theme.rawValue)_retains_theme",
                              observe(styled, in: button, floating: true) == expected)
                        styledAdapter.invalidate()
                    } else { check("floating_menu_\(theme.rawValue)_anchor_available", false) }
                }
                adapter.invalidate()
            }
        }
    }

    private func checkMenuPlacement(folder: URL) async {
        guard let display = ConnectedDisplay.current().first(where: { !$0.descriptor.isBuiltIn })
                ?? ConnectedDisplay.current().first else { return }
        let session = TestMenuSession()
        let batch = await load(session)
        let snapshot = MenuSnapshot(session: session, batch: batch)
        let floating = FloatingControl()
        defer { floating.stop() }
        var measurements: [[String: Any]] = []
        for mode in [PresentationMode.toolbar, .compactIcon] {
            for size in [Configuration.fontSizes.lowerBound, Configuration.fontSizes.upperBound] {
                let prefix = "popup_\(mode.rawValue)_\(size)"
                let preferences = DisplayPreferences(mode: mode,
                    position: StoredPosition(horizontalFraction: 0.5, topOffset: 120), fontSize: size)
                floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
                guard let panel = floatingPanel(), let content = panel.contentView,
                      let button = descendants(of: content).compactMap({ $0 as? NSButton })
                        .first(where: { mode == .compactIcon || $0.title == "File" }) else {
                    check("\(prefix)_anchor_available", false)
                    continue
                }
                let adapter = NativeMenuAdapter(session: session, fontSize: size) { _ in }
                let menu = adapter.makeMenu()
                let probe = MenuPlacementProbe(menu: menu) { window in
                    let visible = menu.items.filter { !$0.isHidden }
                    self.check("\(prefix)_all_rows_visible", visible.count == batch.entries.count
                        && visible.allSatisfy {
                            let frame = $0.accessibilityFrame()
                            return !frame.isEmpty && window.frame.insetBy(dx: -1, dy: -1).contains(frame)
                        })
                    if let view = window.contentView {
                        self.captureCheck("\(prefix)_png", view,
                            to: folder.appendingPathComponent("\(prefix).png"))
                    }
                    if size == Configuration.fontSizes.upperBound, let control = panel.contentView {
                        self.captureCheck("\(prefix)_control_png", control,
                            to: folder.appendingPathComponent("\(prefix)-control.png"))
                    }
                }
                let timer = Timer(timeInterval: 0.04, target: probe,
                    selector: #selector(MenuPlacementProbe.sample(_:)), userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                let location = MenuPopupPlacement.location(below: button)
                _ = menu.popUp(positioning: nil, at: location, in: button)
                timer.invalidate()
                let gap = probe.frame.map { panel.frame.minY - $0.maxY }
                var row: [String: Any] = ["mode": mode.rawValue, "fontSize": size,
                    "toolbarFrame": NSStringFromRect(panel.frame), "menuObserved": probe.frame != nil]
                if let gap { row["visibleGap"] = Double(gap) }
                if let frame = probe.frame { row["menuFrame"] = NSStringFromRect(frame) }
                measurements.append(row)
                check("\(prefix)_outside_control", gap.map { $0 >= 1 && $0 <= 12 } ?? false,
                      detail: gap.map { "Visible gap: \($0) pt" } ?? "Native menu window not observed")
                adapter.invalidate()
            }
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("menu-placement.json"), options: .atomic)
        } catch { check("menu_placement_report_written", false) }
    }

    private func checkStatusMenuPlacement(folder: URL) async {
        let store = ConfigurationStore(defaults: nil, initial: .uiTest())
        store.value.mode = .statusOnly
        let controller = AppController(options: LaunchOptions(uiTestMode: true), store: store)
        let item = controller.installStatusItem()
        defer { NSStatusBar.system.removeStatusItem(item) }
        guard let button = item.button, let menu = item.menu, let window = button.window else {
            check("status_popup_anchor_available", false)
            return
        }
        await pause(0.3) // Allow the new status item's window to reach its menu-bar position.
        var rows: [[String: Any]] = []
        for size in visualFontSizes {
            store.value.fontSize = size
            let probe = MenuPlacementProbe(menu: menu) { window in
                if let view = window.contentView {
                    self.captureCheck("status_popup_\(size)_png", view,
                        to: folder.appendingPathComponent("status-popup-\(size).png"))
                }
            }
            let timer = Timer(timeInterval: 0.04, target: probe,
                selector: #selector(MenuPlacementProbe.sample(_:)), userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            button.performClick(nil)
            timer.invalidate()
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let gap = probe.frame.map { anchor.minY - $0.maxY }
            check("status_popup_\(size)_below_icon", gap.map { $0 >= 0 && $0 <= 12 } ?? false,
                  detail: gap.map { "Visible gap: \($0) pt" } ?? "Native menu window not observed")
            check("status_popup_\(size)_contents_refreshed", menu.item(withTitle: "UI Test App")?.submenu != nil)
            rows.append(["fontSize": size, "visibleGap": gap ?? -1,
                         "anchorFrame": NSStringFromRect(anchor),
                         "menuFrame": probe.frame.map(NSStringFromRect) ?? "unobserved"])
            await pause()
        }
        let actionProbe = StatusMenuActionProbe(menu: menu, windowNumber: window.windowNumber)
        let actionTimer = Timer(timeInterval: 0.04, target: actionProbe,
            selector: #selector(StatusMenuActionProbe.sample(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(actionTimer, forMode: .common)
        button.performClick(nil)
        actionTimer.invalidate()
        await pause()
        check("status_menu_native_nested_navigation", actionProbe.completed, detail: actionProbe.lastState)
        check("status_menu_selected_ui_test_action_survives_close",
              button.toolTip?.contains("UI test only — no command was sent") == true)
        do {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("status-menu-placement.json"), options: .atomic)
        } catch { check("status_menu_placement_report_written", false) }
    }

    private func checkSettingsLayouts(folder: URL) async {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        let displays = ConnectedDisplay.current()
        var rows: [[String: Any]] = []
        var failures: [String] = []
        var leastHeadroom = CGFloat.greatestFiniteMagnitude
        let approval = "Allow Center My Menu in System Settings → General → Login Items to launch it at login."

        for uiTestMode in [false, true] {
            let store = ConfigurationStore(defaults: nil, initial: .uiTest())
            let settings = SettingsWindowController(store: store, uiTestMode: uiTestMode)
            guard let window = settings.window, let content = window.contentView,
                  let scroll = descendants(of: content).compactMap({ $0 as? NSScrollView }).first,
                  let document = scroll.documentView,
                  let login = descendants(of: content).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.accessibilityIdentifier() == "loginStatus" }) else {
                check("settings_layout_views_available", false)
                continue
            }
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }

            func measure(_ name: String, requiresNoScrolling: Bool = false) {
                content.layoutSubtreeIfNeeded()
                scroll.tile()
                content.layoutSubtreeIfNeeded()
                let headroom = scroll.contentView.bounds.height - document.bounds.height
                leastHeadroom = min(leastHeadroom, headroom)
                var clipped: [String] = []
                for view in descendants(of: document) where !view.isHiddenOrHasHiddenAncestor {
                    guard view is NSControl, view.bounds.width > 0, view.bounds.height > 0 else { continue }
                    let rect = view.convert(view.bounds, to: document)
                    if !document.bounds.insetBy(dx: -1, dy: -1).contains(rect) {
                        clipped.append((view as? NSTextField)?.stringValue ?? "Control")
                    }
                    if let field = view as? NSTextField, let cell = field.cell {
                        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: field.bounds.width, height: 10000))
                        if needed.height > field.bounds.height + 1 { clipped.append(field.stringValue) }
                    }
                }
                let scrollbarVisible = scroll.verticalScroller.map { !$0.isHidden } ?? false
                let fits = headroom >= -1 && !scrollbarVisible && clipped.isEmpty
                // Long guidance may scroll in the compact window, but must remain reachable.
                let originalOrigin = scroll.contentView.bounds.origin
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maximum))
                scroll.reflectScrolledClipView(scroll.contentView)
                let bottomReachable = scroll.documentVisibleRect.maxY >= document.bounds.maxY - 2
                scroll.contentView.scroll(to: originalOrigin)
                scroll.reflectScrolledClipView(scroll.contentView)
                let accessible = clipped.isEmpty && bottomReachable && (!requiresNoScrolling || fits)
                rows.append(["configuration": name, "fits": fits, "accessible": accessible,
                             "contentHeight": Double(document.bounds.height),
                             "viewportHeight": Double(scroll.contentView.bounds.height),
                             "scrollbarVisible": scrollbarVisible, "clipped": clipped])
                if !accessible { failures.append(name) }
            }

            let cases: [(AppTheme, DisplayScope, PresentationMode, Int)] = [
                (.system, .widest, .compactIcon, 13),
                (.system, .active, .toolbar, 11),
                (.system, .all, .statusOnly, 20),
                (.light, .widest, .toolbar, 20),
                (.light, .active, .statusOnly, 13),
                (.light, .all, .compactIcon, 11),
                (.dark, .widest, .statusOnly, 11),
                (.dark, .active, .compactIcon, 20),
                (.dark, .all, .toolbar, 13)
            ]
            for (theme, scope, mode, size) in cases {
                store.value.theme = theme
                store.value.displayScope = scope
                store.value.mode = mode
                store.value.fontSize = size
                await pause(0.01)
                for trusted in [false, true] {
                    settings.refresh(displays: displays, trusted: trusted, notice: nil)
                    for excludeBuiltIn in [false, true] {
                        store.value.neverShowOnBuiltInDisplay = excludeBuiltIn
                        settings.refresh(displays: displays, trusted: trusted, notice: nil)
                        for style in [NSScroller.Style.overlay, .legacy] {
                            scroll.scrollerStyle = style
                            measure("normal,uiTestMode=\(uiTestMode),\(theme.rawValue),\(scope.rawValue),\(mode.rawValue),\(size)pt,trusted=\(trusted),excludeBuiltIn=\(excludeBuiltIn),scroller=\(style.rawValue)", requiresNoScrolling: true)
                        }
                    }
                    // Exercise login guidance without changing login registration.
                    login.stringValue = approval
                    login.isHidden = false
                    for style in [NSScroller.Style.overlay, .legacy] {
                        scroll.scrollerStyle = style
                        measure("uiTestMode=\(uiTestMode),\(theme.rawValue),\(scope.rawValue),\(mode.rawValue),\(size)pt,trusted=\(trusted),scroller=\(style.rawValue)")
                    }
                    if !uiTestMode && trusted {
                        captureCheck("settings_layout_\(theme.rawValue)_\(scope.rawValue)_\(mode.rawValue)_png", content, to: folder.appendingPathComponent("layout-\(theme.rawValue)-\(scope.rawValue)-\(mode.rawValue).png"))
                    }
                }
            }

            if !uiTestMode {
                store.value.theme = .dark
                store.value.displayScope = .all
                store.value.mode = .toolbar
                store.value.neverShowOnBuiltInDisplay = true
                settings.refresh(displays: displays, trusted: false, notice: nil)
                login.isHidden = true
                content.layoutSubtreeIfNeeded()
                scroll.tile()
                content.layoutSubtreeIfNeeded()
                check("settings_compact_default_fits_without_scrolling",
                      document.bounds.height <= scroll.contentView.bounds.height + 1)
                captureCheck("settings_compact_default_png", content,
                             to: folder.appendingPathComponent("settings-compact-default.png"))
                let allDisplaysHeight = window.frame.height
                store.value.displayScope = .active
                store.value.fontSize = 20
                settings.refresh(displays: displays, trusted: true, notice: nil)
                measure("active-toolbar-20pt-exclude-built-in", requiresNoScrolling: true)
                captureCheck("settings_active_toolbar_png", content,
                             to: folder.appendingPathComponent("settings-active-toolbar.png"))
                store.value.displayScope = .all
                settings.refresh(displays: displays, trusted: true, notice: nil)
                check("settings_shrinks_back_after_longer_description",
                      abs(window.frame.height - allDisplaysHeight) < 1)
                let compactFrame = window.frame
                settings.refresh(displays: displays, trusted: true,
                    notice: String(repeating: "A longer test notice wraps within the settings window. ", count: 12))
                measure("compact-window-with-long-notice")
                check("settings_long_notice_scrolls_without_enlarging_window",
                      window.frame == compactFrame && document.bounds.height > scroll.contentView.bounds.height)
                settings.refresh(displays: displays, trusted: true, notice: nil)
                measure("compact-window-after-notice-clears", requiresNoScrolling: true)
            }

            // Extra text states: no display, connected displays, and an operation notice.
            store.value.theme = .system
            store.value.fontSize = 20
            store.value.mode = .toolbar
            for scope in DisplayScope.allCases {
                store.value.displayScope = scope
                for (label, screens) in [("no-display", [ConnectedDisplay]()), ("connected-display", displays)] {
                    settings.refresh(displays: screens, trusted: false,
                        notice: "The active app’s menus are temporarily unavailable. Try opening its menu again.")
                    login.stringValue = approval
                    login.isHidden = false
                    measure("uiTestMode=\(uiTestMode),\(scope.rawValue),\(label),login-guidance-and-notice")
                    if scope == .widest {
                        captureCheck("settings_layout_\(label)_ui_test_\(uiTestMode)_png", content, to: folder.appendingPathComponent("layout-\(label)-ui-test-\(uiTestMode).png"))
                    }
                }
            }
        }
        details["settingsLayoutConfigurations"] = rows.count
        details["settingsLayoutMinimumHeadroom"] = Double(leastHeadroom)
        details["settingsLayoutScope"] = "Rendered representative normal and UI test Settings on the connected display; all themes, scopes and modes, minimum/default/maximum font sizes, permission text states, both scrollbar styles, simulated login guidance and display availability states. No login or permission changes."
        check("settings_all_configurations_are_unclipped_and_reachable", failures.isEmpty,
              detail: failures.isEmpty ? "\(rows.count) configurations are unclipped and reachable." : failures.prefix(12).joined(separator: "; "))
        do {
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("settings-layout-matrix.json"), options: .atomic)
        } catch { check("settings_layout_matrix_written", false) }
    }

    private func checkHeadingTracking(floating: FloatingControl, display: ConnectedDisplay,
                                      preferences: DisplayPreferences, snapshot: MenuSnapshot, panel: NSWindow) {
        guard let content = panel.contentView,
              let button = descendants(of: content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "File" }) else {
            check("heading_button_available", false)
            return
        }
        var invocations = 0
        var attachedAtAction = false
        floating.onHeadingMenu = { _, entry, anchor in
            invocations += 1
            attachedAtAction = anchor.window === panel && entry.title == "File"
        }
        let intermediate = MenuSnapshot(session: snapshot.session,
            batch: MenuBatch(entries: Array(snapshot.batch.entries.dropLast(2)), status: .uiTestData))
        let latest = MenuSnapshot(session: snapshot.session,
            batch: MenuBatch(entries: Array(snapshot.batch.entries.dropLast()), status: .uiTestData))
        checkButtonTracking(name: "heading_button", button: button, panel: panel) {
            floating.update(display: display, preferences: preferences, snapshot: intermediate, uiTestMode: true)
            floating.hide()
            floating.update(display: display, preferences: preferences, snapshot: latest, uiTestMode: true)
        }
        let titles = panel.contentView.map { descendants(of: $0).compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty } } ?? []
        check("heading_button_action_keeps_anchor", invocations == 1 && attachedAtAction)
        check("heading_button_latest_update_applied", titles == latest.batch.entries.map(\.title) && panel.isVisible)
        floating.onHeadingMenu = nil
        floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
    }

    private func checkButtonTracking(name: String, button: NSButton, panel: NSWindow,
                                     mutation: @escaping () -> Void) {
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: timestamp, windowNumber: panel.windowNumber, context: nil, eventNumber: 9001, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: timestamp + 0.05, windowNumber: panel.windowNumber, context: nil, eventNumber: 9002, clickCount: 1, pressure: 0) else {
            check(name + "_events_created", false)
            return
        }
        let probe = ButtonTrackingProbe(button: button, panel: panel, mouseUp: up, mutation: mutation)
        let timer = Timer(timeInterval: 0.05, target: probe,
                          selector: #selector(ButtonTrackingProbe.mutateAndRelease(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        // Invoke only our own NSButton, then release it through this process's event
        // queue. No CGEvent posting, global cursor movement, or external input.
        button.mouseDown(with: down)
        timer.invalidate()
        check(name + "_delayed_mutation_during_tracking", probe.didMutate && probe.trackingModeObserved)
        check(name + "_view_and_visibility_deferred", probe.viewStayedAttached && probe.panelStayedVisible && probe.frameStayedFixed)
    }

    private func checkNativeTracking(session: MenuSession, anchor: NSRect) {
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let adapter = NativeMenuAdapter(session: session) { _ in }
        let menu = adapter.makeMenu()
        let probe = PopupTrackingProbe(menu: menu)
        let timer = Timer(timeInterval: 0.04, target: probe,
                          selector: #selector(PopupTrackingProbe.sample(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        _ = menu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.minY - 3), in: nil)
        timer.invalidate()
        adapter.invalidate()
        check("native_popup_populates_during_tracking", probe.populated)
        details["nativePopupItemCount"] = probe.sampledCount
        let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
        check("native_popup_preserves_frontmost_app", before == after)
    }

    #endif

    private func prepare(_ menu: NSMenu) async -> Bool {
        menu.delegate?.menuNeedsUpdate?(menu)
        return await waitFor { !menu.items.contains { $0.title == "Loading menus…" } }
    }

    private func checkFixture(recordPath: String?) async {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "io.github.skylarstein.centermymenu.testhost")
            .filter { !$0.isTerminated }
        guard applications.count == 1, let application = applications.first else {
            check("exactly_one_fixture_running", false, detail: "Launch one fresh Center My Menu Test Host before this check.")
            return
        }
        let service = AXMenuService()
        let session = FixtureCheckingSession(underlying: service.session(for: application))
        let roots = await load(session)
        check("fixture_root_status", roots.status == .ok)
        guard let file = roots.entries.first(where: { $0.title == "File" && $0.hasSubmenu }),
              let dynamic = roots.entries.first(where: { $0.title == "Dynamic" && $0.hasSubmenu }) else {
            check("fixture_top_level_hierarchy", false)
            return
        }
        check("fixture_top_level_hierarchy", true)
        let fileBatch = await load(session, parent: file.id)
        let record = fileBatch.entries.first { $0.title == "Record Action" }
        let disabled = fileBatch.entries.first { $0.title == "Disabled Action" }
        let checked = fileBatch.entries.first { $0.title == "Checked Option" }
        check("ax_file_status", fileBatch.status == .ok)
        check("ax_disabled_item", disabled?.isEnabled == false)
        check("ax_checked_item", checked?.state == .on)
        check("ax_shortcut", record?.shortcut == MenuShortcut(key: "r", modifiers: [.command, .shift]))
        check("ax_separator", fileBatch.entries.contains { $0.isSeparator })
        if let nested = fileBatch.entries.first(where: { $0.title == "Nested" && $0.hasSubmenu }) {
            let nestedBatch = await load(session, parent: nested.id)
            check("ax_nested_item", nestedBatch.entries.contains { $0.title == "Record Nested Action" && $0.isEnabled })
        } else { check("ax_nested_item", false) }
        let dynamicBatch = await load(session, parent: dynamic.id)
        check("ax_dynamic_first_population", dynamicBatch.entries.contains { $0.title == "Record Dynamic Action" && $0.isEnabled })

        var notices: [String] = []
        let adapter = NativeMenuAdapter(session: session) { message in
            if let message { notices.append(message) }
        }
        defer { adapter.invalidate() }
        let menu = adapter.makeMenu()
        check("native_fixture_root_loaded", await prepare(menu))
        guard let fileMenu = menu.item(withTitle: "File")?.submenu,
              let dynamicMenu = menu.item(withTitle: "Dynamic")?.submenu else {
            check("native_fixture_hierarchy", false)
            return
        }
        check("native_fixture_file_loaded", await prepare(fileMenu))
        check("native_fixture_dynamic_loaded", await prepare(dynamicMenu))
        let nativeRecord = fileMenu.item(withTitle: "Record Action")
        let nativeChecked = fileMenu.item(withTitle: "Checked Option")
        check("native_disabled_item", fileMenu.item(withTitle: "Disabled Action")?.isEnabled == false)
        check("native_checked_item", nativeChecked?.state == .on)
        check("native_shortcut", nativeRecord?.keyEquivalent == "r" && nativeRecord?.keyEquivalentModifierMask == [.command, .shift])
        var nativeNested: NSMenuItem?
        if let nestedMenu = fileMenu.item(withTitle: "Nested")?.submenu {
            check("native_fixture_nested_loaded", await prepare(nestedMenu))
            nativeNested = nestedMenu.item(withTitle: "Record Nested Action")
        }
        check("native_nested_item", nativeNested != nil)
        let nativeDynamic = dynamicMenu.item(withTitle: "Record Dynamic Action")
        check("native_dynamic_item", nativeDynamic != nil)
        guard let recordPath else {
            skip("fixture_action_execution", "Supply --fixture-record with the fixture's JSON log path to verify actual commands and exactly-once callbacks.")
            details["actionValidation"] = "not_run_without_record_path"
            return
        }
        let log = URL(fileURLWithPath: (recordPath as NSString).expandingTildeInPath)
        guard readFixtureLog(log) != nil else {
            check("fixture_record_log_available", false, detail: "Use the same --record-path as the fixture and launch it with --reset-record.")
            return
        }
        // The only application we activate is the explicitly identified harmless fixture.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier {
            guard application.activate(options: []) else { check("fixture_activation", false); return }
            let active = await waitFor { NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier }
            check("fixture_activation", active)
            guard active else { return }
        }
        let actions: [(String, NSMenuItem?)] = [("record", nativeRecord), ("checked", nativeChecked),
                                               ("nested", nativeNested), ("dynamic", nativeDynamic)]
        for (actionID, item) in actions {
            guard let item, item.isEnabled, let selector = item.action, let before = readFixtureLog(log) else {
                check("action_\(actionID)_available", false)
                continue
            }
            let requestCount = session.requests[actionID, default: 0]
            let callbackCount = session.callbacks[actionID, default: 0]
            let sent = NSApp.sendAction(selector, to: item.target, from: item)
            check("action_\(actionID)_native_target", sent)
            let callback = await waitFor { session.callbacks[actionID, default: 0] > callbackCount }
            _ = await waitFor(seconds: 1) { (self.readFixtureLog(log)?.count ?? 0) > before.count }
            await pause(0.15)
            let after = readFixtureLog(log) ?? []
            let once = after.count == before.count + 1 && Array(after.prefix(before.count)) == before && after.last == actionID
            check("action_\(actionID)_exactly_once", once)
            check("action_\(actionID)_single_request_and_callback", callback
                  && session.requests[actionID, default: 0] == requestCount + 1
                  && session.callbacks[actionID, default: 0] == callbackCount + 1)
            if !once || !callback { break } // Never retry an ambiguous AXPress.
        }
        let refreshedFile = await load(session, parent: file.id)
        check("checked_state_refreshes_after_action", refreshedFile.entries.first { $0.title == "Checked Option" }?.state == .off)
        check("no_action_failure_notices", notices.isEmpty)
        details["actionValidation"] = "Known fixture commands through NativeMenuAdapter and AXMenuService; compared JSON log changes and callbacks."
        details["actionRequestCounts"] = session.requests
        details["actionCallbackCounts"] = session.callbacks
    }

    private func readFixtureLog(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String],
              values.allSatisfy({ ["about", "record", "disabled", "checked", "nested", "dynamic", "updated"].contains($0) }) else { return nil }
        return values
    }
}

// This wrapper observes the real service, while allowing action execution only for
// exact known fixture paths. It never fabricates menu results or action successes.
private final class FixtureCheckingSession: MenuSession {
    let underlying: MenuSession
    var identity: AppIdentity { underlying.identity }
    var applicationName: String { underlying.applicationName }
    private var paths: [UUID: String] = [:]
    private var permittedActions: [UUID: String] = [:]
    private(set) var requests: [String: Int] = [:]
    private(set) var callbacks: [String: Int] = [:]
    private let allowed = ["File/Record Action": "record", "File/Checked Option": "checked",
                           "File/Nested/Record Nested Action": "nested", "Dynamic/Record Dynamic Action": "dynamic",
                           "File/Record Updated Action": "updated"]

    init(underlying: MenuSession) { self.underlying = underlying }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        underlying.loadChildren(of: parentID) { [self] batch in
            let prefix = parentID.flatMap { paths[$0] }.map { $0 + "/" } ?? ""
            for entry in batch.entries where !entry.isSeparator {
                let path = prefix + entry.title
                paths[entry.id] = path
                if entry.isEnabled, !entry.hasSubmenu, let identifier = allowed[path] {
                    permittedActions[entry.id] = identifier
                }
            }
            completion(batch)
        }
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        guard identity.bundleIdentifier == "io.github.skylarstein.centermymenu.testhost", action.target == identity,
              let identifier = permittedActions[action.entryID] else {
            completion("Runtime check rejected an action outside the fixture allowlist.")
            return
        }
        requests[identifier, default: 0] += 1
        underlying.perform(action) { [self] message in
            callbacks[identifier, default: 0] += 1
            completion(message)
        }
    }
}

// Selector timers execute on the run loop that owns them. Keeping the menu in a
// main-actor object avoids transferring AppKit references through a Sendable block.
#if QA_CHECKS
@MainActor
private final class StatusMenuActionProbe: NSObject {
    private let menu: NSMenu
    private let windowNumber: Int
    private let started = ProcessInfo.processInfo.systemUptime
    private var nextStepAt: TimeInterval = 0
    private var index = 0
    private let steps: [([String], KeyboardTrackingProbe.Key)] = [
        ([], .down), (["UI Test App"], .right),
        (["UI Test App"], .down), (["UI Test App", ""], .right),
        (["UI Test App", ""], .down), (["UI Test App", "", "About UI Test Mac"], .enter)
    ]
    private(set) var lastState = "No native status menu observed"
    var completed: Bool { index == steps.count }

    init(menu: NSMenu, windowNumber: Int) {
        self.menu = menu
        self.windowNumber = windowNumber
    }

    @objc func sample(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - started > 4 {
            timer.invalidate()
            menu.cancelTrackingWithoutAnimation()
            return
        }
        guard !completed, now - started >= 0.2, now >= nextStepAt else { return }
        var path: [String] = []
        var selected = menu.highlightedItem
        while let item = selected {
            path.append(item.title)
            selected = item.submenu?.highlightedItem
        }
        lastState = "Step \(index): \(path)"
        let (expected, key) = steps[index]
        guard path == expected,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: key.rawValue >= 123 ? [.function, .numericPad] : [], timestamp: now,
                windowNumber: windowNumber, context: nil, characters: key.characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.rawValue) else { return }
        index += 1
        nextStepAt = now + 0.16
        NSApp.postEvent(event, atStart: false)
    }
}

@MainActor
private final class MenuPlacementProbe: NSObject {
    let menu: NSMenu
    private let started = ProcessInfo.processInfo.systemUptime
    private(set) var frame: NSRect?
    private(set) var appearance: NSAppearance.Name?
    private let onCapture: ((NSWindow) -> Void)?

    init(menu: NSMenu, onCapture: ((NSWindow) -> Void)? = nil) {
        self.menu = menu
        self.onCapture = onCapture
    }

    @objc func sample(_ timer: Timer) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        guard elapsed >= 0.16 else { return }
        if elapsed < 1, menu.items.contains(where: { $0.title == "Loading menus…" }) { return }
        let menuFrame = menu.accessibilityFrame()
        let window = NSApp.windows.first {
            $0.isVisible && $0.level == .popUpMenu && $0.frame == menuFrame
        }
        frame = window?.frame
        appearance = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        if frame != nil || elapsed > 1 {
            if let window { onCapture?(window) }
            timer.invalidate()
            menu.cancelTrackingWithoutAnimation()
        }
    }
}

@MainActor
private final class PopupTrackingProbe: NSObject {
    let menu: NSMenu
    private let deadline = ProcessInfo.processInfo.systemUptime + 3
    private(set) var populated = false
    private(set) var sampledCount = 0

    init(menu: NSMenu) { self.menu = menu }

    @objc func sample(_ timer: Timer) {
        populated = menu.item(withTitle: "File")?.submenu != nil && menu.item(withTitle: "View")?.submenu != nil
        sampledCount = menu.numberOfItems
        if populated || ProcessInfo.processInfo.systemUptime >= deadline {
            timer.invalidate()
            menu.cancelTracking()
        }
    }
}

@MainActor
private final class ButtonTrackingProbe: NSObject {
    private let button: NSButton
    private let panel: NSWindow
    private let originalContent: NSView?
    private let originalFrame: NSRect
    private let mouseUp: NSEvent
    private let mutation: () -> Void
    private(set) var didMutate = false
    private(set) var trackingModeObserved = false
    private(set) var viewStayedAttached = false
    private(set) var panelStayedVisible = false
    private(set) var frameStayedFixed = false

    init(button: NSButton, panel: NSWindow, mouseUp: NSEvent, mutation: @escaping () -> Void) {
        self.button = button
        self.panel = panel
        self.originalContent = panel.contentView
        self.originalFrame = panel.frame
        self.mouseUp = mouseUp
        self.mutation = mutation
    }

    @objc func mutateAndRelease(_ timer: Timer) {
        timer.invalidate()
        trackingModeObserved = RunLoop.current.currentMode == .eventTracking
        didMutate = true
        mutation()
        viewStayedAttached = button.window === panel && panel.contentView === originalContent
        panelStayedVisible = panel.isVisible
        frameStayedFixed = panel.frame == originalFrame
        NSApp.postEvent(mouseUp, atStart: true)
    }
}
#endif
