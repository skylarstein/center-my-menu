import Foundation
import CoreGraphics

public enum PresentationMode: String, Codable, CaseIterable {
    case compactIcon, toolbar, statusOnly
}

public enum AppTheme: String, Codable, CaseIterable {
    case system, dark, light
}

public enum DisplayScope: String, Codable, CaseIterable {
    case widest, active, all
}

public struct StoredPosition: Codable, Equatable {
    public var horizontalFraction: Double
    public var topOffset: Double

    public init(horizontalFraction: Double, topOffset: Double) {
        self.horizontalFraction = horizontalFraction
        self.topOffset = topOffset
    }
}

// Resolved presentation for one display. Only Configuration is persisted.
public struct DisplayPreferences: Equatable {
    public var mode: PresentationMode
    public var position: StoredPosition?
    public var fontSize: Int
    public var theme: AppTheme
    public var hideInFullScreen: Bool

    public init(mode: PresentationMode, position: StoredPosition? = nil,
                fontSize: Int = Configuration.defaultFontSize, theme: AppTheme = .system,
                hideInFullScreen: Bool = true) {
        self.mode = mode
        self.position = position
        self.fontSize = Configuration.clampedFontSize(fontSize)
        self.theme = theme
        self.hideInFullScreen = hideInFullScreen
    }

    public var showsFloatingControl: Bool { mode != .statusOnly }
}

public struct DisplayDescriptor: Equatable {
    public let id: String
    public let isBuiltIn: Bool
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let safeTopInset: CGFloat

    public init(id: String, isBuiltIn: Bool, frame: CGRect,
                visibleFrame: CGRect, safeTopInset: CGFloat = 0) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeTopInset = safeTopInset
    }
}

public struct Configuration: Codable, Equatable {
    public static let defaultFontSize = 13
    public static let fontSizes = 11...20

    public static func clampedFontSize(_ size: Int) -> Int {
        min(max(size, fontSizes.lowerBound), fontSizes.upperBound)
    }

    public var theme: AppTheme = .system
    public var fontSize: Int = defaultFontSize {
        didSet { fontSize = Self.clampedFontSize(fontSize) }
    }
    public var displayScope: DisplayScope = .widest
    public var mode: PresentationMode = .toolbar
    public var positions: [String: StoredPosition] = [:]
    public var hideInFullScreen = true
    public var neverShowOnBuiltInDisplay = false

    public init() {}

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case theme, fontSize, displayScope, mode, positions, hideInFullScreen, neverShowOnBuiltInDisplay
    }

    private struct DisplayKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve valid preferences across additions and unknown enum values.
        // Only an absent or invalid field falls back to its own default.
        hideInFullScreen = (try? values.decode(Bool.self, forKey: .hideInFullScreen)) ?? true
        neverShowOnBuiltInDisplay = (try? values.decode(Bool.self, forKey: .neverShowOnBuiltInDisplay)) ?? false
        theme = (try? values.decode(AppTheme.self, forKey: .theme)) ?? .system
        displayScope = (try? values.decode(DisplayScope.self, forKey: .displayScope)) ?? .widest
        mode = (try? values.decode(PresentationMode.self, forKey: .mode)) ?? .toolbar
        // One malformed position must not discard other displays' saved positions.
        if let saved = try? values.nestedContainer(keyedBy: DisplayKey.self, forKey: .positions) {
            for key in saved.allKeys {
                positions[key.stringValue] = try? saved.decode(StoredPosition.self, forKey: key)
            }
        }
        fontSize = Self.clampedFontSize((try? values.decode(Int.self, forKey: .fontSize)) ?? Self.defaultFontSize)
    }

    public func profile(for display: DisplayDescriptor) -> DisplayPreferences {
        DisplayPreferences(mode: mode, position: positions[display.id], fontSize: fontSize, theme: theme,
                           hideInFullScreen: hideInFullScreen)
    }

    public func targetDisplays(in displays: [DisplayDescriptor], activeDisplayID: String?) -> [DisplayDescriptor] {
        let eligible = displays.filter { !neverShowOnBuiltInDisplay || !$0.isBuiltIn }
        if displayScope == .all { return eligible }
        // Resolve against all connected displays: a known but excluded active
        // display must not be mistaken for an unknown ID and trigger fallback.
        if displayScope == .active, let active = displays.first(where: { $0.id == activeDisplayID }) {
            return neverShowOnBuiltInDisplay && active.isBuiltIn ? [] : [active]
        }
        // Logical workspace width accounts for scaling and rotation. UUID order
        // breaks ties consistently, independent of focus or enumeration order.
        let widest = eligible.sorted {
            if $0.visibleFrame.width != $1.visibleFrame.width { return $0.visibleFrame.width > $1.visibleFrame.width }
            return $0.id < $1.id
        }.first
        return widest.map { [$0] } ?? []
    }

    public mutating func resetPositions(for displayIDs: [String]) {
        for id in displayIDs { positions.removeValue(forKey: id) }
    }

    public static func uiTest() -> Configuration {
        var value = Configuration()
        value.mode = .toolbar
        return value
    }
}

