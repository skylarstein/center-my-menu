import AppKit
import CenterMyMenuCore

/// One floating control per display, sharing the captured app's menu snapshot.
@MainActor
final class FloatingControls {
    var onRootMenu: ((NSView) -> Void)?
    var onHeadingMenu: ((FloatingControl, MenuSession, MenuEntry, NSView) -> Void)?
    var onPositionChange: ((DisplayDescriptor, StoredPosition) -> Void)?
    var onHover: (() -> Void)?

    private var controls: [String: FloatingControl] = [:]

    func update(displays: [ConnectedDisplay], activeDisplayID: String?, configuration: Configuration,
                snapshot: MenuSnapshot?, uiTestMode: Bool) {
        let connectedIDs = Set(displays.map { $0.descriptor.id })
        for id in Array(controls.keys) where !connectedIDs.contains(id) {
            controls.removeValue(forKey: id)?.stop()
        }
        let targets = configuration.mode == .statusOnly ? []
            : configuration.targetDisplays(in: displays.map(\.descriptor), activeDisplayID: activeDisplayID)
        let targetIDs = Set(targets.map(\.id))
        for (id, control) in controls where !targetIDs.contains(id) { control.hide() }
        for display in displays where targetIDs.contains(display.descriptor.id) {
            let id = display.descriptor.id
            let control: FloatingControl
            if let existing = controls[id] {
                control = existing
            } else {
                control = FloatingControl()
                control.onRootMenu = { [weak self] view in self?.onRootMenu?(view) }
                control.onHeadingMenu = { [weak self, weak control] session, entry, view in
                    guard let control else { return }
                    self?.onHeadingMenu?(control, session, entry, view)
                }
                control.onPositionChange = { [weak self] display, position in
                    self?.onPositionChange?(display, position)
                }
                control.onHover = { [weak self] in self?.onHover?() }
                controls[id] = control
            }
            control.update(display: display, preferences: configuration.profile(for: display.descriptor),
                           snapshot: snapshot, uiTestMode: uiTestMode)
        }
    }

    func setMenuTracking(_ tracking: Bool) {
        for control in controls.values { control.setMenuTracking(tracking) }
    }

    func stop() {
        for control in controls.values { control.stop() }
        controls.removeAll()
    }
}
