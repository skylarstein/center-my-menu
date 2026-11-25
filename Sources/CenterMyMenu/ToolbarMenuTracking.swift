import AppKit
import CenterMyMenuCore

@MainActor
struct ToolbarMenuHeading {
    let entry: MenuEntry
    let view: NSView
}

/// One clicked toolbar gesture, potentially containing several sequential native
/// popups. Never reopen a menu from a timer, event handler or delegate callback.
@MainActor
final class ToolbarMenuTrackingSession: NSObject {
    let identity: AppIdentity
    private let session: MenuSession
    private let fontSize: Int
    private let headingAtPoint: (NSPoint) -> ToolbarMenuHeading?
    private let adjacentHeading: (UUID, Int) -> ToolbarMenuHeading?
    private let isTargetCurrent: () -> Bool
    private let pointerLocation: () -> NSPoint
    private let pressedButtons: () -> Int
    private let onNotice: (String?) -> Void
    private let permissionRequestItem: (() -> NSMenuItem?)?

    private(set) var currentMenu: NSMenu?
    private(set) var currentHeading: ToolbarMenuHeading?
    var openMenus: [NSMenu] { currentAdapter?.openMenus ?? [] }
    private var currentAdapter: NativeMenuAdapter?
    private var timer: Timer?
    private var lastPointer = NSPoint.zero
    private var pendingHeading: ToolbarMenuHeading?
    private var switchRequestedAt: TimeInterval?
    private var keyboardSwitch = false
    private var hasRun = false
    private var running = false
    private var cancelled = false
    private var commandChosen = false

    init(session: MenuSession, fontSize: Int = Configuration.defaultFontSize,
         headingAtPoint: @escaping (NSPoint) -> ToolbarMenuHeading?,
         adjacentHeading: @escaping (UUID, Int) -> ToolbarMenuHeading?,
         isTargetCurrent: @escaping () -> Bool,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         pressedButtons: @escaping () -> Int = { NSEvent.pressedMouseButtons },
         permissionRequestItem: (() -> NSMenuItem?)? = nil,
         onNotice: @escaping (String?) -> Void) {
        self.session = session
        self.fontSize = fontSize
        self.identity = session.identity
        self.headingAtPoint = headingAtPoint
        self.adjacentHeading = adjacentHeading
        self.isTargetCurrent = isTargetCurrent
        self.pointerLocation = pointerLocation
        self.pressedButtons = pressedButtons
        self.onNotice = onNotice
        self.permissionRequestItem = permissionRequestItem
        super.init()
    }

    private var targetIsUsable: Bool {
        session.identity == identity && isTargetCurrent()
    }

    func run(initial: ToolbarMenuHeading) {
        guard !hasRun, initial.entry.isEnabled, initial.entry.hasSubmenu,
              initial.view.window != nil, targetIsUsable else { return }
        hasRun = true
        running = true
        lastPointer = pointerLocation()
        let application = NSApp as? MenuApplication
        let previousInputHandler = application?.toolbarMenuInput
        application?.toolbarMenuInput = { [weak self] event in
            self?.handleInput(event) ?? false
        }
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self,
                          selector: #selector(samplePointer(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        defer {
            timer.invalidate()
            self.timer = nil
            application?.toolbarMenuInput = previousInputHandler
            currentAdapter?.invalidate()
            (currentHeading?.view as? NSButton)?.highlight(false)
            currentAdapter = nil
            currentMenu = nil
            currentHeading = nil
            pendingHeading = nil
            running = false
        }

