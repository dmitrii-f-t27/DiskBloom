import SwiftUI

struct SunburstSegment: Identifiable {
    let id: UUID
    let node: DiskNode
    let depth: Int
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

/// Lays out the ring map by Specs/sunburst_rules.t27.
enum SunburstLayout {
    static let maxDepth = Int(SB_MAX_DEPTH)
    static let maxSegments = Int(SB_MAX_SEGMENTS)

    static func make(for root: DiskNode) -> [SunburstSegment] {
        guard root.size > 0 else { return [] }
        var result: [SunburstSegment] = []
        append(
            children: root.children,
            startAngle: SB_START_ANGLE,
            endAngle: SB_END_ANGLE,
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
        into result: inout [SunburstSegment]
    ) {
        guard sb_lays_out(Int64(depth), Int64(children.count), Int64(result.count)) else { return }
        let total = children.reduce(Int64(0)) { $0 + sr_non_negative($1.size) }
        guard total > 0 else { return }

        var cursor = startAngle
        let fullSpan = endAngle - startAngle
        for (index, child) in children.enumerated() {
            guard sb_has_room(Int64(result.count)) else { break }
            let next = sb_child_end(cursor, fullSpan, sb_share(child.size, total), endAngle, index == children.count - 1)
            let branch = Int(sb_branch(Int64(depth), Int64(index), Int64(inheritedBranch)))
            if sb_visible(cursor, next) {
                result.append(
                    SunburstSegment(
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

    /// Hue, saturation and brightness, or the fixed RGB of the "Other" group (last value 1).
    static func paletteComponents(branch: Int, depth: Int, isVirtual: Bool) -> [Double] {
        if isVirtual { return [SB_VIRTUAL_RED, SB_VIRTUAL_GREEN, SB_VIRTUAL_BLUE, 1] }
        return [sb_hue(Int64(branch)), sb_saturation(Int64(depth)), sb_brightness(Int64(depth)), 0]
    }

    static func paletteColor(branch: Int, depth: Int, isVirtual: Bool = false) -> Color {
        let c = paletteComponents(branch: branch, depth: depth, isVirtual: isVirtual)
        if c[3] == 1 { return Color(red: c[0], green: c[1], blue: c[2]) }
        return Color(hue: c[0], saturation: c[1], brightness: c[2])
    }
}

/// The ring-map arithmetic for the space available, by Specs/sunburst_rules.t27.
struct SunburstGeometry {
    let outerRadius: Double
    let innerRadius: Double
    let ringWidth: Double

    init(side: Double, deepest: Int) {
        outerRadius = sb_outer_radius(side)
        innerRadius = sb_inner_radius(outerRadius)
        ringWidth = sb_ring_width(outerRadius, innerRadius, sb_ring_count(Int64(deepest)))
    }

    var centerSide: Double { sb_center_side(innerRadius) }

    func ring(depth: Int) -> (inner: Double, outer: Double) {
        let inner = sb_ring_inner(innerRadius, Int64(depth), ringWidth)
        return (inner, sb_ring_outer(outerRadius, inner, ringWidth))
    }

    func inCenter(radius: Double) -> Bool { sb_in_center(radius, innerRadius) }

    func hitRing(radius: Double) -> Int? {
        let ring = sb_hit_ring(radius, innerRadius, outerRadius, ringWidth)
        return ring < 0 ? nil : Int(ring)
    }

    static func layoutAngle(_ angle: Double) -> Double { sb_layout_angle(angle) }
    static func hoverY(height: Double) -> Double { sb_hover_y(height) }
    static func inset(start: Double, end: Double, gap: Double) -> Double { sb_sector_inset(start, end, gap) }

    static func hits(_ segment: SunburstSegment, depth: Int, angle: Double) -> Bool {
        sb_segment_hit(Int64(segment.depth), segment.startAngle, segment.endAngle, Int64(depth), angle)
    }
}

private struct RingSector: Shape {
    let startAngle: Double
    let endAngle: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat
    let gap: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let inset = SunburstGeometry.inset(start: startAngle, end: endAngle, gap: gap)
        let start = Angle(radians: startAngle + inset)
        let end = Angle(radians: endAngle - inset)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct SunburstView: View {
    @EnvironmentObject private var model: AppModel
    let root: DiskNode
    private let segments: [SunburstSegment]

    @State private var hoveredNode: DiskNode?

    init(root: DiskNode) {
        self.root = root
        segments = SunburstLayout.make(for: root)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let geometry = SunburstGeometry(side: Double(side), deepest: segments.map(\.depth).max() ?? 0)
            let outerRadius = CGFloat(geometry.outerRadius)
            let innerRadius = CGFloat(geometry.innerRadius)
            let ringWidth = CGFloat(geometry.ringWidth)

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.025))
                    .frame(width: outerRadius * 2 + 14, height: outerRadius * 2 + 14)

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    for segment in segments {
                        let ring = geometry.ring(depth: segment.depth)
                        let inner = CGFloat(ring.inner)
                        let outer = CGFloat(ring.outer)
                        guard outer > inner else { continue }
                        let path = RingSector(
                            startAngle: segment.startAngle,
                            endAngle: segment.endAngle,
                            innerRadius: inner,
                            outerRadius: outer,
                            gap: SB_SECTOR_GAP
                        ).path(in: rect)
                        let isHighlighted = hoveredNode?.id == segment.node.id || model.inspectedNode?.id == segment.node.id
                        context.fill(path, with: .color(segment.color.opacity(isHighlighted ? 1 : 0.88)))
                        context.stroke(
                            path,
                            with: .color(Color.black.opacity(isHighlighted ? 0.55 : 0.32)),
                            lineWidth: isHighlighted ? 2 : 0.8
                        )
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredNode = hitTest(
                            point: point,
                            size: proxy.size,
                            innerRadius: innerRadius,
                            outerRadius: outerRadius,
                            ringWidth: ringWidth
                        )
                    case .ended:
                        hoveredNode = nil
                    }
                }
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let dx = value.location.x - proxy.size.width / 2
                            let dy = value.location.y - proxy.size.height / 2
                            let radius = hypot(dx, dy)
                            if geometry.inCenter(radius: Double(radius)) {
                                model.goBack()
                            } else if let node = hitTest(
                                point: value.location,
                                size: proxy.size,
                                innerRadius: innerRadius,
                                outerRadius: outerRadius,
                                ringWidth: ringWidth
                            ) {
                                model.inspect(node)
                            }
                        }
                )

                centerLabel
                    .frame(width: CGFloat(geometry.centerSide), height: CGFloat(geometry.centerSide))
                    .contentShape(Circle())
                    .onTapGesture { model.goBack() }

                if let hoveredNode {
                    hoverCard(hoveredNode)
                        .frame(maxWidth: 250)
                        .position(x: proxy.size.width / 2, y: CGFloat(SunburstGeometry.hoverY(height: Double(proxy.size.height))))
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ring map of used space")
        .accessibilityRepresentation {
            VStack {
                ForEach(root.children) { child in
                    Button("\(child.name), \(ByteFormat.string(child.size))") {
                        model.inspect(child)
                    }
                }
            }
        }
    }

    private var centerLabel: some View {
        VStack(spacing: 3) {
            Image(systemName: model.canGoBack ? "arrow.uturn.backward" : "internaldrive")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentMint)
            Text(ByteFormat.compact(root.size))
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(model.canGoBack ? "Back" : "folder size")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(8)
        .background(Circle().fill(Color.panelElevated))
        .overlay(Circle().stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func hoverCard(_ node: DiskNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(Color.accentMint)
            Text(node.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(ByteFormat.compact(node.size))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func hitTest(
        point: CGPoint,
        size: CGSize,
        innerRadius: CGFloat,
        outerRadius: CGFloat,
        ringWidth: CGFloat
    ) -> DiskNode? {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let ring = sb_hit_ring(Double(hypot(dx, dy)), Double(innerRadius), Double(outerRadius), Double(ringWidth))
        guard ring >= 0 else { return nil }
        let depth = Int(ring)
        let angle = SunburstGeometry.layoutAngle(atan2(Double(dy), Double(dx)))
        return segments.first { SunburstGeometry.hits($0, depth: depth, angle: angle) }?.node
    }
}

extension Color {
    static let appBackground = Color(red: 0.047, green: 0.067, blue: 0.094)
    static let panel = Color(red: 0.075, green: 0.102, blue: 0.137)
    static let panelElevated = Color(red: 0.095, green: 0.127, blue: 0.166)
    static let separator = Color(red: 0.15, green: 0.20, blue: 0.255)
    static let primaryText = Color(red: 0.96, green: 0.975, blue: 0.99)
    static let secondaryText = Color(red: 0.58, green: 0.65, blue: 0.73)
    static let accentMint = Color(red: 0.33, green: 0.83, blue: 0.76)
    static let danger = Color(red: 1.0, green: 0.35, blue: 0.42)
}
