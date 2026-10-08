import SwiftUI

/// Formatting and ring-map rules as written in Swift before Specs/format_rules.t27 and Specs/sunburst_rules.t27. Oracle only.
enum LegacyByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func compact(_ bytes: Int64) -> String {
        let amount = Double(max(0, bytes))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = amount
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) \(units[index])" }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.*f %@", digits, value, units[index])
    }
}

enum LegacyPlural {
    static func objects(_ count: Int) -> String {
        form(count, one: "item", many: "items")
    }

    static func files(_ count: Int) -> String {
        form(count, one: "file", many: "files")
    }

    private static func form(_ count: Int, one: String, many: String) -> String {
        abs(count) == 1 ? one : many
    }
}
struct LegacyVolumeStats: Sendable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

enum LegacySunburstLayout {
    static let maxDepth = 6
    static let maxSegments = 2_400

    static func make(for root: DiskNode) -> [LegacySunburstSegment] {
        guard root.size > 0 else { return [] }
        var result: [LegacySunburstSegment] = []
        append(
            children: root.children,
            startAngle: -.pi / 2,
            endAngle: .pi * 1.5,
            depth: 0,
            inheritedBranch: 0,
            into: &result
        )
        return result
    }

    private static func append(
        children: [DiskNode],
        startAngle: Double,
        endAngle: Double,
        depth: Int,
        inheritedBranch: Int,
        into result: inout [LegacySunburstSegment]
    ) {
        guard depth < maxDepth, !children.isEmpty, result.count < maxSegments else { return }
        let total = children.reduce(Int64(0)) { $0 + max(0, $1.size) }
        guard total > 0 else { return }

        var cursor = startAngle
        let fullSpan = endAngle - startAngle
        for (index, child) in children.enumerated() {
            guard result.count < maxSegments else { break }
            let fraction = Double(max(0, child.size)) / Double(total)
            let next = index == children.count - 1 ? endAngle : cursor + fullSpan * fraction
            let branch = depth == 0 ? index : inheritedBranch
            if next - cursor > 0.000_01 {
                result.append(
                    LegacySunburstSegment(
                        id: child.id,
                        node: child,
                        depth: depth,
                        startAngle: cursor,
                        endAngle: next,
                        color: paletteColor(branch: branch, depth: depth, isVirtual: child.isVirtual)
                    )
                )
                if !child.children.isEmpty {
                    append(
                        children: child.children,
                        startAngle: cursor,
                        endAngle: next,
                        depth: depth + 1,
                        inheritedBranch: branch,
                        into: &result
                    )
                }
            }
            cursor = next
        }
    }

    static func paletteColor(branch: Int, depth: Int, isVirtual: Bool = false) -> Color {
        if isVirtual { return Color(red: 0.35, green: 0.39, blue: 0.46) }
        let hues: [Double] = [0.48, 0.39, 0.15, 0.075, 0.93, 0.73, 0.56, 0.29]
        let hue = hues[abs(branch) % hues.count]
        let saturation = max(0.46, 0.82 - Double(depth) * 0.055)
        let brightness = max(0.68, 0.96 - Double(depth) * 0.045)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}


struct LegacySunburstSegment {
    let id: UUID
    let node: DiskNode
    let depth: Int
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

extension LegacySunburstLayout {
    static func paletteComponents(branch: Int, depth: Int, isVirtual: Bool) -> [Double] {
        if isVirtual { return [0.35, 0.39, 0.46, 1] }
        let hues: [Double] = [0.48, 0.39, 0.15, 0.075, 0.93, 0.73, 0.56, 0.29]
        let hue = hues[abs(branch) % hues.count]
        let saturation = max(0.46, 0.82 - Double(depth) * 0.055)
        let brightness = max(0.68, 0.96 - Double(depth) * 0.045)
        return [hue, saturation, brightness, 0]
    }
}

/// The ring-map view arithmetic of the old SunburstView body, as one function.
enum LegacySunburstGeometry {
    static func rings(side: Double, deepest: Int) -> [Double] {
        let outerRadius = max(110, side / 2 - 20)
        let innerRadius = max(54, min(84, outerRadius * 0.24))
        let activeRingCount = max(1, deepest + 1)
        let ringWidth = max(12, (outerRadius - innerRadius) / Double(activeRingCount))
        return [outerRadius, innerRadius, ringWidth, innerRadius * 1.72]
    }

    static func ring(depth: Int, inner: Double, outer: Double, width: Double) -> [Double] {
        let ringInner = inner + Double(depth) * width
        return [ringInner, min(outer, ringInner + width - 2)]
    }

    static func inset(start: Double, end: Double, gap: Double) -> Double {
        let span = max(0, end - start)
        return min(gap, span * 0.2)
    }

    static func hitRing(radius: Double, inner: Double, outer: Double, width: Double) -> Int? {
        guard radius >= inner, radius <= outer else { return nil }
        return Int((radius - inner) / width)
    }

    static func layoutAngle(_ raw: Double) -> Double {
        var angle = raw
        if angle < -.pi / 2 { angle += .pi * 2 }
        return angle
    }

    static func hoverY(height: Double) -> Double { max(42, height - 36) }
}

enum LegacyProgress {
    static func scanShows(itemCount: Int, hasPath: Bool) -> Bool { itemCount % 32 == 0 || !hasPath }
    static func duplicateShows(examined: Int) -> Bool { examined == 1 || examined.isMultiple(of: 32) }
}
