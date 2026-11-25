import AppKit
import CenterMyMenuCore

/// Serializes root reads across target changes as well as within one target. AX
/// work already submitted cannot be recalled, so a replacement waits for that one
/// bounded read instead of adding an unbounded collection of superseded AX jobs.
@MainActor
final class RootMenuLoader: NSObject {
    var onSnapshot: ((MenuSnapshot) -> Void)?
    var onRead: (() -> Void)?
    var onRetry: ((AppIdentity) -> Void)?
    private(set) var snapshot: MenuSnapshot?
    var hasScheduledRetry: Bool { retryTimer != nil }

    private struct Context: Equatable {
        let identity: AppIdentity
        let accessAllowed: Bool
    }
    private struct Read {
        let ticket = UUID()
        let generation: UUID
        let session: MenuSession
    }

    private var context: Context?
    private var currentSession: MenuSession?
    private var generation = UUID()
    private var inFlight: Read?
    private var pendingRead = false
    private var retryAllowed = false
    private var suspended = false
    private var stopped = false
    private var presentationTimer: Timer?
    private var pendingPresentation: MenuSnapshot?
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval?
    private var backoff: MenuReadinessBackoff

    init(backoff: MenuReadinessBackoff = MenuReadinessBackoff()) {
        self.backoff = backoff
        super.init()
    }

    func request(session: MenuSession, accessAllowed: Bool, retryAllowed: Bool, force: Bool) {
        guard !stopped else { return }
        let next = Context(identity: session.identity, accessAllowed: accessAllowed)
        let changed = context != next
        self.retryAllowed = accessAllowed && retryAllowed
        if changed {
            // Keep usable headings briefly while the new target loads. Reads
            // start immediately; only empty presentation is delayed. The
            // controller revalidates the target before opening a heading.
            let deferEmptyPresentation = accessAllowed && context?.accessAllowed == true
                && (pendingPresentation != nil
                    || snapshot?.batch.entries.contains(where: { !$0.isSeparator }) == true)
            cancelPresentation()
            if deferEmptyPresentation {
                let timer = Timer(timeInterval: 0.15, target: self,
                    selector: #selector(presentationFired(_:)), userInfo: nil, repeats: false)
                presentationTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            cancelTimer()
            context = next
            generation = UUID() // Permission changes also invalidate an authorized completion.
            currentSession = session
            pendingRead = true
            retryDelay = nil
            backoff.reset()
            publish(MenuSnapshot(session: session,
                batch: MenuBatch(entries: [], message: "Waiting for \(session.applicationName) menus…", status: .loading)))
        } else if force, inFlight?.generation != generation {
            // Repeated refresh/hover/activation requests for the read already in
            // progress are coalesced, not scheduled as another read after it.
            cancelTimer()
            currentSession = session
            pendingRead = true
        }
        if !self.retryAllowed { cancelTimer() }
        pump()
        armRetry()
    }

    func setSuspended(_ value: Bool) {
        guard !stopped, suspended != value else { return }
        suspended = value
        if value {
            cancelTimer()
        } else {
            pump()
            armRetry()
        }
    }

    func stop() {
        stopped = true
        cancelPresentation()
        generation = UUID()
        cancelTimer()
        pendingRead = false
        retryDelay = nil
        currentSession = nil
        context = nil
    }

    private func publish(_ value: MenuSnapshot) {
        snapshot = value
        if presentationTimer != nil, value.batch.entries.isEmpty,
           value.batch.status != .permissionRequired {
            pendingPresentation = value
            return
        }
        cancelPresentation()
        onSnapshot?(value)
    }

    private func cancelPresentation() {
        presentationTimer?.invalidate()
        presentationTimer = nil
        pendingPresentation = nil
    }

    @objc private func presentationFired(_ timer: Timer) {
        guard presentationTimer === timer else { return }
        let value = pendingPresentation
        cancelPresentation()
        if !stopped, let value { onSnapshot?(value) }
    }

    private func pump() {
        guard !stopped, !suspended, pendingRead, inFlight == nil,
              let session = currentSession else { return }
        pendingRead = false
        retryDelay = nil
        cancelTimer()
        let read = Read(generation: generation, session: session)
        inFlight = read // Set before invoking a provider, including synchronous test providers.
        onRead?()
        session.loadChildren(of: nil) { [weak self] batch in self?.complete(read, with: batch) }
    }

    private func complete(_ read: Read, with batch: MenuBatch) {
        guard inFlight?.ticket == read.ticket else { return }
        inFlight = nil
        guard !stopped else { return }
        if generation == read.generation {
            retryDelay = backoff.delay(after: batch)
            publish(MenuSnapshot(session: read.session, batch: batch))
        }
        // Publishing can synchronously change the context. Always consult the
        // current generation/pending request, not the completed read, from here on.
        pump()
        armRetry()
    }

    private func armRetry() {
        guard !stopped, !suspended, retryAllowed, !pendingRead, inFlight == nil,
              retryTimer == nil, let retryDelay, onRetry != nil else { return }
        let timer = Timer(timeInterval: retryDelay, target: self,
                          selector: #selector(retryFired(_:)), userInfo: nil, repeats: false)
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    @objc private func retryFired(_ timer: Timer) {
        guard retryTimer === timer else { return }
        cancelTimer()
        guard !stopped, !suspended, retryAllowed, inFlight == nil,
              let context else { return }
        // The controller must recheck permission, the live menu-bar owner and
        // termination BEFORE requesting another read. The timer never queries AX.
        onRetry?(context.identity)
    }
}
