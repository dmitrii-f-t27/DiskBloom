import AppKit
import Darwin
import Foundation

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

    static func refreshMilliseconds(panelOpen: Bool) -> Int64 { mm_refresh_ms(panelOpen) }

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
    /// listed by its own name. An app is named by its bundle's file name; the monitor then shows the
    /// name Finder shows.
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
                let file = Array(bundle.utf8)[start..<max(start, Int(groupEnd) - 4)]
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

/// Keeps the menu bar percentage fresh, and the list while the panel is open.
@MainActor
final class MemoryMonitorModel: ObservableObject {
    @Published private(set) var snapshot = MemorySnapshot()
    @Published private(set) var rows: [UsageRow] = []
    @Published private(set) var unreadable = 0
    @Published private(set) var measuring = false
    @Published var sortMode = MemoryRules.sortMemory {
        didSet { rows = MemoryGrouping.top(allRows, sort: sortMode) }
    }

    /// False in the App Store edition: the App Sandbox hides other processes.
    let listsProcesses = mm_lists_processes(AppSandbox.isActive)

    private var panelOpen = false
    private var loop: Task<Void, Never>?
    private var allRows: [UsageRow] = []
    private var previousCPU: [Int32: Int64] = [:]
    private var previousAt: ContinuousClock.Instant?
    private var names: [String: String] = [:]
    private var icons: [String: NSImage] = [:]

    init() {
        start()
    }

    var percentText: String { "\(snapshot.percent)%" }

    func panelAppeared() {
        guard !panelOpen else { return }
        panelOpen = true
        measuring = listsProcesses
        restart()
    }

    func panelDisappeared() {
        guard panelOpen else { return }
        panelOpen = false
        allRows = []
        rows = []
        previousCPU = [:]
        previousAt = nil
        measuring = false
        restart()
    }

    func icon(for row: UsageRow) -> NSImage? {
        guard let path = row.bundlePath else { return nil }
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    private func restart() {
        loop?.cancel()
        start()
    }

    private func start() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let wait = MemoryRules.refreshMilliseconds(panelOpen: self.panelOpen)
                try? await Task.sleep(for: .milliseconds(wait))
            }
        }
    }

    private func refresh() async {
        if let system = MemorySampler.system() { snapshot = system }
        guard panelOpen, listsProcesses else { return }
        let sampling = await Task.detached(priority: .utility) { MemorySampler.processes() }.value
        guard panelOpen, !Task.isCancelled else { return }
        let wallNs = previousAt.map { MemoryRules.nanoseconds(sampling.at - $0) } ?? 0
        let grouped = MemoryGrouping.aggregate(
            sampling.samples,
            previousCPU: previousCPU,
            hasPrevious: previousAt != nil,
            wallNs: wallNs
        )
        allRows = grouped.map { row in
            guard let bundle = row.bundlePath else { return row }
            return UsageRow(id: row.id, name: displayName(bundle), bundlePath: bundle, bytes: row.bytes,
                            cpuPermille: row.cpuPermille, processes: row.processes)
        }
        rows = MemoryGrouping.top(allRows, sort: sortMode)
        unreadable = sampling.unreadable
        previousCPU = sampling.samples.reduce(into: [:]) { $0[$1.pid] = $1.cpuNs }
        previousAt = sampling.at
        measuring = false
    }

    private func displayName(_ bundlePath: String) -> String {
        if let cached = names[bundlePath] { return cached }
        let name = FileManager.default.displayName(atPath: bundlePath)
        names[bundlePath] = name
        return name
    }

    /// Brings the DiskBloom window forward, opening one if it was closed.
    func openMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration(),
                                               completionHandler: nil)
        }
    }

    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
