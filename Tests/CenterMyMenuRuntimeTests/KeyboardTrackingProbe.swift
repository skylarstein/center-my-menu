#if QA_CHECKS
import AppKit

// UI-smoke input goes only to our own AppKit queue; no global event posting or AX.
@MainActor
final class KeyboardTrackingProbe: NSObject {
    struct Step {
        let heading: String
        let selection: [String]
        let key: Key
        let openDepth: Int?

        init(_ heading: String, _ selection: [String], _ key: Key, openDepth: Int? = nil) {
            self.heading = heading
            self.selection = selection
            self.key = key
            self.openDepth = openDepth
        }
    }

    enum Key: UInt16 {
        case left = 123, right = 124, down = 125, enter = 36, escape = 53
        var characters: String {
            switch self {
            case .left: return "\u{f702}"
            case .right: return "\u{f703}"
            case .down: return "\u{f701}"
            case .enter: return "\r"
            case .escape: return "\u{1b}"
            }
        }
    }

    private let tracking: ToolbarMenuTrackingSession
    private let windowNumber: Int
    private let steps: [Step]
    private let deadline = ProcessInfo.processInfo.systemUptime + 6
    private var index = 0
    private var nextStepAt: TimeInterval = 0
    private var observedMenu: NSMenu?
    private(set) var timedOut = false
    private(set) var lastState = ""
    var completed: Bool { index == steps.count }

    init(tracking: ToolbarMenuTrackingSession, windowNumber: Int, steps: [Step]) {
        self.tracking = tracking
        self.windowNumber = windowNumber
        self.steps = steps
        self.lastState = "No timer callback; current event: \(NSApp.currentEvent?.type.rawValue ?? 0)"
    }

    func makeTimer() -> Timer {
        let timer = Timer(timeInterval: 0.015, target: self, selector: #selector(sample(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    @objc private func sample(_ timer: Timer) {
        let now = ProcessInfo.processInfo.systemUptime
        if now >= deadline {
            timedOut = true
            timer.invalidate()
            tracking.cancel()
            return
        }
        guard !completed, now >= nextStepAt, let menu = tracking.currentMenu,
              let heading = tracking.currentHeading,
              !menu.items.contains(where: { $0.title == "Loading menus…" }) else { return }
        if observedMenu !== menu {
            observedMenu = menu
            nextStepAt = now + 0.12 // Let AppKit apply the asynchronously populated rows.
            return
        }
        var selection: [String] = []
        var selected = menu.highlightedItem
        while let item = selected {
            selection.append(item.title)
            if let submenu = item.submenu, tracking.openMenus.contains(where: { $0 === submenu }) {
                selected = submenu.highlightedItem
            } else {
                selected = nil
            }
        }
        let step = steps[index]
        lastState = "Step \(index): \(heading.entry.title) \(selection) depth \(tracking.openMenus.count - 1); expected \(step.heading) \(step.selection)"
        guard heading.entry.title == step.heading, selection == step.selection else { return }
        if let depth = step.openDepth, tracking.openMenus.count != depth + 1 { return }
        let key = step.key
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: key.rawValue >= 123 ? [.function, .numericPad] : [], timestamp: now,
            windowNumber: windowNumber, context: nil, characters: key.characters,
            charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.rawValue) else { return }
        index += 1
        nextStepAt = now + 0.12
        NSApp.postEvent(event, atStart: false)
    }
}

extension Array where Element == KeyboardTrackingProbe.Step {
    static var navigation: Self { [
        .init("File", [], .right),
        .init("Edit", [], .down),
        .init("Edit", ["Cut"], .left),
        .init("File", [], .left),
        .init("View", [], .down),
        .init("View", ["Presentation"], .right),
        .init("View", ["Presentation"], .down, openDepth: 1),
        .init("View", ["Presentation", "Compact"], .down),
        .init("View", ["Presentation", "Toolbar"], .down),
        .init("View", ["Presentation", "Zoom"], .right),
        .init("View", ["Presentation", "Zoom"], .down, openDepth: 2),
        .init("View", ["Presentation", "Zoom", "Zoom In"], .left),
        .init("View", ["Presentation", "Zoom"], .left),
        .init("View", ["Presentation"], .left),
        .init("Edit", [], .right),
        .init("View", [], .down),
        .init("View", ["Presentation"], .right),
        .init("View", ["Presentation"], .down, openDepth: 1),
        .init("View", ["Presentation", "Compact"], .right),
        .init("File", [], .down),
        .init("File", ["New"], .enter)
    ] }

    static var emptyReturn: Self { [.init("File", [], .right), .init("Edit", [], .enter)] }
    static var escape: Self { [.init("File", [], .left), .init("View", [], .escape)] }
}
#endif
