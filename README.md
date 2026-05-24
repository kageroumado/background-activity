# BackgroundActivity

A small, energy-aware wrapper around `NSBackgroundActivityScheduler` for macOS. Run periodic work without keeping the CPU pinned, and *also* run it the moment the user comes back to the app — the part Apple's API leaves you to wire up yourself.

## What it does

Tasks fire on three triggers:

1. **System-scheduled** at a configurable interval, with tolerance so the OS can defer, batch, or skip work based on battery, thermal state, and CPU load.
2. **On app activation** if at least `interval` has elapsed since the last successful run. Catches the common case where the system deferred your tasks while the user was away, so they don't see stale state when they switch back.
3. **Immediately on `start()`**, so launch state is fresh.

Two types: `BackgroundActivity` (the scheduler) and `AppActivationObserver` (a filtered `NSWorkspace.didActivateApplicationNotification` adapter with an `AsyncStream`).

## Why not `Timer` or `BGTaskScheduler`

`Timer` ignores the system's energy hints — it'll keep firing whether the laptop is on battery or thermally throttled. `NSBackgroundActivityScheduler` is the energy-aware option, but its API is awkward and it has no concept of "the user just came back, run sooner."

`BGTaskScheduler` is for waking the app *after* it's been terminated — a different problem.

## Installation

Requires macOS 14.

```swift
dependencies: [
    .package(url: "https://github.com/kageroumado/background-activity", from: "1.0.0"),
],
targets: [
    .target(name: "App", dependencies: ["BackgroundActivity"]),
],
```

## Usage

```swift
import BackgroundActivity

let observer = AppActivationObserver()
let activity = BackgroundActivity(
    identifier: "com.example.app.hourly",
    interval: 3_600,                  // 1 hour
    tolerance: 600,                   // ±10 min — let the system batch
    activationObserver: observer,     // optional; enables activation triggers
)

activity.registerTask { await archive.clearExpiredItems() }
activity.registerTask { await indexer.indexNewDocuments() }

activity.start()
```

`stop()` to tear down. `runNow()` to force a run (useful for a "Run Now" button in settings).

### Activation-only mode

Pass `interval: 0` to skip the system scheduler entirely. Tasks then run only on `start()`, `runNow()`, and activations.

```swift
let activity = BackgroundActivity(
    identifier: "com.example.app.onActivation",
    interval: 0,
    activationObserver: observer,
)
```

### Test hooks

Both types expose synchronous test entry points so you can exercise them without driving `NSWorkspace` notifications.

```swift
let observer = AppActivationObserver(bundleIdentifier: nil)
observer._simulateActivation()
await activity.runNow()
```

The package's own test suite uses these — see `BackgroundActivityTests` for examples.

## In production

Used by [Refrax](https://github.com/kageroumado/refrax), a WebKit-based browser for macOS, to drive tab-archive expiration and auto-archive rules across long idle periods. The activation-trigger behavior was added after a user reported that returning to the browser after the weekend showed tabs that should have been archived already — the scheduler had been deferred for so long that nothing had run since they last opened the app.

## License

[MIT](LICENSE).
