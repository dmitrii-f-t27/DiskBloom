import AppKit
import Darwin
import Foundation
import os

// The memory monitor in the menu bar. Swift reads the facts from macOS (VM page counts, the pressure
// level, swap, every readable process's footprint and CPU time); Specs/memory_rules.t27 decides what
// they mean, how processes group into apps, the order of the list and how often it refreshes.

/// How hard the system is pressed (Specs/memory_rules.t27, `mm_level`).
enum MemoryLevel: Sendable {
    case normal, warning, critical

    init(code: UInt32) {
        switch code {
        case UInt32(MM_LEVEL_CRITICAL): self = .critical
        case UInt32(MM_LEVEL_WARNING): self = .warning
        default: self = .normal
        }
    }

    var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// The memory as macOS counts it, at one moment.
struct MemorySnapshot: Sendable, Equatable {
    var total: Int64 = 0
    var used: Int64 = 0
    var app: Int64 = 0
    var wired: Int64 = 0
    var compressed: Int64 = 0
    var cached: Int64 = 0
    var free: Int64 = 0
    var swapUsed: Int64 = 0
    var pressureCode: Int64 = 0
    var percent: Int64 = 0
    var levelCode: UInt32 = UInt32(MM_LEVEL_NORMAL)

    var level: MemoryLevel { MemoryLevel(code: levelCode) }
    var pressureKnown: Bool { mm_pressure_known(pressureCode) }
    var showsSwap: Bool { mm_swap_shows(swapUsed) }
}

/// One process: where it runs from, its memory footprint and the CPU time it has used so far.
struct ProcessSample: Sendable {
    let pid: Int32
    let path: String
    let footprint: Int64
    let cpuNs: Int64
}

/// Every process this user may read, and how many could not be read.
struct ProcessSampling: Sendable {
    let samples: [ProcessSample]
    let unreadable: Int
    let at: ContinuousClock.Instant
}

/// An app with all its helper processes, or a service outside any app.
struct UsageRow: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let bundlePath: String?
    let bytes: Int64
    let cpuPermille: Int64
    let processes: Int
}

enum MemoryRules {
    static let sortMemory = UInt32(MM_SORT_MEMORY)
    static let sortCPU = UInt32(MM_SORT_CPU)

    /// "13.2 GB", "512 MB": binary units, as Activity Monitor shows them.
    static func text(_ bytes: Int64) -> String {
        let unit = mm_memory_unit(bytes)
        let amount = mm_memory_amount(bytes, unit)
        let digits = Int32(mm_memory_digits(unit))
        let unitText = unit == UInt32(MM_UNIT_GB) ? "GB" : "MB"
        return String(format: "%.*f %@", digits, Double(amount) / (digits == 1 ? 10 : 1), unitText)
    }

    /// "12.3%" of one core; "—" until a second sample exists.
    static func cpuText(_ permille: Int64) -> String {
        guard permille >= 0 else { return "—" }
        return String(format: "%.1f%%", Double(permille) / 10)
    }

    static func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1_000_000_000 + parts.attoseconds / 1_000_000_000
    }

    static func nameOrder(_ a: String, _ b: String) -> Int64 {
        if T27Text.less(a, b) { return -1 }
        if T27Text.less(b, a) { return 1 }
        return 0
    }
}

/// Reads the facts from macOS. Nothing here decides; Specs/memory_rules.t27 does.
enum MemorySampler {
    private static let host = mach_host_self()
    private static let timebase: (numer: Int64, denom: Int64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Int64(info.numer), Int64(info.denom))
    }()

    static func system() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        let page = Int64(pageSize)

        var snapshot = MemorySnapshot()
        snapshot.total = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
        snapshot.app = mm_app_bytes(Int64(stats.internal_page_count), Int64(stats.purgeable_count), page)
        snapshot.wired = mm_pages_bytes(Int64(stats.wire_count), page)
        snapshot.compressed = mm_pages_bytes(Int64(stats.compressor_page_count), page)
        snapshot.cached = mm_cached_bytes(Int64(stats.external_page_count), Int64(stats.purgeable_count), page)
        snapshot.used = mm_used_bytes(snapshot.app, snapshot.wired, snapshot.compressed, snapshot.total)
        snapshot.free = mm_free_bytes(snapshot.total, snapshot.used, snapshot.cached)
        snapshot.percent = mm_used_percent(snapshot.used, snapshot.total)
        snapshot.swapUsed = swapUsed()
        snapshot.pressureCode = pressureCode()
        snapshot.levelCode = mm_level(snapshot.pressureCode, snapshot.percent)
        return snapshot
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(clamping: usage.xsu_used)
    }

    private static func pressureCode() -> Int64 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 0 }
        return Int64(level)
    }

    /// Every process this user may read. Other users' processes (root services, the window server) need
    /// administrator rights; they are only counted.
    static func processes() -> ProcessSampling {
        let at = ContinuousClock.now
        let expected = Int(proc_listallpids(nil, 0))
        guard expected > 0 else { return ProcessSampling(samples: [], unreadable: 0, at: at) }
        var pids = [Int32](repeating: 0, count: expected + 64)
        let found = pids.withUnsafeMutableBytes { buffer in
            Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count)))
        }
        var samples: [ProcessSample] = []
        samples.reserveCapacity(max(0, found))
        var unreadable = 0
        var pathBuffer = [UInt8](repeating: 0, count: Int(MM_PATH_MAX))
        for pid in pids.prefix(max(0, min(found, pids.count))) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else {
                unreadable += 1
                continue
            }
            let length = pathBuffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let path = length > 0 ? String(decoding: pathBuffer.prefix(Int(length)), as: UTF8.self) : name(of: pid)
            let ticks = Int64(clamping: info.ri_user_time) &+ Int64(clamping: info.ri_system_time)
            samples.append(ProcessSample(
                pid: pid,
                path: path,
                footprint: Int64(clamping: info.ri_phys_footprint),
                cpuNs: mm_ticks_ns(ticks, timebase.numer, timebase.denom)
            ))
        }
        return ProcessSampling(samples: samples, unreadable: unreadable, at: at)
    }

    private static func name(of pid: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return "pid \(pid)" }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

/// Groups processes into apps and services and orders them, as Specs/memory_rules.t27 says.
enum MemoryGrouping {
    /// Each process inside an app bundle counts for the outermost bundle; a service outside any app is
    /// listed by its own name. An app is named by its bundle's file name without ".app"
    /// (`mm_app_name_end`).
    static func aggregate(
        _ samples: [ProcessSample],
        previousCPU: [Int32: Int64],
        hasPrevious: Bool,
        wallNs: Int64
    ) -> [UsageRow] {
        struct Group {
            var name: String
            var bundlePath: String?
            var bytes: Int64 = 0
            var cpu: Int64 = -1
            var processes = 0
        }
        var groups: [String: Group] = [:]
        for sample in samples {
            let groupEnd = T27Text.withBytes(sample.path) { bytes, length in mm_group_end(bytes, length) }
            let key: String
            var group: Group
            if groupEnd > 0 {
                let bundle = String(decoding: Array(sample.path.utf8.prefix(Int(groupEnd))), as: UTF8.self)
                key = "app:" + bundle
                let start = Int(T27Text.withBytes(bundle) { bytes, length in mm_name_start(bytes, length) })
                let file = Array(bundle.utf8)[start..<max(start, Int(mm_app_name_end(groupEnd)))]
                group = groups[key] ?? Group(name: String(decoding: file, as: UTF8.self), bundlePath: bundle)
            } else {
                let start = T27Text.withBytes(sample.path) { bytes, length in mm_name_start(bytes, length) }
                let name = String(decoding: Array(sample.path.utf8.dropFirst(Int(start))), as: UTF8.self)
                key = "process:" + name
                group = groups[key] ?? Group(name: name.isEmpty ? sample.path : name, bundlePath: nil)
            }
            let before = previousCPU[sample.pid]
            let cpu = mm_cpu_permille(hasPrevious && before != nil, sample.cpuNs, before ?? 0, wallNs)
            group.bytes += sample.footprint
            group.cpu = mm_cpu_sum(group.cpu, cpu)
            group.processes += 1
            groups[key] = group
        }
        return groups.map { key, group in
            UsageRow(id: key, name: group.name, bundlePath: group.bundlePath, bytes: group.bytes,
                     cpuPermille: group.cpu, processes: group.processes)
        }
    }

