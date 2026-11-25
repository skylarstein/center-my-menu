#if QA_CHECKS
import AppKit
import Darwin
import CenterMyMenuCore

// Permission-free interaction checks for the UI-smoke launch mode.
@MainActor
final class InteractionRuntimeChecks: NSObject {
    private let output: URL
    private var checks: [[String: Any]] = []
    private var watchdog: Timer?
    private var finished = false

    private init(output: URL) {
        self.output = output
        super.init()
    }

    static func start(directory: String, then continuation: @escaping (Bool) -> Void) {
        let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
        let runner = InteractionRuntimeChecks(output: folder.appendingPathComponent("interaction-regressions.json"))
        let watchdog = Timer(timeInterval: 20, target: runner,
            selector: #selector(deadlineReached(_:)), userInfo: nil, repeats: false)
        runner.watchdog = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
        Task { @MainActor in
            await runner.run()
            guard !runner.finished else { return }
            // Keep failures visible while allowing the independent UI checks to run.
            continuation(runner.writeReport())
        }
    }

    private func check(_ name: String, _ passed: Bool) {
        checks.append(["name": name, "status": passed ? "passed" : "failed"])
    }

    @objc private func deadlineReached(_ timer: Timer) {
        guard !finished else { return }
        check("interaction_checks_finish_within_deadline", false)
        _ = writeReport()
        exit(1)
    }

    private func writeReport() -> Bool {
        finished = true
        watchdog?.invalidate()
        watchdog = nil
        let failures = checks.filter { $0["status"] as? String == "failed" }.count
        let report: [String: Any] = [
            "mode": "interaction_regressions", "status": failures == 0 ? "passed" : "failed",
            "failedCheckCount": failures, "checks": checks,
            "scope": "Own AppKit views/native menus and scripted providers only. No AX grant, global input posting, cursor warping, or external actions."
        ]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0a)
            try data.write(to: output, options: .atomic)
            if failures > 0 {
                FileHandle.standardError.write(Data("Interaction regressions failed; see interaction-regressions.json.\n".utf8))
            }
            return failures == 0
        } catch {
            FileHandle.standardError.write(Data("Could not write interaction regression report.\n".utf8))
            return false
        }
    }

    private func pause(_ seconds: Double = 0.04) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            await pause(0.01)
        }
        return true
    }

    private func load(_ session: MenuSession) async -> MenuBatch {
        await withCheckedContinuation { continuation in
            session.loadChildren(of: nil) { continuation.resume(returning: $0) }
        }
    }

    private func run() async {
        checkMenuBarTarget()
        await checkReadiness()
        await checkPermissionRecovery()
        await checkStaleNativeWork()
        await checkActionNotices()
        let displays = ConnectedDisplay.current()
        guard let display = displays.first(where: { !$0.descriptor.isBuiltIn }) ?? displays.first else {
            check("interaction_display_available", false)
            return
        }
        await checkDragging(on: display)
        await checkLostMouseUpRecovery(on: display)
        await checkToolbar(on: display)
        await checkKeyboard(on: display)
        await checkMultipleDisplays(on: display)
    }

    private func checkMenuBarTarget() {
        let editor = TargetApplication(pid: 8101, bundle: "test.editor")
        let other = TargetApplication(pid: 8102, bundle: "test.other")
        let own = TargetApplication(pid: ProcessInfo.processInfo.processIdentifier, bundle: "io.github.skylarstein.centermymenu")
        var owner: NSRunningApplication? = editor
        let tracker = AppTargetTracker(menuBarOwner: { owner })
        check("target_uses_menu_bar_owner", tracker.capture() === editor)
        check("target_menu_owner_allows_readiness_retry", tracker.allowsMenuRetry(for: identity(of: editor)))
        owner = own
        check("target_settings_retains_external_owner", tracker.capture() === editor)
        check("target_remembered_app_does_not_retry_under_another_owner", !tracker.allowsMenuRetry(for: identity(of: editor)))
        owner = nil
        check("target_missing_owner_retains_live_target", tracker.capture() === editor)
        owner = other
        check("target_follows_menu_ownership_change", tracker.capture() === other)
        other.didTerminate = true
        check("target_drops_terminated_owner", tracker.capture() == nil)
        check("target_terminated_owner_does_not_retry", !tracker.allowsMenuRetry(for: identity(of: other)))
        owner = own
        check("target_never_selects_itself", tracker.capture() == nil)
    }

    private func checkReadiness() async {
        let transition = RootMenuLoader()
        var presented: [MenuSnapshot] = []
        transition.onSnapshot = { presented.append($0) }
        let first = ScriptedRootSession(pid: 9101)
        let fast = ScriptedRootSession(pid: 9102)
        let slow = ScriptedRootSession(pid: 9103)
        transition.request(session: first, accessAllowed: true, retryAllowed: false, force: true)
        check("transition_startup_shows_loading", presented.last?.batch.status == .loading)
        first.completeNext(MenuBatch(entries: [MenuEntry(title: "First")]))
        _ = await wait { presented.last?.batch.entries.first?.title == "First" }
        let beforeSwitch = presented.count
        transition.request(session: fast, accessAllowed: true, retryAllowed: false, force: true)
        check("transition_reads_immediately_without_loading_flash",
              fast.loadCount == 1 && presented.count == beforeSwitch)
        fast.completeNext(MenuBatch(entries: [MenuEntry(title: "Fast")]))
        await pause(0.18)
        check("transition_fast_result_cancels_waiting_message",
              presented.count == beforeSwitch + 1 && presented.last?.batch.entries.first?.title == "Fast")
        transition.request(session: slow, accessAllowed: true, retryAllowed: false, force: true)
        slow.completeNext(MenuBatch(entries: [], status: .unavailable))
        _ = await wait { transition.snapshot?.batch.status == .unavailable }
        check("transition_brief_empty_result_does_not_flash", presented.last?.batch.entries.first?.title == "Fast")
        await pause(0.18)
        check("transition_persistent_empty_result_is_displayed", presented.last?.batch.status == .unavailable)
        transition.request(session: fast, accessAllowed: true, retryAllowed: false, force: true)
        fast.completeNext(MenuBatch(entries: [MenuEntry(title: "Fast")]))
        _ = await wait { presented.last?.batch.entries.first?.title == "Fast" }
        transition.request(session: slow, accessAllowed: true, retryAllowed: false, force: true)
        let rapid = ScriptedRootSession(pid: 9104)
        let beforeRapidSwitch = presented.count
        transition.request(session: rapid, accessAllowed: true, retryAllowed: false, force: true)
        check("transition_rapid_switch_preserves_grace", presented.count == beforeRapidSwitch)
        slow.completeNext(MenuBatch(entries: [MenuEntry(title: "Stale")]))
        _ = await wait { rapid.loadCount == 1 }
        rapid.completeNext(MenuBatch(entries: [MenuEntry(title: "Rapid")]))
        _ = await wait { presented.last?.batch.entries.first?.title == "Rapid" }
        check("transition_rapid_switch_rejects_stale_result", presented.last?.batch.entries.first?.title == "Rapid")
        transition.request(session: rapid, accessAllowed: false, retryAllowed: false, force: true)
        rapid.completeNext(MenuBatch(entries: [], status: .permissionRequired))
        _ = await wait { transition.snapshot?.batch.status == .permissionRequired }
        check("transition_permission_loss_is_not_delayed", presented.last?.batch.status == .permissionRequired)
        transition.stop()

        // Begin before any menu-bar owner exists, then make one available without
        // an activation notification, hover, or click. The retry must recapture it.
        let missingIdentity = AppIdentity(processIdentifier: 0, bundleIdentifier: nil, launchTime: nil)
        let missing = UnavailableMenuSession(identity: missingIdentity, name: "None",
            message: "Waiting for app menus…", status: .unavailable)
        let arrivingApp = TargetApplication(pid: 9099, bundle: "io.github.skylarstein.centermymenu.qa.scripted")
        var owner: NSRunningApplication?
        let tracker = AppTargetTracker(menuBarOwner: { owner })
        let arriving = ScriptedRootSession(pid: 9099, failures: 2)
        let startup = RootMenuLoader(backoff: MenuReadinessBackoff(initialDelay: 0.01, maximumDelay: 0.02))
        var captureRetries = 0
        startup.onRetry = { [weak startup] previous in
            captureRetries += 1
            if captureRetries == 2 { owner = arrivingApp }
            let session: MenuSession = tracker.capture() == nil ? missing : arriving
            let allowed = tracker.allowsMenuRetry(for: session.identity)
            startup?.request(session: session, accessAllowed: true, retryAllowed: allowed,
                             force: previous == session.identity && allowed)
        }
        startup.request(session: missing, accessAllowed: true,
                        retryAllowed: tracker.allowsMenuRetry(for: missingIdentity), force: false)
        let foundOwner = await wait { startup.snapshot?.batch.status == .ok }
        check("readiness_missing_owner_recovers_without_events_or_clicks", foundOwner && captureRetries >= 4
              && startup.snapshot?.session.identity == arriving.identity && arriving.loadCount == 3)
        startup.stop()

        let automatic = ScriptedRootSession(pid: 9001, failures: 14)
        let loader = RootMenuLoader(backoff: MenuReadinessBackoff(initialDelay: 0.01, maximumDelay: 0.02))
        var retriedIdentities: [AppIdentity] = []
        loader.onRetry = { [weak loader] identity in
            retriedIdentities.append(identity)
            loader?.request(session: automatic, accessAllowed: true, retryAllowed: true, force: true)
        }
        loader.request(session: automatic, accessAllowed: true, retryAllowed: true, force: true)
        let recovered = await wait { loader.snapshot?.batch.status == .ok }
        check("readiness_recovers_after_fourteen_failures_without_clicks", recovered && automatic.loadCount == 15
              && retriedIdentities.count == 14 && retriedIdentities.allSatisfy { $0 == automatic.identity })
        let settledCount = automatic.loadCount
        await pause(0.08)
        check("readiness_success_stops_retry_timer", automatic.loadCount == settledCount && !loader.hasScheduledRetry)
        loader.stop()

        let old = ScriptedRootSession(pid: 9002, launch: 1)
        let replacement = ScriptedRootSession(pid: 9002, launch: 2) // PID reuse is a different target.
        let blocked = ScriptedRootSession(pid: 9002, launch: 2)
        let serial = RootMenuLoader(backoff: MenuReadinessBackoff(initialDelay: 0.01, maximumDelay: 0.02))
        var published: [MenuBatch] = []
        var unexpectedRetries = 0
        serial.onSnapshot = { if $0.batch.status != .loading { published.append($0.batch) } }
        serial.onRetry = { _ in unexpectedRetries += 1 }
        serial.request(session: old, accessAllowed: true, retryAllowed: true, force: true)
        for _ in 0..<20 { serial.request(session: old, accessAllowed: true, retryAllowed: true, force: true) }
        serial.request(session: replacement, accessAllowed: true, retryAllowed: false, force: false)
        check("readiness_coalesces_in_flight_requests", old.loadCount == 1 && replacement.loadCount == 0)
        old.completeNext(MenuBatch(entries: [MenuEntry(title: "Stale")]))
        let replacementStarted = await wait { replacement.loadCount == 1 }
        check("readiness_relaunch_rejects_stale_completion", replacementStarted && published.isEmpty)
        replacement.completeNext(MenuBatch(entries: [], status: .unavailable))
        _ = await wait { serial.snapshot?.batch.status == .unavailable }
        await pause(0.07)
        check("readiness_inactive_target_suspends_retries", unexpectedRetries == 0 && !serial.hasScheduledRetry)

        let beforePermissionChange = published.count
        serial.request(session: replacement, accessAllowed: true, retryAllowed: false, force: true)
        serial.request(session: blocked, accessAllowed: false, retryAllowed: false, force: true)
        check("readiness_permission_change_does_not_enqueue_parallel_read", replacement.loadCount == 2 && blocked.loadCount == 0)
        replacement.completeNext(MenuBatch(entries: [MenuEntry(title: "Authorized but stale")]))
        let blockedStarted = await wait { blocked.loadCount == 1 }
        check("readiness_permission_change_invalidates_completion", blockedStarted && published.count == beforePermissionChange)
        blocked.completeNext(MenuBatch(entries: [], status: .permissionRequired))
        _ = await wait { serial.snapshot?.batch.status == .permissionRequired }
        await pause(0.07)
        check("readiness_permission_required_stops_retries", unexpectedRetries == 0 && !serial.hasScheduledRetry)
        serial.request(session: replacement, accessAllowed: true, retryAllowed: true, force: true)
        let beforeStop = published.count
        serial.stop()
        replacement.completeNext(MenuBatch(entries: [MenuEntry(title: "After stop")]))
        await pause()
        check("readiness_termination_rejects_completion", published.count == beforeStop && !serial.hasScheduledRetry)

        let paused = ScriptedRootSession(pid: 9003)
        let suspender = RootMenuLoader(backoff: MenuReadinessBackoff(initialDelay: 0.02, maximumDelay: 0.04))
        suspender.onRetry = { [weak suspender] _ in
            suspender?.request(session: paused, accessAllowed: true, retryAllowed: true, force: true)
        }
        suspender.request(session: paused, accessAllowed: true, retryAllowed: true, force: true)
        suspender.setSuspended(true)
        paused.completeNext(MenuBatch(entries: [], status: .timedOut))
        _ = await wait { suspender.snapshot?.batch.status == .timedOut }
        await pause(0.08)
        check("readiness_menu_tracking_suspends_retry_work", paused.loadCount == 1 && !suspender.hasScheduledRetry)
        suspender.setSuspended(false)
        let resumed = await wait { paused.loadCount == 2 }
        check("readiness_resumes_after_tracking", resumed)
        paused.completeNext(MenuBatch(entries: [MenuEntry(title: "Ready")]))
        _ = await wait { suspender.snapshot?.batch.status == .ok }
        suspender.stop()

        // Hidden controls queue target/permission changes without reading menus.
        // Status menus load independently; showing controls recaptures a fresh target.
        let hidden = RootMenuLoader(backoff: MenuReadinessBackoff(initialDelay: 0.01, maximumDelay: 0.02))
        let previous = ScriptedRootSession(pid: 9004, failures: 0)
        let visible = ScriptedRootSession(pid: 9005, failures: 2)
        hidden.onRetry = { [weak hidden] _ in
            hidden?.request(session: visible, accessAllowed: true, retryAllowed: true, force: true)
        }
        hidden.setSuspended(true)
        hidden.request(session: missing, accessAllowed: false, retryAllowed: false, force: true)
        hidden.request(session: previous, accessAllowed: true, retryAllowed: true, force: true)
        await pause(0.08)
        check("readiness_hidden_permission_recovery_does_not_poll", previous.loadCount == 0 && !hidden.hasScheduledRetry)
        let onDemand = NativeMenuAdapter(session: previous) { _ in }
        let menu = onDemand.makeMenu()
        menu.delegate?.menuNeedsUpdate?(menu)
        let populated = await wait { menu.item(withTitle: "Ready") != nil }
        onDemand.invalidate()
        hidden.setSuspended(true) // Closing a status menu while still Hidden must not resume reads.
        await pause(0.08)
        check("readiness_hidden_status_menu_loads_on_demand", populated && previous.loadCount == 1 && !hidden.hasScheduledRetry)
        hidden.request(session: visible, accessAllowed: true, retryAllowed: true, force: true)
        hidden.setSuspended(false)
        check("readiness_visible_starts_fresh_target_immediately", visible.loadCount == 1 && previous.loadCount == 1)
        let visibleReady = await wait { hidden.snapshot?.batch.status == .ok }
        check("readiness_visible_retries_until_ready", visibleReady && visible.loadCount == 3 && !hidden.hasScheduledRetry)
        hidden.stop()
    }

    private func checkPermissionRecovery() async {
        let provider = ScriptedRootSession(pid: 9012)
        let controller = AppController(options: LaunchOptions(uiTestMode: true),
            store: ConfigurationStore(defaults: nil, initial: .uiTest()))
        defer { controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let (_, adapter) = controller.makeStatusMenu(for: provider)
        defer { adapter.invalidate() }
        let title = "Grant access…"
        for parentID: UUID? in [nil, UUID()] {
            let menu = adapter.makeMenu(parentID: parentID)
            menu.delegate?.menuNeedsUpdate?(menu)
            let message = parentID == nil ? "Permission is required." : nil
            provider.completeNext(MenuBatch(entries: [], message: message, status: .permissionRequired))
            let populated = await wait { menu.item(withTitle: title) != nil }
            let item = menu.item(withTitle: title)
            check(parentID == nil ? "native_late_root_permission_failure_has_recovery"
                  : "native_late_submenu_permission_failure_has_recovery_without_message",
                  populated && item?.isEnabled == true && item?.target === controller
                  && item?.action == NSSelectorFromString("requestPermission:"))
            if let item, let action = item.action {
                // UI test mode blocks the real permission prompt and System Settings.
                check("native_permission_recovery_action_dispatches_\(parentID == nil ? "root" : "submenu")",
                      NSApp.sendAction(action, to: item.target, from: item))
            }
            menu.delegate?.menuDidClose?(menu)
        }
        let unavailable = adapter.makeMenu()
        unavailable.delegate?.menuNeedsUpdate?(unavailable)
        provider.completeNext(MenuBatch(entries: [], message: "Unavailable", status: .unavailable))
        _ = await wait { unavailable.item(withTitle: "Unavailable") != nil }
        check("native_other_failures_do_not_offer_permission_recovery", unavailable.item(withTitle: title) == nil)

        let invalidated = adapter.makeMenu()
        invalidated.delegate?.menuNeedsUpdate?(invalidated)
        adapter.invalidate()
        provider.completeNext(MenuBatch(entries: [], status: .permissionRequired))
        await pause()
        check("native_invalidated_menu_rejects_permission_recovery", invalidated.item(withTitle: title) == nil)
    }

    private func checkStaleNativeWork() async {
        let provider = ScriptedRootSession(pid: 9010)
        let adapter = NativeMenuAdapter(session: provider) { _ in }
        let closed = adapter.makeMenu()
        closed.delegate?.menuNeedsUpdate?(closed)
        closed.delegate?.menuDidClose?(closed)
        provider.completeNext(MenuBatch(entries: [MenuEntry(title: "Late closed item")]))
        await pause()
        check("native_closed_menu_rejects_late_population", closed.item(withTitle: "Late closed item") == nil)

        let invalidated = adapter.makeMenu()
        invalidated.delegate?.menuNeedsUpdate?(invalidated)
        adapter.invalidate()
        provider.completeNext(MenuBatch(entries: [MenuEntry(title: "Late invalidated item")]))
        await pause()
        check("native_invalidated_adapter_rejects_late_population", invalidated.item(withTitle: "Late invalidated item") == nil)

        var notices: [String?] = []
        let actionable = NativeMenuAdapter(session: provider) { notices.append($0) }
        let menu = actionable.makeMenu()
        menu.delegate?.menuNeedsUpdate?(menu)
        provider.completeNext(MenuBatch(entries: [MenuEntry(title: "Harmless scripted command")]))
        let populated = await wait { menu.item(withTitle: "Harmless scripted command") != nil }
        actionable.invalidate()
        if let item = menu.item(withTitle: "Harmless scripted command"), let action = item.action {
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
        check("native_invalidated_command_target_cannot_execute",
              populated && provider.actionRequests == 0 && notices.isEmpty)
    }

    private func checkActionNotices() async {
        let provider = ScriptedRootSession(pid: 9011)
        let store = ConfigurationStore(defaults: nil, initial: .uiTest())
        store.value.mode = .statusOnly
        // Exercise the real report/tooltip path without normal startup or external actions.
        let controller = AppController(options: LaunchOptions(uiTestMode: true), store: store)
        let statusItem = controller.installStatusItem()
        defer { controller.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        guard let button = statusItem.button else {
            check("action_notice_status_button_available", false)
            return
        }
        let refusal = "Scripted refusal: no command was sent."
        for notice: String? in [refusal, nil] {
            let name = notice == nil ? "native_success_clears_prior_error"
                : "native_refusal_delivered_after_adapter_invalidation"
            let priorErrorVisible = button.toolTip?.contains(refusal) == true
            provider.actionNotice = notice
            let (statusMenu, adapter) = controller.makeStatusMenu(for: provider)
            defer { adapter.invalidate() }
            guard let menu = statusMenu.items.compactMap(\.submenu).first else {
                check(name, false)
                return
            }
            menu.delegate?.menuNeedsUpdate?(menu)
            provider.completeNext(MenuBatch(entries: [MenuEntry(title: "Harmless scripted command")]))
            let populated = await wait { menu.item(withTitle: "Harmless scripted command") != nil }
            guard populated, let item = menu.item(withTitle: "Harmless scripted command"),
                  let action = item.action else {
                check(name, false)
                return
            }
            let previousRequests = provider.actionRequests
            let sent = NSApp.sendAction(action, to: item.target, from: item)
            // The scripted completion is queued on the menu run loop, just like AX.
            adapter.invalidate()
            let delivered = await wait {
                guard let tooltip = button.toolTip else { return false }
                return notice.map { tooltip.contains($0) } ?? !tooltip.contains(refusal)
            }
            check(name, sent && delivered && provider.actionRequests == previousRequests + 1
                  && (notice != nil || priorErrorVisible))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func newPanel(excluding existing: Set<ObjectIdentifier>) -> NSWindow? {
        let panel = NSApp.windows.first { $0.title == "Center My Menu" && !existing.contains(ObjectIdentifier($0)) }
        // Do not leave an identically named hidden QA window for the existing smoke
        // runner's floatingPanel() lookup, even if AppKit retains a closed window.
        panel?.title = "Center My Menu Interaction QA"
        return panel
    }

    private func close(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.75 && abs(a.minY - b.minY) < 0.75
            && abs(a.width - b.width) < 0.75 && abs(a.height - b.height) < 0.75
    }

    // Two display identities on the connected screen exercise lifecycle and routing;
    // this does not substitute for physical multi-monitor acceptance testing.
    private func checkMultipleDisplays(on actual: ConnectedDisplay) async {
        func simulated(_ id: String) -> ConnectedDisplay {
            let descriptor = DisplayDescriptor(id: id, isBuiltIn: false,
                frame: actual.descriptor.frame, visibleFrame: actual.descriptor.visibleFrame,
                safeTopInset: actual.descriptor.safeTopInset)
            return ConnectedDisplay(screen: actual.screen, displayID: actual.displayID,
                                    descriptor: descriptor)
        }
        let a = simulated("qa-display-a"), b = simulated("qa-display-b")
        let session = TestMenuSession()
        let batch = await load(session)
        let snapshot = MenuSnapshot(session: session, batch: batch)
        var configuration = Configuration.uiTest()
        configuration.displayScope = .all
        configuration.positions = [a.descriptor.id: StoredPosition(horizontalFraction: 0.3, topOffset: 120),
                                   b.descriptor.id: StoredPosition(horizontalFraction: 0.7, topOffset: 180)]
        let group = FloatingControls()
        func render(_ displays: [ConnectedDisplay] = [a, b], main: String? = nil) {
            group.update(displays: displays, activeDisplayID: main ?? a.descriptor.id,
                         configuration: configuration, snapshot: snapshot, uiTestMode: true)
        }
        func panel(_ display: ConnectedDisplay) -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue == "CenterMyMenu.Floating.\(display.descriptor.id)" && $0.isVisible }
        }
        func titles(_ window: NSWindow) -> [String] {
            window.contentView.map { descendants($0).compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty } } ?? []
        }
        defer {
            group.onPositionChange = nil
            group.stop()
            for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("CenterMyMenu.Floating.qa-display-") == true {
                window.title = "Center My Menu Multi-display QA"
            }
        }
        render()
        guard let first = panel(a), let second = panel(b) else {
            check("all_displays_create_independent_panels", false)
            return
        }
        check("all_displays_create_independent_panels", first !== second && first.frame != second.frame)
        check("all_displays_share_active_app_menus", titles(first) == batch.entries.map(\.title) && titles(second) == titles(first))
        var correctlyRouted = false
        group.onHeadingMenu = { control, captured, entry, view in
            correctlyRouted = captured === session && view.window === second
                && control.heading(for: entry.id, session: captured)?.view === view
        }
        let heading = second.contentView.flatMap { descendants($0).compactMap { $0 as? NSButton }.first { $0.title == "File" } }
        heading?.performClick(nil)
        check("secondary_display_routes_heading_to_its_own_control", correctlyRouted)

        let secondFrame = second.frame
        var saves = 0
        group.onPositionChange = { display, position in
            saves += 1
            configuration.positions[display.id] = position
            render()
        }
        if let grip = first.contentView.flatMap({ descendants($0).compactMap { $0 as? GripView }.first }),
           let down = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: first.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                timestamp: 1, windowNumber: first.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) {
            var pointer = NSPoint(x: first.frame.minX + 9, y: first.frame.midY)
            var pressedButtons = 1
            grip.pointerLocation = { pointer }
            grip.pressedButtons = { pressedButtons }
            grip.mouseDown(with: down)
            pointer.y -= 35
            pressedButtons = 0
            grip.mouseUp(with: up)
            check("multi_display_drag_saves_only_its_own_position", saves == 1 && close(second.frame, secondFrame)
                  && configuration.positions[b.descriptor.id]?.topOffset == 180
                  && abs((configuration.positions[a.descriptor.id]?.topOffset ?? 0) - 155) < 1)
        } else { check("multi_display_drag_available", false) }
        let firstFrame = first.frame
        configuration.displayScope = .active
        render(main: b.descriptor.id)
        check("active_display_hides_other_controls", !first.isVisible && second.isVisible)
        let displayMonitor = DisplayConfigurationMonitor()
        var displayRefreshes = 0
        displayMonitor.start {
            displayRefreshes += 1
            render(main: a.descriptor.id)
        }
        displayConfigurationCallback(a.displayID, .beginConfigurationFlag, nil)
        await pause()
        check("display_reconfiguration_waits_for_completion", displayRefreshes == 0 && second.isVisible)
        // Exercise the production event path without changing the user's displays.
        displayConfigurationCallback(a.displayID, .setMainFlag, nil)
        let moved = await wait { first.isVisible && !second.isVisible }
        check("display_reconfiguration_refreshes_selected_control", moved && displayRefreshes > 0 && close(first.frame, firstFrame))
        var activeID = a.descriptor.id
        let activeMonitor = ActiveDisplayMonitor(currentID: { activeID }, onChange: { render(main: activeID) })
        activeMonitor.setEnabled(true)
        activeID = b.descriptor.id
        let followed = await wait { !first.isVisible && second.isVisible }
        check("active_display_change_moves_control_without_app_activation", followed)
        activeMonitor.stop()
        activeID = a.descriptor.id
        await pause(0.3)
        check("active_display_monitor_stops_when_disabled", !first.isVisible && second.isVisible)
        displayMonitor.stop()
        let refreshesAtStop = displayRefreshes
        displayConfigurationCallback(a.displayID, .setMainFlag, nil)
        await pause()
        check("display_reconfiguration_stop_removes_observation", displayRefreshes == refreshesAtStop)
        configuration.displayScope = .all
        render([a])
        check("disconnect_removes_only_disconnected_control", first.isVisible && !second.isVisible)
        render()
        guard let reconnected = panel(b) else { check("reconnect_restores_control", false); return }
        check("reconnect_restores_independent_position", close(reconnected.frame, secondFrame) && close(first.frame, firstFrame))
        configuration.mode = .compactIcon
        render()
        check("mode_changes_every_display", abs(first.frame.width - 54) < 1 && abs(reconnected.frame.width - 54) < 1)
        configuration.mode = .statusOnly
        render()
        check("status_only_hides_every_floating_control", !first.isVisible && !reconnected.isVisible)
        configuration.mode = .toolbar
        render()
        check("returning_to_toolbar_restores_positions", close(first.frame, firstFrame) && close(reconnected.frame, secondFrame))
        let originalFirst = first.contentView, originalSecond = reconnected.contentView
        group.setMenuTracking(true)
        render()
        check("menu_tracking_defers_all_display_updates", first.contentView === originalFirst && reconnected.contentView === originalSecond)
        group.setMenuTracking(false)
        check("menu_tracking_resumes_all_display_updates", first.contentView !== originalFirst && reconnected.contentView !== originalSecond)
    }

    private func checkDragging(on display: ConnectedDisplay) async {
        let testSession = TestMenuSession()
        let roots = await load(testSession)
        let entries = roots.entries.filter { ["File", "Edit", "View"].contains($0.title) }
        let snapshot = MenuSnapshot(session: testSession, batch: MenuBatch(entries: entries, status: .uiTestData))
        var pointer = NSPoint.zero
        var pressedButtons = 1
        var buttonSamples = 0
        var afterReleasedSample: (() -> Void)?
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let floating = FloatingControl(pointerLocation: { pointer }, pressedButtons: {
            buttonSamples += 1
            let buttons = pressedButtons
            if buttons & 1 == 0 {
                let release = afterReleasedSample
                afterReleasedSample = nil
                release?()
            }
            return buttons
        })
        defer {
            afterReleasedSample = nil
            floating.onPositionChange = nil
            floating.stop()
        }
        let preferences = DisplayPreferences(mode: .toolbar, position: StoredPosition(horizontalFraction: 0.5, topOffset: 60))
        floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
        guard let panel = newPanel(excluding: existing), let content = panel.contentView,
              let grip = descendants(content).compactMap({ $0 as? GripView }).first else {
            check("drag_test_grip_available", false)
            return
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 9100, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown), let motion = event(.leftMouseDragged), let up = event(.leftMouseUp) else {
            check("drag_test_events_available", false)
            return
        }
        // These are calls to our own view with per-instance pointer/button sources.
        // They never post global input or move the real cursor.
        let initial = panel.frame
        pointer = NSPoint(x: initial.minX + 9, y: initial.midY)
        let anchor = PointerAnchoredDrag(frame: initial, pointer: pointer)
        let start = pointer
        var saves: [(DisplayDescriptor, StoredPosition)] = []
        var frameAtSave: NSRect?
        let latest = DisplayPreferences(mode: .toolbar)
        floating.onPositionChange = { descriptor, position in
            saves.append((descriptor, position))
            frameAtSave = panel.frame
            var saved = latest
            saved.position = position
            floating.update(display: display, preferences: saved, snapshot: snapshot, uiTestMode: true)
        }
        grip.mouseDown(with: down)
        floating.update(display: display, preferences: DisplayPreferences(mode: .compactIcon), snapshot: snapshot, uiTestMode: true)
        floating.hide()
        floating.update(display: display, preferences: latest, snapshot: snapshot, uiTestMode: true)
        check("drag_down_does_not_finish_or_persist", saves.isEmpty)
        check("drag_defers_content_frame_and_visibility_changes", panel.contentView === content && panel.frame == initial && panel.isVisible)
        let dx = min(60, max(0, (display.descriptor.frame.width - initial.width) / 5))
        let dy = -min(60, display.descriptor.frame.height / 10)
        pointer = NSPoint(x: start.x + dx, y: start.y + dy)
        grip.mouseDragged(with: motion)
        let first = panel.frame
        for _ in 0..<30 { grip.mouseDragged(with: motion) }
        check("drag_repeated_screen_sample_does_not_drift", close(panel.frame, first)
              && close(panel.frame, anchor.frame(at: pointer, on: display.descriptor)) && saves.isEmpty)
        let samplesBeforeHold = buttonSamples
        let sampledHeldButton = await wait { buttonSamples >= samplesBeforeHold + 3 }
        check("drag_held_button_survives_recovery_samples", sampledHeldButton
              && panel.contentView === content && panel.isVisible && close(panel.frame, first) && saves.isEmpty)
        pointer = NSPoint(x: start.x + dx + 13, y: start.y + dy - 17)
        let released = anchor.frame(at: pointer, on: display.descriptor)
        let samplesBeforeRelease = buttonSamples
        afterReleasedSample = {
            // Queue only our own view's release, after the timer observes the
            // released button but before its next sample. No input is posted.
            Task { @MainActor in grip.mouseUp(with: up) }
        }
        pressedButtons = 0
        let releasedNormally = await wait { !saves.isEmpty }
        check("drag_released_sample_allows_queued_normal_mouse_up",
              releasedNormally && buttonSamples == samplesBeforeRelease + 1)
        check("drag_release_uses_final_pointer_and_saves_once", releasedNormally && saves.count == 1
              && frameAtSave.map { close($0, released) } == true && close(panel.frame, released))
        let samplesAfterRelease = buttonSamples
        grip.mouseUp(with: up)
        grip.cancelTracking()
        await pause(0.25)
        check("drag_late_mouse_up_does_not_save_twice_or_resume_sampling",
              releasedNormally && saves.count == 1 && buttonSamples == samplesAfterRelease)
        if let saved = saves.first {
            let restored = ControlLayout.place(requestedSize: panel.frame.size, on: saved.0,
                preferences: DisplayPreferences(mode: .toolbar, position: saved.1)).frame
            check("drag_release_position_round_trips_without_snapback", close(restored, panel.frame)
                  && saved.0.id == display.descriptor.id)
        } else { check("drag_release_position_round_trips_without_snapback", false) }

        guard let nextContent = panel.contentView,
              let nextGrip = descendants(nextContent).compactMap({ $0 as? GripView }).first else {
            check("drag_refreshed_grip_available", false)
            return
        }
        floating.onPositionChange = { descriptor, position in saves.append((descriptor, position)) }
        let otherDescriptor = DisplayDescriptor(id: "interaction-other-display", isBuiltIn: false,
            frame: display.descriptor.frame, visibleFrame: display.descriptor.visibleFrame,
            safeTopInset: display.descriptor.safeTopInset)
        let other = ConnectedDisplay(screen: display.screen, displayID: display.displayID,
                                     descriptor: otherDescriptor)
        let otherPreferences = DisplayPreferences(mode: .toolbar,
            position: StoredPosition(horizontalFraction: 0.25, topOffset: 160))
        pointer = NSPoint(x: panel.frame.minX + 9, y: panel.frame.midY)
        pressedButtons = 1
        nextGrip.mouseDown(with: down)
        floating.update(display: other, preferences: otherPreferences, snapshot: snapshot, uiTestMode: true)
        pointer.x += 30
        pointer.y -= 20
        nextGrip.mouseDragged(with: motion)
        pressedButtons = 0
        nextGrip.mouseUp(with: up)
        let otherFrame = ControlLayout.place(requestedSize: panel.frame.size, on: otherDescriptor,
                                             preferences: otherPreferences).frame
        check("drag_pending_display_keeps_its_own_saved_position", saves.count == 2
              && saves.last?.0.id == display.descriptor.id && close(panel.frame, otherFrame))
        if let current = panel.contentView.flatMap({ descendants($0).compactMap { $0 as? GripView }.first }) {
            pointer = NSPoint(x: panel.frame.minX + 9, y: panel.frame.midY)
            pressedButtons = 1
            current.mouseDown(with: down)
            let samplesBeforeStop = buttonSamples
            let sampledBeforeStop = await wait { buttonSamples > samplesBeforeStop }
            floating.hide()
            floating.stop()
            let samplesAtStop = buttonSamples
            pressedButtons = 0
            current.mouseUp(with: up)
            current.cancelTracking()
            floating.stop()
            await pause(0.25)
            check("drag_stop_balances_tracking_without_saving",
                  sampledBeforeStop && saves.count == 2 && !panel.isVisible && buttonSamples == samplesAtStop)
        } else { check("drag_stop_balances_tracking_without_saving", false) }
    }

    private func checkLostMouseUpRecovery(on display: ConnectedDisplay) async {
        var pointer = NSPoint.zero
        var pressedButtons = 1
        var samples = 0
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let floating = FloatingControl(pointerLocation: { pointer }, pressedButtons: {
            samples += 1
            return pressedButtons
        })
        defer { floating.onPositionChange = nil; floating.stop() }
        var saves = 0
        floating.onPositionChange = { _, _ in saves += 1 }
        let initialPreferences = DisplayPreferences(mode: .toolbar,
            position: StoredPosition(horizontalFraction: 0.5, topOffset: 60))
        let pendingPreferences = DisplayPreferences(mode: .compactIcon,
            position: StoredPosition(horizontalFraction: 0.3, topOffset: 150))
        floating.update(display: display, preferences: initialPreferences, snapshot: nil, uiTestMode: true)
        guard let panel = newPanel(excluding: existing) else {
            check("drag_lost_up_panel_available", false)
            return
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 9100, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = event(.leftMouseDown), let motion = event(.leftMouseDragged), let up = event(.leftMouseUp) else {
            check("drag_lost_up_events_available", false)
            return
        }

        for shouldHide in [false, true] {
            let kind = shouldHide ? "hide" : "update"
            floating.update(display: display, preferences: initialPreferences, snapshot: nil, uiTestMode: true)
            guard let content = panel.contentView,
                  let grip = descendants(content).compactMap({ $0 as? GripView }).first else {
                check("drag_lost_up_\(kind)_grip_available", false)
                return
            }
            let initial = panel.frame
            pointer = NSPoint(x: initial.minX + 9, y: initial.midY)
            pressedButtons = 1
            grip.mouseDown(with: down)
            pointer.y -= 40
            grip.mouseDragged(with: motion)
            let moved = panel.frame
            floating.update(display: display, preferences: pendingPreferences, snapshot: nil, uiTestMode: true)
            if shouldHide { floating.hide() }
            check("drag_lost_up_\(kind)_remains_deferred",
                  panel.contentView === content && panel.isVisible && close(panel.frame, moved)
                    && !close(moved, initial) && saves == 0)

            let samplesBeforeRelease = samples
            // A held right button must not keep a released left-button drag alive.
            pressedButtons = shouldHide ? 2 : 0
            // Deliberately omit mouseUp: exercise the real run-loop timer.
            let recovered = await wait {
                shouldHide ? !panel.isVisible : panel.contentView !== content
            }
            let expected = shouldHide ? initial
                : ControlLayout.place(requestedSize: NSSize(width: 54, height: 30),
                                      on: display.descriptor, preferences: pendingPreferences).frame
            check("drag_lost_up_applies_deferred_\(kind)",
                  recovered && samples == samplesBeforeRelease + 2
                    && close(panel.frame, expected) && panel.isVisible == !shouldHide)
            check("drag_lost_up_\(kind)_cancellation_does_not_save", recovered && saves == 0)

            let samplesAfterRecovery = samples
            let contentAfterRecovery = panel.contentView
            grip.mouseUp(with: up)
            grip.cancelTracking()
            await pause(0.25)
            check("drag_lost_up_\(kind)_late_release_is_inert_and_sampling_stops",
                  recovered && saves == 0 && samples == samplesAfterRecovery
                    && panel.contentView === contentAfterRecovery
                    && close(panel.frame, expected) && panel.isVisible == !shouldHide)
        }
    }

    private func checkKeyboard(on display: ConnectedDisplay) async {
        let session = RecordingTestMenuSession()
        let roots = await load(session)
        let entries = ["File", "Edit", "View"].compactMap { title in roots.entries.first { $0.title == title } }
        guard entries.count == 3 else { check("keyboard_ui_test_headings_available", false); return }
        let floating = FloatingControl()
        defer { floating.stop() }
        let disabled = MenuEntry(title: "Unavailable", isEnabled: false, hasSubmenu: true)
        let snapshot = MenuSnapshot(session: session, batch: MenuBatch(entries: [entries[0], disabled, entries[1], entries[2]], status: .uiTestData))
        floating.update(display: display,
            preferences: DisplayPreferences(mode: .toolbar, position: StoredPosition(horizontalFraction: 0.5, topOffset: 140)),
            snapshot: snapshot, uiTestMode: true)
        guard let initial = floating.heading(for: entries[0].id, session: session) else {
            check("keyboard_initial_heading_available", false); return
        }
        let pointer = toolbarScreenPoint(initial)
        _ = await wait { floating.heading(at: pointer, for: session) != nil }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let settings = SettingsWindowController(store: ConfigurationStore(defaults: nil, initial: .uiTest()), uiTestMode: true)
        defer { settings.close() }

        for cycle in 0..<3 {
            if cycle > 0, let frontmost, frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                settings.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                let gainedFocus = await wait { NSApp.isActive }
                settings.window?.orderOut(nil)
                frontmost.activate(options: [])
                let restoredFocus = await wait { NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost.processIdentifier }
                check("keyboard_settings_focus_round_trip_\(cycle)", gainedFocus && restoredFocus)
                await pause(0.15) // Allow activation/deactivation events to finish before tracking.
            }
            let tracking = ToolbarMenuTrackingSession(session: session,
                headingAtPoint: { floating.heading(at: $0, for: session) },
                adjacentHeading: { floating.adjacentHeading(to: $0, direction: $1, session: session) },
                isTargetCurrent: { true }, pointerLocation: { pointer }, pressedButtons: { 0 }, onNotice: { _ in })
            let probe = KeyboardTrackingProbe(tracking: tracking, windowNumber: initial.view.window?.windowNumber ?? 0,
                steps: cycle == 0 ? .navigation : cycle == 1 ? .emptyReturn : .escape)
            let before = session.actions.count
            check("keyboard_anchor_attached_cycle_\(cycle)", initial.view.window?.isVisible == true)
            floating.setMenuTracking(true)
            let timer = probe.makeTimer()
            tracking.run(initial: initial)
            timer.invalidate()
            floating.setMenuTracking(false)
            let name = cycle == 0 ? "arrows_submenus_wrap_disabled_headings_and_return"
                : cycle == 1 ? "return_without_selection_closes_menu" : "escape_after_arrow_switch_closes_menu"
            check("keyboard_\(name)", probe.completed && !probe.timedOut && session.actions.count == before + (cycle == 0 ? 1 : 0))
            check("keyboard_handler_removed_after_cycle_\(cycle)", (NSApp as? MenuApplication)?.toolbarMenuInput == nil)
            check("keyboard_preserves_frontmost_app_cycle_\(cycle)", NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost?.processIdentifier)
            if !probe.completed {
                checks.append(["name": "keyboard_last_state_\(cycle)", "status": "failed", "detail": probe.lastState,
                    "timedOut": probe.timedOut, "lastEventType": NSApp.currentEvent?.type.rawValue ?? 0,
                    "actions": session.actions.count - before])
            }
        }
    }

    private func checkToolbar(on display: ConnectedDisplay) async {
        let session = RecordingTestMenuSession()
        let roots = await load(session)
        let entries = ["File", "Edit", "View"].compactMap { title in roots.entries.first { $0.title == title } }
        guard entries.count == 3 else { check("hover_ui_test_headings_available", false); return }
        let snapshot = MenuSnapshot(session: session, batch: MenuBatch(entries: entries, status: .uiTestData))
        let preferences = DisplayPreferences(mode: .toolbar, position: StoredPosition(horizontalFraction: 0.5, topOffset: 60))
        let existing = Set(NSApp.windows.map { ObjectIdentifier($0) })
        let floating = FloatingControl()
        defer { floating.stop() }
        floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
        guard let panel = newPanel(excluding: existing), let content = panel.contentView else {
            check("hover_panel_available", false)
            return
        }
        let anchors = entries.compactMap { floating.heading(for: $0.id, session: session) }
        guard anchors.count == 3 else { check("hover_anchors_available", false); return }
        var pointer = toolbarScreenPoint(anchors[0])
        // Window-server hit testing lags orderFront. Wait for the actual visible
        // heading instead of starting the native popup against an unpresented panel.
        _ = await wait { floating.heading(at: pointer, for: session)?.entry.id == entries[0].id }
        var targetCurrent = true
        check("hover_hit_test_requires_captured_provider", floating.heading(at: pointer, for: session)?.entry.id == entries[0].id
              && floating.heading(at: pointer, for: TestMenuSession()) == nil)
        let tracking = ToolbarMenuTrackingSession(session: session,
            headingAtPoint: { floating.heading(at: $0, for: session) },
            adjacentHeading: { floating.adjacentHeading(to: $0, direction: $1, session: session) },
            isTargetCurrent: { targetCurrent }, pointerLocation: { pointer }, pressedButtons: { 0 }, onNotice: { _ in })
        var deferred = false
        let latest = MenuSnapshot(session: session, batch: MenuBatch(entries: Array(entries.dropLast()), status: .uiTestData))
        let probe = ToolbarTrackingProbe(tracking: tracking, anchors: anchors, mode: .switchAndInvoke,
            movePointer: { pointer = $0 }, changeTarget: { targetCurrent = false }, onFirstPopup: {
                let frame = panel.frame
                floating.update(display: display, preferences: preferences, snapshot: latest, uiTestMode: true)
                floating.hide()
                floating.update(display: display, preferences: preferences, snapshot: latest, uiTestMode: true)
                deferred = panel.contentView === content && panel.frame == frame && panel.isVisible
            })
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        floating.setMenuTracking(true)
        let timer = probe.makeTimer()
        tracking.run(initial: anchors[0])
        timer.invalidate()
        floating.setMenuTracking(false)
        check("hover_native_tracking_switches_two_siblings_without_clicks", !probe.timedOut && probe.visited == entries.map(\.id))
        check("hover_tracking_is_nonrecursive_and_keeps_identity", probe.reentrantRunRejected && tracking.identity == session.identity)
        check("hover_tracking_defers_refresh_for_entire_chain", deferred
              && floating.heading(for: entries[2].id, session: session) == nil)
        check("hover_submenu_command_uses_captured_provider_once", probe.nestedLoaded && probe.invoked
              && session.actions.count == 1 && session.actions.first?.target == session.identity)
        let actionCount = session.actions.count
        let staleSent = probe.sendStaleAction()
        await pause()
        check("hover_cancelled_sibling_cannot_send_stale_command", staleSent && session.actions.count == actionCount)
        check("hover_native_popups_preserve_frontmost_app", before == NSWorkspace.shared.frontmostApplication?.processIdentifier)

        for mode in [ToolbarTrackingProbe.Mode.dismiss, .escape, .targetChange, .commandTargetChange] {
            floating.update(display: display, preferences: preferences, snapshot: snapshot, uiTestMode: true)
            let currentAnchors = entries.compactMap { floating.heading(for: $0.id, session: session) }
            guard currentAnchors.count == 3 else { check("hover_repeat_anchors_available", false); return }
            pointer = toolbarScreenPoint(currentAnchors[0])
            targetCurrent = true
            var notices: [String?] = []
            let run = ToolbarMenuTrackingSession(session: session,
                headingAtPoint: { floating.heading(at: $0, for: session) },
                adjacentHeading: { floating.adjacentHeading(to: $0, direction: $1, session: session) },
                isTargetCurrent: { targetCurrent }, pointerLocation: { pointer }, pressedButtons: { 0 },
                onNotice: { notices.append($0) })
            let probe = ToolbarTrackingProbe(tracking: run, anchors: currentAnchors, mode: mode,
                movePointer: { pointer = $0 }, changeTarget: { targetCurrent = false }, onFirstPopup: {})
            floating.setMenuTracking(true)
            let timer = probe.makeTimer()
            run.run(initial: currentAnchors[0])
            timer.invalidate()
            floating.setMenuTracking(false)
            let checkName = mode == .dismiss ? "hover_native_dismissal_does_not_reopen"
                : mode == .escape ? "hover_escape_ends_tracking_without_reopen"
                : mode == .targetChange ? "hover_target_change_cancels_entire_session"
                : "hover_command_target_change_reports_refusal"
            let noticeCorrect = mode == .commandTargetChange
                ? probe.invoked && notices == ["The app or menu changed. Reopen the menu and try again."]
                : notices.isEmpty
            check(checkName,
                  !probe.timedOut && probe.visited.count == 1 && run.currentMenu == nil
                    && session.actions.count == actionCount && noticeCorrect)
        }
    }
}

