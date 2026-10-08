import SwiftUI

extension CacheVerdict {
    var color: Color {
        switch self {
        case .safe: .accentMint
        case .optional: Color(red: 1.0, green: 0.77, blue: 0.36)
        case .quitFirst: Color(red: 1.0, green: 0.55, blue: 0.36)
        case .keep: .secondaryText
        case .useTool: Color(red: 0.49, green: 0.67, blue: 1.0)
        }
    }

    var icon: String {
        switch self {
        case .safe: "checkmark.circle.fill"
        case .optional: "exclamationmark.circle.fill"
        case .quitFirst: "pause.circle.fill"
        case .keep: "lock.circle.fill"
        case .useTool: "terminal.fill"
        }
    }
}

struct CacheExplorerView: View {
    @EnvironmentObject private var model: CacheExplorerModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.separator.opacity(0.55))
                .frame(height: 1)
            content
            if model.analysis != nil, !model.isScanning {
                CacheSelectionBar()
            }
        }
        .background(Color.appBackground)
        .sheet(isPresented: $model.showingReview) {
            CacheReviewSheet()
                .environmentObject(model)
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Caches")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primaryText)
                Text("What each cache is, who owns it and whether it is safe to clear")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            if model.isScanning {
                Button(action: model.cancelAnalysis) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button(action: model.startAnalysis) {
                    Label(model.analysis == nil ? "Measure Caches" : "Measure Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isNavigationLocked)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(Color.panel.opacity(0.78))
    }

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            CacheScanningView(progress: model.progress)
        } else if let analysis = model.analysis {
            CacheResultsView(analysis: analysis)
        } else {
            CacheWelcomeView(start: model.startAnalysis)
        }
    }
}

