import AppKit

@MainActor
@objc(CenterMyMenuApplication)
final class MenuApplication: NSApplication {
    // Installed only for the lifetime of a toolbar popup chain. NSMenu's nested
    // tracking loop reads nextEvent directly, bypassing sendEvent/local monitors.
    var toolbarMenuInput: ((NSEvent) -> Bool)?

    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?,
                            inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        while let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue) {
            if dequeue, mode == .eventTracking, toolbarMenuInput?(event) == true {
                continue // Consume only a handled toolbar-navigation key.
            }
            return event
        }
        return nil
    }
}
