import AppKit
import SwiftUI

/// The menu bar item: a memory chip and the share of memory in use.
struct MemoryMenuLabel: View {
    @ObservedObject var monitor: MemoryMonitorModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: monitor.snapshot.level == .normal ? "memorychip" : "memorychip.fill")
            Text(monitor.percentText)
                .monospacedDigit()
        }
        .accessibilityLabel("Memory \(monitor.percentText) used, pressure \(monitor.snapshot.level.title)")
    }
}

/// The panel under the menu bar item: how full the memory is, and which apps and services use it.
struct MemoryMenuPanel: View {
    @ObservedObject var monitor: MemoryMonitorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summary
            breakdown
            Divider()
            usage
            Divider()
            actions
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { monitor.panelAppeared() }
        .onDisappear { monitor.panelDisappeared() }
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
        }
        .controlSize(.small)
    }
}