    /// The rows the panel lists, in the chosen order.
    static func top(_ rows: [UsageRow], sort: UInt32) -> [UsageRow] {
        let shown = rows.filter { mm_row_shows($0.bytes, $0.cpuPermille) }.sorted { a, b in
            // The name comparison is costly, so it is made only when memory and CPU tie.
            if mm_row_before(sort, a.bytes, a.cpuPermille, b.bytes, b.cpuPermille, 0) { return true }
            if mm_row_before(sort, b.bytes, b.cpuPermille, a.bytes, a.cpuPermille, 0) { return false }
            return mm_row_before(sort, a.bytes, a.cpuPermille, b.bytes, b.cpuPermille, MemoryRules.nameOrder(a.name, b.name))
        }
        return Array(shown.prefix(Int(mm_rows_shown(Int64(shown.count)))))
    }
}

/// Holds the numbers the menu bar panel shows. `MenuBarController` samples memory and hands each sample over
/// (`apply`); this model lists the processes while the panel is open.
@MainActor
final class MemoryMonitorModel: ObservableObject {
    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var known = false
    @Published private(set) var rows: [UsageRow] = []
    @Published private(set) var unreadable = 0
    @Published private(set) var measuring = false
    @Published var sortMode = MemoryRules.sortMemory {
        didSet { rows = MemoryGrouping.top(allRows, sort: sortMode) }
    }

    /// False in the App Store edition: the App Sandbox hides other processes.
    let listsProcesses = mm_lists_processes(AppSandbox.isActive)

    private var panelOpen = false
    private var listLoop: Task<Void, Never>?
    private var allRows: [UsageRow] = []
    private var previousCPU: [Int32: Int64] = [:]
    private var previousAt: ContinuousClock.Instant?
    private var icons: [String: NSImage] = [:]

    /// "85%", or "—%" while the figure is not known (before the first good sample, and after
    /// `MM_SAMPLE_MISSES_MAX` failed samples in a row).
    var percentText: String { known ? "\(snapshot.percent)%" : "—%" }

    /// Takes one sample from the menu bar controller. The snapshot is published only when the panel is open or
    /// the menu bar figure was just shown (`mm_snapshot_publishes`), so a closed panel causes no redraw.
    func apply(_ s: MemorySnapshot?, known: Bool, labelShown: Bool) {
        if let s, mm_snapshot_publishes(panelOpen, labelShown) { snapshot = s }
        if self.known != known { self.known = known }
    }

    func panelAppeared() {
        guard !panelOpen else { return }
        panelOpen = true
        measuring = listsProcesses
        listLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, mm_lists_now(panelOpen, listsProcesses) else { return }
                await refreshList()
                try? await Task.sleep(for: .milliseconds(Int(MM_PANEL_REFRESH_MS)))
            }
        }
    }

    func panelDisappeared() {
        guard panelOpen else { return }
        panelOpen = false
        allRows = []
        rows = []
        previousCPU = [:]
        previousAt = nil
        measuring = false
        listLoop?.cancel()
        listLoop = nil
    }

    func icon(for row: UsageRow) -> NSImage? {
        guard let path = row.bundlePath else { return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    private func refreshList() async {
        guard panelOpen, listsProcesses else { return }
        let sampling = await Task.detached(priority: .utility) { MemorySampler.processes() }.value
        guard panelOpen, !Task.isCancelled else { return }
        let wallNs = previousAt.map { MemoryRules.nanoseconds(sampling.at - $0) } ?? 0
        allRows = MemoryGrouping.aggregate(
            sampling.samples,
            previousCPU: previousCPU,
            hasPrevious: previousAt != nil,
            wallNs: wallNs
        )
        rows = MemoryGrouping.top(allRows, sort: sortMode)
        unreadable = sampling.unreadable
        previousCPU = sampling.samples.reduce(into: [:]) { $0[$1.pid] = $1.cpuNs }
        previousAt = sampling.at
        measuring = false
    }

    /// Brings up the DiskBloom window (MainWindow). The panel's Open DiskBloom button and the live check's
    /// open-window step call this.
    func openMainWindow() {
        MainWindow.open()
    }

    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}

/// The DiskBloom window: how Open DiskBloom, the live check's open-window step and opening DiskBloom again
/// bring it up (Specs/memory_rules.t27: mm_open_route, mm_open_pending, mm_reopen_opens).
@MainActor
enum MainWindow {
    /// The id of the main window scene (`WindowGroup(id:)`).
    nonisolated static let sceneID = "main"

    /// Opens a new window of the main window scene. The menu bar item hands it over when it appears.
    private(set) static var openScene: (@MainActor () -> Void)?
    private static var lastSceneAt: Int64?

    static var sceneReady: Bool { openScene != nil }

    static func register(_ open: @escaping @MainActor () -> Void) {
        openScene = open
    }

    /// What the app has now, read from AppKit. Every `NSPanel` (the menu bar panel) is ignored.
    struct Facts {
        /// A window on screen that can become the main window.
        let shown: NSWindow?
        let hidden: Bool
        /// A window minimized to the Dock (macOS reports it as unable to become the main window).
        let minimized: NSWindow?
        /// A window that can become the main window, as DiskBloom 1.6 tested it.
        let kept: NSWindow?
    }

    /// Reads `NSApp`, so the smoke tests never call it.
    static func find() -> Facts {
        let windows = NSApp.windows.filter { !($0 is NSPanel) }
        return Facts(
            shown: windows.first(where: { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }),
            hidden: NSApp.isHidden,
            minimized: windows.first(where: { $0.isMiniaturized }),
            kept: windows.first(where: { $0.canBecomeMain })
        )
    }

    // The pure decisions: the smoke test calls these without AppKit.

    static func pending(sinceSceneMs: Int64) -> Bool {
        mm_open_pending(sinceSceneMs)
    }

    static func route(
        shown: Bool, hidden: Bool, minimized: Bool, kept: Bool, launchSuppressed: Bool, scenePending: Bool,
        sceneReady: Bool
    ) -> UInt32 {
        mm_open_route(shown, hidden, minimized, kept, launchSuppressed, scenePending, sceneReady)
    }

    static func routeName(_ route: UInt32) -> String {
        switch route {
        case UInt32(MM_OPEN_SHOWN): return "shown"
        case UInt32(MM_OPEN_MINIMIZED): return "minimized"
        case UInt32(MM_OPEN_KEPT): return "kept"
        case UInt32(MM_OPEN_SCENE): return "scene"
        case UInt32(MM_OPEN_LAUNCH): return "launch"
        case UInt32(MM_OPEN_NONE): return "none"
        case UInt32(MM_OPEN_UNHIDE): return "unhide"
        case UInt32(MM_OPEN_PENDING): return "pending"
        default: return "unknown"
        }
    }

    static func reopenOpens(launchSuppressed: Bool, windowShown: Bool) -> Bool {
        mm_reopen_opens(launchSuppressed, windowShown)
    }

    private static func decide() -> (route: UInt32, facts: Facts, pending: Bool) {
        let facts = find()
        let scenePending = lastSceneAt.map { pending(sinceSceneMs: MenuBarClock.now() - $0) } ?? false
        let chosen = route(
            shown: facts.shown != nil, hidden: facts.hidden, minimized: facts.minimized != nil,
            kept: facts.kept != nil, launchSuppressed: MenuBarRelaunch.launchSuppressed,
            scenePending: scenePending, sceneReady: sceneReady
        )
        return (chosen, facts, scenePending)
    }

    /// Brings a DiskBloom window forward, and opens one if there is none. A window is about to open, so the
    /// Dock icon and the menu bar come back before the app activates. A copy that started without its window
    /// that cannot open one (NONE) or is still waiting for one (PENDING) changes nothing at all.
    static func open() {
        let first = decide()
        if first.route == UInt32(MM_OPEN_NONE) || first.route == UInt32(MM_OPEN_PENDING) {
            #if DEBUG
            note(route: first.route, first: first.route, facts: first.facts, pending: first.pending)
            #endif
            return
        }
        DockIcon.update(windowOpen: true, appHidden: NSApp.isHidden)
        NSApp.activate()
        let now = decide()
        #if DEBUG
        note(route: now.route, first: first.route, facts: now.facts, pending: now.pending)
        #endif
        switch now.route {
        case UInt32(MM_OPEN_SHOWN):
            now.facts.shown?.makeKeyAndOrderFront(nil)
        case UInt32(MM_OPEN_UNHIDE):
            NSApp.unhide(nil)
        case UInt32(MM_OPEN_MINIMIZED):
            now.facts.minimized?.deminiaturize(nil)
            now.facts.minimized?.makeKeyAndOrderFront(nil)
        case UInt32(MM_OPEN_KEPT):
            now.facts.kept?.makeKeyAndOrderFront(nil)
        case UInt32(MM_OPEN_SCENE):
            lastSceneAt = MenuBarClock.now()
            openScene?()
        case UInt32(MM_OPEN_LAUNCH):
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        default:
            break
        }
    }

    #if DEBUG
    private static func note(route: UInt32, first: UInt32, facts: Facts, pending scenePending: Bool) {
        func name(_ window: NSWindow?) -> String {
            guard let window else { return "-" }
            return String(describing: type(of: window)).replacingOccurrences(of: " ", with: "")
        }
        MenuBarAutomation.note(
            "open-window route=\(routeName(route)) first=\(routeName(first)) shown=\(name(facts.shown)) "
                + "hidden=\(facts.hidden ? 1 : 0) mini=\(name(facts.minimized)) kept=\(name(facts.kept)) "
                + "suppressed=\(MenuBarRelaunch.launchSuppressed ? 1 : 0) ready=\(sceneReady ? 1 : 0) "
                + "pending=\(scenePending ? 1 : 0)"
        )
    }
    #endif
}

// MARK: - The menu bar figure: clock, controller, watchdog
//
// The figure in the menu bar is sampled every second and shown when it changes (Specs/memory_rules.t27: how
// often, when a change is due, when the figure is unknown). A watchdog on its own thread notices when the
// figure stops updating, nudges the main run loop and, after two minutes, lets DiskBloom reopen itself.
//
// Isolation rule: a closure literal passed to a non-@Sendable Dispatch, CoreFoundation or C block parameter
// must not be written inside a @MainActor body, unless that closure always runs on the main thread. Dispatch
// is a Swift 5 mode module, so such a closure would be inferred @MainActor, and Swift 6 would insert a runtime
// isolation check that traps when it runs on another queue. Those closures are written in the nonisolated
// helpers below (`MainRunLoop`, `MenuBarPressure`, `MenuBarWatchdog`).

/// Milliseconds on the clock that stops during sleep (CLOCK_UPTIME_RAW).
enum MenuBarClock {
    static func now() -> Int64 { Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000_000) }
}

