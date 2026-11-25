import AppKit
import CoreGraphics

private let displayConfigurationChanged = Notification.Name("CenterMyMenu.DisplayConfigurationChanged")

// Core Graphics calls before and after reconfiguration. Only the latter has
// current display IDs and geometry. Hop out of the callback before reading AppKit.
func displayConfigurationCallback(_ display: CGDirectDisplayID,
                                  _ flags: CGDisplayChangeSummaryFlags,
                                  _ context: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: displayConfigurationChanged, object: nil)
    }
}

@MainActor
final class DisplayConfigurationMonitor {
    private var observer: NSObjectProtocol?
    private var registered = false
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        guard observer == nil else { return }
        self.onChange = onChange
        observer = NotificationCenter.default.addObserver(forName: displayConfigurationChanged,
            object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.onChange?() }
            }
        registered = CGDisplayRegisterReconfigurationCallback(displayConfigurationCallback, nil) == .success
    }

    func stop() {
        onChange = nil
        if registered {
            CGDisplayRemoveReconfigurationCallback(displayConfigurationCallback, nil)
            registered = false
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
