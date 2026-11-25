import Foundation
import CenterMyMenuCore

final class TestMenuSession: MenuSession {
    let identity = AppIdentity(processIdentifier: -1, bundleIdentifier: "io.github.skylarstein.centermymenu.uitest", launchTime: nil)
    let applicationName = "UI Test App"
    private var roots: [MenuEntry] = []
    private var children: [UUID: [MenuEntry]] = [:]
    private var actions: Set<UUID> = []

    init() {
        let recent = branch("Open Recent", [leaf("Welcome Example"), leaf("Sample Project"), .separator(), leaf("Clear Menu")])
        let zoom = branch("Zoom", [leaf("Zoom In", key: "+"), leaf("Zoom Out", key: "-"), leaf("Actual Size", key: "0")])
        let presentation = branch("Presentation", [leaf("Compact", mark: .on), leaf("Toolbar", mark: .mixed), zoom])
        roots = [
            branch("", [leaf("About UI Test Mac"), .separator(), leaf("UI Test System Settings…")]),
            branch("UI Test App", [leaf("About UI Test App"), .separator(), leaf("Settings…", key: ","), .separator(), leaf("Quit UI Test App", key: "q")]),
            branch("File", [leaf("New", key: "n"), leaf("Open…", key: "o"), recent, .separator(), leaf("Save", enabled: false, key: "s"), leaf("Close", key: "w")]),
            branch("Edit", [leaf("Undo", enabled: false, key: "z"), .separator(), leaf("Cut", key: "x"), leaf("Copy", key: "c"), leaf("Paste", key: "v"), leaf("Select All", key: "a")]),
            branch("View", [presentation, .separator(), leaf("Show Sidebar", mark: .on), leaf("Show Inspector", mark: .mixed)]),
            branch("Window", [leaf("Minimize", key: "m"), leaf("Zoom"), .separator(), leaf("Bring All to Front")]),
            branch("Help", [leaf("UI Test Help"), leaf("This mode never sends app actions")])
        ]
    }

    private func leaf(_ title: String, enabled: Bool = true, key: String? = nil, mark: MenuMark = .off) -> MenuEntry {
        let entry = MenuEntry(title: title, isEnabled: enabled, state: mark,
                              shortcut: key.map { MenuShortcut(key: $0) })
        actions.insert(entry.id)
        return entry
    }

    private func branch(_ title: String, _ entries: [MenuEntry]) -> MenuEntry {
        let entry = MenuEntry(title: title, hasSubmenu: true)
        children[entry.id] = entries
        return entry
    }

    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void) {
        let entries = parentID.flatMap { children[$0] } ?? (parentID == nil ? roots : [])
        deliverToMenuRunLoop { completion(MenuBatch(entries: entries, status: .uiTestData)) }
    }

    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void) {
        let message = action.target == identity && actions.contains(action.entryID)
            ? "UI test only — no command was sent to any application." : "That test item is no longer available."
        deliverToMenuRunLoop { completion(message) }
    }
}