/// How a relaunched copy starts, and whether this copy may relaunch at all.
enum MenuBarRelaunch {
    /// True in a copy that the watchdog of an earlier copy started (`-DiskBloomRelaunched YES`).
    static let launchedByWatchdog: Bool = UserDefaults.standard.bool(forKey: "DiskBloomRelaunched")

    /// A copy can start without its window only on macOS 15 and later (`defaultLaunchBehavior`).
    static let launchSuppressible: Bool = {
        if #available(macOS 15.0, *) { return true } else { return false }
    }()

    /// A relaunched copy starts without a window (and so without a Disk Map scan). In a debug build the
    /// live checks can ask for the same with `-DiskBloomAutomationNoWindow YES`.
    static let suppressesLaunchWindow: Bool = {
        if launchedByWatchdog { return true }
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "DiskBloomAutomationNoWindow")
        #else
        return false
        #endif
    }()

    /// True when the main window scene really started suppressed (macOS 15 and later).
    static let launchSuppressed: Bool = suppressesLaunchWindow && launchSuppressible

    static func arguments(bundlePath: String, extra: [String]) -> [String] {
        ["/usr/bin/open", "-n", "-g", bundlePath, "--args", "-DiskBloomRelaunched", "YES",
         "-ApplePersistenceIgnoreState", "YES"] + extra
    }
}

/// What the watchdog thread may know about the app when it decides on a relaunch. The main thread copies
/// it into the heartbeat on every tick. The default errs toward no relaunch.
struct RelaunchFacts: Sendable, Equatable {
    var windowOpen: Bool
    var appHidden: Bool
    var canQuit: Bool
    var queued: Int64
    var keepsToolState: Bool

    static let noRelaunch = RelaunchFacts(windowOpen: true, appHidden: true, canQuit: false, queued: 0, keepsToolState: true)
}

/// The numbers shared between the main thread (ticks, echoes) and the watchdog thread.
final class MenuBarHeartbeat: Sendable {
    struct State: Sendable {
        var tickAt: Int64
        var echoAt: Int64
        var echoPending: Bool
        var lastCheckAt: Int64
        var staleChecks: Int64
        var facts: RelaunchFacts
    }

    private let lock: OSAllocatedUnfairLock<State>

    init(now: Int64) {
        lock = OSAllocatedUnfairLock(initialState: State(
            tickAt: now, echoAt: now, echoPending: false, lastCheckAt: now, staleChecks: 0, facts: .noRelaunch))
    }

    func tick(at now: Int64, facts: RelaunchFacts) {
        lock.withLock { state in
            state.tickAt = now
            state.facts = facts
        }
    }

    /// True if the caller may send an echo (none is pending); it marks one as pending.
    func beginEcho() -> Bool {
        lock.withLock { state in
            if state.echoPending { return false }
            state.echoPending = true
            return true
        }
    }

    func echo(at now: Int64) {
        lock.withLock { state in
            state.echoAt = now
            state.echoPending = false
        }
    }

    func read() -> State { lock.withLock { $0 } }

    func recordCheck(at now: Int64, staleChecks: Int64) {
        lock.withLock { state in
            state.lastCheckAt = now
            state.staleChecks = staleChecks
        }
    }

    /// Starts the clocks again at `now`; the relaunch facts stay.
    func reset(now: Int64) {
        lock.withLock { state in
            state.tickAt = now
            state.echoAt = now
            state.lastCheckAt = now
            state.staleChecks = 0
            state.echoPending = false
        }
    }
}

/// Runs a block on the main thread's run loop in every common mode, and wakes the loop. This does not go
/// through the main dispatch queue, so it still runs when a block on that queue holds it.
enum MainRunLoop {
    static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { body() }
        }
        CFRunLoopWakeUp(main)
    }
}

/// The memory-pressure source. It is built here, outside any @MainActor code (isolation rule above): its
/// handler runs on the source's own queue and hands over to the main run loop.
enum MenuBarPressure {
    static let event: @Sendable () -> Void = {
        MainRunLoop.perform { MenuBarController.shared?.tick(.pressure) }
    }

    static func makeSource() -> any DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue(label: "DiskBloom.MemoryPressure", qos: .utility)
        )
        source.setEventHandler { event() }
        source.resume()
        return source
    }
}

/// The source of the one-second ticks.
@MainActor
protocol TickScheduler: AnyObject {
    func start(intervalMs: Int64, toleranceMs: Int64, _ fire: @escaping @MainActor @Sendable () -> Void)
    func stop()
}

/// A repeating Timer on the main run loop in the common modes (so it also runs while a menu is open).
@MainActor
final class RunLoopTickScheduler: TickScheduler {
    private var timer: Timer?

