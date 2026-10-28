import AppKit
import Darwin
import Foundation

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

        print("MEMORY_MONITOR_SMOKE_OK")
    }
}
