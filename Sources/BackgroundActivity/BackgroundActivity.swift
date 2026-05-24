import Foundation
import Observation
import os

/// Coordinates periodic background tasks using `NSBackgroundActivityScheduler`.
///
/// `BackgroundActivity` runs registered tasks on three triggers:
///
/// 1. **System-scheduled** via `NSBackgroundActivityScheduler` at a configurable
///    interval (with tolerance so the system can batch, defer, or skip work based
///    on battery, thermal, and CPU state).
/// 2. **On app activation** if at least `minimumInterval` has elapsed since the
///    last successful run. This catches the common case where the app was idle
///    long enough that the scheduler skipped runs.
/// 3. **Immediately on `start()`** so the app has fresh state at launch.
///
/// ## Usage
///
/// ```swift
/// let observer = AppActivationObserver()
/// let activity = BackgroundActivity(
///     identifier: "com.example.app.hourly",
///     interval: 3_600,
///     tolerance: 600,
///     activationObserver: observer
/// )
///
/// activity.registerTask { [weak self] in
///     await self?.refreshFeed()
/// }
///
/// activity.registerTask { [weak archiver] in
///     await archiver?.clearExpiredItems()
/// }
///
/// activity.start()
/// ```
///
/// ## Power Efficiency
///
/// `NSBackgroundActivityScheduler` is the energy-aware option for periodic work
/// on macOS. The system may defer, batch, or skip your task based on battery
/// and thermal conditions. A larger `tolerance` value gives the system more
/// flexibility — values around 10–20% of the interval are reasonable.
///
/// ## Thread Safety
///
/// All public methods are `@MainActor`. Registered tasks run in the order they
/// were registered.
@MainActor
@Observable
public final class BackgroundActivity {
    // MARK: - Observable State

    /// Timestamp of the last successful task run.
    public private(set) var lastTaskRun: Date?

    /// Whether `start()` has been called and `stop()` has not.
    public private(set) var isRunning: Bool = false

    // MARK: - Configuration

    @ObservationIgnored
    private let identifier: String

    @ObservationIgnored
    private let interval: TimeInterval

    @ObservationIgnored
    private let tolerance: TimeInterval

    @ObservationIgnored
    private let qualityOfService: QualityOfService

    @ObservationIgnored
    private let logger: Logger

    // MARK: - Dependencies

    @ObservationIgnored
    private let activationObserver: AppActivationObserver?

    // MARK: - Private State

    @ObservationIgnored
    private var scheduler: NSBackgroundActivityScheduler?

    @ObservationIgnored
    private var registeredTasks: [@Sendable () async -> Void] = []

    @ObservationIgnored
    private var activationTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a background activity coordinator.
    ///
    /// - Parameters:
    ///   - identifier: Reverse-DNS identifier for the underlying scheduler.
    ///     Pass a unique string per coordinator (e.g., `"com.example.app.hourly"`).
    ///   - interval: Interval between scheduled runs, in seconds. Must be ≥ 1 to
    ///     arm the system scheduler. Pass `0` (or any value < 1) to disable
    ///     scheduled runs entirely; tasks will then run only on `start()`,
    ///     activation, or `runNow()`. Defaults to 1 hour.
    ///   - tolerance: How much the system may shift each run, in seconds.
    ///     Larger values save more energy. Defaults to 10 minutes. Ignored when
    ///     `interval < 1`.
    ///   - qualityOfService: QoS for the scheduler. Defaults to `.background`.
    ///   - activationObserver: Optional observer that, when provided, triggers an
    ///     immediate run if the app activates and at least `interval` has elapsed
    ///     since the last successful run. Pass `nil` to disable activation triggers.
    ///   - logger: Logger used for diagnostic messages. Defaults to a no-op logger.
    public init(
        identifier: String,
        interval: TimeInterval = 3_600,
        tolerance: TimeInterval = 600,
        qualityOfService: QualityOfService = .background,
        activationObserver: AppActivationObserver? = nil,
        logger: Logger = Logger(.disabled),
    ) {
        self.identifier = identifier
        self.interval = interval
        self.tolerance = tolerance
        self.qualityOfService = qualityOfService
        self.activationObserver = activationObserver
        self.logger = logger
    }

    // MARK: - Task Registration

    /// Registers an async task to run on each scheduled tick.
    ///
    /// Tasks execute sequentially in registration order. Registration is only
    /// valid before ``start()`` is called; tasks added after starting are still
    /// stored but their first run depends on when the next tick happens.
    public func registerTask(_ task: @escaping @Sendable () async -> Void) {
        registeredTasks.append(task)
    }

    // MARK: - Lifecycle

    /// Starts the scheduler.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops.
    /// On the first call, tasks run immediately and the system scheduler is armed.
    public func start() {
        guard !isRunning else { return }
        isRunning = true

        // Immediate run so consumers see fresh state at launch.
        Task { await runTasks() }

        startActivationListener()

        if interval >= 1 {
            let scheduler = NSBackgroundActivityScheduler(identifier: identifier)
            scheduler.interval = interval
            // NSBackgroundActivityScheduler requires 0 < tolerance ≤ interval/2; clamp defensively.
            scheduler.tolerance = max(1, min(tolerance, interval / 2))
            scheduler.repeats = true
            scheduler.qualityOfService = qualityOfService
            scheduler.schedule { [weak self] completion in
                Task { @MainActor [weak self] in
                    guard let self else {
                        completion(.finished)
                        return
                    }

                    if self.scheduler?.shouldDefer == true {
                        completion(.deferred)
                        return
                    }

                    await self.runTasks()
                    completion(.finished)
                }
            }
            self.scheduler = scheduler
        }

        logger.debug("BackgroundActivity '\(self.identifier, privacy: .public)' started")
    }

    /// Stops the scheduler.
    ///
    /// Cancels the activation listener and invalidates the system scheduler.
    /// Tasks already in flight continue to completion.
    public func stop() {
        guard isRunning else { return }
        isRunning = false

        activationTask?.cancel()
        activationTask = nil

        scheduler?.invalidate()
        scheduler = nil

        logger.debug("BackgroundActivity '\(self.identifier, privacy: .public)' stopped")
    }

    /// Manually triggers a run.
    ///
    /// Useful for "Run Now" UI affordances. Updates `lastTaskRun` like any other run.
    public func runNow() async {
        await runTasks()
    }

    // MARK: - Private

    private func startActivationListener() {
        guard let activationObserver else { return }

        activationTask = Task { [weak self] in
            guard let self else { return }

            for await _ in activationObserver.makeActivationsStream() {
                guard !Task.isCancelled else { break }

                if let lastRun = self.lastTaskRun {
                    let elapsed = Date().timeIntervalSince(lastRun)
                    guard elapsed >= self.interval else { continue }
                }

                await self.runTasks()
            }
        }
    }

    private func runTasks() async {
        lastTaskRun = Date()

        for task in registeredTasks {
            await task()
        }

        logger.debug("BackgroundActivity '\(self.identifier, privacy: .public)' completed \(self.registeredTasks.count) task(s)")
    }
}