    func start(intervalMs: Int64, toleranceMs: Int64, _ fire: @escaping @MainActor @Sendable () -> Void) {
        stop()
        let newTimer = Timer(timeInterval: Double(intervalMs) / 1000, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
        newTimer.tolerance = Double(toleranceMs) / 1000
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// The colour of the chip in the menu bar: none (the bar's own colour), yellow or red.
enum MenuBarTint: Equatable, Sendable {
    case none, yellow, red
}

/// What the menu bar item shows: the percentage, a chip symbol with its colour, and the spoken text. The chip
/// follows the percent shown (`mm_chip_band`), not the pressure level. The chip draws the title without its
/// percent sign (`MenuBarChipImage.drawnText`); the title keeps the sign. The image itself is built in
/// `MenuBarChipImage`, so this struct stays `Sendable`.
struct MenuBarLabel: Equatable, Sendable {
    var title: String
    var symbol: String
    var tint: MenuBarTint
    var accessibility: String

    /// True for the ladybug of the automation switch (DEBUG builds), which keeps its own title next to it.
    var isDebugMarker: Bool { symbol == "ladybug" }

    static let unknown = MenuBarLabel(title: "—%", symbol: "memorychip", tint: .none,
                                      accessibility: "Memory figure unavailable")

    static func make(percent: Int64, level: UInt32, known: Bool, debugMarker: Bool) -> MenuBarLabel {
        let memoryLevel = MemoryLevel(code: level)
        let symbol: String
        let tint: MenuBarTint
        if debugMarker {
            symbol = "ladybug"
            tint = .none
        } else {
            switch mm_chip_band(percent, known) {
            case UInt32(MM_CHIP_RED):
                symbol = "memorychip.fill"
                tint = .red
            case UInt32(MM_CHIP_YELLOW):
                symbol = "memorychip.fill"
                tint = .yellow
            default:
                symbol = "memorychip"
                tint = .none
            }
        }
        guard known else {
            return MenuBarLabel(title: "—%", symbol: symbol, tint: tint, accessibility: "Memory figure unavailable")
        }
        return MenuBarLabel(title: "\(percent)%", symbol: symbol, tint: tint,
                            accessibility: "Memory \(percent)% used, pressure \(memoryLevel.title)")
    }
}

/// Where the controller puts the label (the SwiftUI label model, or a fake in the smoke test).
@MainActor
protocol MenuBarDisplay: AnyObject {
    func show(_ label: MenuBarLabel)
}

/// Persisted log lines of the menu bar figure: subsystem = bundle id, category MenuBar, level notice.
protocol MenuBarLogging: Sendable {
    func notice(_ line: String)
}

struct SystemMenuBarLog: MenuBarLogging {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.dmitrii-f-t27.DiskBloom",
                                category: "MenuBar")
    private let mirrorsToStandardError: Bool

    init() {
        #if DEBUG
        mirrorsToStandardError = UserDefaults.standard.bool(forKey: "DiskBloomAutomationMenuBar")
        #else
        mirrorsToStandardError = false
        #endif
    }

    func notice(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        #if DEBUG
        if mirrorsToStandardError {
            let at = Int64(Date().timeIntervalSince1970 * 1000)
            "DISKBLOOM_AUTOMATION menubar at=\(at) \(line)\n".withCString { pointer in
                _ = write(2, pointer, strlen(pointer))
            }
        }
        #endif
    }
}

enum MenuBarLog {
    static let system: any MenuBarLogging = SystemMenuBarLog()
}

/// What the watchdog does to reopen DiskBloom. Real ones come from `RelaunchCommand.hooks()`.
struct MenuBarRelaunchHooks: Sendable {
    let spawn: @Sendable () -> (rc: Int32, pid: pid_t)
    /// The exit status of `open`, or nil if it did not finish in time.
    let waitExit: @Sendable (pid_t, Int64) -> Int32?
    let exit: @Sendable () -> Void
}

/// The `open` command that starts the new copy. Everything is built once at install, so a relaunch allocates
/// nothing. It is immutable after init and its strings are never freed.
final class RelaunchCommand: @unchecked Sendable {
    private let argv: [UnsafeMutablePointer<CChar>?]
    private let envp: [UnsafeMutablePointer<CChar>?]

    init(bundlePath: String, extra: [String]) {
        var arguments: [UnsafeMutablePointer<CChar>?] = MenuBarRelaunch.arguments(bundlePath: bundlePath, extra: extra)
            .map { strdup($0) }
        arguments.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment
            .map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        argv = arguments
        envp = environment
    }

    func spawn() -> (rc: Int32, pid: pid_t) {
        var child: pid_t = 0
        let rc = posix_spawn(&child, "/usr/bin/open", nil, nil, argv, envp)
        return (rc, child)
    }

    /// Polls `waitpid` every 100 ms for up to `ms`. The exit status; 255 if `open` died from a signal; nil on
    /// a timeout or a `waitpid` error.
    static func waitExit(_ pid: pid_t, _ ms: Int64) -> Int32? {
        var waited: Int64 = 0
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                if (status & 0x7f) == 0 { return (status >> 8) & 0xff }
                return 255
            }
            if result < 0 { return nil }
            if waited >= ms { return nil }
            usleep(100_000)
            waited += 100
        }
    }

    func hooks() -> MenuBarRelaunchHooks {
        MenuBarRelaunchHooks(
            spawn: { self.spawn() },
            waitExit: { RelaunchCommand.waitExit($0, $1) },
            exit: { _exit(0) }
        )
    }
}

/// Watches the heartbeat from a thread of its own and acts as Specs/memory_rules.t27 says. It never touches
/// AppKit. Spike U2 (2026-10-29): a plain Thread that sleeps with Thread.sleep keeps running while the main
/// thread is blocked.
final class MenuBarWatchdog: Sendable {
    private struct Control: Sendable {
        var stopped = false
        var finished = false
        var openTried = false
    }

    private let heartbeat: MenuBarHeartbeat
    private let intervalMs: Int64
    private let installAt: Int64
    private let clock: @Sendable () -> Int64
    private let nudge: @Sendable () -> Void
    private let echo: @Sendable () -> Void
    private let log: any MenuBarLogging
    private let canRelaunch: Bool
    private let relaunched: Bool
    private let hooks: MenuBarRelaunchHooks?
    private let control = OSAllocatedUnfairLock(initialState: Control())

    init(
        heartbeat: MenuBarHeartbeat,
        intervalMs: Int64 = Int64(MM_WATCHDOG_MS),
        installAt: Int64,
        clock: @escaping @Sendable () -> Int64,
        nudge: @escaping @Sendable () -> Void,
        echo: @escaping @Sendable () -> Void,
        log: any MenuBarLogging,
        canRelaunch: Bool,
        relaunched: Bool,
        hooks: MenuBarRelaunchHooks?
    ) {
        self.heartbeat = heartbeat
        self.intervalMs = intervalMs
        self.installAt = installAt
        self.clock = clock
        self.nudge = nudge
        self.echo = echo
        self.log = log
        self.canRelaunch = canRelaunch
        self.relaunched = relaunched
        self.hooks = hooks
    }

    /// The real nudge: a block on the main run loop that restarts the scheduler and ticks.
    static let realNudge: @Sendable () -> Void = {
        MainRunLoop.perform { MenuBarController.shared?.nudge() }
    }

    /// The real echo: a round trip through the main dispatch queue. The clock is read on main.
    static func realEcho(_ heartbeat: MenuBarHeartbeat) -> @Sendable () -> Void {
        return {
            if heartbeat.beginEcho() {
                DispatchQueue.main.async { heartbeat.echo(at: MenuBarClock.now()) }
            }
        }
    }

