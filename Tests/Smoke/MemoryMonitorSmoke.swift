import AppKit
import Darwin
import Foundation
import os

// The memory monitor: real numbers from this Mac, grouping and order on fixed samples.

private enum SmokeFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

/// Keeps one core busy for a moment, so this process has CPU time between two samples.
private func spin(milliseconds: Int) -> UInt64 {
    let end = ContinuousClock.now + .milliseconds(milliseconds)
    var value: UInt64 = 1
    while ContinuousClock.now < end { value = value &* 6364136223846793005 &+ 1442695040888963407 }
    return value
}

/// Waits until the scan the model started has ended (it finishes or is cancelled).
@MainActor
private func waitForScan(_ app: AppModel) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while app.isScanning {
        if ContinuousClock.now > deadline { throw SmokeFailure.assertion("the scan did not end within 30 s") }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// Waits until the monitor has measured the processes once.
@MainActor
private func waitUntilMeasured(_ m: MemoryMonitorModel) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while m.measuring {
        if ContinuousClock.now > deadline { throw SmokeFailure.assertion("the monitor did not measure within 10 s") }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// Bytes in use in every malloc zone of this process.
private func mallocInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return Int(stats.size_in_use)
}

// MARK: - The menu bar figure (M10-M19): fakes

private final class Counter: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: 0)
    func add() { storage.withLock { $0 += 1 } }
    var value: Int { storage.withLock { $0 } }
}

private final class Flag: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: false)
    func set(_ value: Bool = true) { storage.withLock { $0 = value } }
    var value: Bool { storage.withLock { $0 } }
}

