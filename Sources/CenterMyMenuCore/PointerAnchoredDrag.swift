import Foundation
import CoreGraphics

/// All coordinates are AppKit screen points, never coordinates relative to a moving window.
public struct PointerAnchoredDrag {
    public let initialFrame: CGRect
    public let initialPointer: CGPoint

    public init(frame: CGRect, pointer: CGPoint) {
        initialFrame = frame
        initialPointer = pointer
    }

    public func proposedFrame(at pointer: CGPoint) -> CGRect {
        initialFrame.offsetBy(dx: pointer.x - initialPointer.x,
                              dy: pointer.y - initialPointer.y)
    }

    public func frame(at pointer: CGPoint, on display: DisplayDescriptor) -> CGRect {
        let proposed = proposedFrame(at: pointer)
        // StoredPosition describes the center in the FULL display coordinate space,
        // not a fraction of the window's remaining horizontal travel. Use the same
        // inverse and constraints as restoration, without accumulating rounded deltas.
        let preferences = DisplayPreferences(mode: .toolbar,
            position: ControlLayout.storedPosition(of: proposed, on: display))
        return ControlLayout.place(requestedSize: initialFrame.size, on: display,
                                   preferences: preferences).frame
    }
}