    /// One check. Returns what `mm_watchdog_action` said.
    @discardableResult
    func check(now: Int64) -> UInt32 {
        let state = heartbeat.read()
        let tickAge = max(0, now - state.tickAt)
        let echoAge = max(0, now - state.echoAt)
        let late = now - state.lastCheckAt - intervalMs
        let reason = mm_stale_reason(tickAge, echoAge)
        let action = mm_watchdog_action(reason, late, state.staleChecks)
        let next = mm_stale_checks_next(reason, late, state.staleChecks)
        heartbeat.recordCheck(at: now, staleChecks: next)
        if action == UInt32(MM_WATCHDOG_NUDGE) {
            nudgeOrRelaunch(reason: reason, tickAge: tickAge, echoAge: echoAge, facts: state.facts, now: now)
        } else if action == UInt32(MM_WATCHDOG_THROTTLED) {
            log.notice("throttled late=\(late)")
        } else if action == UInt32(MM_WATCHDOG_RECOVERED) {
            log.notice("recovered tickAge=\(tickAge) echoAge=\(echoAge)")
        }
        return action
    }

    private func nudgeOrRelaunch(reason: UInt32, tickAge: Int64, echoAge: Int64, facts f: RelaunchFacts, now: Int64) {
        let tried = control.withLock { $0.openTried }
        let allowed = hooks != nil && mm_relaunches(
            tickAge, echoAge, f.windowOpen, f.appHidden, f.canQuit, f.queued, f.keepsToolState,
            canRelaunch, relaunched, now - installAt, tried)
        var exited = false
        if allowed, let hooks {
            log.notice("relaunch tickAge=\(tickAge) echoAge=\(echoAge)")
            let started = clock()
            let (rc, pid) = hooks.spawn()
            if rc != 0 {
                log.notice("relaunch-failed code=\(rc)")
            } else {
                control.withLock { $0.openTried = true }
                let status = hooks.waitExit(pid, Int64(MM_RELAUNCH_OPEN_WAIT_MS))
                let waited = max(0, clock() - started)
                if mm_relaunch_exits(Int64(rc), status != nil, Int64(status ?? 0)) {
                    if let status {
                        log.notice("relaunch open-exit status=\(status) waited_ms=\(waited)")
                    } else {
                        log.notice("relaunch open-pending waited_ms=\(MM_RELAUNCH_OPEN_WAIT_MS)")
                    }
                    hooks.exit()
                    exited = true
                } else {
                    log.notice("relaunch-failed open-status=\(status ?? 0)")
                }
            }
        } else if max(tickAge, echoAge) > Int64(MM_RELAUNCH_STALE_MS) {
            log.notice("relaunch-skipped window=\(f.windowOpen ? 1 : 0) hidden=\(f.appHidden ? 1 : 0) "
                       + "canQuit=\(f.canQuit ? 1 : 0) queued=\(f.queued) toolState=\(f.keepsToolState ? 1 : 0) "
                       + "allowed=\(hooks != nil ? 1 : 0) tried=\(tried ? 1 : 0)")
        }
        guard !exited else { return }
        let why = reason == UInt32(MM_STALE_TICK) ? "tick" : "main-queue"
        log.notice("nudge reason=\(why) tickAge=\(tickAge) echoAge=\(echoAge)")
        nudge()
    }

    /// Starts the thread. It sleeps with Thread.sleep and reads the clock that stops during sleep.
    func start() {
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: Double(intervalMs) / 1000)
                if isStopped { break }
                echo()
                check(now: clock())
            }
            control.withLock { $0.finished = true }
        }
        thread.name = "DiskBloom.MenuBarWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        control.withLock { $0.stopped = true }
    }

    var isFinished: Bool { control.withLock { $0.finished } }
    private var isStopped: Bool { control.withLock { $0.stopped } }
}

/// Why a tick runs. Only `.timer` is rate-limited; the others are forced.
enum TickReason: String, Sendable {
    case launch, timer, pressure, wake, panel, watchdog
}

/// Samples memory every second, shows the figure when it changes, and keeps the heartbeat the watchdog reads.
/// Specs/memory_rules.t27 decides: when a figure is known, when a change shows, when the watchdog acts.
@MainActor
final class MenuBarController {
    static var shared: MenuBarController?

    private let monitor: MemoryMonitorModel
    private let display: any MenuBarDisplay
    private let sampler: @MainActor () -> MemorySnapshot?
    private let clock: @MainActor () -> Int64
    private let heartbeat: MenuBarHeartbeat
    private let scheduler: any TickScheduler
    private let log: any MenuBarLogging
    private let facts: (@MainActor () -> RelaunchFacts)?
    private let debugMarker: Bool

    private var installed = false
    private var installAt: Int64
    private var misses: Int64 = 0
    private var last: MemorySnapshot?
    private var wasKnown = false
    private var shownPercent: Int64 = 0
    private var shownLevel = UInt32(MM_LEVEL_NORMAL)
    private var shownKnown = false
    private var shownAt: Int64
    private var shownLabel = MenuBarLabel.unknown
    private var lastPressureCode: Int64 = -1
    private var watchdog: MenuBarWatchdog?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var wakeToken: (any NSObjectProtocol)?

    init(
        monitor: MemoryMonitorModel,
        display: any MenuBarDisplay,
        sampler: @escaping @MainActor () -> MemorySnapshot?,
        clock: @escaping @MainActor () -> Int64,
        heartbeat: MenuBarHeartbeat,
        scheduler: any TickScheduler,
        log: any MenuBarLogging,
        facts: (@MainActor () -> RelaunchFacts)?,
        debugMarker: Bool
    ) {
        self.monitor = monitor
        self.display = display
        self.sampler = sampler
        self.clock = clock
        self.heartbeat = heartbeat
        self.scheduler = scheduler
        self.log = log
        self.facts = facts
        self.debugMarker = debugMarker
        let now = clock()
        installAt = now
        shownAt = now
    }

