import AppKit
import ApplicationServices
import Carbon
import CenterMyMenuCore

// A dispatch-main completion alone can be delayed by a nested menu-tracking loop.
func deliverToMenuRunLoop(_ body: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, body)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

func identity(of application: NSRunningApplication) -> AppIdentity {
    AppIdentity(processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                launchTime: application.launchDate?.timeIntervalSince1970)
}

@MainActor
final class AppTargetTracker {
    private var lastExternal: NSRunningApplication?
    private let menuBarOwner: () -> NSRunningApplication?

    init(menuBarOwner: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.menuBarOwningApplication }) {
        self.menuBarOwner = menuBarOwner
    }

    private func record(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              application.bundleIdentifier != "io.github.skylarstein.centermymenu",
              !application.isTerminated else { return }
        lastExternal = application
    }

    func capture() -> NSRunningApplication? {
        // A permission dialog can receive keys while another app still owns the
        // visible menu bar. Only the menu-bar owner can replace our target.
        if let owner = menuBarOwner() { record(owner) }
        guard let lastExternal, !lastExternal.isTerminated else {
            self.lastExternal = nil
            return nil
        }
        return lastExternal
    }

    func allowsMenuRetry(for target: AppIdentity) -> Bool {
        // No target yet: retry capture until macOS reports a menu-bar owner.
        // This does not issue an AX read against any application.
        if target.processIdentifier == 0 { return true }
        guard let owner = menuBarOwner(), !owner.isTerminated else { return false }
        return identity(of: owner) == target
    }
}

final class AXMenuService {
    private let queue = DispatchQueue(label: "io.github.skylarstein.centermymenu.accessibility", qos: .userInitiated)

    @MainActor
    func session(for application: NSRunningApplication, onNeedsRefresh: @escaping () -> Void = {}) -> AXMenuSession {
        AXMenuSession(application: application, queue: queue, onNeedsRefresh: onNeedsRefresh)
    }
}

// CF downcasts are made only after checking the Core Foundation runtime type.
private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func axElements(_ value: CFTypeRef?) -> [AXUIElement] {
    guard let value, CFGetTypeID(value) == CFArrayGetTypeID(),
          let objects = value as? [AnyObject] else { return [] }
    return objects.compactMap { object in
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
}

private final class AXBudget {
    let deadline: TimeInterval
    var failure: MenuLoadStatus?
    var limited = false

    init(seconds: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + seconds }

    func check() -> Bool {
        if failure != nil { return false }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            failure = .timedOut
            return false
        }
        return true
    }

    private func record(_ error: AXError) {
        switch error {
        case .cannotComplete: failure = .timedOut
        case .invalidUIElement: failure = .unavailable
        case .apiDisabled: failure = .permissionRequired
        default: break // Unsupported/no-value attributes are normal for many applications.
        }
    }

    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard check() else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.08)
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        if error != .success { record(error); return nil }
        return result
    }

    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    func children(_ element: AXUIElement, limit: Int = 251, markLimit: Bool = true) -> [AXUIElement] {
        guard check() else { return [] }
        AXUIElementSetMessagingTimeout(element, 0.08)
        var count: CFIndex = 0
        let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        guard countError == .success else { record(countError); return [] }
        guard count > 0, check() else { return [] }
        if markLimit && count > limit { limited = true }
        var array: CFArray?
        let error = AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString,
                                                   0, min(count, limit), &array)
        guard error == .success else { record(error); return [] }
        return axElements(array)
    }
}

final class AXMenuSession: MenuSession {
    let identity: AppIdentity
    let applicationName: String
    private let application: NSRunningApplication
    private let applicationElement: AXUIElement
    private let queue: DispatchQueue
    private let onNeedsRefresh: () -> Void

    private struct Reference {
        let element: AXUIElement
        let depth: Int
        let hasSubmenu: Bool
    }
    // Accessed only on queue. References retain the original AX objects for action lifetime.
    private var references: [UUID: Reference] = [:]
    private let maximumEntries = 250

