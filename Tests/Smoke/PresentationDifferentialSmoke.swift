import Foundation

/// Compares the formatting and ring-map rules written in Swift before Specs/format_rules.t27 and
/// Specs/sunburst_rules.t27 (Tests/Smoke/PresentationLegacy.swift) with the ones that ask the specs.
/// Angles and colours must be bit-for-bit equal.
@main
@MainActor
struct PresentationDifferentialSmoke {
    static func main() throws {
        var generator = SplitMix(seed: 0xF0F0)
        var checks = 0

        var sizes: [Int64] = Array(-5...2_100).map(Int64.init)
        for exponent in 0..<19 {
            let base = Int64(pow(10.0, Double(exponent)))
            sizes += [base - 1, base, base + 1, base / 2 * 3, base / 1000 * 999]
        }
        sizes += [Int64.max, Int64.min, Int64.max - 1, 999_999, 1_000_000, 9_995_000, 99_950_000]
        for _ in 0..<20_000 { sizes.append(Int64(bitPattern: generator.next()) >> Int(generator.next() % 64)) }
        for size in sizes {
            try same("compact \(size)", LegacyByteFormat.compact(size), ByteFormat.compact(size))
            checks += 1
        }
        for count in -50...50 {
            try same("plural \(count)", LegacyPlural.objects(count), Plural.objects(count))
            try same("files \(count)", LegacyPlural.files(count), Plural.files(count))
        }
        for _ in 0..<5_000 {
            let total = Int64(bitPattern: generator.next()) >> Int(generator.next() % 64)
            let available = Int64(bitPattern: generator.next()) >> Int(generator.next() % 64)
            guard total.subtractingReportingOverflow(available).overflow == false else { continue }
            let before = LegacyVolumeStats(total: total, available: available)
            let after = VolumeStats(total: total, available: available)
            try same("used \(total) \(available)", before.used, after.used)
            try same("fraction \(total) \(available)", before.usedFraction.bitPattern, after.usedFraction.bitPattern)
            checks += 1
        }
        for count in 0..<3_000 {
            try same("scan progress \(count)", LegacyProgress.scanShows(itemCount: count, hasPath: true), fm_scan_progress_shows(Int64(count), true))
            try same("scan progress empty \(count)", LegacyProgress.scanShows(itemCount: count, hasPath: false), fm_scan_progress_shows(Int64(count), false))
            try same("duplicate progress \(count)", LegacyProgress.duplicateShows(examined: count), fm_duplicate_progress_shows(Int64(count)))
        }

        // Ring map layout on real trees.
        var segments = 0
        for path in ["/System/Library/CoreServices", "/Applications", "/System/Library/Fonts", NSHomeDirectory() + "/Library/Caches/Homebrew"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var scanner = DiskScanner()
            let root = try scanner.scan(root: URL(fileURLWithPath: path), counter: ScanCounter()).root
            var targets = [root]
            targets += root.children.filter { !$0.children.isEmpty }
            for target in targets {
                let before = LegacySunburstLayout.make(for: target)
                let after = SunburstLayout.make(for: target)
                try same("\(path) segment count", before.count, after.count)
                for (a, b) in zip(before, after) {
                    try same("\(path) \(a.node.name) segment", "\(a.id)|\(a.depth)|\(a.startAngle.bitPattern)|\(a.endAngle.bitPattern)",
                             "\(b.id)|\(b.depth)|\(b.startAngle.bitPattern)|\(b.endAngle.bitPattern)")
                    segments += 1
                }
            }
        }
        for branch in -20...40 {
            for depth in 0...12 {
                for virtual in [false, true] {
                    try same("palette \(branch) \(depth) \(virtual)",
                             LegacySunburstLayout.paletteComponents(branch: branch, depth: depth, isVirtual: virtual).map(\.bitPattern),
                             SunburstLayout.paletteComponents(branch: branch, depth: depth, isVirtual: virtual).map(\.bitPattern))
                }
            }
        }

        // View geometry.
        for _ in 0..<20_000 {
            let side = Double(generator.next() % 400_000) / 100
            let deepest = Int(generator.next() % 12) - 1
            let legacy = LegacySunburstGeometry.rings(side: side, deepest: deepest)
            let geometry = SunburstGeometry(side: side, deepest: deepest)
            try same("rings \(side) \(deepest)", legacy.map(\.bitPattern),
                     [geometry.outerRadius, geometry.innerRadius, geometry.ringWidth, geometry.centerSide].map(\.bitPattern))
            let depth = Int(generator.next() % 8)
            let ring = geometry.ring(depth: depth)
            try same("ring \(side) \(depth)", LegacySunburstGeometry.ring(depth: depth, inner: legacy[1], outer: legacy[0], width: legacy[2]).map(\.bitPattern),
                     [ring.inner, ring.outer].map(\.bitPattern))
            let radius = Double(generator.next() % 200_000) / 100
            try same("hit \(radius)", LegacySunburstGeometry.hitRing(radius: radius, inner: legacy[1], outer: legacy[0], width: legacy[2]), geometry.hitRing(radius: radius))
            try same("center \(radius)", radius < legacy[1], geometry.inCenter(radius: radius))
            let angle = (Double(generator.next() % 2_000_000) / 1_000_000 - 1) * .pi
            try same("angle \(angle)", LegacySunburstGeometry.layoutAngle(angle).bitPattern, SunburstGeometry.layoutAngle(angle).bitPattern)
            let start = Double(generator.next() % 10_000) / 1_000
            let end = start + (Double(generator.next() % 2_000) / 1_000 - 0.2)
            try same("inset \(start) \(end)", LegacySunburstGeometry.inset(start: start, end: end, gap: 0.006).bitPattern,
                     SunburstGeometry.inset(start: start, end: end, gap: 0.006).bitPattern)
            try same("hover \(side)", LegacySunburstGeometry.hoverY(height: side).bitPattern, SunburstGeometry.hoverY(height: side).bitPattern)
            checks += 1
        }
        print("PRESENTATION_DIFFERENTIAL_OK checks=\(checks) segments=\(segments)")
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else { throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PresentationDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