    /// Called once from `applicationDidFinishLaunching`.
    /// No ProcessInfo activity and no disableAutomaticTermination: spike U3, 2026-10-29 (no throttling
    /// without an activity; the TAL key unchanged by the call).
    func install() {
        guard !installed else { return }
        installed = true
        installAt = clock()
        heartbeat.reset(now: installAt)
        shownAt = installAt
        let canRelaunch = mm_can_relaunch(AppSandbox.isActive, MenuBarRelaunch.launchSuppressible)
        let relaunched = MenuBarRelaunch.launchedByWatchdog
        let suppressed = MenuBarRelaunch.suppressesLaunchWindow
        if suppressed {
            // A copy started without a window leaves the Dock, as in monitor mode.
            DockIcon.update(windowOpen: false, appHidden: NSApp.isHidden)
        }
        tick(.launch)
        startScheduler()

        let relaunchOn = canRelaunch && facts != nil
        var hooks: MenuBarRelaunchHooks?
        if relaunchOn {
            #if DEBUG
            let extra = MenuBarAutomation.relaunchArguments()
            #else
            let extra: [String] = []
            #endif
            hooks = RelaunchCommand(bundlePath: Bundle.main.bundlePath, extra: extra).hooks()
        }
        let watchdog = MenuBarWatchdog(
            heartbeat: heartbeat,
            installAt: installAt,
            clock: { MenuBarClock.now() },
            nudge: MenuBarWatchdog.realNudge,
            echo: MenuBarWatchdog.realEcho(heartbeat),
            log: log,
            canRelaunch: relaunchOn,
            relaunched: relaunched,
            hooks: hooks
        )
        watchdog.start()
        self.watchdog = watchdog

        // No handler closure is written here (isolation rule above).
        pressureSource = MenuBarPressure.makeSource()
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarController.shared?.handleWake() }
        }

        let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        log.notice("installed interval=\(MM_LABEL_REFRESH_MS) minChange=\(MM_LABEL_MIN_CHANGE_MS) "
                   + "watchdog=\(MM_WATCHDOG_MS) relaunch=\(relaunchOn ? 1 : 0) relaunched=\(relaunched ? 1 : 0) "
                   + "suppressed=\(suppressed ? 1 : 0) policy=\(policy)")
        #if DEBUG
        MenuBarAutomation.start(controller: self, monitor: monitor, log: log)
        #endif
    }

    private func startScheduler() {
        scheduler.start(
            intervalMs: Int64(MM_LABEL_REFRESH_MS),
            toleranceMs: mm_timer_tolerance_ms(Int64(MM_LABEL_REFRESH_MS))
        ) {
            MenuBarController.shared?.tick(.timer)
        }
    }

    func tick(_ reason: TickReason) {
        #if DEBUG
        // What the item shows now is what the earlier ticks set (the view updates after they return).
        let readBack = MenuBarAutomation.readBack()
        #endif
        let now = clock()
        let sample = sampler()
        misses = sample == nil ? misses + 1 : 0
        if let sample { last = sample }
        let known = mm_label_known(misses, last != nil)
        if sample == nil && misses == 1 { log.notice("sample-failed") }
        if wasKnown && !known { log.notice("unknown") }
        wasKnown = known
        if let sample, sample.pressureCode != lastPressureCode {
            lastPressureCode = sample.pressureCode
            log.notice("pressure code=\(sample.pressureCode)")
        }

        #if DEBUG
        let percent = MenuBarAutomation.forcedPercent ?? last?.percent ?? 0
        #else
        let percent = last?.percent ?? 0
        #endif
        let level = last?.levelCode ?? UInt32(MM_LEVEL_NORMAL)
        let changes = mm_label_changes(shownPercent, shownLevel, shownKnown, percent, level, known)
        let due = mm_label_due(reason != .timer, shownPercent, shownLevel, shownKnown, percent, level, known, now - shownAt)
        let show = changes && due
        if show {
            let label = MenuBarLabel.make(percent: percent, level: level, known: known, debugMarker: debugMarker)
            display.show(label)
            shownLabel = label
            shownPercent = percent
            shownLevel = level
            shownKnown = known
            shownAt = now
        }
        monitor.apply(sample, known: known, labelShown: show)
        heartbeat.tick(at: now, facts: facts?() ?? .noRelaunch)
        #if DEBUG
        MenuBarAutomation.didTick(
            now: now, reason: reason, percent: percent, level: level, known: known, shown: show,
            held: changes && !due, title: shownLabel.title, readBack: readBack)
        #endif
    }

    func panelOpened() {
        monitor.panelAppeared()
        log.notice("panel opened")
        tick(.panel)
    }

    func panelClosed() {
        monitor.panelDisappeared()
        log.notice("panel closed")
    }

    /// The watchdog's nudge: start the scheduler again, then tick.
    func nudge() {
        scheduler.stop()
        startScheduler()
        tick(.watchdog)
    }

    func handleWake() {
        log.notice("wake")
        tick(.wake)
    }

    #if DEBUG
    /// Fault F2 of the live check: the ticks stop and the heartbeat is left alone.
    func debugStopScheduler() {
        scheduler.stop()
    }
    #endif
}

/// Asks every malloc zone to return its free pages once the Disk Map's data has been dropped
/// (Specs/memory_rules.t27, `MM_RELIEF_DELAY_MS`). The delay lets the closed window's views let go of the
/// map first. On macOS 27 the allocator ignores the request and returns 0 (measured 2026-10-28); there it
/// is the disk scanner's per-entry autorelease pool (DiskScanner) that keeps the scan's temporary objects
/// from piling up.
enum MemoryRelief {
    static func schedule() {
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(Int(MM_RELIEF_DELAY_MS)))
            let released = malloc_zone_pressure_relief(nil, 0)
            #if DEBUG
            FileHandle.standardError.write(Data("DISKBLOOM_AUTOMATION relief-bytes=\(released)\n".utf8))
            #else
            _ = released
            #endif
        }
    }
}

/// Monitor mode: once no DiskBloom window is open, only the menu bar monitor is in use, so the Disk Map's
/// data is dropped and the freed memory returned to macOS. DiskBloom also leaves the Dock (`mm_dock_shown`,
/// `DockIcon`). Specs/memory_rules.t27 decides when (`mm_window_open`, `mm_monitor_action`); this class reads
/// the facts and acts on the answer.
@MainActor
final class MonitorModeController {
    private weak var app: AppModel?
    private var observer: (any NSObjectProtocol)?
    private var recheck: Task<Void, Never>?

    func attach(app: AppModel) {
        self.app = app
        recheck?.cancel()
        recheck = nil
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            // Only the window's identity crosses into the main-actor closure.
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.windowWillClose(closing) }
        }
        #if DEBUG
        MonitorModeAutomation.start(app: app)
        #endif
    }

    /// A DiskBloom window appeared (each WindowGroup window's onAppear): the Dock icon and the menu bar come back.
    func windowAppeared() {
        if DockIcon.update(windowOpen: true, appHidden: NSApp.isHidden) { NSApp.activate() }
    }

    private func windowWillClose(_ closing: ObjectIdentifier?) {
        // Only a DiskBloom window closing can move the Dock icon; the panel, sheets and alerts cannot.
        let closingCounts = NSApp.windows.contains {
            ObjectIdentifier($0) == closing
                && mm_window_open($0.canBecomeMain, $0 is NSPanel, $0.isVisible, $0.isMiniaturized)
        }
        // Runs after the close completes; the closing window is left out in case it still looks open.
        Task { [weak self] in self?.check(excluding: closing, updatesDock: closingCounts) }
    }

    private func check(excluding closing: ObjectIdentifier?, updatesDock: Bool = false) {
        let open = NSApp.windows.contains {
            ObjectIdentifier($0) != closing
                && mm_window_open($0.canBecomeMain, $0 is NSPanel, $0.isVisible, $0.isMiniaturized)
        }
        let hidden = NSApp.isHidden
        if updatesDock { DockIcon.update(windowOpen: open, appHidden: hidden) }
        apply(windowOpen: open, appHidden: hidden)
    }

    /// Acts on what `mm_monitor_action` says and returns its code.
    @discardableResult
    func apply(windowOpen: Bool, appHidden: Bool) -> UInt32 {
        guard let app else { return UInt32(MM_MONITOR_KEEP) }
        let action = mm_monitor_action(windowOpen, appHidden, app.isMovingToTrash,
                                       Int64(app.collection.count), app.holdsDiskMap)
        if action == UInt32(MM_MONITOR_RELEASE) {
            app.releaseDiskMap()
            MemoryRelief.schedule()
        } else if action == UInt32(MM_MONITOR_WAIT) {
            recheck?.cancel()
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(MM_MONITOR_RECHECK_MS)))
                guard !Task.isCancelled else { return }
                self?.check(excluding: nil)
            }
        }
        return action
    }
}

/// DiskBloom's Dock icon (Specs/memory_rules.t27, `mm_dock_shown`): shown while a DiskBloom window is open or
/// the app is hidden, gone otherwise, so a DiskBloom with only its menu bar item leaves the Dock.
@MainActor
enum DockIcon {
    /// Pure: reads nothing from the app, so the smoke test can check it.
    static func policy(windowOpen: Bool, appHidden: Bool) -> NSApplication.ActivationPolicy {
        mm_dock_shown(windowOpen, appHidden) ? .regular : .accessory
    }

    /// Sets the policy only when it differs from the current one. Returns true when it changed.
    @discardableResult
    static func update(windowOpen: Bool, appHidden: Bool) -> Bool {
        let wanted = policy(windowOpen: windowOpen, appHidden: appHidden)
        guard NSApp.activationPolicy() != wanted else { return false }
        #if DEBUG
        let wasActive = NSApp.isActive
        #endif
        let changed = NSApp.setActivationPolicy(wanted)
        #if DEBUG
        let name = wanted == .regular ? "regular" : "accessory"
        let active = wasActive ? 1 : 0
        let line = changed
            ? "DISKBLOOM_AUTOMATION activation-policy=\(name) active=\(active)\n"
            : "DISKBLOOM_AUTOMATION activation-policy-refused=\(name) active=\(active)\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
        return changed
    }
}