private final class ManualClock: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: Int64(0))
    var now: Int64 {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private final class LogSink: MenuBarLogging {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    func notice(_ line: String) { storage.withLock { $0.append(line) } }
    var lines: [String] { storage.withLock { $0 } }
    func count(prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
    func has(prefix: String) -> Bool { count(prefix: prefix) > 0 }
    func has(containing text: String) -> Bool { lines.contains { $0.contains(text) } }
}

@MainActor
private final class FakeDisplay: MenuBarDisplay {
    private(set) var shown: [MenuBarLabel] = []
    private(set) var label = MenuBarLabel.unknown
    func show(_ label: MenuBarLabel) {
        shown.append(label)
        self.label = label
    }
}

@MainActor
private final class ScriptedSampler {
    var script: [MemorySnapshot?]
    private(set) var calls = 0
    private(set) var onMainThread: [Bool] = []

    init(_ script: [MemorySnapshot?]) { self.script = script }

    func next() -> MemorySnapshot? {
        onMainThread.append(Thread.isMainThread)
        guard !script.isEmpty else { return nil }
        let index = min(calls, script.count - 1)
        calls += 1
        return script[index]
    }
}

@MainActor
private final class ManualScheduler: TickScheduler {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var intervals: [Int64] = []
    private(set) var tolerances: [Int64] = []
    private var fire: (@MainActor @Sendable () -> Void)?

    func start(intervalMs: Int64, toleranceMs: Int64, _ fire: @escaping @MainActor @Sendable () -> Void) {
        starts += 1
        intervals.append(intervalMs)
        tolerances.append(toleranceMs)
        self.fire = fire
    }

    func stop() { stops += 1 }
}

@MainActor
private final class FactsBox {
    var value = RelaunchFacts.noRelaunch
}

@MainActor
private final class MenuBarRig {
    let clock = ManualClock()
    let display = FakeDisplay()
    let sampler: ScriptedSampler
    let scheduler = ManualScheduler()
    let log = LogSink()
    let heartbeat: MenuBarHeartbeat
    let monitor = MemoryMonitorModel()
    let facts = FactsBox()
    let controller: MenuBarController

    init(script: [MemorySnapshot?]) {
        let clock = clock
        let sampler = ScriptedSampler(script)
        let heartbeat = MenuBarHeartbeat(now: 0)
        let facts = facts
        self.sampler = sampler
        self.heartbeat = heartbeat
        controller = MenuBarController(
            monitor: monitor, display: display, sampler: { sampler.next() }, clock: { clock.now },
            heartbeat: heartbeat, scheduler: scheduler, log: log, facts: { facts.value }, debugMarker: false)
    }
}

private func fakeSnapshot(
    percent: Int64, level: UInt32 = UInt32(MM_LEVEL_NORMAL), used: Int64 = 1000, pressure: Int64 = 1
) -> MemorySnapshot {
    var snapshot = MemorySnapshot()
    snapshot.total = 10_000
    snapshot.used = used
    snapshot.percent = percent
    snapshot.levelCode = level
    snapshot.pressureCode = pressure
    return snapshot
}

/// Runs the main run loop. The smoke binary has no NSApplication, and its `@main` body runs inside a main-queue
/// job, where a nested `CFRunLoopRunInMode` returns at once when the mode has no timer, source or queued block.
/// The no-op timer keeps the mode busy. (No `DispatchSemaphore.wait` on the main actor.)
@MainActor
private func pumpMainRunLoop(seconds: Double, until done: () -> Bool = { false }) {
    let keepAlive = Timer(timeInterval: 0.01, repeats: true) { _ in }
    RunLoop.main.add(keepAlive, forMode: .default)
    defer { keepAlive.invalidate() }
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while !done() && ContinuousClock.now < deadline {
        _ = CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }
}

/// Runs `work` on a global dispatch queue. Written outside any actor: the closure literal for the Dispatch
/// block must not become @MainActor (the isolation rule in MemoryMonitor.swift).
private func runOnGlobalQueue(_ work: @escaping @Sendable () -> Void) {
    DispatchQueue.global().async { work() }
}

/// A watchdog with scripted hooks, driven by `check(now:)`.
private final class RelaunchRig: Sendable {
    let heartbeat = MenuBarHeartbeat(now: 0)
    let log = LogSink()
    let clock = ManualClock()
    let nudges = Counter()
    let spawns = Counter()
    let exits = Counter()
    let watchdog: MenuBarWatchdog

    init(
        facts: RelaunchFacts = RelaunchFacts(windowOpen: false, appHidden: false, canQuit: true, queued: 0, keepsToolState: false),
        canRelaunch: Bool = true, relaunched: Bool = false, installAt: Int64 = 0,
        spawnRC: Int32 = 0, waitStatus: Int32? = 0
    ) {
        let nudges = nudges, spawns = spawns, exits = exits, clock = clock
        let hooks = MenuBarRelaunchHooks(
            spawn: { spawns.add(); return (spawnRC, 4242) },
            waitExit: { _, _ in waitStatus },
            exit: { exits.add() }
        )
        watchdog = MenuBarWatchdog(
            heartbeat: heartbeat, installAt: installAt, clock: { clock.now },
            nudge: { nudges.add() }, echo: {}, log: log,
            canRelaunch: canRelaunch, relaunched: relaunched, hooks: hooks)
        heartbeat.tick(at: 0, facts: facts)
    }

    /// Checks every 5000 ms from `from` to `through`.
    func run(from: Int64, through: Int64) {
        var now = from
        while now <= through {
            clock.now = now
            watchdog.check(now: now)
            now += 5000
        }
    }
}

@MainActor
private func menuBarChecks() throws {
    let reasonNone = UInt32(MM_WATCHDOG_NONE)
    let nudge = UInt32(MM_WATCHDOG_NUDGE)

    // M10: the label shows what is true, and a change of the number alone waits (Specs/memory_rules.t27).
    do {
        let rig = MenuBarRig(script: [
            nil,                                                                                  // 1
            fakeSnapshot(percent: 85, used: 1000),                                                // 2
            fakeSnapshot(percent: 85, used: 2000),                                                // 3
            fakeSnapshot(percent: 79, used: 3000), fakeSnapshot(percent: 79, used: 3000),         // 4
            fakeSnapshot(percent: 79, level: UInt32(MM_LEVEL_WARNING), used: 3500, pressure: 2),  // 5
            fakeSnapshot(percent: 80, level: UInt32(MM_LEVEL_WARNING), used: 3600, pressure: 2),  // 6
            nil, nil, nil,                                                                        // 7
            fakeSnapshot(percent: 81, used: 3700),                                                // 8
        ])
        // 1: no good sample yet.
        rig.clock.now = 1000
        rig.controller.tick(.launch)
        try require(rig.display.shown.isEmpty, "M10.1: a label was shown before a good sample")
        try require(rig.display.label.title == "—%", "M10.1: the label model is not unknown")
        try require(rig.monitor.percentText == "—%", "M10.1: the panel text is not unknown")
        // 2: the first good sample shows at once.
        rig.clock.now = 2000
        rig.controller.tick(.launch)
        try require(rig.display.shown.count == 1 && rig.display.label.title == "85%"
                    && rig.display.label.symbol == "memorychip", "M10.2: \(rig.display.shown)")
        try require(rig.display.label.accessibility == "Memory 85% used, pressure Normal", "M10.2: accessibility")
        try require(rig.monitor.snapshot.used == 1000 && rig.monitor.percentText == "85%", "M10.2: panel snapshot")
        // 3: same percent, other bytes: nothing is shown or published.
        rig.clock.now = 2500
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 1, "M10.3: shown again for the same percent")
        try require(rig.monitor.snapshot.used == 1000, "M10.3: the closed panel's snapshot was published")
        // 4: 79 percent from a timer tick waits until 2000 ms after the show.
        rig.clock.now = 3000
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 1, "M10.4: a number-only change was shown after 1000 ms")
        rig.clock.now = 4000
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 2 && rig.display.label.title == "79%", "M10.4: \(rig.display.shown)")
        // 5: a level change is due at once and fills the chip.
        rig.clock.now = 4500
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 3 && rig.display.label.symbol == "memorychip.fill",
                    "M10.5: \(rig.display.shown)")
        // 6: a forced tick shows a number-only change at once.
        rig.clock.now = 4600
        rig.controller.tick(.pressure)
        try require(rig.display.shown.count == 4 && rig.display.label.title == "80%", "M10.6: \(rig.display.shown)")
        // 7: three failed samples in a row make the figure unknown.
        let failed = rig.log.count(prefix: "sample-failed")
        let unknown = rig.log.count(prefix: "unknown")
        rig.clock.now = 5000
        rig.controller.tick(.timer)
        rig.clock.now = 6000
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 4 && rig.monitor.percentText == "80%", "M10.7: unknown too early")
        rig.clock.now = 7000
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 5 && rig.display.label.title == "—%", "M10.7: \(rig.display.shown)")
        try require(!rig.monitor.known && rig.monitor.percentText == "—%", "M10.7: the panel still shows a number")
        try require(rig.log.count(prefix: "sample-failed") == failed + 1, "M10.7: sample-failed not logged once")
        try require(rig.log.count(prefix: "unknown") == unknown + 1, "M10.7: unknown not logged once")
        // 8: a good sample brings the number back at once.
        rig.clock.now = 7100
        rig.controller.tick(.timer)
        try require(rig.display.shown.count == 6 && rig.display.label.title == "81%", "M10.8: \(rig.display.shown)")
        try require(rig.monitor.known && rig.monitor.percentText == "81%", "M10.8: the panel is still unknown")
        try require(MenuBarLabel.make(percent: 5, level: 0, known: true, debugMarker: true).symbol == "ladybug",
                    "M10: the debug marker is missing")
    }

    // M11: the heartbeat.
    do {
        let rig = MenuBarRig(script: [fakeSnapshot(percent: 50)])
        let facts = RelaunchFacts(windowOpen: false, appHidden: false, canQuit: true, queued: 2, keepsToolState: false)
        rig.facts.value = facts
        rig.clock.now = 5000
        rig.controller.tick(.timer)
        let state = rig.heartbeat.read()
        try require(state.tickAt == 5000, "M11: tickAt \(state.tickAt)")
        try require(state.facts == facts, "M11: the facts were not copied")
        try require(rig.heartbeat.beginEcho(), "M11: first echo refused")
        try require(!rig.heartbeat.beginEcho(), "M11: second echo allowed while pending")
        rig.heartbeat.recordCheck(at: 123, staleChecks: 5)
        rig.heartbeat.reset(now: 9000)
        let reset = rig.heartbeat.read()
        try require(reset.tickAt == 9000 && reset.echoAt == 9000 && reset.lastCheckAt == 9000, "M11: reset times \(reset)")
        try require(reset.staleChecks == 0 && !reset.echoPending, "M11: reset counters \(reset)")
        try require(reset.facts == facts, "M11: reset lost the facts")
        try require(rig.heartbeat.beginEcho(), "M11: echo still pending after reset")
    }

    // M12: the watchdog's decisions, one check every 5000 ms.
    do {
        let heartbeat = MenuBarHeartbeat(now: 0)
        let log = LogSink()
        let nudges = Counter()
        let watchdog = MenuBarWatchdog(
            heartbeat: heartbeat, installAt: 0, clock: { 0 }, nudge: { nudges.add() }, echo: {}, log: log,
            canRelaunch: false, relaunched: false, hooks: nil)
        func check(_ now: Int64, tickFresh: Bool, echoFresh: Bool = true) -> UInt32 {
            if tickFresh { heartbeat.tick(at: now, facts: .noRelaunch) }
            if echoFresh { heartbeat.echo(at: now) }
            return watchdog.check(now: now)
        }
        try require(check(5000, tickFresh: false) == reasonNone, "M12: first check")
        try require(check(10000, tickFresh: false) == reasonNone, "M12: tick age 10000 is not stale")
        try require(check(15000, tickFresh: false) == nudge && nudges.value == 1, "M12: no nudge at tick age 15000")
        try require(log.has(prefix: "nudge reason=tick"), "M12: reason=tick not logged")
        var now: Int64 = 15000
        for _ in 0..<11 {
            now += 5000
            _ = check(now, tickFresh: false)
        }
        try require(nudges.value == 1, "M12: nudged again within 12 stale checks: \(nudges.value)")
        now += 5000
        try require(check(now, tickFresh: false) == nudge && nudges.value == 2, "M12: no re-nudge on the 12th stale check")
        now += 5000
        try require(check(now, tickFresh: true) == UInt32(MM_WATCHDOG_RECOVERED), "M12: no recovery")
        try require(log.count(prefix: "recovered") == 1, "M12: recovered not logged once")
        now += 5000
        try require(check(now, tickFresh: true) == reasonNone, "M12: a second recovery")
        // The tick runs but the main queue does not answer: the echo is 5000, 10000 and then 15000 ms old.
        now += 5000
        _ = check(now, tickFresh: true, echoFresh: false)
        now += 5000
        try require(check(now, tickFresh: true, echoFresh: false) == reasonNone, "M12: echo age 10000 is not stale")
        now += 5000
        let queued = check(now, tickFresh: true, echoFresh: false)
        try require(queued == nudge && nudges.value == 3, "M12: no nudge when only the echo is stale")
        try require(log.has(prefix: "nudge reason=main-queue"), "M12: reason=main-queue not logged")
        // A check that runs very late means the process was throttled.
        let before = nudges.value
        now += Int64(MM_WATCHDOG_MS) + 5001
        try require(check(now, tickFresh: false, echoFresh: false) == UInt32(MM_WATCHDOG_THROTTLED), "M12: no throttled")
        try require(nudges.value == before && heartbeat.read().staleChecks == 0, "M12: throttled nudged or kept the count")
        try require(log.has(prefix: "throttled late=5001"), "M12: throttled not logged")
        // A check exactly MM_WATCHDOG_LATE_MS late is still on time.
        try require(
            mm_stale_checks_next(UInt32(MM_STALE_TICK), Int64(MM_WATCHDOG_LATE_MS), 7) == 8,
            "M12: a check exactly MM_WATCHDOG_LATE_MS late reset the stale count")
        try require(
            mm_watchdog_action(UInt32(MM_STALE_TICK), Int64(MM_WATCHDOG_LATE_MS), 12) == nudge,
            "M12: a check exactly MM_WATCHDOG_LATE_MS late was throttled")
    }

    // M12b: a nudge restarts the scheduler and ticks.
    do {
        let rig = MenuBarRig(script: [fakeSnapshot(percent: 60)])
        rig.clock.now = 4000
        rig.controller.nudge()
        try require(rig.scheduler.stops == 1 && rig.scheduler.starts == 1, "M12b: scheduler not restarted")
        try require(rig.scheduler.intervals == [1000] && rig.scheduler.tolerances == [100], "M12b: interval or tolerance")
        try require(rig.sampler.calls == 1 && rig.heartbeat.read().tickAt == 4000, "M12b: no tick after the nudge")
    }

    // M13: a memory-pressure event and a wake each sample once and update the heartbeat.
    do {
        let rig = MenuBarRig(script: [fakeSnapshot(percent: 60)])
        rig.clock.now = 1000
        rig.controller.tick(.pressure)
        try require(rig.sampler.calls == 1 && rig.heartbeat.read().tickAt == 1000, "M13: pressure tick")
        rig.clock.now = 1500
        rig.controller.handleWake()
        try require(rig.sampler.calls == 2 && rig.heartbeat.read().tickAt == 1500, "M13: wake tick")
        try require(rig.log.count(prefix: "wake") == 1, "M13: wake not logged once")
        try require(rig.log.has(prefix: "pressure code=1"), "M13: pressure code not logged")
    }

    // M13b: the pressure handler hands over to the main run loop from another queue.
    do {
        let rig = MenuBarRig(script: [fakeSnapshot(percent: 61)])
        MenuBarController.shared = rig.controller
        defer { MenuBarController.shared = nil }
        let before = rig.sampler.calls
        let called = Flag()
        runOnGlobalQueue {
            MenuBarPressure.event()
            called.set()
        }
        pumpMainRunLoop(seconds: 1.0, until: { called.value && rig.sampler.calls == before + 1 })
        try require(called.value, "M13b: the event handler did not run")
        try require(rig.sampler.calls == before + 1, "M13b: the pressure tick did not run")
        try require(rig.sampler.onMainThread.last == true, "M13b: the pressure tick did not run on the main thread")
        let source = MenuBarPressure.makeSource()
        source.cancel()
    }

    // M14: the panel.
    do {
        let rig = MenuBarRig(script: [fakeSnapshot(percent: 70, used: 1000), fakeSnapshot(percent: 70, used: 2000)])
        rig.clock.now = 1000
        rig.controller.tick(.launch)
        try require(rig.monitor.snapshot.used == 1000, "M14: first snapshot")
        rig.clock.now = 1100
        rig.controller.panelOpened()
        try require(rig.monitor.measuring == rig.monitor.listsProcesses, "M14: measuring after open")
        try require(rig.log.has(prefix: "panel opened"), "M14: panel opened not logged")
        try require(rig.display.shown.count == 1, "M14: the open panel changed the label")
        try require(rig.monitor.snapshot.used == 2000, "M14: the forced tick did not publish the snapshot")
        rig.controller.panelClosed()
        try require(rig.monitor.rows.isEmpty && !rig.monitor.measuring, "M14: rows after close")
        try require(rig.log.has(prefix: "panel closed"), "M14: panel closed not logged")
    }

    // M15: the real scheduler fires on the main run loop and stops.
    do {
        let scheduler = RunLoopTickScheduler()
        let fired = Counter()
        scheduler.start(intervalMs: 100, toleranceMs: 10) { fired.add() }
        pumpMainRunLoop(seconds: 1.0)
        try require(fired.value >= 5, "M15: fired only \(fired.value) times in 1 s")
        scheduler.stop()
        let atStop = fired.value
        pumpMainRunLoop(seconds: 0.5)
        try require(fired.value == atStop, "M15: fired after stop")
    }

    // M16: MainRunLoop.perform from another queue runs on the main thread.
    do {
        let ran = Flag()
        let onMain = Flag()
        let posted = Flag()
        runOnGlobalQueue {
            MainRunLoop.perform {
                onMain.set(Thread.isMainThread)
                ran.set()
            }
            posted.set()
        }
        pumpMainRunLoop(seconds: 1.0, until: { posted.value && ran.value })
        try require(ran.value, "M16: the block did not run")
        try require(onMain.value, "M16: the block did not run on the main thread")
    }

    // M17: a real watchdog thread nudges the main run loop, and stops.
    do {
        let heartbeat = MenuBarHeartbeat(now: MenuBarClock.now())
        heartbeat.tick(at: MenuBarClock.now() - 20000, facts: .noRelaunch)
        let count = Counter()
        let watchdog = MenuBarWatchdog(
            heartbeat: heartbeat, intervalMs: 50, installAt: MenuBarClock.now(), clock: { MenuBarClock.now() },
            nudge: { MainRunLoop.perform { count.add() } }, echo: {}, log: LogSink(),
            canRelaunch: false, relaunched: false, hooks: nil)
        watchdog.start()
        pumpMainRunLoop(seconds: 1.0, until: { count.value >= 1 })
        try require(count.value >= 1, "M17: the watchdog never nudged")
        watchdog.stop()
        pumpMainRunLoop(seconds: 1.0, until: { watchdog.isFinished })
        try require(watchdog.isFinished, "M17: the watchdog thread did not end")
        pumpMainRunLoop(seconds: 0.1)
        let atStop = count.value
        pumpMainRunLoop(seconds: 0.3)
        try require(count.value == atStop, "M17: nudged after stop")
    }

    // M18: reopening itself.
    do {
        // (a) Nudges at 15000 and 75000 do not reopen; the one at 135000 does.
        let a = RelaunchRig()
        a.run(from: 5000, through: 130000)
        try require(a.spawns.value == 0 && a.nudges.value == 2, "M18a: early relaunch \(a.spawns.value)")
        a.run(from: 135000, through: 135000)
        try require(a.spawns.value == 1 && a.exits.value == 1, "M18a: spawn \(a.spawns.value) exit \(a.exits.value)")
        try require(a.log.has(prefix: "relaunch tickAge=135000"), "M18a: relaunch not logged")
        try require(a.log.has(prefix: "relaunch open-exit status=0"), "M18a: open-exit not logged")
        try require(a.nudges.value == 2, "M18a: nudged after exit")

        // (b) A failed spawn nudges, and a later nudge may try again.
        let b = RelaunchRig(spawnRC: 1)
        b.run(from: 5000, through: 135000)
        try require(b.spawns.value == 1 && b.exits.value == 0 && b.nudges.value == 3, "M18b: first failure")
        try require(b.log.has(prefix: "relaunch-failed code=1"), "M18b: failure not logged")
        b.run(from: 140000, through: 190000)
        try require(b.spawns.value == 1, "M18b: retried within 12 stale checks")
        b.run(from: 195000, through: 195000)
        try require(b.spawns.value == 2, "M18b: no retry on the 12th stale check")

        // (c) An open that reports a failure is never run again.
        let c = RelaunchRig(waitStatus: 3)
        c.run(from: 5000, through: 135000)
        try require(c.spawns.value == 1 && c.exits.value == 0, "M18c: first run")
        try require(c.log.has(prefix: "relaunch-failed open-status=3"), "M18c: status not logged")
        c.run(from: 140000, through: 255000)
        try require(c.spawns.value == 1, "M18c: open ran again after a failed open")
        let skipped = c.log.lines.filter { $0.hasPrefix("relaunch-skipped") }
        try require(skipped.count == 2 && skipped.allSatisfy { $0.contains("tried=1") }, "M18c: \(skipped)")

        // (d) An open that is still running: quit anyway.
        let d = RelaunchRig(waitStatus: nil)
        d.run(from: 5000, through: 135000)
        try require(d.spawns.value == 1 && d.exits.value == 1, "M18d: spawn \(d.spawns.value) exit \(d.exits.value)")
        try require(d.log.has(prefix: "relaunch open-pending"), "M18d: open-pending not logged")

        // (e) An open window.
        let e = RelaunchRig(facts: RelaunchFacts(windowOpen: true, appHidden: false, canQuit: true, queued: 0, keepsToolState: false))
        e.run(from: 5000, through: 135000)
        try require(e.spawns.value == 0 && e.nudges.value == 3, "M18e: spawn \(e.spawns.value) nudges \(e.nudges.value)")
        try require(e.log.has(containing: "relaunch-skipped window=1"), "M18e: skip not logged")

        // (f) This build cannot relaunch.
        let f = RelaunchRig(canRelaunch: false)
        f.run(from: 5000, through: 135000)
        try require(f.spawns.value == 0, "M18f: relaunched although it cannot")

        // (g) A relaunched copy waits 10 minutes.
        let g1 = RelaunchRig(relaunched: true, installAt: 135000 - 599999)
        g1.run(from: 5000, through: 135000)
        try require(g1.spawns.value == 0, "M18g: relaunched again after 599999 ms")
        let g2 = RelaunchRig(relaunched: true, installAt: 135000 - 600000)
        g2.run(from: 5000, through: 135000)
        try require(g2.spawns.value == 1, "M18g: not relaunched after 600000 ms")

        // (h) The command line.
        try require(MenuBarRelaunch.arguments(bundlePath: "/X.app", extra: [])
                    == ["/usr/bin/open", "-n", "-g", "/X.app", "--args", "-DiskBloomRelaunched", "YES",
                        "-ApplePersistenceIgnoreState", "YES"], "M18h: arguments")
        try require(MenuBarRelaunch.arguments(bundlePath: "/X.app", extra: ["-A", "B"]).suffix(2) == ["-A", "B"],
                    "M18h: extra arguments")

        // (i) A hidden app keeps its windows.
        let i = RelaunchRig(facts: RelaunchFacts(windowOpen: false, appHidden: true, canQuit: true, queued: 0, keepsToolState: false))
        i.run(from: 5000, through: 135000)
        try require(i.spawns.value == 0 && i.log.has(containing: "hidden=1"), "M18i: hidden app")

        // (j) A tool that keeps a selection, a review, a report or a notice.
        let j = RelaunchRig(facts: RelaunchFacts(windowOpen: false, appHidden: false, canQuit: true, queued: 0, keepsToolState: true))
        j.run(from: 5000, through: 135000)
        try require(j.spawns.value == 0 && j.log.has(containing: "toolState=1"), "M18j: tool state")

        // The command itself: argv and a real `open` are not run here.
        _ = RelaunchCommand(bundlePath: "/X.app", extra: [])

        // (k) How `RelaunchCommand.waitExit` decodes an exit. Only children of this test run here, never `open`.
        func spawnChild(_ path: String, _ args: [String] = []) throws -> pid_t {
            let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
            defer { for p in argv { free(p) } }
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            var child: pid_t = 0
            let rc = posix_spawn(&child, path, nil, nil, argv, envp)
            try require(rc == 0 && child > 0, "M18k: could not start \(path): rc \(rc)")
            return child
        }
        let exitsZero = try spawnChild("/usr/bin/true")
        try require(RelaunchCommand.waitExit(exitsZero, 3000) == 0, "M18k: exit status 0")
        let exitsOne = try spawnChild("/usr/bin/false")
        try require(RelaunchCommand.waitExit(exitsOne, 3000) == 1, "M18k: exit status 1")
        let sleeper = try spawnChild("/bin/sleep", ["5"])
        try require(RelaunchCommand.waitExit(sleeper, 300) == nil, "M18k: a running child did not time out")
        _ = kill(sleeper, SIGKILL)
        try require(RelaunchCommand.waitExit(sleeper, 3000) == 255, "M18k: a killed child did not give 255")
    }

    // M19: opening the DiskBloom window. No window is opened, no AppModel is made, and neither `find()` nor
    // `open()` runs (they read NSApp). The decisions are the pure wrappers; the action is a counter.
    do {
        let none = UInt32(MM_OPEN_NONE)
        let launch = UInt32(MM_OPEN_LAUNCH)
        let shownRoute = UInt32(MM_OPEN_SHOWN)
        let keptRoute = UInt32(MM_OPEN_KEPT)

        // Before any registration the copy has no open-window action, so a suppressed copy does nothing.
        try require(!MainWindow.sceneReady, "M19: a scene action before any registration")
        try require(MainWindow.openScene == nil, "M19: openScene set before any registration")
        try require(MainWindow.route(shown: false, hidden: false, minimized: false, kept: false, launchSuppressed: true,
                                     scenePending: false, sceneReady: MainWindow.sceneReady) == none,
                    "M19: a suppressed copy without an action did not choose NONE")

        // All 128 combinations of the seven facts.
        for bits in 0..<128 {
            let shown = bits & 1 != 0
            let hidden = bits & 2 != 0
            let minimized = bits & 4 != 0
            let kept = bits & 8 != 0
            let suppressed = bits & 16 != 0
            let pending = bits & 32 != 0
            let ready = bits & 64 != 0
            let chosen = MainWindow.route(shown: shown, hidden: hidden, minimized: minimized, kept: kept,
                                          launchSuppressed: suppressed, scenePending: pending, sceneReady: ready)
            if suppressed {
                // D4: a suppressed copy never asks macOS to open DiskBloom (the reopen would come straight back).
                try require(chosen != launch, "M19: LAUNCH for a suppressed copy, bits=\(bits)")
            } else {
                // D3: every other copy follows the DiskBloom 1.6 rule.
                let expected = (shown || kept) ? (shown ? shownRoute : keptRoute) : launch
                try require(chosen == expected, "M19: copy with its window, bits=\(bits) got \(chosen) want \(expected)")
            }
        }

        // Spot checks for a suppressed copy.
        func suppressedRoute(shown: Bool = false, hidden: Bool = false, minimized: Bool = false, kept: Bool = false,
                             pending: Bool = false, ready: Bool = false) -> UInt32 {
            MainWindow.route(shown: shown, hidden: hidden, minimized: minimized, kept: kept, launchSuppressed: true,
                             scenePending: pending, sceneReady: ready)
        }
        try require(suppressedRoute(shown: true) == shownRoute, "M19: shown")
        try require(suppressedRoute(hidden: true) == UInt32(MM_OPEN_UNHIDE), "M19: hidden")
        try require(suppressedRoute(minimized: true) == UInt32(MM_OPEN_MINIMIZED), "M19: minimized")
        try require(suppressedRoute(kept: true) == keptRoute, "M19: kept")
        try require(suppressedRoute(pending: true) == UInt32(MM_OPEN_PENDING), "M19: pending")
        try require(suppressedRoute(ready: true) == UInt32(MM_OPEN_SCENE), "M19: ready")
        try require(suppressedRoute() == none, "M19: nothing")

        // The registration seam.
        let opened = Counter()
        MainWindow.register { opened.add() }
        try require(MainWindow.sceneReady, "M19: not ready after register")
        MainWindow.openScene?()
        try require(opened.value == 1, "M19: the registered action ran \(opened.value) times")

        // The wait after a new-window request.
        try require(MainWindow.pending(sinceSceneMs: 0), "M19: pending at 0")
        try require(MainWindow.pending(sinceSceneMs: 999), "M19: pending at 999")
        try require(!MainWindow.pending(sinceSceneMs: 1000), "M19: pending at 1000")
        try require(!MainWindow.pending(sinceSceneMs: -1), "M19: pending at -1")

        // The route names.
        let names = ["shown", "minimized", "kept", "scene", "launch", "none", "unhide", "pending"]
        for (index, name) in names.enumerated() {
            try require(MainWindow.routeName(UInt32(index)) == name, "M19: route name \(index)")
        }
        try require(MainWindow.routeName(99) == "unknown", "M19: route name 99")

        // Opening DiskBloom again: only a suppressed copy without a window on screen opens one.
        try require(MainWindow.reopenOpens(launchSuppressed: true, windowShown: false), "M19: reopen (true, false)")
        try require(!MainWindow.reopenOpens(launchSuppressed: true, windowShown: true), "M19: reopen (true, true)")
        try require(!MainWindow.reopenOpens(launchSuppressed: false, windowShown: false), "M19: reopen (false, false)")
        try require(!MainWindow.reopenOpens(launchSuppressed: false, windowShown: true), "M19: reopen (false, true)")

        // A plain start (no relaunch argument) is not suppressed, and the scene has its id.
        try require(!MenuBarRelaunch.launchSuppressed, "M19: this process started suppressed")
        try require(MainWindow.sceneID == "main", "M19: scene id")
    }
}

