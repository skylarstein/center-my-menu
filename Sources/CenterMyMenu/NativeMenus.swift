import AppKit
import CenterMyMenuCore

struct MenuSnapshot {
    let session: MenuSession
    let batch: MenuBatch
}

@MainActor
enum MenuPopupPlacement {
    static func location(below view: NSView) -> NSPoint {
        // NSMenu positions its content, not its outer border. Leave room for
        // native top padding as well as a small visible gap below the control.
        let contentGap: CGFloat = 8
        guard let window = view.window else {
            return NSPoint(x: view.bounds.minX,
                           y: view.isFlipped ? view.bounds.maxY + contentGap : view.bounds.minY - contentGap)
        }
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let isFloatingControl = window.identifier?.rawValue.hasPrefix("CenterMyMenu.Floating.") == true
        let bottom = isFloatingControl ? window.frame.minY : anchor.minY
        let point = NSPoint(x: anchor.minX, y: bottom - contentGap)
        return view.convert(window.convertPoint(fromScreen: point), from: nil)
    }
}

@MainActor
final class NativeMenuAdapter {
    let session: MenuSession
    private let onNotice: (String?) -> Void
    private let permissionRequestItem: (() -> NSMenuItem?)?
    private let canInvoke: () -> Bool
    private let fontSize: Int?
    private var delegates: [LazyMenuDelegate] = []
    private var commandTargets: [MenuCommandTarget] = []
    private(set) var isValid = true
    private(set) var hasInvokedCommand = false
    fileprivate(set) var openMenus: [NSMenu] = []

    init(session: MenuSession, fontSize: Int? = nil,
         canInvoke: @escaping () -> Bool = { true },
         permissionRequestItem: (() -> NSMenuItem?)? = nil,
         onNotice: @escaping (String?) -> Void) {
        self.session = session
        self.fontSize = fontSize.map(Configuration.clampedFontSize)
        self.canInvoke = canInvoke
        self.permissionRequestItem = permissionRequestItem
        self.onNotice = onNotice
    }

    func makeMenu(parentID: UUID? = nil) -> NSMenu {
        let menu = NSMenu(title: session.applicationName)
        if let fontSize { menu.font = .menuFont(ofSize: CGFloat(fontSize)) }
        menu.autoenablesItems = false
        let delegate = LazyMenuDelegate(owner: self, parentID: parentID)
        delegates.append(delegate) // NSMenu does not retain its delegate for us.
        menu.delegate = delegate
        menu.addItem(Self.informationItem("Loading menus…"))
        return menu
    }

    func invalidate() { isValid = false }

    fileprivate func populate(_ menu: NSMenu, with batch: MenuBatch) {
        guard isValid else { return }
        menu.removeAllItems()
        for entry in batch.entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: entry.shortcut?.key ?? "")
            item.isEnabled = entry.isEnabled
            switch entry.state {
            case .off: item.state = .off
            case .on: item.state = .on
            case .mixed: item.state = .mixed
            }
            var modifiers: NSEvent.ModifierFlags = []
            if let shortcut = entry.shortcut {
                if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
                if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
                if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
                if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
            }
            item.keyEquivalentModifierMask = modifiers
            if entry.hasSubmenu {
                item.submenu = makeMenu(parentID: entry.id)
            } else {
                let target = MenuCommandTarget(command: MenuCommand(entryID: entry.id, session: session),
                    canInvoke: { [weak self] in
                        guard let self, self.isValid, self.canInvoke() else { return false }
                        self.hasInvokedCommand = true
                        return true
                    }, onNotice: onNotice)
                commandTargets.append(target)
                item.target = target
                item.action = #selector(MenuCommandTarget.invoke(_:))
            }
            menu.addItem(item)
        }
        if let message = batch.message {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(Self.informationItem(message))
        }
        if batch.status == .permissionRequired, let item = permissionRequestItem?() {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            menu.addItem(Self.informationItem("No accessible menu items are available here."))
        }
        // NSMenu reflects structural mutations while tracking. Calling update() here can
        // recursively ask the delegate to reload; we deliberately do not spin a run loop.
    }

    static func informationItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

@MainActor
private final class LazyMenuDelegate: NSObject, NSMenuDelegate {
    weak var owner: NativeMenuAdapter?
    let parentID: UUID?
    private var requested = false
    private var generation = 0

    init(owner: NativeMenuAdapter, parentID: UUID?) {
        self.owner = owner
        self.parentID = parentID
    }

    // AppKit permits structural updates here, but forbids them in menuWillOpen.
    func menuNeedsUpdate(_ menu: NSMenu) { request(menu) }

    func menuWillOpen(_ menu: NSMenu) {
        owner?.openMenus.append(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        owner?.openMenus.removeAll { $0 === menu }
        requested = false
        generation += 1
    }

    private func request(_ menu: NSMenu) {
        guard !requested, let owner, owner.isValid else { return }
        requested = true
        generation += 1
        let ticket = generation
        menu.removeAllItems()
        menu.addItem(NativeMenuAdapter.informationItem("Loading menus…"))
        owner.session.loadChildren(of: parentID) { [weak self, weak menu] batch in
            guard let self, let menu, self.generation == ticket,
                  let owner = self.owner, owner.isValid else { return }
            owner.populate(menu, with: batch)
        }
    }
}

@MainActor
private final class MenuCommandTarget: NSObject {
    private let command: MenuCommand
    private let canInvoke: () -> Bool
    private let onNotice: (String?) -> Void

    init(command: MenuCommand, canInvoke: @escaping () -> Bool,
         onNotice: @escaping (String?) -> Void) {
        self.command = command
        self.canInvoke = canInvoke
        self.onNotice = onNotice
    }

    @objc func invoke(_ sender: NSMenuItem) {
        guard sender.isEnabled, canInvoke() else { return }
        // A legitimately selected command may complete after tracking ends. Guard
        // acceptance here, but keep its completion/notice alive after invalidation.
        command.execute { [onNotice] message in
            onNotice(message)
        }
    }
}