    @MainActor
    init(application: NSRunningApplication, queue: DispatchQueue, onNeedsRefresh: @escaping () -> Void = {}) {
        self.onNeedsRefresh = onNeedsRefresh
        self.application = application
        self.identity = CenterMyMenu.identity(of: application)
        self.applicationName = application.localizedName ?? application.bundleIdentifier ?? "Application"
        self.applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        self.queue = queue
    }

    private var isAlive: Bool {
        guard !application.isTerminated,
              let current = NSRunningApplication(processIdentifier: identity.processIdentifier) else { return false }
        return CenterMyMenu.identity(of: current) == identity
    }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        // Include time waiting behind other reads. Superseded popups must not each
        // receive a new full budget and hold up the next read or selected command.
        let budget = AXBudget(seconds: parentID == nil ? 0.8 : 1.2)
        queue.async { [self] in
            let batch = readChildren(parentID, budget: budget)
            deliverToMenuRunLoop { completion(batch) }
        }
    }

    private func readChildren(_ parentID: UUID?, budget: AXBudget) -> MenuBatch {
        guard budget.check() else { return unavailable(.timedOut) }
        guard AXIsProcessTrusted() else { return unavailable(.permissionRequired) }
        guard isAlive else { return unavailable(.unavailable, "The captured app has exited. Reopen the menu.") }
        let topLevel = parentID == nil
        let elements: [AXUIElement]
        let depth: Int
        if let parentID {
            guard let reference = references[parentID] else {
                return unavailable(.unavailable, "This menu is stale. Reopen it to refresh.")
            }
            guard reference.depth < 12 else {
                return unavailable(.truncated, "Submenu depth safety limit reached.")
            }
            depth = reference.depth + 1
            let children = budget.children(reference.element)
            // AXMenuBarItem/AXMenuItem usually contains an AXMenu wrapper. Read it fresh.
            if let wrapper = children.prefix(3).first(where: { budget.string($0, kAXRoleAttribute) == "AXMenu" }) {
                elements = budget.children(wrapper)
            } else {
                elements = children
            }
        } else {
            depth = 0
            guard let menuBar = axElement(budget.value(applicationElement, kAXMenuBarAttribute)) else {
                return unavailable(budget.failure ?? .unavailable, budget.failure == nil
                    ? "This app did not expose a menu bar." : nil)
            }
            elements = budget.children(menuBar)
        }

        var entries: [MenuEntry] = []
        if elements.count > maximumEntries { budget.limited = true }
        for element in elements.prefix(maximumEntries) {
            guard budget.check() else { break }
            guard references.count < 4096 else { budget.limited = true; break }
            if let entry = readEntry(element, topLevel: topLevel, budget: budget) {
                entries.append(entry)
                if !entry.isSeparator {
                    references[entry.id] = Reference(element: element, depth: depth, hasSubmenu: entry.hasSubmenu)
                }
            }
        }
        let status = budget.failure ?? (budget.limited ? .truncated : (entries.isEmpty ? .empty : .ok))
        return MenuBatch(entries: entries, message: message(for: status), status: status)
    }

    private func readEntry(_ element: AXUIElement, topLevel: Bool, budget: AXBudget) -> MenuEntry? {
        let role = budget.string(element, kAXRoleAttribute) ?? ""
        guard ["AXMenuBarItem", "AXMenuItem", "AXSeparator"].contains(role) else { return nil }
        var rawTitle = budget.string(element, kAXTitleAttribute) ?? ""
        var appleMenu = false
        if topLevel {
            let subrole = budget.string(element, kAXSubroleAttribute)
            appleMenu = subrole == "AXAppleMenu"
            if rawTitle.isEmpty {
                rawTitle = budget.string(element, kAXDescriptionAttribute) ?? ""
            }
        }
        let hasSubmenu: Bool
        if topLevel {
            hasSubmenu = true // Even unavailable top-level menus get a meaningful lazy placeholder.
        } else if let child = budget.children(element, limit: 1, markLimit: false).first {
            let childRole = budget.string(child, kAXRoleAttribute)
            hasSubmenu = childRole == "AXMenu" || childRole == "AXMenuItem"
        } else {
            hasSubmenu = false
        }
        if role == "AXSeparator" || (!topLevel && rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasSubmenu) {
            return .separator()
        }
        let enabled = (budget.value(element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
        var mark: MenuMark = .off
        var shortcut: MenuShortcut?
        if !topLevel {
            let character = (budget.string(element, kAXMenuItemMarkCharAttribute) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !character.isEmpty {
                mark = ["-", "−", "–", "mixed"].contains(character.lowercased()) ? .mixed : .on
            } else if let number = budget.value(element, kAXValueAttribute) as? NSNumber {
                if number.intValue == 1 { mark = .on }
                if number.intValue == 2 { mark = .mixed }
            }
            shortcut = readShortcut(element, budget: budget)
        }
        guard budget.failure == nil else { return nil }
        return MenuEntry(title: MenuMapping.title(rawTitle, isTopLevel: topLevel, isAppleMenu: appleMenu),
                         isEnabled: enabled, state: mark, shortcut: shortcut, hasSubmenu: hasSubmenu)
    }

    private func readShortcut(_ element: AXUIElement, budget: AXBudget) -> MenuShortcut? {
        let character = budget.string(element, kAXMenuItemCmdCharAttribute) ?? ""
        var key: String?
        if character.utf16.count == 1, character.unicodeScalars.first?.value != 0 {
            key = character.lowercased()
        }
        if key == nil, let virtual = budget.value(element, kAXMenuItemCmdVirtualKeyAttribute) as? NSNumber {
            key = keyForVirtualKey(virtual.intValue)
        }
        if key == nil, let glyph = budget.value(element, kAXMenuItemCmdGlyphAttribute) as? NSNumber {
            key = keyForGlyph(glyph.intValue)
        }
        guard let key else { return nil }
        let raw = (budget.value(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
        // Public AXMenuItemModifiers bits: shift=1, option=2, control=4, no-command=8.
        var modifiers: MenuModifiers = []
        if raw & 8 == 0 { modifiers.insert(.command) }
        if raw & 1 != 0 { modifiers.insert(.shift) }
        if raw & 2 != 0 { modifiers.insert(.option) }
        if raw & 4 != 0 { modifiers.insert(.control) }
        return MenuShortcut(key: key, modifiers: modifiers)
    }

    private func keyForVirtualKey(_ key: Int) -> String? {
        let special: [Int: String] = [
            48: "\t", 36: "\r", 76: "\u{3}", 53: "\u{1b}", 51: "\u{8}",
            117: "\u{f728}", 123: "\u{f702}", 124: "\u{f703}", 125: "\u{f701}",
            126: "\u{f700}", 115: "\u{f729}", 119: "\u{f72b}", 116: "\u{f72c}", 121: "\u{f72d}"
        ]
        if let value = special[key] { return value }
        let functionKeys = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        guard let index = functionKeys.firstIndex(of: key), let scalar = UnicodeScalar(0xf704 + index) else { return nil }
        return String(scalar)
    }

    private func keyForGlyph(_ glyph: Int) -> String? {
        let virtual: [Int: Int] = [
            Int(kMenuTabRightGlyph): 48, Int(kMenuReturnGlyph): 36, Int(kMenuEnterGlyph): 76,
            Int(kMenuEscapeGlyph): 53, Int(kMenuDeleteLeftGlyph): 51, Int(kMenuDeleteRightGlyph): 117,
            Int(kMenuLeftArrowGlyph): 123, Int(kMenuRightArrowGlyph): 124,
            Int(kMenuUpArrowGlyph): 126, Int(kMenuDownArrowGlyph): 125,
            Int(kMenuNorthwestArrowGlyph): 115, Int(kMenuSoutheastArrowGlyph): 119,
            Int(kMenuPageUpGlyph): 116, Int(kMenuPageDownGlyph): 121
        ]
        if glyph == Int(kMenuSpaceGlyph) { return " " }
        return virtual[glyph].flatMap(keyForVirtualKey)
    }

    private func message(for status: MenuLoadStatus) -> String? {
        switch status {
        case .ok, .uiTestData: return nil
        case .loading: return "Loading menus…"
        case .permissionRequired: return "Allow Center My Menu to read and control app menus."
        case .timedOut: return "The app did not respond within the reading budget. Reopen to refresh."
        case .truncated: return "This menu is partial because a safety limit was reached. Reopen to refresh."
        case .empty, .unavailable: return "This app did not expose menu items here. Some apps populate only their own open menus."
        }
    }

    private func unavailable(_ status: MenuLoadStatus, _ text: String? = nil) -> MenuBatch {
        MenuBatch(entries: [], message: text ?? message(for: status), status: status)
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        // Defer until the native popup has relinquished tracking; never activate Center My Menu.
        DispatchQueue.main.async { [self] in prepareAction(action, completion: completion) }
    }

    @MainActor
    private func prepareAction(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        guard action.target == identity, isAlive else {
            onNeedsRefresh()
            completion("The app or menu changed. Reopen the menu and try again.")
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier == identity.processIdentifier {
            enqueuePress(action, completion: completion)
        } else if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier || front?.bundleIdentifier == "io.github.skylarstein.centermymenu" {
            // Settings is the sole case where we restore a target on an explicit command.
            guard application.activate(options: []) else {
                completion("Switch back to the captured app and reopen the menu.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [self] in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == identity.processIdentifier else {
                    completion("The captured app could not be made active. No command was sent.")
                    return
                }
                enqueuePress(action, completion: completion)
            }
        } else {
            onNeedsRefresh()
            completion("The app or menu changed. Reopen the menu and try again.")
        }
    }

    private func enqueuePress(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            let error: String?
            var needsRefresh = false
            if !AXIsProcessTrusted() {
                error = "Permission is no longer available. Open Center My Menu Settings."
            } else if !isAlive || action.target != identity {
                needsRefresh = true
                error = "The app or menu changed. Reopen the menu and try again."
            } else if let reference = references[action.entryID], !reference.hasSubmenu {
                var pid: pid_t = 0
                if AXUIElementGetPid(reference.element, &pid) != .success || pid != identity.processIdentifier {
                    needsRefresh = true
                    error = "The app or menu changed. Reopen the menu and try again."
                } else {
                    let budget = AXBudget(seconds: 0.25)
                    let enabled = (budget.value(reference.element, kAXEnabledAttribute) as? NSNumber)?.boolValue ?? true
                    if budget.failure == .unavailable {
                        needsRefresh = true
                        error = "The app or menu changed. Reopen the menu and try again."
                    } else if budget.failure == .permissionRequired {
                        error = "Permission is no longer available. Open Center My Menu Settings."
                    } else if budget.failure != nil {
                        error = "The app did not respond while verifying the item. No command was sent."
                    } else if !enabled {
                        error = "That menu item is now disabled."
                    } else if !application.isActive || !isAlive {
                        // Reads ahead of this action can hold the serial AX queue. Recheck
                        // focus after those reads, immediately before sending the command.
                        needsRefresh = true
                        error = "The app or menu changed. Reopen the menu and try again."
                    } else {
                        AXUIElementSetMessagingTimeout(reference.element, 0.2)
                        // Exactly one press. A timeout can mean the command DID execute.
                        let result = AXUIElementPerformAction(reference.element, kAXPressAction as CFString)
                        switch result {
                        case .success: error = nil
                        case .invalidUIElement:
                            needsRefresh = true
                            error = "The app or menu changed. Reopen the menu and try again."
                        case .apiDisabled:
                            error = "Permission is no longer available. Open Center My Menu Settings."
                        case .actionUnsupported: error = "This app does not expose AXPress for that menu item."
                        default: error = "The app did not confirm AXPress (\(result.rawValue)). It may have run; it was not retried."
                        }
                    }
                }
            } else {
                needsRefresh = true
                error = "The app or menu changed. Reopen the menu and try again."
            }
            // Refresh stale snapshots, but never retry a selected command.
            deliverToMenuRunLoop {
                if needsRefresh { self.onNeedsRefresh() }
                completion(error)
            }
        }
    }
}

final class UnavailableMenuSession: MenuSession {
    let identity: AppIdentity
    let applicationName: String
    private let batch: MenuBatch

    init(identity: AppIdentity, name: String, message: String, status: MenuLoadStatus) {
        self.identity = identity
        self.applicationName = name
        self.batch = MenuBatch(entries: [], message: message, status: status)
    }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        deliverToMenuRunLoop { [batch] in completion(batch) }
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        deliverToMenuRunLoop { [batch] in completion(batch.message) }
    }
}
