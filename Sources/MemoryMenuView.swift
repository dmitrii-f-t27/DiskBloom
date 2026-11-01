import AppKit
import SwiftUI

/// What the menu bar item shows. Only `MenuBarController` sets it, and only when the figure changes, so the
/// label (and macOS's menu bar) redraw only then.
@MainActor
final class MenuBarLabelModel: ObservableObject, MenuBarDisplay {
    @Published private(set) var label = MenuBarLabel.unknown

    func show(_ label: MenuBarLabel) {
        if self.label != label { self.label = label }
    }
}

/// The menu bar item as one image: a memory chip with pins on its top and bottom edge, and the percent drawn
/// inside it, so the item takes less room than a symbol with a separate title. Up to 80 % (and for an unknown
/// figure) it is the outline chip, a template that follows the bar's colour, with digits in the same ink; above
/// 80 % it is the filled chip in yellow with dark digits, above 90 % in red with white digits (`mm_chip_band`).
/// The colours are fixed sRGB values, never the dynamic system colours: a dynamic colour would be baked in
/// with whichever appearance is current when the bitmap is drawn, and the bitmap is cached. The coloured chip
/// is not a template, so the menu bar draws its colours as they are. The digits are tabular, so every width from
/// 0 % to 99 % and the unknown figure share one width and the item does not jump; only "100%" is wider. The
/// percent sign is drawn at full size, in the font of the digits. The image has two bitmap representations, 1x
/// and 2x, each drawn on its own so that both are sharp. The bitmap is drawn without a drawing closure: such a
/// closure may run on any thread. The only other image is the ladybug of the automation switch (DEBUG builds),
/// which is a plain symbol and keeps its title as a separate text.
@MainActor
enum MenuBarChipImage {
    /// Sizes in points. They are internal so that the smoke test can read them.
    static let fontSize: CGFloat = 11
    static let bodyHeight: CGFloat = 14
    static let pinHeight: CGFloat = 2
    static let imageHeight: CGFloat = 18
    static let pinWidth: CGFloat = 2
    static let pinCount = 4
    /// One point: one pixel at 1x, two at 2x.
    static let strokeWidth: CGFloat = 1
    /// The gap between the stroke and the text.
    static let textInset: CGFloat = 1.5
    static let cornerRadius: CGFloat = 2.5
    /// How many images the cache keeps; when it is full it is emptied before the next one is stored.
    static let cacheLimit = 16