private final class TargetApplication: NSRunningApplication, @unchecked Sendable {
    private let pid: pid_t
    private let bundle: String
    var didTerminate = false

    init(pid: pid_t, bundle: String) {
        self.pid = pid
        self.bundle = bundle
        super.init()
    }

    override var processIdentifier: pid_t { pid }
    override var bundleIdentifier: String? { bundle }
    override var isTerminated: Bool { didTerminate }
    override var launchDate: Date? { Date(timeIntervalSince1970: 1) }
}

private final class ScriptedRootSession: MenuSession {
    let identity: AppIdentity
    let applicationName = "Scripted readiness provider"
    private let failures: Int?
    private var pending: [(MenuBatch) -> Void] = []
    private(set) var loadCount = 0
    private(set) var actionRequests = 0
    var actionNotice: String? = "Scripted provider: no external command was sent."

    init(pid: Int32, launch: TimeInterval = 1, failures: Int? = nil) {
        identity = AppIdentity(processIdentifier: pid, bundleIdentifier: "io.github.skylarstein.centermymenu.qa.scripted", launchTime: launch)
        self.failures = failures
    }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        loadCount += 1
        if let failures {
            let batch = loadCount <= failures ? MenuBatch(entries: [], status: .unavailable)
                : MenuBatch(entries: [MenuEntry(title: "Ready", hasSubmenu: true)])
            deliverToMenuRunLoop { completion(batch) }
        } else {
            pending.append(completion)
        }
    }

    func completeNext(_ batch: MenuBatch) {
        guard !pending.isEmpty else { return }
        let completion = pending.removeFirst()
        deliverToMenuRunLoop { completion(batch) }
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        actionRequests += 1
        let notice = actionNotice
        deliverToMenuRunLoop { completion(notice) }
    }
}

