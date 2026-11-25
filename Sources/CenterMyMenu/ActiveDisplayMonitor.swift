import AppKit

/// Active-screen changes need not change the app or display configuration.
/// Sample AppKit's active screen only in Active display mode; never track mouse movement.
@MainActor
final class ActiveDisplayMonitor: NSObject {
    private let currentID: () -> String?
    private let onChange: () -> Void
    private var timer: Timer?
    private var previousID: String?

    init(currentID: @escaping () -> String?, onChange: @escaping () -> Void) {
        self.currentID = currentID
        self.onChange = onChange
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard timer == nil else { return }
        previousID = currentID()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func sample() {
        let next = currentID()
        guard next != previousID else { return }
        previousID = next
        onChange()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        previousID = nil
    }
}
