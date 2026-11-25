import AppKit
import ApplicationServices
import Darwin
import CenterMyMenuCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let options: LaunchOptions
    private let store: ConfigurationStore
    private let tracker = AppTargetTracker()
    private let accessibility = AXMenuService()
    private let rootLoader = RootMenuLoader()
    private let floating = FloatingControls()
    private let displayMonitor = DisplayConfigurationMonitor()
    private lazy var activeDisplayMonitor = ActiveDisplayMonitor(
        currentID: { [weak self] in ConnectedDisplay.activeID(in: self?.displays ?? []) },
        onChange: { [weak self] in
            self?.renderFloating()
            self?.refreshSettings()
        })
    private var statusItem: NSStatusItem?
    private var statusMenuAdapter: NativeMenuAdapter?
    private var statusMenuTracking = false
    private var settings: SettingsWindowController?
    private var displays: [ConnectedDisplay] = []
    private var snapshot: MenuSnapshot?
    private var trusted = false
    private var permissionTimer: Timer?
    private var menuTracking = false
    private var rootLoadingSuspended = false
    private var headingTracking: ToolbarMenuTrackingSession?
    private var terminating = false
    private var lastRootRead: TimeInterval = 0
    private var lastNotice: String?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var menuBarOwnerObservation: NSKeyValueObservation?
    private var runtimeChecks: RuntimeChecks?

    init(options: LaunchOptions, store: ConfigurationStore? = nil) {
        self.options = options
        self.store = store ?? ((options.uiTestMode || options.fixtureCheckOutput != nil)
            ? ConfigurationStore(defaults: nil, initial: .uiTest())
            : ConfigurationStore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        trusted = AXIsProcessTrusted()
        displays = ConnectedDisplay.current()
        #if QA_CHECKS
        if let output = options.fullScreenCheckOutput {
            RuntimeChecks().startFullScreenCheck(outputPath: output)
            return
        }
        if let directory = options.uiSmokeDirectory {
            let checks = RuntimeChecks()
            runtimeChecks = checks
            if options.settingsCheckOnly {
                checks.startUISmoke(directory: directory, screenshots: true,
                                    interactionChecksPassed: true, settingsOnly: true)
                return
            }
            InteractionRuntimeChecks.start(directory: directory) { passed in
                checks.startUISmoke(directory: directory, screenshots: true, interactionChecksPassed: passed)
            }
            return
        }
        #endif
        if let output = options.fixtureCheckOutput {
            let checks = RuntimeChecks()
            runtimeChecks = checks
            checks.startFixture(outputPath: output, recordPath: options.fixtureRecordPath)
            return
        }
        if options.uiTestMode { lastNotice = "UI test mode — known menus, no external app actions." }
        installMainMenu()
        installStatusItem()
        connectControls()
        observeChanges()
        updatePermissionTimer()
        updateRootLoadingSuspension()
        refreshTarget(force: true)
        renderFloating()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        permissionTimer?.invalidate()
        displayMonitor.stop()
        activeDisplayMonitor.stop()
        menuBarOwnerObservation?.invalidate()
        menuBarOwnerObservation = nil
        rootLoader.stop()
        headingTracking?.cancel()
        if runtimeChecks == nil { floating.stop() }
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Center My Menu", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Center My Menu")
        appMenu.addItem(utilityItem("About Center My Menu", action: #selector(openAbout(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(utilityItem("Settings…", action: #selector(openSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(utilityItem("Quit Center My Menu", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        // A nil target routes Close to the focused window through the responder chain.
        let closeItem = NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(closeItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        NSApp.mainMenu = main
    }

    @discardableResult
    func installStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.behavior = [] // No removalAllowed: the escape hatch must remain present.
        item.autosaveName = "CenterMyMenu.PersistentStatusItem"
        item.isVisible = true
        if let button = item.button {
            button.image = MenuIcon.templateImage(accessibilityDescription: "Center My Menu")
            button.setAccessibilityLabel(options.uiTestMode ? "Center My Menu — UI Test" : "Center My Menu")
        }
        let menu = NSMenu(title: "Center My Menu")
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusTooltip()
        return item
    }

    private func connectControls() {
        rootLoader.onRead = { [weak self] in
            self?.lastRootRead = ProcessInfo.processInfo.systemUptime
        }
        rootLoader.onRetry = { [weak self] identity in
            guard let self, !self.terminating, !self.menuTracking else { return }
            self.recheckPermission()
            self.refreshTarget(force: true, retrying: identity)
        }
        rootLoader.onSnapshot = { [weak self] value in
            guard let self, !self.terminating else { return }
            if !self.options.uiTestMode {
                let current = self.tracker.capture().map { identity(of: $0) }
                    ?? AppIdentity(processIdentifier: 0, bundleIdentifier: nil, launchTime: nil)
                // Workspace notifications may be queued behind a tracking loop.
                // Do not publish an old target even before its notification runs.
                guard current == value.session.identity else {
                    self.refreshTarget(force: false)
                    return
                }
            }
            self.snapshot = value
            self.renderFloating()
            self.refreshSettings()
            if value.batch.status == .permissionRequired { self.recheckPermission() }
        }
        floating.onRootMenu = { [weak self] view in self?.showRootMenu(in: view) }
        floating.onHeadingMenu = { [weak self] control, session, entry, view in
            self?.showHeading(control: control, session: session, entry: entry, in: view)
        }
        floating.onPositionChange = { [weak self] display, position in
            guard let self else { return }
            self.store.value.positions[display.id] = position
            self.configurationChanged()
        }
        floating.onHover = { [weak self] in
            guard let self, !self.menuTracking,
                  ProcessInfo.processInfo.systemUptime - self.lastRootRead > 2 else { return }
            self.recheckPermission()
            self.refreshTarget(force: true)
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         handler: @escaping (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { notification in
            DispatchQueue.main.async { handler(notification) }
        }
        observers.append((center, token))
    }

    private func observeChanges() {
        displayMonitor.start { [weak self] in self?.displaysChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        // Menu ownership and keyboard focus can change independently. Read the
        // live owner when the callback runs, rather than caching an event's app.
        menuBarOwnerObservation = NSWorkspace.shared.observe(\.menuBarOwningApplication) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.recheckPermission()
                self?.refreshTarget(force: false)
            }
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            guard let self else { return }
            self.recheckPermission()
            self.refreshTarget(force: false)
        }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] _ in
            // Capture the actual menu-bar owner, not an unrelated background launch.
            self?.refreshTarget(force: false)
        }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { [weak self] _ in
            self?.refreshTarget(force: false)
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.displaysChanged()
            self?.refreshTarget(force: true)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in self?.displaysChanged() }
        observe(.default, NSApplication.didBecomeActiveNotification) { [weak self] _ in
            self?.recheckPermission()
            self?.refreshTarget(force: false) // Suspend external readiness retries while Settings is active.
            self?.refreshSettings()
        }
    }

    private func displaysChanged() {
        headingTracking?.cancel()
        displays = ConnectedDisplay.current()
        renderFloating()
        refreshSettings()
    }

    private func capturedSession() -> MenuSession {
        let target = tracker.capture() // Capture BEFORE any popup; never select our own application.
        if options.uiTestMode { return TestMenuSession() }
        let targetIdentity = target.map { identity(of: $0) }
            ?? AppIdentity(processIdentifier: 0, bundleIdentifier: nil, launchTime: nil)
        let name = target?.localizedName ?? target?.bundleIdentifier ?? "None"
        if !trusted {
            return UnavailableMenuSession(identity: targetIdentity, name: name,
                message: "Allow Center My Menu to read and control app menus.",
                status: .permissionRequired)
        }
        guard let target else {
            return UnavailableMenuSession(identity: targetIdentity, name: "None",
                message: "Switch to another application, then reopen this menu.", status: .unavailable)
        }
        return accessibility.session(for: target) { [weak self] in
            guard let self, !self.terminating else { return }
            self.lastNotice = nil
            self.recheckPermission()
            self.refreshTarget(force: true)
        }
    }

    private func refreshTarget(force: Bool, retrying retryIdentity: AppIdentity? = nil) {
        guard !terminating else { return }
        let session = capturedSession()
        let retryAllowed = !options.uiTestMode && trusted && tracker.allowsMenuRetry(for: session.identity)
        // A timer for A must not force a read of an inactive remembered A, or
        // continue A's backoff against B. A changed context starts independently.
        let shouldForce = retryIdentity.map { $0 == session.identity && retryAllowed } ?? force
        rootLoader.request(session: session, accessAllowed: trusted || options.uiTestMode,
                           retryAllowed: retryAllowed, force: shouldForce)
    }

    private func renderFloating() {
        guard !terminating, !menuTracking else { return }
        activeDisplayMonitor.setEnabled(store.value.displayScope == .active
            && store.value.mode != .statusOnly && displays.count > 1)
        floating.update(displays: displays, activeDisplayID: ConnectedDisplay.activeID(in: displays),
                        configuration: store.value, snapshot: snapshot, uiTestMode: options.uiTestMode)
    }

    private func configurationChanged() {
        displays = ConnectedDisplay.current()
        updateRootLoadingSuspension()
        renderFloating()
        refreshSettings()
    }

    private func updateRootLoadingSuspension() {
        let suspended = menuTracking || store.value.mode == .statusOnly
        guard suspended != rootLoadingSuspended else { return }
        rootLoadingSuspended = suspended
        // Recapture the current target while still suspended, then start one
        // fresh read. Permission polling and on-demand status menus are separate.
        if !suspended { refreshTarget(force: true) }
        rootLoader.setSuspended(suspended)
    }

    private func recheckPermission() {
        guard !terminating else { return }
        let next = AXIsProcessTrusted()
        let changed = next != trusted
        trusted = next
        updatePermissionTimer()
        if changed {
            if !next { headingTracking?.cancel() }
            refreshTarget(force: true)
            renderFloating()
            refreshSettings()
        }
        updateStatusTooltip()
    }

    private func updatePermissionTimer() {
        if trusted {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { self?.recheckPermission() }
            }
            permissionTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateStatusTooltip() {
        var text = options.uiTestMode ? "Center My Menu — UI Test" : "Center My Menu"
        text += trusted ? " · Access granted" : " · Access required"
        if let lastNotice { text += "\n" + lastNotice }
        statusItem?.button?.toolTip = text
    }

    private func report(_ message: String?) {
        lastNotice = message
        recheckPermission()
        refreshSettings()
    }

    private func refreshSettings() {
        settings?.refresh(displays: displays, trusted: trusted,
                          notice: lastNotice)
    }

    private func utilityItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func adapter(for session: MenuSession) -> NativeMenuAdapter {
        NativeMenuAdapter(session: session, fontSize: store.value.fontSize,
            permissionRequestItem: { [weak self] in self?.makePermissionRequestItem() }) { [weak self] message in self?.report(message) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu, !menuTracking else { return }
        recheckPermission()
        statusMenuAdapter?.invalidate()
        let (contents, adapter) = makeStatusMenu(for: capturedSession())
        statusMenuAdapter = adapter
        menu.removeAllItems()
        for item in contents.items {
            contents.removeItem(item)
            menu.addItem(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        guard beginPopupTracking() else { menu.cancelTrackingWithoutAnimation(); return }
        statusMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem?.menu, statusMenuTracking else { return }
        statusMenuTracking = false
        // AppKit delivers the selected action after closing. Keep its adapter until
        // the next opening and let the action enqueue before resuming root reads.
        DispatchQueue.main.async { [weak self] in self?.endPopupTracking() }
    }

    func makeStatusMenu(for session: MenuSession) -> (NSMenu, NativeMenuAdapter) {
        // The entire status menu tree uses untouched AppKit fonts and appearance.
        let adapter = NativeMenuAdapter(session: session,
            permissionRequestItem: { [weak self] in self?.makePermissionRequestItem() }) { [weak self] message in self?.report(message) }
        let menu = NSMenu(title: "Center My Menu")
        menu.autoenablesItems = false
        if options.uiTestMode { menu.addItem(NativeMenuAdapter.informationItem("UI TEST — no external app actions")) }
        let current = NSMenuItem(title: session.applicationName, action: nil, keyEquivalent: "")
        current.submenu = adapter.makeMenu()
        menu.addItem(current)
        menu.addItem(.separator())
        if !trusted && !options.uiTestMode {
            menu.addItem(makePermissionRequestItem())
            menu.addItem(.separator())
        }
        if let lastNotice {
            menu.addItem(NativeMenuAdapter.informationItem(lastNotice))
            menu.addItem(.separator())
        }
        menu.addItem(utilityItem("Settings…", action: #selector(openSettings(_:))))
        menu.addItem(.separator())
        menu.addItem(utilityItem("About Center My Menu", action: #selector(openAbout(_:))))
        menu.addItem(utilityItem("Quit Center My Menu", action: #selector(quit(_:))))
        return (menu, adapter)
    }

    private func showRootMenu(in view: NSView) {
        guard !menuTracking else { return }
        recheckPermission()
        let session = capturedSession()
        let adapter = adapter(for: session)
        popup(rootMenu(using: adapter), adapter: adapter, in: view)
    }

    private func rootMenu(using adapter: NativeMenuAdapter) -> NSMenu {
        guard !trusted && !options.uiTestMode else { return adapter.makeMenu() }
        let menu = NSMenu(title: "Center My Menu")
        menu.autoenablesItems = false
        menu.addItem(NativeMenuAdapter.informationItem("Allow Center My Menu to read and control app menus."))
        menu.addItem(.separator())
        menu.addItem(makePermissionRequestItem())
        return menu
    }

    private func showHeading(control: FloatingControl, session: MenuSession, entry: MenuEntry, in view: NSView) {
        guard !menuTracking else { return }
        recheckPermission()
        let captured = capturedSession()
        // A toolbar snapshot may lag a just-switched app. Never send its label to a new target.
        if captured.identity != session.identity || (!trusted && !options.uiTestMode) {
            let adapter = adapter(for: captured)
            popup(rootMenu(using: adapter), adapter: adapter, in: view)
            return
        }
        guard let initial = control.heading(for: entry.id, session: session), initial.view === view else { return }
        let capturedIdentity = session.identity
        let tracking = ToolbarMenuTrackingSession(session: session, fontSize: store.value.fontSize,
            headingAtPoint: { [weak control] point in control?.heading(at: point, for: session) },
            adjacentHeading: { [weak control] id, direction in
                control?.adjacentHeading(to: id, direction: direction, session: session)
            },
            isTargetCurrent: { [weak self] in self?.isHeadingTargetCurrent(capturedIdentity) ?? false },
            permissionRequestItem: { [weak self] in self?.makePermissionRequestItem() },
            onNotice: { [weak self] message in self?.report(message) })
        withPopupTracking {
            headingTracking = tracking
            defer { headingTracking = nil }
            tracking.run(initial: initial)
        }
    }

    private func isHeadingTargetCurrent(_ capturedIdentity: AppIdentity) -> Bool {
        guard !terminating else { return false }
        if options.uiTestMode { return true }
        guard trusted, AXIsProcessTrusted(), let target = tracker.capture() else { return false }
        return identity(of: target) == capturedIdentity
    }

    private func withPopupTracking(_ body: () -> Void) {
        guard beginPopupTracking() else { return }
        defer { endPopupTracking() }
        body()
    }

    private func beginPopupTracking() -> Bool {
        guard !terminating, !menuTracking else { return false }
        menuTracking = true
        updateRootLoadingSuspension() // Leave AX available for lazy submenus and the chosen command.
        floating.setMenuTracking(true)
        return true
    }

    private func endPopupTracking() {
        menuTracking = false
        floating.setMenuTracking(false)
        renderFloating()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.terminating, !self.menuTracking else { return }
            // The selected command's already-enqueued main callback goes first.
            // Recapture lifecycle state before resuming any pending root read.
            self.recheckPermission()
            self.updateRootLoadingSuspension()
        }
    }

    private func popup(_ menu: NSMenu, adapter: NativeMenuAdapter, in view: NSView) {
        defer { adapter.invalidate() }
        menu.font = .menuFont(ofSize: CGFloat(store.value.fontSize))
        withPopupTracking {
            let location = MenuPopupPlacement.location(below: view)
            // Retains delegates, action targets, the captured app, and AX objects throughout tracking.
            _ = withExtendedLifetime(adapter) {
                menu.popUp(positioning: nil, at: location, in: view)
            }
        }
    }

    @objc private func openAbout(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.tracker.capture()
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let credits = NSAttributedString(string: "https://github.com/skylarstein/center-my-menu", attributes: [
                .link: URL(string: "https://github.com/skylarstein/center-my-menu")!,
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .paragraphStyle: paragraph
            ])
            NSApp.orderFrontStandardAboutPanel(options: [
                .applicationName: "Center My Menu",
                .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.1",
                .version: "",
                .credits: credits
            ])
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in self?.presentSettings() }
    }

    private func presentSettings() {
        _ = tracker.capture()
        if settings == nil {
            let controller = SettingsWindowController(store: store, uiTestMode: options.uiTestMode)
            controller.onPreferencesChanged = { [weak self] in self?.configurationChanged() }
            controller.onPermissionRequest = { [weak self] in self?.requestAccessibility() }
            settings = controller
        }
        recheckPermission()
        refreshSettings()
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true) // Only explicit Settings opens activate this app.
    }

    private func makePermissionRequestItem() -> NSMenuItem {
        utilityItem("Grant access…", action: #selector(requestPermission(_:)))
    }

    @objc private func requestPermission(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in self?.requestAccessibility() }
    }

    private func requestAccessibility() {
        guard !options.uiTestMode else { return }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        recheckPermission()
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

}
