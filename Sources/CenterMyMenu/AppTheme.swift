import AppKit
import CenterMyMenuCore

extension AppTheme {
    @MainActor
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}
