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

@main
private struct MemoryMonitorSmoke {
    static func main() throws {
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

        print("MEMORY_MONITOR_SMOKE_OK")
    }
}
