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

/// The chip of the menu bar item as an image. Up to 80 % it is the outline chip, a template that follows the
/// bar's colour; above 80 % it is the filled chip in yellow, above 90 % in red (`mm_chip_band`). The coloured
/// chip is baked into a bitmap and is not a template, so the menu bar draws its colours as they are and does
/// not apply its own symbol configuration to it. One configuration serves every case, so the chip keeps its
/// size from band to band. The bitmap is drawn without a drawing closure: such a closure may run on any thread.
@MainActor
enum MenuBarChipImage {
    private static let configuration = NSImage.SymbolConfiguration(
        pointSize: NSFont.systemFontSize, weight: .regular, scale: .medium)
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, tint: MenuBarTint) -> NSImage {
        let key = "\(symbol)|\(tint)"
        if let cached = cache[key] { return cached }
        guard let built = build(symbol: symbol, tint: tint) else { return placeholder() }
        cache[key] = built
        return built
    }

    private static func build(symbol: String, tint: MenuBarTint) -> NSImage? {
        let color: NSColor
        switch tint {
        case .none:
            guard let plain = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return nil }
            plain.isTemplate = true
            return plain
        case .yellow:
            color = .systemYellow
        case .red:
            color = .systemRed
        }
        let colored = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(colored) else { return nil }
        let size = symbolImage.size
        let pixelsWide = Int((size.width * 2).rounded(.up))
        let pixelsHigh = Int((size.height * 2).rounded(.up))
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)
        symbolImage.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        rep.size = size
        let baked = NSImage(size: size)
        baked.addRepresentation(rep)
        baked.isTemplate = false
        return baked
    }

    /// What a missing symbol or drawing context shows: an empty template image, never a crash.
    private static func placeholder() -> NSImage {
        let empty = NSImage(size: NSSize(width: 16, height: 16))
        empty.isTemplate = true
        return empty
    }
}

/// The menu bar item: a memory chip that follows the percent shown, and the share of memory in use. The item
/// exists from launch, also in a copy started without its window, so it hands the window-opening action to
/// `MainWindow`.
struct MemoryMenuLabel: View {
    @ObservedObject var model: MenuBarLabelModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarChipImage.image(symbol: model.label.symbol, tint: model.label.tint))
            Text(model.label.title)
                .monospacedDigit()
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