    private static let configuration = NSImage.SymbolConfiguration(
        pointSize: NSFont.systemFontSize, weight: .regular, scale: .medium)
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
    private static var cache: [String: NSImage] = [:]
    /// The width every title from "0%" to "99%" and "—%" shares: digits are tabular.
    private static let widestTwoDigits: CGFloat =
        titleText("00%", ink: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)).size().width

    static var cacheCount: Int { cache.count }

    static func image(for label: MenuBarLabel) -> NSImage {
        let key = "\(label.symbol)|\(label.tint)|\(label.title)"
        if let cached = cache[key] { return cached }
        guard let built = label.isDebugMarker ? symbolTemplate(label.symbol) : chip(for: label) else {
            return placeholder()
        }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = built
        return built
    }

    /// The colours of one band: the body (nil for the outline chip) and the ink of the digits. The outline chip
    /// is a template, so only the alpha of its black ink matters.
    private static func palette(for tint: MenuBarTint) -> (body: NSColor?, ink: NSColor) {
        switch tint {
        case .none:
            return (nil, NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        case .yellow:
            return (NSColor(srgbRed: 1, green: 204.0 / 255, blue: 0, alpha: 1),
                    NSColor(srgbRed: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255, alpha: 1))
        case .red:
            return (NSColor(srgbRed: 215.0 / 255, green: 0, blue: 21.0 / 255, alpha: 1),
                    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        }
    }

    /// A plain symbol, as a template that follows the bar's colour.
    private static func symbolTemplate(_ symbol: String) -> NSImage? {
        guard let plain = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        plain.isTemplate = true
        return plain
    }

    /// A position rounded to a whole pixel of the given scale (1 or 2 pixels per point).
    private static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// The text of the chip: the whole string in one font and one ink.
    static func titleText(_ text: String, ink: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
    }

    private static func chip(for label: MenuBarLabel) -> NSImage? {
        let colors = palette(for: label.tint)
        let title = titleText(label.title, ink: colors.ink)
        let titleWidth = title.size().width
        let textWidth = ceil(max(titleWidth, widestTwoDigits))
        let bodyWidth = textWidth + 2 * (strokeWidth + textInset)
        let size = NSSize(width: bodyWidth, height: imageHeight)
        // Each scale is drawn on its own, so that the 1x bitmap is not a 2x bitmap scaled down.
        guard let standard = renderRep(scale: 1, title: title, titleWidth: titleWidth, bodyWidth: bodyWidth, colors: colors),
              let sharp = renderRep(scale: 2, title: title, titleWidth: titleWidth, bodyWidth: bodyWidth, colors: colors)
        else { return nil }
        standard.size = size
        sharp.size = size
        let baked = NSImage(size: size)
        baked.addRepresentation(standard)
        baked.addRepresentation(sharp)
        baked.isTemplate = label.tint == .none
        return baked
    }

    /// The chip at `scale` pixels per point (1 or 2). Every position is a whole pixel of that scale, so the
    /// stroke and the pins are crisp at 1x as well. Nil if no bitmap or drawing context can be made.
    private static func renderRep(scale: Int, title: NSAttributedString, titleWidth: CGFloat, bodyWidth: CGFloat,
                                  colors: (body: NSColor?, ink: NSColor)) -> NSBitmapImageRep? {
        let factor = CGFloat(scale)
        let pixelsWide = Int((bodyWidth * factor).rounded(.up))
        let pixelsHigh = Int((imageHeight * factor).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.cgContext.scaleBy(x: factor, y: factor)
        // A transparent bitmap must not get coloured fringes around the digits.
        context.cgContext.setShouldSmoothFonts(false)
        context.cgContext.setAllowsFontSmoothing(false)
        if scale == 1 {
            // At 1x the second digit should start on a whole pixel too. AppKit may ignore these flags.
            context.cgContext.setAllowsFontSubpixelPositioning(false)
            context.cgContext.setShouldSubpixelPositionFonts(false)
        }

        // The pins, one pixel into the body so that no gap shows between pin and body. The two left pins are
        // snapped to whole pixels and the right ones mirror them, so the chip stays symmetric at every width.
        let overlap = 1 / factor
        var pinX = [CGFloat](repeating: 0, count: pinCount)
        for index in 0..<(pinCount / 2) {
            let x = snap(bodyWidth * (CGFloat(index) + 0.5) / CGFloat(pinCount) - pinWidth / 2, scale: factor)
            pinX[index] = x
            pinX[pinCount - 1 - index] = bodyWidth - pinWidth - x
        }
        (colors.body ?? colors.ink).setFill()
        for x in pinX {
            NSBezierPath(rect: NSRect(x: x, y: 0, width: pinWidth, height: pinHeight + overlap)).fill()
            NSBezierPath(rect: NSRect(x: x, y: pinHeight + bodyHeight - overlap,
                                      width: pinWidth, height: pinHeight + overlap)).fill()
        }

        // The body: filled in yellow or red, or an outline in the ink of the template. The path runs through the
        // middle of the stroke, so it lies on whole pixels at 1x and at 2x.
        let bodyRect = NSRect(x: 0, y: pinHeight, width: bodyWidth, height: bodyHeight)
        if let body = colors.body {
            body.setFill()
            NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        } else {
            colors.ink.setStroke()
            let outline = NSBezierPath(
                roundedRect: bodyRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2),
                xRadius: cornerRadius - strokeWidth / 2, yRadius: cornerRadius - strokeWidth / 2)
            outline.lineWidth = strokeWidth
            outline.stroke()
        }

        // The digits. Without .usesLineFragmentOrigin the origin of the rectangle is the baseline.
        let baseline = snap(pinHeight + (bodyHeight - font.capHeight) / 2, scale: factor)
        let originX = snap((bodyWidth - titleWidth) / 2, scale: factor)
        title.draw(with: NSRect(x: originX, y: baseline, width: ceil(titleWidth), height: bodyHeight),
                   options: [], context: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// What a missing symbol or drawing context shows: an empty template image, never a crash.
    private static func placeholder() -> NSImage {
        let empty = NSImage(size: NSSize(width: 16, height: 16))
        empty.isTemplate = true
        return empty
    }
}

/// The menu bar item: a memory chip with the share of memory in use drawn inside it. The item exists from
/// launch, also in a copy started without its window, so it hands the window-opening action to `MainWindow`.
struct MemoryMenuLabel: View {
    @ObservedObject var model: MenuBarLabelModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarChipImage.image(for: model.label))
            #if DEBUG
            if model.label.isDebugMarker {
                Text(model.label.title)
                    .monospacedDigit()
            }
            #endif
        }
        .accessibilityLabel(model.label.accessibility)
        .onAppear {
            let action = openWindow
            MainWindow.register { action(id: MainWindow.sceneID) }
        }
    }
}

