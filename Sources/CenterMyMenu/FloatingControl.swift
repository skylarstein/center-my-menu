import AppKit
import CoreGraphics
import CenterMyMenuCore

// Normalize the display UUID's ownership as imported by the selected SDK.
private func retainedUUID(_ value: Unmanaged<CFUUID>?) -> CFUUID? { value?.takeRetainedValue() }
private func retainedUUID(_ value: CFUUID?) -> CFUUID? { value }

@MainActor
struct ConnectedDisplay {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let descriptor: DisplayDescriptor

    static func activeID(in displays: [ConnectedDisplay]) -> String? {
        guard let number = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return displays.first(where: { $0.displayID == number.uint32Value })?.descriptor.id
    }

    static func current() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = number.uint32Value
            var key = "display-\(displayID)"
            if let uuid = retainedUUID(CGDisplayCreateUUIDFromDisplayID(displayID)),
               let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) {
                key = string as String
            }
            let descriptor = DisplayDescriptor(id: key, isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                                               frame: screen.frame, visibleFrame: screen.visibleFrame,
                                               safeTopInset: screen.safeAreaInsets.top)
            return ConnectedDisplay(screen: screen, displayID: displayID,
                                    descriptor: descriptor)
        }
    }
}

@MainActor
private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class ActionButton: NSButton {
    private let handler: (NSButton) -> Void
    var onTrackingBegin: (() -> Void)?
    var onTrackingEnd: (() -> Void)?

    init(title: String, handler: @escaping (NSButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(pressed(_:))
        self.font = NSFont.systemFont(ofSize: 13)
        self.isBordered = false
        self.contentTintColor = .labelColor
        self.bezelStyle = .inline
        self.focusRingType = .none
        self.setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onTrackingBegin?()
        defer { onTrackingEnd?() }
        super.mouseDown(with: event)
    }
    @objc private func pressed(_ sender: NSButton) { handler(sender) }
}

@MainActor
final class GripView: NSView {
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    var pressedButtons: () -> Int = { NSEvent.pressedMouseButtons }
    var onBegin: ((NSPoint) -> Bool)?
    var onMove: ((NSPoint) -> Void)?
    var onEnd: ((NSPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var tracking = false
    private var releaseTimer: Timer?
    private var releasedSamples = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = NSRect(x: bounds.midX - 3 + CGFloat(column) * 4,
                                  y: bounds.midY - 5 + CGFloat(row) * 4, width: 2, height: 2)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        if tracking { cancelTracking() }
        guard window != nil, onBegin?(pointerLocation()) == true else { return }
        tracking = true
        NSCursor.closedHand.push()
        let timer = Timer(timeInterval: 0.1, target: ReleaseTimerTarget(grip: self),
                          selector: #selector(ReleaseTimerTarget.sample(_:)), userInfo: nil, repeats: true)
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        // Do not use performDrag's return as a mouse-up/final-frame boundary. Its
        // native tracking/window-server behavior is not our gesture lifetime.
        // AppKit routes subsequent drag/up events to this mouse-down view, even
        // outside its bounds; presentation deferral keeps that view attached.
    }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        // Converting queued event.locationInWindow using an already-moved window
        // feeds window movement back into the next delta. Sample screen points instead.
        onMove?(pointerLocation())
    }

    override func mouseUp(with event: NSEvent) {
        guard tracking else { return }
        let point = pointerLocation()
        endTracking()
        onEnd?(point) // Includes movement since the last delivered mouseDragged event.
    }

    func cancelTracking() {
        guard tracking else { return }
        endTracking()
        onCancel?()
    }

    private func endTracking() {
        tracking = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        releasedSamples = 0
        NSCursor.pop()
    }

    private func samplePressedButtons() {
        guard tracking else { return }
        if pressedButtons() & 1 != 0 {
            releasedSamples = 0
            return
        }
        // Give a queued normal mouseUp another run-loop turn to finish and save.
        // A missing up cancels instead; elapsed drag duration is irrelevant.
        releasedSamples += 1
        if releasedSamples >= 2 { cancelTracking() }
    }

    // Timer retains its target, so the target must not retain the grip.
    @MainActor
    private final class ReleaseTimerTarget: NSObject {
        private weak var grip: GripView?

        init(grip: GripView) { self.grip = grip }

        @objc func sample(_ timer: Timer) {
            guard let grip else {
                timer.invalidate()
                return
            }
            grip.samplePressedButtons()
        }
    }
}

@MainActor
private final class HoverEffectView: NSVisualEffectView {
    var onHover: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        self.area = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
}

@MainActor
final class FloatingControl {
    var onRootMenu: ((NSView) -> Void)?
    var onHeadingMenu: ((MenuSession, MenuEntry, NSView) -> Void)?
    var onPositionChange: ((DisplayDescriptor, StoredPosition) -> Void)?
    var onHover: (() -> Void)?

    private var panel: PassivePanel
    private let pointerLocation: () -> NSPoint
    private let pressedButtons: () -> Int
    private var display: ConnectedDisplay?
    private var preferences = DisplayPreferences(mode: .statusOnly)
    private var menuTracking = false
    private var dragState: PointerAnchoredDrag?
    private var dragging: Bool { dragState != nil }
    private weak var grip: GripView?
    private var buttonTrackingDepth = 0
    private var pointerTracking: Bool { dragging || buttonTrackingDepth > 0 }
    private var presentationTracking: Bool { pointerTracking || menuTracking }
    private var toolbarScroll: NSScrollView?
    private var renderedIdentity: AppIdentity?
    private var renderedSession: MenuSession?
    private var renderedMode: PresentationMode = .statusOnly
    private var headings: [ToolbarMenuHeading] = []

    private struct PendingUpdate {
        let display: ConnectedDisplay
        var preferences: DisplayPreferences
        let snapshot: MenuSnapshot?
        let uiTestMode: Bool
    }
    private var pendingUpdate: PendingUpdate?
    private var pendingHide = false

    init(pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         pressedButtons: @escaping () -> Int = { NSEvent.pressedMouseButtons }) {
        self.pointerLocation = pointerLocation
        self.pressedButtons = pressedButtons
        panel = Self.makePanel(behavior: [.canJoinAllSpaces, .fullScreenNone, .stationary, .ignoresCycle])
    }

    private static func makePanel(behavior: NSWindow.CollectionBehavior) -> PassivePanel {
        let panel = PassivePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Center My Menu"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false // Only our pointer-anchored grip changes the frame.
        panel.isMovableByWindowBackground = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.collectionBehavior = behavior
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        return panel
    }

    private func makeButton(title: String, handler: @escaping (NSButton) -> Void) -> ActionButton {
        let button = ActionButton(title: title, handler: handler)
        button.font = .systemFont(ofSize: CGFloat(preferences.fontSize))
        button.onTrackingBegin = { [weak self] in
            guard let self else { return }
            self.buttonTrackingDepth += 1
        }
        button.onTrackingEnd = { [weak self] in
            guard let self, self.buttonTrackingDepth > 0 else { return }
            self.buttonTrackingDepth -= 1
            self.applyPendingPresentation()
        }
        return button
    }

    func update(display: ConnectedDisplay, preferences: DisplayPreferences,
                snapshot: MenuSnapshot?, uiTestMode: Bool) {
        // AX completions can arrive inside NSButton/native-menu tracking, or
        // between grip down/drag/up events. Preserve all anchors until it ends.
        if presentationTracking {
            pendingUpdate = PendingUpdate(display: display, preferences: preferences,
                                          snapshot: snapshot, uiTestMode: uiTestMode)
            pendingHide = false
            return
        }
        let sameToolbar = renderedIdentity == snapshot?.session.identity && renderedMode == preferences.mode
        let horizontalOffset = sameToolbar ? (toolbarScroll?.contentView.bounds.minX ?? 0) : 0
        renderedIdentity = snapshot?.session.identity
        renderedSession = snapshot?.session
        renderedMode = preferences.mode
        headings.removeAll()
        if !sameToolbar { toolbarScroll = nil }
        self.display = display
        self.preferences = preferences
        // Let WindowServer handle full-screen Spaces per display. This changes
        // eligibility only; it never moves the panel or rewrites saved positions.
        let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
            preferences.hideInFullScreen ? .fullScreenNone : .fullScreenAuxiliary]
        if panel.collectionBehavior != behavior {
            // Full-screen eligibility can remain attached to the existing
            // WindowServer window after retagging. Recreate only for this
            // preference change, after the tracking guard above has cleared.
            panel.title = ""
            panel.close()
            panel = Self.makePanel(behavior: behavior)
        }
        panel.identifier = NSUserInterfaceItemIdentifier("CenterMyMenu.Floating.\(display.descriptor.id)")
        panel.appearance = preferences.theme.appearance
        guard preferences.showsFloatingControl else { hide(); return }
        toolbarScroll = nil

        let entries = snapshot?.batch.entries.filter { !$0.isSeparator } ?? []
        let fallback: String
        switch snapshot?.batch.status {
        case .permissionRequired: fallback = "Permission required"
        default:
            if let session = snapshot?.session, session.identity.processIdentifier > 0 {
                fallback = "Waiting for \(session.applicationName) menus…"
            } else {
                fallback = "Waiting for app menus…"
            }
        }
        let font = NSFont.systemFont(ofSize: CGFloat(preferences.fontSize))
        let titles = entries.isEmpty ? [fallback] : entries.map(\.title)
        let widths = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 20 }
        let naturalWidth: CGFloat = preferences.mode == .compactIcon ? 54 : 26 + widths.reduce(0, +)
        let height: CGFloat = preferences.mode == .compactIcon ? 30
            : max(30, ceil(font.ascender - font.descender + font.leading) + 12)
        let geometry = ControlLayout.place(requestedSize: NSSize(width: naturalWidth, height: height),
                                           on: display.descriptor, preferences: preferences)
        let size = geometry.frame.size
        let effect = HoverEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        effect.onHover = { [weak self] in self?.onHover?() }
        effect.toolTip = uiTestMode ? "UI test menus — no external actions" : "Center My Menu — \(snapshot?.session.applicationName ?? "Current App")"

        let grip = GripView(frame: NSRect(x: 3, y: 0, width: 13, height: size.height))
        self.grip = grip
        grip.pointerLocation = pointerLocation
        grip.pressedButtons = pressedButtons
        grip.toolTip = "Drag to move. Reset to top center in Settings."
        grip.setAccessibilityElement(true)
        grip.setAccessibilityLabel("Drag Center My Menu")
        grip.onBegin = { [weak self] point in self?.beginDrag(at: point) ?? false }
        grip.onMove = { [weak self] point in self?.moveDrag(to: point) }
        grip.onEnd = { [weak self] point in self?.finishDrag(at: point) }
        grip.onCancel = { [weak self] in self?.cancelDrag() }
        effect.addSubview(grip)

        if preferences.mode == .compactIcon {
            let button = makeButton(title: "") { [weak self] button in self?.onRootMenu?(button) }
            button.image = MenuIcon.templateImage(accessibilityDescription: "Open current app menus")
            button.imagePosition = .imageOnly
            button.contentTintColor = .labelColor
            button.frame = NSRect(x: 18, y: 2, width: max(1, size.width - 22), height: size.height - 4)
            button.setAccessibilityLabel(uiTestMode ? "Open test menus" : "Open current app menus")
            effect.addSubview(button)
        } else {
            let overflow = geometry.hasHorizontalOverflow
            let arrowWidth: CGFloat = overflow ? 18 : 0
            let scroll = NSScrollView(frame: NSRect(x: 20 + arrowWidth, y: 2,
                                                    width: max(1, size.width - 26 - 2 * arrowWidth),
                                                    height: size.height - 4))
            scroll.drawsBackground = false
            scroll.borderType = .noBorder
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.horizontalScrollElasticity = .none
            scroll.verticalScrollElasticity = .none
            let document = NSView(frame: NSRect(x: 0, y: 0, width: max(widths.reduce(0, +), scroll.contentSize.width), height: size.height - 4))
            var x: CGFloat = 0
            for index in titles.indices {
                let button: ActionButton
                if !entries.isEmpty, let session = snapshot?.session {
                    let entry = entries[index]
                    button = makeButton(title: entry.title) { [weak self] button in
                        self?.onHeadingMenu?(session, entry, button)
                    }
                    button.isEnabled = entry.isEnabled
                    headings.append(ToolbarMenuHeading(entry: entry, view: button))
                } else {
                    button = makeButton(title: titles[index]) { [weak self] button in self?.onRootMenu?(button) }
                }
                button.frame = NSRect(x: x, y: 0, width: widths[index], height: size.height - 4)
                document.addSubview(button)
                x += widths[index]
            }
            scroll.documentView = document
            toolbarScroll = scroll
            effect.addSubview(scroll)
            if overflow {
                for direction in [-1, 1] {
                    let button = makeButton(title: "") { [weak scroll] _ in
                        guard let scroll, let document = scroll.documentView else { return }
                        let maximum = max(0, document.bounds.width - scroll.contentView.bounds.width)
                        let proposed = scroll.contentView.bounds.minX + CGFloat(direction) * max(80, scroll.contentSize.width * 0.7)
                        scroll.contentView.scroll(to: NSPoint(x: min(max(0, proposed), maximum), y: 0))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    button.image = NSImage(systemSymbolName: direction < 0 ? "chevron.left" : "chevron.right", accessibilityDescription: "Scroll menu headings")
                    button.imagePosition = .imageOnly
                    button.frame = NSRect(x: direction < 0 ? 20 : size.width - 24, y: 2, width: 18, height: size.height - 4)
                    button.toolTip = direction < 0 ? "Scroll headings left" : "Scroll headings right"
                    effect.addSubview(button)
                }
            }
        }
        panel.contentView = effect
        panel.setFrame(geometry.frame, display: true)
        if let scroll = toolbarScroll, let document = scroll.documentView {
            scroll.tile()
            let maximum = max(0, document.bounds.width - scroll.contentView.bounds.width)
            scroll.contentView.scroll(to: NSPoint(x: min(max(0, horizontalOffset), maximum), y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // Content refreshes must not pull an already-visible panel into a
        // different Space (in particular another app's full-screen Space).
        if !panel.isVisible { panel.orderFrontRegardless() }
    }


    func heading(for entryID: UUID, session: MenuSession) -> ToolbarMenuHeading? {
        guard panel.isVisible, renderedMode == .toolbar,
              let renderedSession, renderedSession === session else { return nil }
        return headings.first {
            $0.entry.id == entryID && $0.entry.isEnabled && $0.entry.hasSubmenu && $0.view.window === panel
        }
    }

    func adjacentHeading(to entryID: UUID, direction: Int, session: MenuSession) -> ToolbarMenuHeading? {
        guard panel.isVisible, renderedMode == .toolbar,
              let renderedSession, renderedSession === session else { return nil }
        let available = headings.filter {
            $0.entry.isEnabled && $0.entry.hasSubmenu && $0.view.window === panel
                && !$0.view.isHiddenOrHasHiddenAncestor
        }
        guard available.count > 1, let index = available.firstIndex(where: { $0.entry.id == entryID }) else { return nil }
        return available[(index + direction + available.count) % available.count]
    }

    func heading(at screenPoint: NSPoint, for session: MenuSession) -> ToolbarMenuHeading? {
        guard panel.isVisible, renderedMode == .toolbar,
              let renderedSession, renderedSession === session else { return nil }
        // A native menu can be repositioned over the toolbar near a screen edge.
        // Do not interpret a menu row or an obscuring window as a toolbar hover.
        guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == panel.windowNumber else { return nil }
        return headings.first { heading in
            guard heading.entry.isEnabled, heading.entry.hasSubmenu,
                  heading.view.window === panel, !heading.view.isHiddenOrHasHiddenAncestor else { return false }
            let visible = heading.view.visibleRect.intersection(heading.view.bounds)
            guard !visible.isEmpty else { return false }
            let rectangle = panel.convertToScreen(heading.view.convert(visible, to: nil))
            return rectangle.contains(screenPoint)
        }
    }

    func setMenuTracking(_ value: Bool) {
        menuTracking = value
        if !value { applyPendingPresentation() }
    }

    func hide() {
        if presentationTracking {
            pendingUpdate = nil
            pendingHide = true
            return
        }
        panel.orderOut(nil)
    }

    func stop() {
        dragState = nil
        buttonTrackingDepth = 0
        menuTracking = false
        pendingUpdate = nil
        pendingHide = false
        grip?.cancelTracking()
        hide()
    }

    private func beginDrag(at point: NSPoint) -> Bool {
        guard !presentationTracking, display != nil, panel.isVisible else { return false }
        dragState = PointerAnchoredDrag(frame: panel.frame, pointer: point)
        return true
    }

    private func moveDrag(to point: NSPoint) {
        guard let dragState, let display else { return }
        panel.setFrame(dragState.frame(at: point, on: display.descriptor), display: true)
    }

    private func finishDrag(at point: NSPoint) {
        guard let dragState, let display else { return }
        var descriptor = display.descriptor
        var adjusted = preferences
        if let pendingUpdate, pendingUpdate.display.descriptor.id == descriptor.id {
            adjusted = pendingUpdate.preferences
            descriptor = pendingUpdate.display.descriptor
        }
        // Use the actual release point, then persist the frame AppKit accepted.
        // A same-display geometry change gets its latest safe area before saving.
        // A different display never inherits the completed gesture's position.
        panel.setFrame(dragState.frame(at: point, on: descriptor), display: true)
        let position = ControlLayout.storedPosition(of: panel.frame, on: descriptor)
        adjusted.position = position
        preferences = adjusted
        if pendingUpdate?.display.descriptor.id == descriptor.id {
            pendingUpdate?.preferences.position = position
        }
        // Keep deferring through the callback, which may synchronously save and
        // render newer preferences, a newer snapshot, or a different display.
        onPositionChange?(descriptor, position)
        self.dragState = nil
        applyPendingPresentation()
    }

    private func cancelDrag() {
        guard let dragState else { return }
        panel.setFrame(dragState.initialFrame, display: true)
        self.dragState = nil
        applyPendingPresentation()
    }

    private func applyPendingPresentation() {
        guard !presentationTracking else { return }
        let update = pendingUpdate
        let shouldHide = pendingHide
        pendingUpdate = nil
        pendingHide = false
        if shouldHide {
            hide()
        } else if let update {
            self.update(display: update.display, preferences: update.preferences,
                        snapshot: update.snapshot, uiTestMode: update.uiTestMode)
        }
    }

}
