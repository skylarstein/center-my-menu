import AppKit
import ServiceManagement
import CenterMyMenuCore

@MainActor
private final class FlippedSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

// Draw with semantic colors so the groups follow the window's light/dark appearance.
@MainActor
private final class SettingsGroup: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.025).setFill()
        outline.fill()
        NSColor.labelColor.withAlphaComponent(0.16).setStroke()
        outline.lineWidth = 1
        outline.stroke()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    var onPreferencesChanged: (() -> Void)?
    var onPermissionRequest: (() -> Void)?

    private let store: ConfigurationStore
    private let uiTestMode: Bool
    private var currentDisplays: [ConnectedDisplay] = []
    private let displayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let builtInToggle = NSButton(checkboxWithTitle: "Never show on built-in display", target: nil, action: nil)
    private let fullScreenToggle = NSButton(checkboxWithTitle: "Hide floating toolbar in full screen", target: nil, action: nil)
    private let loginToggle = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset to Top Center", target: nil, action: nil)
    private let permissionButton = NSButton(title: "Open Permission Settings…", target: nil, action: nil)
    private let loginSettingsButton = NSButton(title: "Login Items Settings…", target: nil, action: nil)
    private let displayNote = NSTextField(wrappingLabelWithString: "")
    private let permissionIcon = NSImageView()
    private let permissionStatus = NSTextField(wrappingLabelWithString: "")
    private let operationNotice = NSTextField(wrappingLabelWithString: "")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private var loginError: String?
    private var loginBusy = false
    private let settingsScroll = NSScrollView()
    private var lastFittedContentSize: NSSize?

    init(store: ConfigurationStore, uiTestMode: Bool) {
        self.store = store
        self.uiTestMode = uiTestMode
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: uiTestMode ? 710 : 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = uiTestMode ? "Center My Menu (UI Test)" : "Center My Menu"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 620, height: 400)
        super.init(window: window)
        buildInterface()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildInterface() {
        guard let window else { return }
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = content
        let scroll = settingsScroll
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        content.addSubview(scroll)
        let document = FlippedSettingsDocument(frame: NSRect(x: 0, y: 0, width: 620, height: 550))
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
        func add(_ view: NSView, fill: Bool = false) {
            stack.addArrangedSubview(view)
            if fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        let title = NSTextField(labelWithString: uiTestMode ? "Center My Menu (UI Test)" : "Center My Menu")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let appIcon = NSImageView()
        appIcon.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyDown
        appIcon.setAccessibilityElement(false)
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 48),
            appIcon.heightAnchor.constraint(equalToConstant: 48)
        ])
        add(row([appIcon, title]))
        themePopup.addItems(withTitles: ["System Default", "Dark", "Light"])
        themePopup.setAccessibilityIdentifier("themePicker")
        themePopup.setAccessibilityLabel("Theme")
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        fontSizePopup.addItems(withTitles: Configuration.fontSizes.map { "\($0) pt" })
        fontSizePopup.setAccessibilityIdentifier("fontSizePicker")
        fontSizePopup.setAccessibilityLabel("Menu font size")
        fontSizePopup.toolTip = "Text size for floating controls and their menus. The status-icon menu uses macOS defaults. Default: 13 pt."
        fontSizePopup.target = self
        fontSizePopup.action = #selector(fontSizeChanged(_:))
        add(group("Appearance", views: [
            settingRow("Theme:", control: themePopup), divider(),
            settingRow("Size:", control: fontSizePopup)
        ]), fill: true)

        displayPopup.addItems(withTitles: ["Widest Display", "Active Display", "All Displays"])
        displayPopup.setAccessibilityIdentifier("displayScopePicker")
        modePopup.addItems(withTitles: ["Icon", "Menu Toolbar", "Hidden"])
        modePopup.setAccessibilityIdentifier("presentationModePicker")
        displayPopup.setAccessibilityLabel("Display")
        modePopup.setAccessibilityLabel("Mode")
        builtInToggle.setAccessibilityIdentifier("neverShowOnBuiltInDisplay")
        builtInToggle.target = self
        builtInToggle.action = #selector(builtInChanged(_:))
        fullScreenToggle.setAccessibilityIdentifier("hideInFullScreen")
        fullScreenToggle.target = self
        fullScreenToggle.action = #selector(fullScreenChanged(_:))
        displayNote.setAccessibilityIdentifier("displayRoutingNote")
        add(group("Display & Position", views: [
            settingRow("Display:", control: displayPopup), divider(),
            settingRow("Mode:", control: modePopup),
            builtInToggle, fullScreenToggle, displayNote,
            note("Drag the grip to move the toolbar. Positions are saved per display. The default overlays the menu bar. On notched displays, it stays below the notch."),
            resetButton
        ]), fill: true)
        loginStatus.setAccessibilityIdentifier("loginStatus")
        permissionIcon.imageScaling = .scaleProportionallyDown
        permissionIcon.setAccessibilityElement(false) // The status text conveys the same information.
        permissionIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            permissionIcon.widthAnchor.constraint(equalToConstant: 16),
            permissionIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
        let accessSummary = row([NSTextField(labelWithString: "App permissions:"), permissionIcon, permissionStatus])
        permissionStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let accessRow = row([accessSummary, NSView(), permissionButton])
        add(group("Startup & Privacy", views: [
            row([loginToggle, NSView(), loginSettingsButton]), loginStatus,
            divider(), accessRow
        ]), fill: true)
        operationNotice.setAccessibilityIdentifier("operationNotice")
        operationNotice.isHidden = true
        add(operationNotice, fill: true)
        if uiTestMode {
            add(note("UI test mode uses in-memory preferences, needs no app permissions, and never executes external app commands or changes login registration."), fill: true)
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .right
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(versionLabel)
        NSLayoutConstraint.activate([
            versionLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            versionLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -4)
        ])

        for field in [displayNote, loginStatus, operationNotice] {
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.maximumNumberOfLines = 0
        }
        for control in [displayPopup, modePopup] { control.target = self }
        displayPopup.action = #selector(displayChanged(_:))
        modePopup.action = #selector(modeChanged(_:))
        resetButton.target = self
        resetButton.action = #selector(resetPosition(_:))
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission(_:))
        loginToggle.target = self
        loginToggle.action = #selector(changeLogin(_:))
        loginToggle.allowsMixedState = true
        loginSettingsButton.target = self
        loginSettingsButton.action = #selector(openLoginSettings(_:))
        permissionButton.isEnabled = !uiTestMode
        loginSettingsButton.isEnabled = !uiTestMode
    }

    private func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        return field
    }

    private func section(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14, weight: .semibold)
        return field
    }

    private func group(_ title: String, views: [NSView]) -> NSView {
        let group = SettingsGroup()
        let contents = NSStackView()
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 8
        contents.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(contents)
        let heading = section(title)
        contents.addArrangedSubview(heading)
        contents.setCustomSpacing(12, after: heading)
        for view in views {
            contents.addArrangedSubview(view)
            // Buttons keep their native size; rows and help text use the group width.
            if !(view is NSButton) {
                view.widthAnchor.constraint(equalTo: contents.widthAnchor).isActive = true
            }
        }
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: group.leadingAnchor, constant: 16),
            contents.trailingAnchor.constraint(equalTo: group.trailingAnchor, constant: -16),
            contents.topAnchor.constraint(equalTo: group.topAnchor, constant: 12),
            contents.bottomAnchor.constraint(equalTo: group.bottomAnchor, constant: -12)
        ])
        return group
    }

    private func settingRow(_ title: String, control: NSPopUpButton) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 90).isActive = true
        control.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return row([label, control, NSView()])
    }

    private func divider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        return row
    }

    func refresh(displays: [ConnectedDisplay], trusted: Bool, notice: String?) {
        currentDisplays = displays
        builtInToggle.state = store.value.neverShowOnBuiltInDisplay ? .on : .off
        fullScreenToggle.state = store.value.hideInFullScreen ? .on : .off
        operationNotice.stringValue = notice ?? ""
        operationNotice.isHidden = operationNotice.stringValue.isEmpty
        window?.appearance = store.value.theme.appearance
        themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: store.value.theme) ?? 0)
        fontSizePopup.selectItem(at: store.value.fontSize - Configuration.fontSizes.lowerBound)
        displayPopup.selectItem(at: DisplayScope.allCases.firstIndex(of: store.value.displayScope) ?? 0)
        modePopup.selectItem(at: PresentationMode.allCases.firstIndex(of: store.value.mode) ?? 0)
        let targets = store.value.targetDisplays(in: displays.map(\.descriptor),
            activeDisplayID: ConnectedDisplay.activeID(in: displays))
        resetButton.isEnabled = store.value.mode != .statusOnly && !targets.isEmpty
        if store.value.mode == .statusOnly {
            displayNote.stringValue = "Menus remain available from the status icon."
        } else if displays.isEmpty {
            displayNote.stringValue = "No display is currently available. The status icon remains usable."
        } else if store.value.neverShowOnBuiltInDisplay && !displays.contains(where: { !$0.descriptor.isBuiltIn }) {
            displayNote.stringValue = "No eligible external display is connected. Floating controls are hidden. The status icon remains usable."
        } else if targets.isEmpty {
            displayNote.stringValue = "Active Display: The active built-in display is excluded. Floating controls stay hidden rather than moving to another display. The status icon remains usable."
        } else if store.value.displayScope == .all {
            displayNote.stringValue = store.value.neverShowOnBuiltInDisplay
                ? "Shows the active app’s menus on all external displays."
                : "Shows the active app’s menus on all displays."
        } else {
            switch store.value.displayScope {
            case .widest:
                displayNote.stringValue = store.value.neverShowOnBuiltInDisplay
                    ? "Widest Display: Uses the widest external display."
                    : "Widest Display: Uses the widest display."
            case .active:
                displayNote.stringValue = store.value.neverShowOnBuiltInDisplay
                    ? "Active Display: Follows the external display you’re actively using. Floating controls stay hidden while the built-in display is active."
                    : "Active Display: Follows the display you’re actively using."
            case .all: break
            }
        }
        permissionStatus.stringValue = trusted
            ? "Access granted"
            : "Access required"
        permissionIcon.image = NSImage(systemSymbolName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                      accessibilityDescription: nil)
        permissionIcon.contentTintColor = trusted ? .systemGreen : .systemYellow
        permissionStatus.toolTip = trusted ? "Access granted." : "Allow Center My Menu to read and control app menus."
        permissionStatus.textColor = trusted || uiTestMode ? .secondaryLabelColor : .systemOrange
        refreshLoginStatus()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        guard AppTheme.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        store.value.theme = AppTheme.allCases[sender.indexOfSelectedItem]
        onPreferencesChanged?()
    }

    @objc private func fontSizeChanged(_ sender: NSPopUpButton) {
        let size = sender.indexOfSelectedItem + Configuration.fontSizes.lowerBound
        guard Configuration.fontSizes.contains(size) else { return }
        store.value.fontSize = size
        onPreferencesChanged?()
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guard DisplayScope.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        store.value.displayScope = DisplayScope.allCases[sender.indexOfSelectedItem]
        onPreferencesChanged?()
    }

    @objc private func fullScreenChanged(_ sender: NSButton) {
        store.value.hideInFullScreen = sender.state == .on
        onPreferencesChanged?()
    }

    @objc private func builtInChanged(_ sender: NSButton) {
        store.value.neverShowOnBuiltInDisplay = sender.state == .on
        onPreferencesChanged?()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard PresentationMode.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        store.value.mode = PresentationMode.allCases[sender.indexOfSelectedItem]
        onPreferencesChanged?()
    }

    @objc private func resetPosition(_ sender: Any?) {
        let targets = store.value.targetDisplays(in: currentDisplays.map(\.descriptor),
            activeDisplayID: ConnectedDisplay.activeID(in: currentDisplays))
        store.value.resetPositions(for: targets.map(\.id))
        onPreferencesChanged?()
    }

    @objc private func requestPermission(_ sender: Any?) { if !uiTestMode { onPermissionRequest?() } }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        var guidance: String?
        switch status {
        case .enabled:
            loginToggle.state = .on
        case .requiresApproval:
            loginToggle.state = .mixed
            guidance = "Allow Center My Menu in System Settings → General → Login Items to launch it at login."
        case .notRegistered, .notFound:
            loginToggle.state = .off
        @unknown default:
            loginToggle.state = .off
        }
        loginToggle.isEnabled = !loginBusy && !uiTestMode
        loginStatus.stringValue = loginError ?? guidance ?? ""
        loginStatus.isHidden = loginStatus.stringValue.isEmpty
        fitNormalContent()
    }

    private func fitNormalContent() {
        guard let window, let content = window.contentView,
              let document = settingsScroll.documentView else { return }
        // Measure the normal form at full width. A prior scrollbar must not make
        // text wrap more and permanently inflate the next fitted window height.
        settingsScroll.hasVerticalScroller = false
        content.layoutSubtreeIfNeeded()
        settingsScroll.tile()
        content.layoutSubtreeIfNeeded()
        let noticeHeight = operationNotice.isHidden ? 0 : operationNotice.frame.height + 16
        let footerHeight = content.bounds.height - settingsScroll.frame.height
        let size = NSSize(width: content.bounds.width,
                          height: ceil(document.bounds.height - noticeHeight + footerHeight + 1))
        if size != lastFittedContentSize {
            lastFittedContentSize = size
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            let available = (window.screen ?? NSScreen.main)?.visibleFrame
            if let available { frame.size.height = min(frame.height, available.height) }
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            if let available { frame.origin.y = max(frame.minY, available.minY) }
            window.setFrame(frame, display: window.isVisible)
        }
        // Exceptional notices (or a manually shortened window) can still scroll.
        settingsScroll.hasVerticalScroller = true
        content.layoutSubtreeIfNeeded()
        settingsScroll.tile()
    }

    @objc private func changeLogin(_ sender: NSButton) {
        guard !loginBusy, !uiTestMode else { return }
        let status = SMAppService.mainApp.status
        let enable = status != .enabled && status != .requiresApproval
        loginBusy = true
        loginError = nil
        refreshLoginStatus()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if enable { try SMAppService.mainApp.register() }
                else { try await SMAppService.mainApp.unregister() }
                self.loginError = nil
            } catch {
                self.loginError = "Couldn’t \(enable ? "enable" : "disable") launch at login. \(error.localizedDescription)"
            }
            self.loginBusy = false
            self.refreshLoginStatus()
        }
    }

    @objc private func openLoginSettings(_ sender: Any?) {
        if !uiTestMode { SMAppService.openSystemSettingsLoginItems() }
    }
}