        var heading = initial
        while !cancelled && targetIsUsable {
            pendingHeading = nil
            keyboardSwitch = false
            switchRequestedAt = nil
            currentHeading = heading
            let adapter = NativeMenuAdapter(session: session, fontSize: fontSize, canInvoke: { [weak self] in
                self?.claimCommand() ?? false
            }, permissionRequestItem: permissionRequestItem, onNotice: onNotice)
            let menu = adapter.makeMenu(parentID: heading.entry.id)
            currentAdapter = adapter
            currentMenu = menu
            (heading.view as? NSButton)?.highlight(true)
            // A keyboard-selected heading may be outside the toolbar's viewport.
            heading.view.scrollToVisible(heading.view.bounds)
            let location = MenuPopupPlacement.location(below: heading.view)
            let selected = withExtendedLifetime(adapter) {
                menu.popUp(positioning: nil, at: location, in: heading.view)
            }
            (heading.view as? NSButton)?.highlight(false)
            currentMenu = nil
            currentAdapter = nil
            adapter.invalidate()

            // Only our deliberate pointer/keyboard switch permits another popup. An
            // ordinary native dismissal (including Escape/outside click), a command,
            // or a changed target ends the ENTIRE clicked tracking session.
            guard !selected, !adapter.hasInvokedCommand, !commandChosen, !cancelled,
                  pendingHeading != nil, let requestedAt = switchRequestedAt,
                  !inputSupersededSwitch(since: requestedAt), targetIsUsable,
                  pressedButtons() == 0 else { break }
            let point = pointerLocation()
            let next = keyboardSwitch ? pendingHeading : headingAtPoint(point)
            guard let next, next.entry.isEnabled,
                  next.entry.hasSubmenu, next.view.window != nil else { break }
            heading = next
            lastPointer = point
        }
    }

    func cancel() {
        cancelled = true
        pendingHeading = nil
        currentAdapter?.invalidate()
        currentMenu?.cancelTrackingWithoutAnimation()
    }

    private func claimCommand() -> Bool {
        guard running, !cancelled, !commandChosen, pendingHeading == nil else { return false }
        // A selection can race a target change before the next cancellation sample.
        // Report that refusal, but keep already-cancelled or superseded UI quiet.
        guard targetIsUsable else {
            cancel()
            onNotice("The app or menu changed. Reopen the menu and try again.")
            return false
        }
        commandChosen = true
        return true
    }

    private func handleInput(_ event: NSEvent) -> Bool {
        guard running, !cancelled, !commandChosen, currentMenu != nil else { return false }
        switch event.type {
        case .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel:
            break
        default:
            return false
        }
        lastPointer = pointerLocation()
        guard targetIsUsable else { cancel(); return false }
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           event.keyCode == 123 || event.keyCode == 124 {
            let direction = event.keyCode == 123 ? -1 : 1
            if pendingHeading == nil, let adapter = currentAdapter {
                guard !adapter.openMenus.isEmpty else { return false }
                // Let AppKit enter/leave submenus, including a hover-open submenu
                // that has not yet acquired a highlighted child.
                if direction < 0 && adapter.openMenus.count > 1 { return false }
                let activeMenu = adapter.openMenus.last { $0.highlightedItem != nil }
                if direction > 0, activeMenu?.highlightedItem?.submenu != nil { return false }
            }
            if let current = pendingHeading ?? currentHeading,
               let next = adjacentHeading(current.entry.id, direction), let menu = currentMenu {
                requestKeyboardSwitch(to: next, event: event, menu: menu)
                return true
            }
        }
        if pendingHeading != nil {
            // A dismissal, command or pointer gesture supersedes a pending switch.
            cancel()
        }
        return false // AppKit retains Up/Down, Return, Escape, shortcuts and mouse input.
    }

    private func requestKeyboardSwitch(to heading: ToolbarMenuHeading, event: NSEvent, menu: NSMenu) {
        pendingHeading = heading
        keyboardSwitch = true
        switchRequestedAt = event.timestamp
        currentAdapter?.invalidate()
        menu.cancelTrackingWithoutAnimation()
    }

    private func inputSupersededSwitch(since time: TimeInterval) -> Bool {
        // Also inspect the last dequeued event after the native loop unwinds. The
        // arrow that requested a switch has the same timestamp, so cannot veto it.
        guard let event = NSApp.currentEvent, event.timestamp > time else { return false }
        switch event.type {
        case .keyDown, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel:
            return true
        default:
            return false
        }
    }

    @objc private func samplePointer(_ timer: Timer) {
        guard running, !cancelled, !commandChosen, let menu = currentMenu else { return }
        guard targetIsUsable else { cancel(); return }
        guard pendingHeading == nil else { return }
        let point = pointerLocation()
        let moved = point != lastPointer
        lastPointer = point
        // Stationary pointers must not undo keyboard navigation. Mouse presses
        // remain native selection/dismissal gestures, not hover-switch requests.
        guard moved, pressedButtons() == 0,
              let heading = headingAtPoint(point), heading.entry.isEnabled,
              heading.entry.hasSubmenu, heading.entry.id != currentHeading?.entry.id else { return }
        pendingHeading = heading
        switchRequestedAt = ProcessInfo.processInfo.systemUptime
        // Invalidate BEFORE cancelling: neither a late lazy completion nor a late
        // action from this menu is allowed to escape into its replacement.
        currentAdapter?.invalidate()
        menu.cancelTrackingWithoutAnimation()
    }
}
