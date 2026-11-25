import Foundation

public struct AppIdentity: Equatable, Hashable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let launchTime: TimeInterval?

    public init(processIdentifier: Int32, bundleIdentifier: String?, launchTime: TimeInterval?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchTime = launchTime
    }
}

public enum MenuMark: Equatable {
    case off, on, mixed
}

public struct MenuModifiers: OptionSet, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = MenuModifiers(rawValue: 1 << 0)
    public static let shift = MenuModifiers(rawValue: 1 << 1)
    public static let option = MenuModifiers(rawValue: 1 << 2)
    public static let control = MenuModifiers(rawValue: 1 << 3)
}

public struct MenuShortcut: Equatable {
    public let key: String
    public let modifiers: MenuModifiers
    public init(key: String, modifiers: MenuModifiers = .command) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct MenuEntry: Identifiable, Equatable {
    public let id: UUID
    public let title: String
    public let isEnabled: Bool
    public let isSeparator: Bool
    public let state: MenuMark
    public let shortcut: MenuShortcut?
    public let hasSubmenu: Bool

    public init(id: UUID = UUID(), title: String, isEnabled: Bool = true,
                isSeparator: Bool = false, state: MenuMark = .off,
                shortcut: MenuShortcut? = nil, hasSubmenu: Bool = false) {
        self.id = id
        self.title = title
        self.isEnabled = isEnabled
        self.isSeparator = isSeparator
        self.state = state
        self.shortcut = shortcut
        self.hasSubmenu = hasSubmenu
    }

    public static func separator() -> MenuEntry {
        MenuEntry(title: "", isEnabled: false, isSeparator: true)
    }
}

public enum MenuLoadStatus: String {
    case loading, ok, empty, unavailable, permissionRequired, timedOut, truncated, uiTestData
}

public struct MenuBatch {
    public let entries: [MenuEntry]
    public let message: String?
    public let status: MenuLoadStatus

    public init(entries: [MenuEntry], message: String? = nil, status: MenuLoadStatus = .ok) {
        self.entries = MenuMapping.normalized(entries)
        self.message = message
        self.status = status
    }
}

public enum MenuMapping {
    public static func title(_ raw: String?, isTopLevel: Bool, isAppleMenu: Bool = false) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if isTopLevel && (isAppleMenu || ["apple", "apple menu", ""].contains(value.lowercased())) {
            return ""
        }
        return value.isEmpty ? "Untitled Menu" : value
    }

    public static func normalized(_ entries: [MenuEntry]) -> [MenuEntry] {
        var result: [MenuEntry] = []
        for entry in entries {
            if entry.isSeparator && (result.isEmpty || result.last?.isSeparator == true) { continue }
            result.append(entry)
        }
        if result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}

public struct CapturedMenuAction: Equatable {
    public let target: AppIdentity
    public let entryID: UUID
    public init(target: AppIdentity, entryID: UUID) {
        self.target = target
        self.entryID = entryID
    }
}

// Providers deliver completions on the main run loop, including menu-tracking modes.
// A session represents ONE captured application, never a mutable global current target.
public protocol MenuSession: AnyObject {
    var identity: AppIdentity { get }
    var applicationName: String { get }
    func loadChildren(of parentID: UUID?, completion: @escaping (MenuBatch) -> Void)
    func perform(_ action: CapturedMenuAction, completion: @escaping (String?) -> Void)
}

public final class MenuCommand {
    public let action: CapturedMenuAction
    private let session: MenuSession

    public init(entryID: UUID, session: MenuSession) {
        self.session = session
        self.action = CapturedMenuAction(target: session.identity, entryID: entryID)
    }

    public func execute(completion: @escaping (String?) -> Void) {
        session.perform(action, completion: completion)
    }
}