public final class ConfigurationStore {
    private static let key = "CenterMyMenu.configuration.v1"
    private let defaults: UserDefaults?
    public var value: Configuration {
        didSet {
            if let data = try? JSONEncoder().encode(value) {
                defaults?.set(data, forKey: Self.key)
            }
        }
    }

    public init(defaults: UserDefaults? = .standard, initial: Configuration? = nil) {
        self.defaults = defaults
        if let initial {
            value = initial
        } else if let data = defaults?.data(forKey: Self.key),
                  let decoded = try? JSONDecoder().decode(Configuration.self, from: data) {
            value = decoded
        } else {
            value = Configuration()
            // Leave unreadable storage intact until the user changes a preference.
        }
    }
}

public struct ControlGeometry: Equatable {
    public let frame: CGRect
    public let hasHorizontalOverflow: Bool
}

public enum ControlLayout {
    public static let horizontalMargin: CGFloat = 8
    public static let belowBarGap: CGFloat = 6

    public static func place(requestedSize: CGSize, on screen: DisplayDescriptor,
                             preferences: DisplayPreferences) -> ControlGeometry {
        let frame = screen.frame
        let side = min(horizontalMargin, max(0, (frame.width - 1) / 2))
        let safeClearance = screen.safeTopInset > 0
            ? min(max(0, frame.height - 1), screen.safeTopInset + belowBarGap) : 0
        let bottomMargin = min(8, max(0, frame.height / 4))
        let ceiling = frame.maxY - safeClearance
        let floor = min(ceiling - 1,
                        max(frame.minY + bottomMargin, screen.visibleFrame.minY + bottomMargin))
        let available = CGRect(x: frame.minX + side, y: floor,
                               width: max(1, frame.width - 2 * side),
                               height: max(1, ceiling - floor))
        let width = min(max(1, requestedSize.width), available.width)
        let height = min(max(1, requestedSize.height), available.height)
        // When the menu bar auto-hides, visibleFrame may reach the physical top.
        let barHeight = max(24, frame.maxY - min(frame.maxY, screen.visibleFrame.maxY))
        let center: CGPoint
        if let saved = preferences.position {
            center = CGPoint(x: frame.minX + CGFloat(saved.horizontalFraction) * frame.width,
                             y: frame.maxY - CGFloat(saved.topOffset))
        } else if screen.safeTopInset > 0 {
            let top = frame.maxY - max(barHeight, screen.safeTopInset) - belowBarGap
            center = CGPoint(x: frame.midX, y: top - height / 2)
        } else {
            center = CGPoint(x: frame.midX, y: frame.maxY - max(height / 2, barHeight / 2))
        }
        let x = min(max(center.x - width / 2, available.minX), available.maxX - width)
        let y = min(max(center.y - height / 2, available.minY), available.maxY - height)
        return ControlGeometry(frame: CGRect(x: x, y: y, width: width, height: height),
                               hasHorizontalOverflow: requestedSize.width > width + 0.5)
    }

    public static func storedPosition(of panelFrame: CGRect, on screen: DisplayDescriptor) -> StoredPosition {
        StoredPosition(horizontalFraction: Double((panelFrame.midX - screen.frame.minX) / max(1, screen.frame.width)),
                       topOffset: Double(screen.frame.maxY - panelFrame.midY))
    }
}

