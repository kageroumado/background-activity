import Foundation
import Testing

@testable import BackgroundActivity

@MainActor
@Suite("BackgroundActivity")
struct BackgroundActivityTests {
    @Test("Immediate run on start")
    func immediateRunOnStart() async throws {
        let activity = BackgroundActivity(identifier: "test.immediate")
        let counter = Counter()

        activity.registerTask { await counter.increment() }
        activity.start()

        try await counter.waitForCount(at: 1, within: .seconds(1))
        activity.stop()
    }

    @Test("Tasks execute in registration order")
    func executionOrder() async throws {
        let activity = BackgroundActivity(identifier: "test.order")
        let recorder = OrderRecorder()

        activity.registerTask { await recorder.append("first") }
        activity.registerTask { await recorder.append("second") }
        activity.registerTask { await recorder.append("third") }

        await activity.runNow()

        #expect(await recorder.entries == ["first", "second", "third"])
    }

    @Test("runNow updates lastTaskRun")
    func runNowUpdatesTimestamp() async {
        let activity = BackgroundActivity(identifier: "test.timestamp")
        #expect(activity.lastTaskRun == nil)

        await activity.runNow()

        #expect(activity.lastTaskRun != nil)
    }

    @Test("start is idempotent")
    func startIsIdempotent() async throws {
        let activity = BackgroundActivity(identifier: "test.idempotent.start")
        let counter = Counter()
        activity.registerTask { await counter.increment() }

        activity.start()
        activity.start()
        activity.start()

        // Give the immediate run a chance to fire exactly once.
        try await Task.sleep(for: .milliseconds(100))
        #expect(activity.isRunning)
        // Multiple start() calls must not enqueue multiple immediate runs.
        #expect(await counter.value == 1)

        activity.stop()
    }

    @Test("stop is safe before start")
    func stopBeforeStart() {
        let activity = BackgroundActivity(identifier: "test.stop.early")
        activity.stop() // must not crash, must remain not running
        #expect(!activity.isRunning)
    }

    @Test("isRunning reflects lifecycle")
    func isRunningLifecycle() async throws {
        let activity = BackgroundActivity(identifier: "test.isRunning")
        #expect(!activity.isRunning)

        activity.start()
        #expect(activity.isRunning)

        activity.stop()
        #expect(!activity.isRunning)
    }

    @Test("Activation trigger runs tasks if minimum interval elapsed")
    func activationTriggersRun() async throws {
        let observer = AppActivationObserver(bundleIdentifier: nil)
        // interval=0 disables the system scheduler, so activation is the only trigger.
        let activity = BackgroundActivity(
            identifier: "test.activation",
            interval: 0,
            activationObserver: observer,
        )

        let counter = Counter()
        activity.registerTask { await counter.increment() }
        activity.start()

        // Wait for the immediate-on-start run.
        try await counter.waitForCount(at: 1, within: .seconds(1))

        // With interval=0, any activation should trigger a run.
        observer._simulateActivation()

        try await counter.waitForCount(at: 2, within: .seconds(1))
        activity.stop()
    }

    @Test("Activation trigger is suppressed within minimum interval")
    func activationSuppressedWithinInterval() async throws {
        let observer = AppActivationObserver(bundleIdentifier: nil)
        let activity = BackgroundActivity(
            identifier: "test.activation.suppressed",
            interval: 0,
            activationObserver: observer,
        )

        // Inject a very-recent lastTaskRun and a long suppression interval by
        // running once, then immediately simulating activation. With interval=0,
        // we need to drive suppression a different way: register a stop after
        // the start's immediate run and verify activation while running.
        let counter = Counter()
        activity.registerTask { await counter.increment() }

        // Use the public init with a non-zero interval to exercise suppression.
        // (We re-create instead of mutating to keep the API immutable.)
        let suppressing = BackgroundActivity(
            identifier: "test.activation.suppressed.real",
            interval: 60,
            activationObserver: observer,
        )
        suppressing.registerTask { await counter.increment() }
        suppressing.start()

        try await counter.waitForCount(at: 1, within: .seconds(1))

        observer._simulateActivation()
        // Give the listener a moment — the run should NOT happen.
        try await Task.sleep(for: .milliseconds(150))

        #expect(await counter.value == 1)
        suppressing.stop()
        _ = activity // silence unused warning
    }
}

@MainActor
@Suite("AppActivationObserver")
struct AppActivationObserverTests {
    @Test("Simulated activation updates state")
    func simulatedActivation() {
        let observer = AppActivationObserver(bundleIdentifier: nil)
        #expect(observer.lastActivationTime == nil)
        #expect(!observer.isAppActive)

        let now = Date()
        observer._simulateActivation(at: now)

        #expect(observer.isAppActive)
        #expect(observer.lastActivationTime == now)
    }

    @Test("Multiple streams each receive activations")
    func multipleStreamsEach() async throws {
        let observer = AppActivationObserver(bundleIdentifier: nil)
        let stream1 = observer.makeActivationsStream()
        let stream2 = observer.makeActivationsStream()

        async let first: Date? = stream1.first(where: { _ in true })
        async let second: Date? = stream2.first(where: { _ in true })

        // Give the streams a moment to subscribe.
        try await Task.sleep(for: .milliseconds(20))
        observer._simulateActivation()

        let (a, b) = await (first, second)
        #expect(a != nil)
        #expect(b != nil)
    }
}

// MARK: - Test Helpers

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }

    func waitForCount(at target: Int, within timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while value < target {
            if ContinuousClock.now >= deadline {
                throw CountTimeout(expected: target, actual: value)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    struct CountTimeout: Error, CustomStringConvertible {
        let expected: Int
        let actual: Int
        var description: String { "Counter timed out: expected \(expected), actual \(actual)" }
    }
}

private actor OrderRecorder {
    private(set) var entries: [String] = []

    func append(_ entry: String) {
        entries.append(entry)
    }
}
