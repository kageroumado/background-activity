import AppKit
import Observation

/// Observes app activation events on macOS.
///
/// `AppActivationObserver` tracks when your app becomes the frontmost application,
/// publishing activation events via an `AsyncStream` and storing the most recent
/// activation timestamp.
///
/// ## Why This Exists
///
/// `NSWorkspace.didActivateApplicationNotification` is global — it fires for every
/// application that activates, not just yours. This observer filters to your own
/// bundle identifier and exposes the result through a structured-concurrency API.
///
/// ## Usage
///
/// ```swift
/// let observer = AppActivationObserver()
///
/// // Read the last activation time
/// if let lastActive = observer.lastActivationTime {
///     let idleTime = Date().timeIntervalSince(lastActive)
/// }
///
/// // Subscribe to future activations
/// for await date in observer.makeActivationsStream() {
///     print("App activated at \(date)")
/// }
/// ```
@MainActor
@Observable
public final class AppActivationObserver {
    // MARK: - State

    /// Whether the app is currently frontmost.
    ///
    /// Initialized to `false` until the first activation event is observed.
    public private(set) var isAppActive: Bool = false

    /// Timestamp of the most recent activation.
    ///
    /// `nil` until the app activates for the first time after this observer is created.
    public private(set) var lastActivationTime: Date?

    // MARK: - Async Sequence

    /// Returns an async stream that yields the date of each activation event.
    ///
    /// Each call creates a new independent subscription. Streams finish when this
    /// observer is deallocated.
    public func makeActivationsStream() -> AsyncStream<Date> {
        let (stream, continuation) = AsyncStream.makeStream(of: Date.self)
        let id = UUID()
        continuations[id] = continuation

        continuation.onTermination = { @Sendable [weak self] _ in
            DispatchQueue.main.async { self?.continuations.removeValue(forKey: id) }
        }

        return stream
    }

    // MARK: - Private

    @ObservationIgnored
    private var continuations: [UUID: AsyncStream<Date>.Continuation] = [:]

    @ObservationIgnored
    private nonisolated(unsafe) var activationObserver: (any NSObjectProtocol)?

    @ObservationIgnored
    private nonisolated(unsafe) var deactivationObserver: (any NSObjectProtocol)?

    @ObservationIgnored
    private let bundleIdentifier: String?

    // MARK: - Initialization

    /// Creates a new activation observer.
    ///
    /// - Parameter bundleIdentifier: The bundle ID to filter activation events to.
    ///   Defaults to `Bundle.main.bundleIdentifier`. Pass `nil` to receive activation
    ///   events for any application.
    public init(bundleIdentifier: String? = Bundle.main.bundleIdentifier) {
        self.bundleIdentifier = bundleIdentifier
        setupObservers()
    }

    deinit {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupObservers() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            guard self.matchesFilter(notification) else { return }
            MainActor.assumeIsolated { self.handleActivation() }
        }

        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self] notification in
            guard let self else { return }
            guard self.matchesFilter(notification) else { return }
            MainActor.assumeIsolated { self.handleDeactivation() }
        }
    }

    private nonisolated func matchesFilter(_ notification: Notification) -> Bool {
        guard let target = bundleIdentifier else { return true }
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return false }
        return app.bundleIdentifier == target
    }

    private func handleActivation() {
        isAppActive = true

        let now = Date()
        lastActivationTime = now

        for continuation in continuations.values {
            continuation.yield(now)
        }
    }

    private func handleDeactivation() {
        isAppActive = false
    }

    // MARK: - Testing Hooks

    /// Synthesizes an activation event for testing.
    ///
    /// Useful in tests that want to drive activation behavior without depending on
    /// `NSWorkspace` notifications, which can't easily be triggered in a process
    /// that isn't frontmost.
    public func _simulateActivation(at date: Date = Date()) {
        isAppActive = true
        lastActivationTime = date
        for continuation in continuations.values {
            continuation.yield(date)
        }
    }
}