#if DEBUG
/// Debug-only hook for the live memory check. Compiled out of every release build (build.sh and the Xcode
/// Release configuration), like ScreenshotAutomation.
///   -DiskBloomAutomationMonitorMode YES        waits for the Disk Map scan, closes every window after 60 s,
///                                              quits 90 s later
///   -DiskBloomAutomationMonitorRoot <folder>   every Disk Map scan that would start on its own (at launch or
///                                              when a window opens) scans <folder> instead of the home folder
///                                              (`AppModel.startInitialScan`, debug builds)
/// The value may come from the arguments or from the test bundle's persisted defaults (the live checks of the
/// menu bar figure set it with `defaults write`; see MenuBarAutomation).
/// Progress goes to stderr as `DISKBLOOM_AUTOMATION <marker>` lines.
/// The scan-finished line also gives the map's root, size, file count, folder count and scan seconds.
@MainActor
enum MonitorModeAutomation {
    static func start(app: AppModel) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "DiskBloomAutomationMonitorMode") else { return }
        if let root = defaults.string(forKey: "DiskBloomAutomationMonitorRoot") {
            app.startScan(at: URL(fileURLWithPath: root, isDirectory: true))
        }
        Task {
            while app.snapshot == nil || app.isScanning {
                try? await Task.sleep(for: .seconds(1))
            }
            log(scanFinishedLine(app))
            try? await Task.sleep(for: .seconds(60))
            for window in NSApp.windows
            where mm_window_open(window.canBecomeMain, window is NSPanel, window.isVisible, window.isMiniaturized) {
                window.performClose(nil)
            }
            log("windows-closed")
            try? await Task.sleep(for: .seconds(90))
            log("quitting")
            NSApp.terminate(nil)
        }
    }

    /// The marker for a finished scan. Built in its own function so no copy of the map lives on in the task
    /// above, which keeps running through the release.
    private static func scanFinishedLine(_ app: AppModel) -> String {
        guard let snapshot = app.snapshot else { return "scan-finished root=none" }
        let root = snapshot.root
        return "scan-finished root=\(root.url?.path ?? "none") size=\(root.size) files=\(root.fileCount) folders=\(root.directoryCount) seconds=\(Int(snapshot.duration.rounded()))"
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("DISKBLOOM_AUTOMATION \(line)\n".utf8))
    }
}
#endif

#if DEBUG
/// Debug-only driver for the live check of the menu bar figure (the plan's sections 9 and 10). Compiled out of
/// every release build. Every flag is read from the arguments or the persisted defaults:
///   -DiskBloomAutomationMenuBar YES              master switch: tick, step and fault lines, the stderr mirror of
///                                                the MenuBar log lines, the ladybug symbol, the read-back
///   -DiskBloomAutomationMenuBarSchedule <name>   live | relaunched | m1 | window | window-finder |
///                                                window-normal (default none)
///   -DiskBloomAutomationMenuBarStallMs <ms>      length of fault F1 (default 0: F1 is skipped)
///   -DiskBloomAutomationMenuBarQuitAfter <s>     quits at the first tick this long after install
///   -DiskBloomAutomationNoWindow YES             starts without a window (`MenuBarRelaunch`)
///   -DiskBloomAutomationMenuBarForcePercent <n>  shows n % instead of the measured figure, to see each chip
///                                                band (independent of the master switch: no ladybug)
/// The schedule advances at the end of every tick, so a blocked main thread delays it, not the watchdog.
@MainActor
enum MenuBarAutomation {
    struct ReadBack: Sendable {
        var title: String
        var accessibility: String
        static let none = ReadBack(title: "n/a", accessibility: "n/a")
    }

    private enum Action {
        case windowsAndCommands, windows, closeWindows, openWindow, closeIfOpen, miniaturize, hide, openTwice
        case f1, f2, f3, f4, terminate
    }

    private struct Step {
        let name: String
        let seconds: Int64
        let action: Action
    }

    static let enabled: Bool = UserDefaults.standard.bool(forKey: "DiskBloomAutomationMenuBar")
    static let forcedPercent: Int64? = UserDefaults.standard.object(forKey: "DiskBloomAutomationMenuBarForcePercent") == nil ? nil : Int64(UserDefaults.standard.integer(forKey: "DiskBloomAutomationMenuBarForcePercent"))
    private static var controller: MenuBarController?
    private static var monitor: MemoryMonitorModel?
    private static var sink: (any MenuBarLogging)?
    private static var steps: [Step] = []
    private static var nextStep = 0
    private static var startedAt: Int64 = 0
    private static var quitAfterMs: Int64 = 0
    private static var stallMs: Int64 = 0
    private static var tickCount = 0
    private static var quitSent = false

    static func start(controller: MenuBarController, monitor: MemoryMonitorModel, log: any MenuBarLogging) {
        guard enabled else { return }
        self.controller = controller
        self.monitor = monitor
        sink = log
        startedAt = MenuBarClock.now()
        let defaults = UserDefaults.standard
        stallMs = Int64(defaults.integer(forKey: "DiskBloomAutomationMenuBarStallMs"))
        quitAfterMs = Int64(defaults.integer(forKey: "DiskBloomAutomationMenuBarQuitAfter")) * 1000
        steps = schedule(named: defaults.string(forKey: "DiskBloomAutomationMenuBarSchedule") ?? "")
        nextStep = 0
    }

    /// Writes one line into the same log as the ticks and steps (only while the live check is on).
    static func note(_ line: String) {
        guard enabled, let sink else { return }
        sink.notice(line)
    }

    /// The extra arguments a relaunched copy gets from the watchdog of a debug build.
    static func relaunchArguments() -> [String] {
        guard enabled else { return [] }
        let defaults = UserDefaults.standard
        var extra = ["-DiskBloomAutomationMenuBar", "YES"]
        if let root = defaults.string(forKey: "DiskBloomAutomationMonitorRoot") {
            extra += ["-DiskBloomAutomationMonitorRoot", root]
        }
        switch defaults.string(forKey: "DiskBloomAutomationMenuBarSchedule") {
        case "live":
            extra += ["-DiskBloomAutomationMenuBarSchedule", "relaunched", "-DiskBloomAutomationMenuBarQuitAfter", "120"]
        case "m1":
            extra += ["-DiskBloomAutomationMenuBarSchedule", "m1", "-DiskBloomAutomationMenuBarQuitAfter", "3600"]
        default:
            break
        }
        return extra
    }