// MARK: - The version line of the panel (M20)

private func writeInfoPlist(_ values: [String: Any], bundle: URL) throws {
    let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
}

private func versionChecks(root: URL) throws {
    let unknown = "DiskBloom unknown version (unknown build)"

    // The text: a missing, blank or empty value is named as missing and never replaced by another value.
    try require(AppVersionText.text(short: "1.7.1", build: "9") == "DiskBloom 1.7.1 (9)", "M20.1: both present")
    try require(AppVersionText.text(short: nil, build: "9") == "DiskBloom unknown version (9)", "M20.1: no version")
    try require(AppVersionText.text(short: "1.7.1", build: nil) == "DiskBloom 1.7.1 (unknown build)", "M20.1: no build")
    try require(AppVersionText.text(short: nil, build: nil) == unknown, "M20.1: neither")
    try require(AppVersionText.text(short: "  ", build: "") == AppVersionText.text(short: nil, build: nil),
                "M20.2: blank and empty values are not the nil result")
    try require(AppVersionText.text(short: " 1.7.1\n", build: "9 ") == "DiskBloom 1.7.1 (9)", "M20.2: values are not trimmed")

    // The bundle: the values come from the Info.plist of the bundle that is asked.
    let m20 = root.appendingPathComponent("m20", isDirectory: true)
    try? FileManager.default.removeItem(at: m20)
    let full = m20.appendingPathComponent("Full.app", isDirectory: true)
    let empty = m20.appendingPathComponent("Empty.app", isDirectory: true)
    let numbers = m20.appendingPathComponent("Numbers.app", isDirectory: true)
    try writeInfoPlist(["CFBundleIdentifier": "test.m20.full",
                        "CFBundleShortVersionString": "3.4.5", "CFBundleVersion": "77"], bundle: full)
    try writeInfoPlist(["CFBundleIdentifier": "test.m20.empty"], bundle: empty)
    try writeInfoPlist(["CFBundleIdentifier": "test.m20.numbers",
                        "CFBundleShortVersionString": 7, "CFBundleVersion": 8], bundle: numbers)
    guard let fullBundle = Bundle(url: full) else { throw SmokeFailure.assertion("M20.3: Full.app is not a bundle") }
    guard let emptyBundle = Bundle(url: empty) else { throw SmokeFailure.assertion("M20.3: Empty.app is not a bundle") }
    guard let numbersBundle = Bundle(url: numbers) else { throw SmokeFailure.assertion("M20.3: Numbers.app is not a bundle") }
    try require(AppVersionText.text(of: fullBundle) == "DiskBloom 3.4.5 (77)", "M20.3: \(AppVersionText.text(of: fullBundle))")
    try require(AppVersionText.text(of: emptyBundle) == unknown, "M20.4: \(AppVersionText.text(of: emptyBundle))")
    try require(AppVersionText.text(of: numbersBundle) == unknown, "M20.5: \(AppVersionText.text(of: numbersBundle))")

    // The wiring: the tests have no view inspector, so the sources are read. Tests/Smoke/<this file> is three
    // path levels below the checkout.
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)
    let menuSource = try String(contentsOf: sources.appendingPathComponent("MemoryMenuView.swift"), encoding: .utf8)
    guard let panelStart = menuSource.range(of: "struct MemoryMenuPanel") else {
        throw SmokeFailure.assertion("M20.6: struct MemoryMenuPanel is not in MemoryMenuView.swift")
    }
    let panel = menuSource[panelStart.upperBound...]
    guard let actionsAt = panel.range(of: "            actions\n") else {
        throw SmokeFailure.assertion("M20.6: the panel body does not list actions")
    }
    guard let textAt = panel.range(of: "Text(versionText)") else {
        throw SmokeFailure.assertion("M20.6: the panel does not show Text(versionText)")
    }
    guard let paddingAt = panel.range(of: ".padding(14)") else {
        throw SmokeFailure.assertion("M20.6: the panel body has no .padding(14)")
    }
    try require(actionsAt.upperBound <= textAt.lowerBound && textAt.upperBound <= paddingAt.lowerBound,
                "M20.6: the version text is not between actions and .padding(14)")
    let styling = panel[textAt.upperBound..<paddingAt.lowerBound]
    try require(styling.contains(".caption2"), "M20.7: the version text is not .caption2")
    try require(styling.contains(".secondary"), "M20.7: the version text is not .secondary")

    let appSource = try String(contentsOf: sources.appendingPathComponent("DiskBloomApp.swift"), encoding: .utf8)
    try require(appSource.contains("AppVersionText.text(of: .main)"), "M20.8: the app does not read the main bundle")
    try require(appSource.contains("versionText: runningVersion"), "M20.8: the panel is not given the version text")
}