private final class RecordingTestMenuSession: MenuSession {
    private let testSession = TestMenuSession()
    var identity: AppIdentity { testSession.identity }
    var applicationName: String { testSession.applicationName }
    private(set) var actions: [CapturedMenuAction] = []

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        testSession.loadChildren(of: parentID, completion: completion)
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        actions.append(action)
        testSession.perform(action, completion: completion)
    }
}

@MainActor
private func toolbarScreenPoint(_ heading: ToolbarMenuHeading) -> NSPoint {
    let view = heading.view
    let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    return view.window?.convertPoint(toScreen: point) ?? .zero
}

@MainActor
private final class ToolbarTrackingProbe: NSObject {
    enum Mode { case switchAndInvoke, dismiss, escape, targetChange, commandTargetChange }
    private let tracking: ToolbarMenuTrackingSession
    private let anchors: [ToolbarMenuHeading]
    private let mode: Mode
    private let movePointer: (NSPoint) -> Void
    private let changeTarget: () -> Void
    private let onFirstPopup: () -> Void
    private let deadline = ProcessInfo.processInfo.systemUptime + 3
    private var requestedNested = false
    private var changedTarget = false
    private var staleItem: NSMenuItem?
    private var staleTarget: AnyObject?
    private var staleSelector: Selector?
    private(set) var visited: [UUID] = []
    private(set) var timedOut = false
    private(set) var nestedLoaded = false
    private(set) var invoked = false
    private(set) var reentrantRunRejected = false