    private static func schedule(named name: String) -> [Step] {
        switch name {
        case "live":
            var list = [
                Step(name: "windows-commands", seconds: 5, action: .windowsAndCommands),
                Step(name: "close-windows", seconds: 20, action: .closeWindows),
                Step(name: "open-window", seconds: 80, action: .openWindow),
                Step(name: "windows-after-open", seconds: 90, action: .windows),
                Step(name: "close-windows-again", seconds: 110, action: .closeWindows),
                Step(name: "windows-after-close", seconds: 120, action: .windows),
            ]
            if stallMs > 0 { list.append(Step(name: "F1", seconds: 140, action: .f1)) }
            list += [
                Step(name: "F2", seconds: 200, action: .f2),
                Step(name: "F3", seconds: 260, action: .f3),
                Step(name: "F4", seconds: 610, action: .f4),
                Step(name: "terminate", seconds: 800, action: .terminate),
            ]
            return list
        case "relaunched":
            return [
                Step(name: "windows", seconds: 5, action: .windows),
                Step(name: "open-window", seconds: 30, action: .openWindow),
                Step(name: "windows-commands", seconds: 40, action: .windowsAndCommands),
                Step(name: "close-windows", seconds: 50, action: .closeWindows),
                Step(name: "windows-after-close", seconds: 60, action: .windows),
                Step(name: "windows-after-finder", seconds: 80, action: .windows),
                Step(name: "close-windows-again", seconds: 90, action: .closeWindows),
                Step(name: "windows-final", seconds: 100, action: .windows),
            ]
        case "window":
            // Pass A of run-window.zsh: no window at the start; the script sends the Finder-style open at +57.
            return [
                Step(name: "windows-start", seconds: 5, action: .windows),
                Step(name: "open-first", seconds: 8, action: .openTwice),
                Step(name: "windows-after-open", seconds: 14, action: .windowsAndCommands),
                Step(name: "open-front", seconds: 15, action: .openWindow),
                Step(name: "windows-after-front", seconds: 20, action: .windows),
                Step(name: "miniaturize", seconds: 21, action: .miniaturize),
                Step(name: "windows-minimized", seconds: 25, action: .windows),
                Step(name: "open-restore", seconds: 26, action: .openWindow),
                Step(name: "windows-restored", seconds: 31, action: .windows),
                Step(name: "hide", seconds: 32, action: .hide),
                Step(name: "windows-hidden", seconds: 36, action: .windows),
                Step(name: "open-unhide", seconds: 37, action: .openWindow),
                Step(name: "windows-unhidden", seconds: 42, action: .windows),
                Step(name: "close-1", seconds: 43, action: .closeWindows),
                Step(name: "windows-closed", seconds: 49, action: .windows),
                Step(name: "windows-after-finder", seconds: 63, action: .windows),
                Step(name: "close-2", seconds: 64, action: .closeWindows),
                Step(name: "windows-final", seconds: 70, action: .windows),
            ]
        case "window-finder":
            // Pass B: no window at the start; the Finder-style open comes at +8.
            return [
                Step(name: "windows-start", seconds: 5, action: .windows),
                Step(name: "windows-after-finder", seconds: 14, action: .windows),
                Step(name: "close-1", seconds: 15, action: .closeWindows),
                Step(name: "windows-final", seconds: 21, action: .windows),
            ]
        case "window-normal":
            // Pass C: a normal launch; the Finder-style open comes at +14.
            return [
                Step(name: "windows-start", seconds: 5, action: .windows),
                Step(name: "close-1", seconds: 6, action: .closeWindows),
                Step(name: "windows-closed", seconds: 12, action: .windows),
                Step(name: "windows-after-finder", seconds: 20, action: .windows),
                Step(name: "close-2", seconds: 21, action: .closeWindows),
                Step(name: "windows-closed-2", seconds: 27, action: .windows),
                Step(name: "open-normal", seconds: 28, action: .openWindow),
                Step(name: "windows-after-open", seconds: 34, action: .windows),
                Step(name: "close-3", seconds: 35, action: .closeWindows),
                Step(name: "windows-final", seconds: 41, action: .windows),
            ]
        case "m1":
            return [Step(name: "windows", seconds: 5, action: .closeIfOpen)]
        default:
            return []
        }
    }

    /// Called at the end of every tick.
    static func didTick(
        now: Int64, reason: TickReason, percent: Int64, level: UInt32, known: Bool, shown: Bool, held: Bool,
        title: String, readBack: ReadBack
    ) {
        guard enabled, let sink else { return }
        tickCount += 1
        let epoch = Int64(Date().timeIntervalSince1970 * 1000)
        var line = "tick ms=\(epoch) up=\(now) n=\(tickCount) reason=\(reason.rawValue) percent=\(percent) "
            + "level=\(level) known=\(known ? 1 : 0) shown=\(shown ? 1 : 0) held=\(held ? 1 : 0) "
            + "label=\"\(title)\" rbTitle=\"\(readBack.title)\" rbAx=\"\(readBack.accessibility)\""
        if reason == .panel, let monitor { line += " panelText=\"\(monitor.percentText)\"" }
        sink.notice(line)
        runDueSteps(now: now, sink: sink)
    }

    private static func runDueSteps(now: Int64, sink: any MenuBarLogging) {
        let elapsed = now - startedAt
        while nextStep < steps.count, elapsed >= steps[nextStep].seconds * 1000 {
            let step = steps[nextStep]
            nextStep += 1
            sink.notice("step name=\(step.name) t=\(String(format: "%.1f", Double(elapsed) / 1000))")
            run(step.action, sink: sink)
        }
        if quitAfterMs > 0, !quitSent, elapsed >= quitAfterMs {
            quitSent = true
            sink.notice("step name=quit-after t=\(String(format: "%.1f", Double(elapsed) / 1000))")
            NSApp.terminate(nil)
        }
    }

    private static func run(_ action: Action, sink: any MenuBarLogging) {
        switch action {
        case .windows:
            logWindows(sink)
        case .windowsAndCommands:
            logWindows(sink)
            let choose = hasMenuItem("Choose Folder…", in: NSApp.mainMenu)
            let rescan = hasMenuItem("Rescan", in: NSApp.mainMenu)
            sink.notice("commands choose=\(choose ? 1 : 0) rescan=\(rescan ? 1 : 0)")
        case .closeWindows:
            closeWindows()
        case .openWindow:
            monitor?.openMainWindow()
        case .openTwice:
            monitor?.openMainWindow()
            monitor?.openMainWindow()
        case .miniaturize:
            MainWindow.find().shown?.miniaturize(nil)
        case .hide:
            NSApp.hide(nil)
        case .closeIfOpen:
            let count = openWindowCount()
            logWindows(sink)
            if count > 0 {
                closeWindows()
                sink.notice("step name=m1-closed-window")
            }
        case .f1:
            sink.notice("fault F1 start")
            usleep(UInt32(clamping: stallMs * 1000))
            sink.notice("fault F1 end")
        case .f2:
            controller?.debugStopScheduler()
            sink.notice("fault F2 start")
        case .f3:
            sink.notice("fault F3 start")
            // This block always runs on the main thread, so the isolation rule allows the literal here.
            DispatchQueue.main.async {
                _ = CFRunLoopRunInMode(.defaultMode, 20, false)
                sink.notice("fault F3 end")
            }
        case .f4:
            sink.notice("fault F4 start")
            usleep(180_000_000)
            sink.notice("fault F4 end relaunch=none")
        case .terminate:
            NSApp.terminate(nil)
        }
    }

    private static func openWindowCount() -> Int {
        NSApp.windows.filter { mm_window_open($0.canBecomeMain, $0 is NSPanel, $0.isVisible, $0.isMiniaturized) }.count
    }

    private static func logWindows(_ sink: any MenuBarLogging) {
        let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        let minimized = NSApp.windows.filter { !($0 is NSPanel) && $0.isMiniaturized }.count
        sink.notice(
            "windows=\(openWindowCount()) policy=\(policy) mini=\(minimized) hidden=\(NSApp.isHidden ? 1 : 0) "
                + "scene=\(MainWindow.sceneReady ? 1 : 0)"
        )
    }

    private static func closeWindows() {
        for window in NSApp.windows
        where mm_window_open(window.canBecomeMain, window is NSPanel, window.isVisible, window.isMiniaturized) {
            window.performClose(nil)
        }
    }

    private static func hasMenuItem(_ title: String, in menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        for item in menu.items {
            if item.title == title || hasMenuItem(title, in: item.submenu) { return true }
        }
        return false
    }

    // MARK: Read-back of the status item (spike U1b)

    /// What the status item's button shows now. Taken at the start of a tick: it reflects the ticks before.
    static func readBack() -> ReadBack {
        guard enabled else { return .none }
        let windows = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
        for window in windows {
            if let content = window.contentView, let found = find(in: content, strict: true) { return found }
        }
        for window in windows {
            if let content = window.contentView, let found = find(in: content, strict: false) { return found }
        }
        return .none
    }

    private static func find(in view: NSView, strict: Bool) -> ReadBack? {
        let button = view as? NSButton
        let matches: Bool
        if strict {
            matches = String(describing: type(of: view)).contains("StatusBarButton")
        } else {
            matches = button.map { $0.title.contains("%") || ($0.accessibilityLabel() ?? "").contains("%") } ?? false
        }
        if matches {
            return ReadBack(title: button?.title ?? "", accessibility: view.accessibilityLabel() ?? "")
        }
        for child in view.subviews {
            if let found = find(in: child, strict: strict) { return found }
        }
        return nil
    }
}
#endif