@main
@MainActor
private struct MemoryMonitorSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SmokeFailure.assertion("fixture root required") }

        // The system totals, as macOS reports them on this Mac.
        guard let system = MemorySampler.system() else { throw SmokeFailure.assertion("no VM statistics") }
        try require(system.total == Int64(ProcessInfo.processInfo.physicalMemory), "total is not the physical memory")
        try require(system.used > 0 && system.used <= system.total, "used memory out of range: \(system.used)")
        try require(system.used == mm_used_bytes(system.app, system.wired, system.compressed, system.total),
                    "used is not app + wired + compressed")
        try require(system.wired > 0, "no wired memory")
        try require((0...100).contains(system.percent), "percent out of range: \(system.percent)")
        try require(system.free >= 0 && system.cached >= 0 && system.swapUsed >= 0, "negative figure")
        try require([0, 1, 2, 4].contains(system.pressureCode), "unexpected pressure code \(system.pressureCode)")
        try require(MemoryRules.text(system.total).hasSuffix(" GB"), "total not shown in GB: \(MemoryRules.text(system.total))")

        // Every readable process; this one must be among them, with its footprint and CPU time.
        let first = MemorySampler.processes()
        let me = getpid()
        guard let mine = first.samples.first(where: { $0.pid == me }) else {
            throw SmokeFailure.assertion("own process not sampled")
        }
        try require(mine.footprint > 1_000_000, "own footprint too small: \(mine.footprint)")
        try require(mine.path.hasSuffix("/MemoryMonitorSmoke"), "own path wrong: \(mine.path)")
        try require(first.samples.count > 10, "too few processes: \(first.samples.count)")
        try require(first.unreadable >= 0, "negative unreadable count")

        _ = spin(milliseconds: 300)
        let second = MemorySampler.processes()
        let wallNs = MemoryRules.nanoseconds(second.at - first.at)
        let previous = first.samples.reduce(into: [Int32: Int64]()) { $0[$1.pid] = $1.cpuNs }
        let rows = MemoryGrouping.aggregate(second.samples, previousCPU: previous, hasPrevious: true, wallNs: wallNs)
        guard let own = rows.first(where: { $0.id == "process:MemoryMonitorSmoke" }) else {
            throw SmokeFailure.assertion("own process not grouped by name")
        }
        try require(own.cpuPermille >= 300, "busy process shows too little CPU: \(own.cpuPermille)")
        try require(own.cpuPermille <= 1500, "busy process shows too much CPU: \(own.cpuPermille)")
        let firstRows = MemoryGrouping.aggregate(first.samples, previousCPU: [:], hasPrevious: false, wallNs: 0)
        try require(firstRows.allSatisfy { $0.cpuPermille == -1 }, "CPU known without an earlier sample")
        try require(MemoryRules.cpuText(-1) == "—" && MemoryRules.cpuText(123) == "12.3%", "CPU text")

        // Fixed samples: helpers count for their outermost app; services by their own name.
        let samples = [
            ProcessSample(pid: 1, path: "/Applications/Big.app/Contents/MacOS/Big", footprint: 3_000_000_000, cpuNs: 2_000),
            ProcessSample(pid: 2, path: "/Applications/Big.app/Contents/Frameworks/Big Helper (Renderer).app/Contents/MacOS/Big Helper (Renderer)",
                          footprint: 1_000_000_000, cpuNs: 5_000),
            ProcessSample(pid: 3, path: "/usr/libexec/tool", footprint: 50_000_000, cpuNs: 90_000),
            ProcessSample(pid: 4, path: "/opt/bin/tool", footprint: 20_000_000, cpuNs: 0),
            ProcessSample(pid: 5, path: "/usr/sbin/tiny", footprint: 4_096, cpuNs: 0),
        ]
        let before: [Int32: Int64] = [1: 1_000, 2: 1_000, 3: 10_000]
        let fixed = MemoryGrouping.aggregate(samples, previousCPU: before, hasPrevious: true, wallNs: 100_000)
        guard let big = fixed.first(where: { $0.id == "app:/Applications/Big.app" }) else {
            throw SmokeFailure.assertion("helper not grouped into its app")
        }
        try require(big.name == "Big" && big.processes == 2 && big.bytes == 4_000_000_000, "app group: \(big)")
        try require(big.cpuPermille == 10 + 40, "app CPU is not the sum of its processes: \(big.cpuPermille)")
        guard let tool = fixed.first(where: { $0.id == "process:tool" }) else {
            throw SmokeFailure.assertion("services not grouped by name")
        }
        try require(tool.processes == 2 && tool.bytes == 70_000_000 && tool.cpuPermille == 800, "service group: \(tool)")

        let byMemory = MemoryGrouping.top(fixed, sort: MemoryRules.sortMemory)
        try require(byMemory.map(\.name) == ["Big", "tool"], "memory order: \(byMemory.map(\.name))")
        let byCPU = MemoryGrouping.top(fixed, sort: MemoryRules.sortCPU)
        try require(byCPU.map(\.name) == ["tool", "Big"], "CPU order: \(byCPU.map(\.name))")
        try require(MemoryRules.text(4_000_000_000) == "3.7 GB" && MemoryRules.text(70_000_000) == "67 MB",
                    "sizes: \(MemoryRules.text(4_000_000_000)), \(MemoryRules.text(70_000_000))")

        let many = (0..<20).map { i in
            UsageRow(id: "p\(i)", name: "p\(i)", bundlePath: nil, bytes: Int64(2_000_000 + i), cpuPermille: -1, processes: 1)
        }
        try require(MemoryGrouping.top(many, sort: MemoryRules.sortMemory).count == 8, "more than 8 rows")

        let tied = [
            UsageRow(id: "b", name: "b", bundlePath: nil, bytes: 5_000_000, cpuPermille: 20, processes: 1),
            UsageRow(id: "a", name: "a", bundlePath: nil, bytes: 5_000_000, cpuPermille: 20, processes: 1),
        ]
        try require(MemoryGrouping.top(tied, sort: MemoryRules.sortMemory).map(\.name) == ["a", "b"], "memory tie not by name")
        try require(MemoryGrouping.top(tied, sort: MemoryRules.sortCPU).map(\.name) == ["a", "b"], "CPU tie not by name")
        try require(MemoryLevel(code: UInt32(MM_LEVEL_NORMAL)) == .normal
                    && MemoryLevel(code: UInt32(MM_LEVEL_WARNING)) == .warning
                    && MemoryLevel(code: UInt32(MM_LEVEL_CRITICAL)) == .critical, "level mapping")
        try require(MemoryRules.text(69_730_304) == "67 MB", "MB rounding: \(MemoryRules.text(69_730_304))")
        try require(MemoryRules.text(1_073_741_824) == "1.0 GB", "GB text: \(MemoryRules.text(1_073_741_824))")

        // N1: an app is named by its bundle's file name without ".app".
        let named = MemoryGrouping.aggregate(
            [
                ProcessSample(pid: 11, path: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT", footprint: 1_000_000, cpuNs: 0),
                ProcessSample(pid: 12, path: "/Applications/Foo.Bar.app/Contents/MacOS/Foo", footprint: 1_000_000, cpuNs: 0),
                ProcessSample(pid: 13, path: "/Applications/Время.app/Contents/MacOS/x", footprint: 1_000_000, cpuNs: 0),
            ],
            previousCPU: [:], hasPrevious: false, wallNs: 0
        )
        try require(Set(named.map(\.name)) == ["ChatGPT", "Foo.Bar", "Время"], "app names: \(named.map(\.name).sorted())")

        // N2: the live rows of this Mac carry the same names.
        let live = MemoryMonitorModel()
        live.panelAppeared()
        try await waitUntilMeasured(live)
        for row in live.rows {
            if let bundlePath = row.bundlePath {
                let expected = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
                try require(row.name == expected, "row \(row.name) is not the bundle name \(expected)")
            }
            try require(!row.name.hasSuffix(".app"), "row name ends in .app: \(row.name)")
        }
        print("MEMORY_MONITOR_APP_ROWS=\(live.rows.filter { $0.bundlePath != nil }.count)")
        live.panelDisappeared()
        try require(live.rows.isEmpty && !live.measuring, "N2: rows or measuring kept after the panel closed")
        try await Task.sleep(for: .milliseconds(Int(MM_PANEL_REFRESH_MS) + 500))
        try require(live.rows.isEmpty && !live.measuring, "N2: the list loop ran after the panel closed")

        // M1: a small tree to scan.
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 4096).write(to: root.appendingPathComponent("a.bin"))
        try Data(count: 2048).write(to: root.appendingPathComponent("sub/b.bin"))
        try Data(count: 1024).write(to: root.appendingPathComponent("sub/c.bin"))

        // M2: a new model holds no map, and there is nothing to release.
        let app = AppModel()
        let mode = MonitorModeController()
        mode.attach(app: app)
        try require(!app.holdsDiskMap, "a new model holds a map")
        try require(mode.apply(windowOpen: false, appHidden: false) == UInt32(MM_MONITOR_KEEP), "release with no map")

        // M3: a scan gives a map.
        app.startScan(at: root)
        try await waitForScan(app)
        try require(app.snapshot != nil && app.holdsDiskMap, "no map after the scan")

        // M4: an open window, or a hidden app, keeps the map.
        try require(mode.apply(windowOpen: true, appHidden: false) == UInt32(MM_MONITOR_KEEP), "open window did not keep the map")
        try require(app.snapshot != nil, "open window dropped the map")
        try require(mode.apply(windowOpen: false, appHidden: true) == UInt32(MM_MONITOR_KEEP), "hidden app did not keep the map")
        try require(app.snapshot != nil, "hidden app dropped the map")

        // M5: a cleanup queue with items keeps the map.
        guard let file = app.snapshot?.root.children.first(where: { !$0.isDirectory && !$0.isVirtual }) else {
            throw SmokeFailure.assertion("no plain file in the fixture")
        }
        let reason = app.rejectionReason(for: file)
        try require(reason == nil, "the fixture file cannot be queued: \(reason ?? "")")
        app.toggleCollection(file)
        try require(app.collection.count == 1, "the file was not queued: \(app.collection.count)")
        try require(mode.apply(windowOpen: false, appHidden: false) == UInt32(MM_MONITOR_KEEP_QUEUE), "queue did not keep the map")
        try require(app.snapshot != nil, "queue kept no map")
        app.removeFromCollection(file)
        try require(app.collection.isEmpty, "the file is still queued")

        // M6: with no window and no queue, the Disk Map is dropped; the section on screen is kept (a review,
        // move or report in another tool must stay reachable), and the rest of the map's state is as at launch.
        app.selectWorkspaceSection(.cacheExplorer)
        try require(mode.apply(windowOpen: false, appHidden: false) == UInt32(MM_MONITOR_RELEASE), "no release")
        try require(app.snapshot == nil, "snapshot kept")
        try require(app.focusNode == nil, "focus kept")
        try require(app.inspectedNode == nil, "inspected node kept")
        try require(!app.isScanning, "still scanning")
        try require(app.collection.isEmpty, "queue kept")
        try require(!app.canGoBack, "history kept")
        try require(app.workspaceSection == .cacheExplorer, "release changed the section")
        try require(app.currentURL.path == UserHome.path, "current folder not reset")
        try require(app.analysisRootURL.path == UserHome.path, "analysis root not reset")
        try require(!app.holdsDiskMap, "still holds a map")
        try require(mode.apply(windowOpen: false, appHidden: false) == UInt32(MM_MONITOR_KEEP), "second release was not a no-op")

        // M7: a running scan is cancelled, and it does not land afterwards.
        app.startScan(at: root)
        try require(app.isScanning && app.holdsDiskMap, "scan did not start")
        try require(mode.apply(windowOpen: false, appHidden: false) == UInt32(MM_MONITOR_RELEASE), "running scan not released")
        try require(!app.isScanning && app.snapshot == nil, "scan still running after release")
        try await Task.sleep(for: .seconds(1))
        try require(app.snapshot == nil && !app.isScanning, "a cancelled scan landed after release")

        // M8: the disk scanner frees each entry's temporary objects before the next one (DiskScanner), so a
        // finished and dropped scan leaves almost nothing behind, even before any outer autorelease pool
        // drains. This guards the pool of the folder loop. The pool of the measuring loop always runs inside
        // it, so only the static check and the live check cover that one.
        let m8Root = root.appendingPathComponent("m8", isDirectory: true)
        for m8Folder in 0..<30 {
            let m8Dir = m8Root.appendingPathComponent("d\(m8Folder)", isDirectory: true)
            try files.createDirectory(at: m8Dir, withIntermediateDirectories: true)
            for m8File in 0..<100 {
                try Data([1]).write(to: m8Dir.appendingPathComponent("f\(m8File).bin"))
            }
        }
        // No `await` from here to m8Left: a suspension could drain an outer pool and hide a missing one.
        let m8Before = mallocInUse()
        var m8Entries = 0
        do {
            var scanner = DiskScanner()
            let snapshot = try scanner.scan(root: m8Root, counter: ScanCounter())
            m8Entries = snapshot.root.fileCount + snapshot.root.directoryCount
        }
        let m8Left = mallocInUse() - m8Before
        let m8PerEntry = m8Left / max(m8Entries, 1)
        print("MEMORY_MONITOR_SCAN_LEFT_BYTES_PER_ENTRY=\(m8PerEntry) entries=\(m8Entries) left=\(m8Left)")
        try require(m8Entries == 3031, "the scan saw \(m8Entries) entries, not 3031")
        try require(m8PerEntry < 300, "the scan kept its temporary objects to the end: \(m8PerEntry) bytes per entry")

        // M9: the Dock icon (mm_dock_shown); only the mapping, this test is not an app and never sets its own policy.
        try require(DockIcon.policy(windowOpen: true, appHidden: false) == .regular,
                    "an open window did not keep the Dock icon")
        try require(DockIcon.policy(windowOpen: false, appHidden: true) == .regular,
                    "a hidden app lost its Dock icon")
        try require(DockIcon.policy(windowOpen: true, appHidden: true) == .regular,
                    "an open window in a hidden app lost the Dock icon")
        try require(DockIcon.policy(windowOpen: false, appHidden: false) == .accessory,
                    "an app with no window and not hidden kept the Dock icon")

        // M20: the version line of the panel.
        try versionChecks(root: root)

        // M10-M19: the menu bar figure (clock, label policy, watchdog, relaunch, opening the window).
        try menuBarChecks()

        print("MEMORY_MONITOR_SMOKE_OK")
    }
}