    init(tracking: ToolbarMenuTrackingSession, anchors: [ToolbarMenuHeading], mode: Mode,
         movePointer: @escaping (NSPoint) -> Void, changeTarget: @escaping () -> Void,
         onFirstPopup: @escaping () -> Void) {
        self.tracking = tracking
        self.anchors = anchors
        self.mode = mode
        self.movePointer = movePointer
        self.changeTarget = changeTarget
        self.onFirstPopup = onFirstPopup
    }

    func makeTimer() -> Timer {
        let timer = Timer(timeInterval: 0.015, target: self,
                          selector: #selector(sample(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    func sendStaleAction() -> Bool {
        guard let staleSelector, let staleTarget, let staleItem else { return false }
        return NSApp.sendAction(staleSelector, to: staleTarget, from: staleItem)
    }

    @objc private func sample(_ timer: Timer) {
        if ProcessInfo.processInfo.systemUptime >= deadline {
            timedOut = true
            timer.invalidate()
            tracking.cancel()
            return
        }
        guard let menu = tracking.currentMenu, let heading = tracking.currentHeading,
              !menu.items.contains(where: { $0.title == "Loading menus…" }) else { return }
        if visited.last != heading.entry.id {
            visited.append(heading.entry.id)
            if visited.count == 1 {
                staleItem = menu.items.first { $0.action != nil && $0.isEnabled }
                staleTarget = staleItem?.target
                staleSelector = staleItem?.action
                tracking.run(initial: anchors[0]) // Must reject a reentrant run, not nest popUp.
                reentrantRunRejected = tracking.currentMenu === menu
                onFirstPopup()
            }
        }
        switch mode {
        case .dismiss:
            timer.invalidate()
            menu.cancelTracking()
        case .escape:
            if !changedTarget {
                changedTarget = true
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: anchors[0].view.window?.windowNumber ?? 0, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    NSApp.postEvent(event, atStart: true)
                }
            }
        case .targetChange:
            if !changedTarget {
                changedTarget = true
                changeTarget()
                movePointer(toolbarScreenPoint(anchors[1]))
            }
        case .commandTargetChange:
            guard let item = menu.items.first(where: { $0.isEnabled && $0.action != nil }),
                  let action = item.action else { return }
            // Change the target immediately before selection, without letting the
            // tracking timer cancel first. The provider must never receive this action.
            changeTarget()
            invoked = NSApp.sendAction(action, to: item.target, from: item)
            timer.invalidate()
            menu.cancelTrackingWithoutAnimation()
        case .switchAndInvoke:
            if heading.entry.id == anchors[0].entry.id {
                movePointer(toolbarScreenPoint(anchors[1]))
            } else if heading.entry.id == anchors[1].entry.id {
                movePointer(toolbarScreenPoint(anchors[2]))
            } else if let submenu = menu.item(withTitle: "Presentation")?.submenu {
                if !requestedNested {
                    requestedNested = true
                    submenu.delegate?.menuNeedsUpdate?(submenu)
                    return
                }
                guard let item = submenu.item(withTitle: "Compact"), let action = item.action else { return }
                nestedLoaded = item.state == .on && item.isEnabled
                invoked = NSApp.sendAction(action, to: item.target, from: item)
                movePointer(toolbarScreenPoint(anchors[0]))
                timer.invalidate()
                menu.cancelTracking()
            }
        }
    }
}
#endif
