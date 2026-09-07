import SwiftUI

struct SunburstSegment: Identifiable {
    let id: UUID
    let node: DiskNode
    let depth: Int
    let startAngle: Double
    let endAngle: Double
    let color: Color
}

enum SunburstLayout {
    static let maxDepth = 6
    static let maxSegments = 2_400

    static func make(for root: DiskNode) -> [SunburstSegment] {
        guard root.size > 0 else { return [] }
        var result: [SunburstSegment] = []
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
        into result: inout [SunburstSegment]
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

    static func paletteColor(branch: Int, depth: Int, isVirtual: Bool = false) -> Color {
        if isVirtual { return Color(red: 0.35, green: 0.39, blue: 0.46) }
        let hues: [Double] = [0.48, 0.39, 0.15, 0.075, 0.93, 0.73, 0.56, 0.29]
        let hue = hues[abs(branch) % hues.count]
        let saturation = max(0.46, 0.82 - Double(depth) * 0.055)
        let brightness = max(0.68, 0.96 - Double(depth) * 0.045)
        return Color(hue: hue, saturation: saturation, brightness: brightness)
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
        let span = max(0, endAngle - startAngle)
        let inset = min(gap, span * 0.2)
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
            let outerRadius = max(110, side / 2 - 20)
            let innerRadius = max(54, min(84, outerRadius * 0.24))
            let activeRingCount = max(1, (segments.map(\.depth).max() ?? 0) + 1)
            let ringWidth = max(12, (outerRadius - innerRadius) / CGFloat(activeRingCount))

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.025))
                    .frame(width: outerRadius * 2 + 14, height: outerRadius * 2 + 14)

                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    for segment in segments {
                        let inner = innerRadius + CGFloat(segment.depth) * ringWidth
                        let outer = min(outerRadius, inner + ringWidth - 2)
                        guard outer > inner else { continue }
                        let path = RingSector(
                            startAngle: segment.startAngle,
                            endAngle: segment.endAngle,
                            innerRadius: inner,
                            outerRadius: outer,
                            gap: 0.006
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
                            if radius < innerRadius {
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
                    .frame(width: innerRadius * 1.72, height: innerRadius * 1.72)
                    .contentShape(Circle())
                    .onTapGesture { model.goBack() }

                if let hoveredNode {
                    hoverCard(hoveredNode)
                        .frame(maxWidth: 250)
                        .position(x: proxy.size.width / 2, y: max(42, proxy.size.height - 36))
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Круговая карта занятого места")
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
            Text(model.canGoBack ? "Назад" : "размер папки")
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
        let radius = hypot(dx, dy)
        guard radius >= innerRadius, radius <= outerRadius else { return nil }
        let depth = Int((radius - innerRadius) / ringWidth)
        var angle = atan2(Double(dy), Double(dx))
        if angle < -.pi / 2 { angle += .pi * 2 }
        return segments.first { segment in
            segment.depth == depth && angle >= segment.startAngle && angle <= segment.endAngle
        }?.node
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