private struct CacheWelcomeView: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.accentMint.opacity(0.08))
                    .frame(width: 132, height: 132)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text("See which caches you can clear")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("DiskBloom measures your app caches, Xcode build data and command-line tool caches, finds the app that owns each one and checks whether it is running. Every cache gets a verdict with a plain reason.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 650)
            HStack(spacing: 12) {
                ForEach([CacheVerdict.safe, .optional, .quitFirst, .keep], id: \.self) { verdict in
                    Label(verdict.title, systemImage: verdict.icon)
                        .foregroundStyle(verdict.color)
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            Button(action: start) {
                Label("Measure Caches", systemImage: "archivebox")
            }
            .buttonStyle(PrimaryButtonStyle())
            Text("Looks in ~/Library/Caches, Xcode DerivedData and ~/.cache. Nothing is moved until you review the exact paths and confirm.")
                .font(.system(size: 9.5))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 620)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct CacheScanningView: View {
    let progress: ScanProgress

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(Color.accentMint)
            Text("Measuring caches…")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primaryText)
            Text("\(progress.itemCount.formatted()) items examined")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            if !progress.currentPath.isEmpty {
                Text(progress.currentPath)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 620)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

private struct CacheResultsView: View {
    @EnvironmentObject private var model: CacheExplorerModel
    let analysis: CacheAnalysis

    var body: some View {
        VStack(spacing: 0) {
            summary
            if model.visibleItems.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.accentMint)
                    Text(model.verdictFilter == nil ? "No caches found" : "Nothing in this group")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(model.visibleItems) { item in
                                CacheRow(item: item)
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                    }
                    .onChange(of: model.highlightedIDs) { _, ids in
                        guard let first = model.visibleItems.first(where: { ids.contains($0.id) }) else { return }
                        withAnimation { proxy.scrollTo(first.id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                CacheFilterChip(verdict: nil, value: ByteFormat.compact(analysis.totalSize), label: "all · \(analysis.items.count)")
                ForEach(CacheVerdict.allCases, id: \.self) { verdict in
                    if analysis.count(of: verdict) > 0 {
                        CacheFilterChip(
                            verdict: verdict,
                            value: ByteFormat.compact(analysis.size(of: verdict)),
                            label: "\(verdict.shortTitle) · \(analysis.count(of: verdict))"
                        )
                    }
                }
                Spacer()
                Text("Measured \(analysis.scannedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Color.accentMint)
                Text("Caches grow back as you use your apps, so clearing them frees space for a while, not forever. Clear the big safe ones when you need room; leave the rest.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(11)
            .background(Color.accentMint.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct CacheFilterChip: View {
    @EnvironmentObject private var model: CacheExplorerModel
    let verdict: CacheVerdict?
    let value: String
    let label: String

    private var isActive: Bool { model.verdictFilter == verdict }
    private var tint: Color { verdict?.color ?? .accentMint }

    var body: some View {
        Button {
            model.verdictFilter = verdict
        } label: {
            HStack(spacing: 8) {
                Image(systemName: verdict?.icon ?? "archivebox.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primaryText)
                    Text(label)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 45)
            .background(isActive ? tint.opacity(0.13) : Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? tint.opacity(0.5) : Color.white.opacity(0.055), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(verdict?.explanation ?? "Show every cache")
    }
}

private struct CacheRow: View {
    @EnvironmentObject private var model: CacheExplorerModel
    let item: CacheItem

    private var isSelected: Bool { model.selectedIDs.contains(item.id) }
    private var isHighlighted: Bool { model.highlightedIDs.contains(item.id) }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                model.toggle(item)
            } label: {
                Image(systemName: item.isSelectable ? (isSelected ? "checkmark.square.fill" : "square") : "minus.square")
                    .font(.system(size: 15))
                    .foregroundStyle(item.isSelectable ? (isSelected ? Color.accentMint : Color.secondaryText) : Color.secondaryText.opacity(0.35))
            }
            .buttonStyle(.plain)
            .disabled(!item.isSelectable || model.isNavigationLocked)
            .help(item.isSelectable ? "Add to the cleanup selection" : item.verdict.explanation)
            .padding(.top, 9)

            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(item.verdict.color.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: item.category.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.verdict.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    Text(item.category.title)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                    if let owner = item.ownerName, owner != item.title {
                        Text(owner)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(1)
                    }
                }
                Text(item.reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = item.cleanupHint {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                        Text(hint)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(CacheVerdict.useTool.color)
                }
                Text(item.url.path)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.url.path)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(ByteFormat.compact(item.size))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primaryText)
                Label(item.verdict.title, systemImage: item.verdict.icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(item.verdict.color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(item.verdict.color.opacity(0.12), in: Capsule())
                if let date = item.lastModified {
                    Text("updated \(date.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Color.secondaryText)
                }
            }

            VStack(spacing: 6) {
                Button { model.reveal(item) } label: { Image(systemName: "finder") }
                    .buttonStyle(IconButtonStyle())
                    .help("Reveal in Finder")
                if item.cleanupHint != nil {
                    Button { model.copyHint(item) } label: { Image(systemName: "doc.on.clipboard") }
                        .buttonStyle(IconButtonStyle())
                        .help("Copy the cleanup command")
                }
            }
        }
        .padding(12)
        .background(
            isSelected ? Color.accentMint.opacity(0.07) : Color.panelElevated,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHighlighted ? Color.accentMint.opacity(0.75) : Color.white.opacity(0.055), lineWidth: isHighlighted ? 1.5 : 1)
        )
    }
}

private struct CacheSelectionBar: View {
    @EnvironmentObject private var model: CacheExplorerModel

    private var safeCount: Int { model.analysis?.count(of: .safe) ?? 0 }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedIDs.isEmpty ? "Nothing selected" : "\(model.selectedIDs.count) selected · \(ByteFormat.string(model.selectedSize))")
                    .font(.system(size: 12, weight: .bold))
                Text("Selected caches go to the Trash after you review their exact paths.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
            }
            Spacer()
            if safeCount > 0 {
                Button("Select All Safe") { model.selectAll(verdict: .safe) }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(model.isNavigationLocked)
            }
            if !model.selectedIDs.isEmpty {
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(model.isNavigationLocked)
            }
            Button {
                model.requestReview()
            } label: {
                if model.isReviewing || model.isMovingToTrash {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Review & Move to Trash", systemImage: "trash")
                }
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(model.selectedIDs.isEmpty || model.isNavigationLocked)
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(Color.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.separator.opacity(0.6)).frame(height: 1)
        }
    }
}

private struct CacheReviewSheet: View {
    @EnvironmentObject private var model: CacheExplorerModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Color.danger.opacity(0.14))
                    Image(systemName: "trash.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.danger)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Review caches before moving")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("\(model.selectedItems.count) \(Plural.objects(model.selectedItems.count)) · \(ByteFormat.string(model.selectedSize))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
            }
            .padding(22)

            Rectangle().fill(Color.separator).frame(height: 1)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.selectedItems) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: item.verdict.icon)
                                    .foregroundStyle(item.verdict.color)
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(item.verdict.title)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(item.verdict.color)
                                Spacer()
                                Text(ByteFormat.string(item.size))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            Text(item.url.path)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color.secondaryText)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 300)

            VStack(alignment: .leading, spacing: 6) {
                Label("Caches are moved to the system Trash, not deleted permanently.", systemImage: "arrow.uturn.backward.circle")
                Label("Right before each move, DiskBloom checks again that the owner is not running and the folder did not change.", systemImage: "checkmark.shield")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            Rectangle().fill(Color.separator).frame(height: 1)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash") { model.moveReviewedItemsToTrash() }
                    .buttonStyle(DangerButtonStyle())
            }
            .padding(18)
        }
        .frame(width: 640, height: 540)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }
}