/// The version line of the panel. A missing value is named as missing, never replaced by another value.
enum AppVersionText {
    static func text(short: String?, build: String?) -> String {
        "DiskBloom \(present(short) ?? "unknown version") (\(present(build) ?? "unknown build"))"
    }

    static func text(of bundle: Bundle) -> String {
        text(short: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
             build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// The value without surrounding white space, or nil when nothing is left.
    private static func present(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The panel under the menu bar item: how full the memory is, and which apps and services use it.
struct MemoryMenuPanel: View {
    @ObservedObject var monitor: MemoryMonitorModel
    /// False while a move to the Trash runs (Specs/memory_rules.t27, mm_can_quit).
    let canQuit: Bool
    /// The line at the bottom of the panel: which version of DiskBloom this is (AppVersionText).
    let versionText: String
    /// Called when the panel appears and disappears, one run-loop turn later: setting published values from
    /// inside a view update is a SwiftUI fault. The run loop (not a Task) is used because a Task runs from
    /// the main dispatch queue.
    let opened: @MainActor @Sendable () -> Void
    let closed: @MainActor @Sendable () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            breakdown
            Divider()
            usage
            Divider()
            actions
            Text(versionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { let f = opened; MainRunLoop.perform { f() } }
        .onDisappear { let f = closed; MainRunLoop.perform { f() } }
    }

    private var snapshot: MemorySnapshot { monitor.snapshot }

    private var levelColor: Color {
        switch snapshot.level {
        case .normal: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Memory")
                    .font(.headline)
                Spacer()
                Label(snapshot.pressureKnown ? "Pressure: \(snapshot.level.title)" : "Estimated: \(snapshot.level.title)",
                      systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(levelColor)
            }
            ProgressView(value: Double(snapshot.percent), total: 100)
                .tint(levelColor)
            HStack {
                Text("\(MemoryRules.text(snapshot.used)) of \(MemoryRules.text(snapshot.total)) used")
                Spacer()
                Text(monitor.percentText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var breakdown: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            figure("App memory", snapshot.app)
            figure("Wired", snapshot.wired)
            figure("Compressed", snapshot.compressed)
            figure("Cached files", snapshot.cached)
            figure("Free", snapshot.free)
            if snapshot.showsSwap {
                figure("Swap used", snapshot.swapUsed)
            }
        }
        .font(.caption)
    }

    private func figure(_ title: String, _ bytes: Int64) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(MemoryRules.text(bytes))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var usage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Using the most")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Order", selection: $monitor.sortMode) {
                    Text("Memory").tag(MemoryRules.sortMemory)
                    Text("CPU").tag(MemoryRules.sortCPU)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .disabled(!monitor.listsProcesses)
            }
            if !monitor.listsProcesses {
                Text("The App Store edition runs in the App Sandbox, which hides other apps' processes. The totals above still come from macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if monitor.rows.isEmpty {
                HStack(spacing: 8) {
                    if monitor.measuring {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(monitor.measuring ? "Measuring…" : "Nothing to show.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(monitor.rows) { row in
                        usageRow(row)
                    }
                }
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageRow(_ row: UsageRow) -> some View {
        HStack(spacing: 8) {
            Group {
                if let icon = monitor.icon(for: row) {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.processes > 1 {
                Text("\(row.processes)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("\(row.processes) processes")
            }
            Spacer(minLength: 8)
            Text(MemoryRules.text(row.bytes))
                .monospacedDigit()
                .frame(width: 64, alignment: .trailing)
            Text(MemoryRules.cpuText(row.cpuPermille))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
    }

    private var footnote: String {
        var text = "Memory is each process's footprint, as Activity Monitor shows it; CPU is the share of one core."
        if mm_notes_unreadable(Int64(monitor.unreadable)) {
            text += " \(monitor.unreadable) processes of other users (system services) need administrator rights and are not listed."
        }
        return text
    }

    private var actions: some View {
        HStack {
            Button("Open DiskBloom") { monitor.openMainWindow() }
            Button("Activity Monitor") { monitor.openActivityMonitor() }
            Spacer()
            Button("Quit DiskBloom") { NSApp.terminate(nil) }
                .disabled(!canQuit)
                .help(canQuit ? "Quit DiskBloom, as Quit in the DiskBloom menu does." : "Wait for the move to the Trash to finish.")
        }
        .controlSize(.small)
    }
}
