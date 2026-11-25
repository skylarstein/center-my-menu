import AppKit

/// Centered dropdown artwork for native controls.
enum MenuIcon {
    static func templateImage(accessibilityDescription: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            drawTemplate()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription
        return image
    }

    static func drawTemplate() {
        // Point-aligned edges keep the two menu rows clear at both 1x and 2x.
        let shape = NSBezierPath()
        shape.windingRule = .evenOdd
        shape.append(rounded(NSRect(x: 0, y: 12, width: 18, height: 4), 1.5))
        shape.append(rounded(NSRect(x: 7, y: 13, width: 4, height: 2), 0.75))
        shape.append(rounded(NSRect(x: 3, y: 2, width: 12, height: 9), 2))
        shape.append(rounded(NSRect(x: 5, y: 8, width: 8, height: 1), 0.5))
        shape.append(rounded(NSRect(x: 5, y: 5, width: 8, height: 1), 0.5))
        NSColor.black.setFill()
        shape.fill()
    }

    private static func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    }
}
