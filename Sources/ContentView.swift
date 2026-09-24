import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var orphanedData: OrphanedAppDataModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 232)
            Rectangle()
                .fill(Color.separator.opacity(0.65))
                .frame(width: 1)
            Group {
                switch model.workspaceSection {
                case .diskMap:
                    VStack(spacing: 0) {
                        TopBar()
                        Rectangle()
                            .fill(Color.separator.opacity(0.5))
                            .frame(height: 1)
                        Group {
                            if model.isScanning {
                                ScanningView()
                            } else if let focus = model.focusNode {
                                AnalysisView(root: focus)
                            } else {
                                WelcomeView()
                            }
                        }
                        CollectionBar()
                    }
                case .appUninstaller:
                    AppUninstallerView()
                case .orphanedAppData:
                    OrphanedAppDataView()
                case .duplicateFinder:
                    DuplicateFinderView()
                }
            }
        }
        .background(Color.appBackground)
        .foregroundStyle(Color.primaryText)
        .frame(minWidth: 1080, minHeight: 700)
        .preferredColorScheme(.dark)
        .onAppear { model.startInitialScan() }
        .sheet(isPresented: $model.showingTrashReview) {
            TrashReviewSheet()
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
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppMark()
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DiskBloom")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("space under control")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 22)

            Text("TOOLS")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.secondaryText)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            VStack(spacing: 4) {
                WorkspaceSectionRow(
                    section: .diskMap,
                    title: "Disk Map",
                    subtitle: "find large folders",
                    icon: "chart.pie.fill"
                )
                WorkspaceSectionRow(
                    section: .appUninstaller,
                    title: "App Uninstaller",
                    subtitle: "app + related data",
                    icon: "app.badge.checkmark"
                )
                WorkspaceSectionRow(
                    section: .orphanedAppData,
                    title: "Possible Leftovers",
                    subtitle: "folders with no matching .app",
                    icon: "folder.badge.questionmark"
                )
                WorkspaceSectionRow(
                    section: .duplicateFinder,
                    title: "Duplicate Files",
                    subtitle: "byte-for-byte matches",
                    icon: "doc.on.doc.fill"
                )
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 18)

            if model.workspaceSection == .diskMap {
                Text("SOURCES")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.secondaryText)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.sources) { source in
                            SourceRow(source: source)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Safe Mode", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentMint)
                    Text("Exact paths are shown before any action. Shared and potentially important data are off by default.")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 11))
                .padding(.horizontal, 12)
            }

            Spacer(minLength: 12)

            VolumeUsageCard(stats: model.volumeStats)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 5) {
                Label("Only on this Mac", systemImage: "lock.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentMint)
                Text("No telemetry: analysis stays on the selected source.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .background(Color.panel)
    }
}

private struct WorkspaceSectionRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var uninstaller: AppUninstallerModel
    @EnvironmentObject private var orphanedData: OrphanedAppDataModel
    let section: WorkspaceSection
    let title: String
    let subtitle: String
    let icon: String

    private var isActive: Bool { model.workspaceSection == section }

    var body: some View {
        Button { model.selectWorkspaceSection(section) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentMint : Color.secondaryText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                if isActive {
                    Circle().fill(Color.accentMint).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isActive ? Color.accentMint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(
            uninstaller.isMovingToTrash
                || uninstaller.isReviewing
                || uninstaller.showingReview
                || uninstaller.showingOutcomeReport
                || orphanedData.isNavigationLocked
        )
    }
}

private struct SourceRow: View {
    @EnvironmentObject private var model: AppModel
    let source: ScanSource

    private var isActive: Bool {
        model.currentURL.standardizedFileURL.path == source.url.standardizedFileURL.path
    }

    var body: some View {
        Button {
            model.selectWorkspaceSection(.diskMap)
            model.open(source: source.url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentMint : Color.secondaryText)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    Text(source.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Circle()
                        .fill(Color.accentMint)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isActive ? Color.accentMint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct VolumeUsageCard: View {
    let stats: VolumeStats

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Disk")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(Int(stats.usedFraction * 100))% used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentMint, Color(hue: 0.56, saturation: 0.8, brightness: 0.96)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * stats.usedFraction)
                }
            }
            .frame(height: 7)
            HStack {
                Text(ByteFormat.compact(stats.used))
                Spacer()
                Text("\(ByteFormat.compact(stats.available)) available")
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color.secondaryText)
        }
        .padding(12)
        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.05), lineWidth: 1))
    }
}

private struct TopBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!model.canGoBack)

            if model.focusStack.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.isScanning ? "Analyzing" : "Overview")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.currentURL.path)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.focusStack.enumerated()), id: \.element.id) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Color.secondaryText.opacity(0.6))
                            }
                            Button(node.name) { model.goToBreadcrumb(node) }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: index == model.focusStack.count - 1 ? .semibold : .regular))
                                .foregroundStyle(index == model.focusStack.count - 1 ? Color.primaryText : Color.secondaryText)
                        }
                    }
                }
            }

            Spacer()

            if let snapshot = model.snapshot {
                HStack(spacing: 12) {
                    Label("\(snapshot.root.fileCount.formatted()) \(Plural.files(snapshot.root.fileCount))", systemImage: "doc.on.doc")
                    if snapshot.root.unreadableCount > 0 {
                        Label("\(snapshot.root.unreadableCount) inaccessible", systemImage: "exclamationmark.lock")
                            .foregroundStyle(Color.orange)
                    }
                    if snapshot.skippedMountPoints > 0 {
                        Label("\(snapshot.skippedMountPoints) other volumes skipped", systemImage: "externaldrive.badge.xmark")
                    }
                    Text(String(format: "%.1f s", snapshot.duration))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.secondaryText)
            }

            Button(action: model.rescan) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isScanning)

            Button(action: model.chooseFolder) {
                Label("Choose Folder", systemImage: "folder.badge.plus")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .background(Color.appBackground)
    }
}

private struct AnalysisView: View {
    let root: DiskNode

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(root.name)
                            .font(.system(size: 23, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        Text("Estimated used space · click a sector for details")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(ByteFormat.string(root.size))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("\(root.itemCount.formatted()) \(Plural.objects(root.itemCount))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                if root.unreadableCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.lock.fill")
                            .foregroundStyle(Color.orange)
                        Text("The map is incomplete: \(root.unreadableCount) inaccessible areas are not included in the estimate.")
                            .font(.system(size: 11, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.orange.opacity(0.2), lineWidth: 1))
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                }

                SunburstView(root: root)
                    .padding(18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color.separator.opacity(0.5))
                .frame(width: 1)

            InspectorPanel(root: root)
                .frame(width: 345)
        }
    }
}

private struct InspectorPanel: View {
    @EnvironmentObject private var model: AppModel
    let root: DiskNode

    private var visibleChildren: [DiskNode] {
        root.children
    }

    var body: some View {
        VStack(spacing: 0) {
            if let inspected = model.inspectedNode {
                InspectedCard(node: inspected)
                Rectangle().fill(Color.separator.opacity(0.5)).frame(height: 1)
            }

            HStack {
                Text("CONTENTS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.secondaryText)
                Spacer()
                Text("by size")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if visibleChildren.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                    Text("No accessible items in this folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color.secondaryText)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(visibleChildren.enumerated()), id: \.element.id) { index, child in
                            ChildRow(node: child, color: SunburstLayout.paletteColor(branch: index, depth: 0, isVirtual: child.isVirtual))
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color.panel.opacity(0.72))
    }
}

private struct InspectedCard: View {
    @EnvironmentObject private var model: AppModel
    let node: DiskNode

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: node.isDirectory ? (node.isPackage ? "shippingbox.fill" : "folder.fill") : "doc.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentMint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.name)
                        .font(.system(size: 14, weight: .bold))
                        .lineLimit(2)
                    Text(ByteFormat.string(node.size))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentMint)
                }
                Spacer(minLength: 0)
            }

            if let path = node.url?.path {
                Text(path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else {
                Text("Aggregate group of small items")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondaryText)
            }

            HStack(spacing: 7) {
                if node.isDirectory && !node.isVirtual {
                    Button {
                        model.enter(node)
                    } label: {
                        Label("Open", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                if node.url != nil {
                    Button {
                        model.revealInFinder(node)
                    } label: {
                        Image(systemName: "finder")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                }
                Spacer()
                Button {
                    model.toggleCollection(node)
                } label: {
                    Label(
                        model.isCollected(node) ? "Queued" : "Queue",
                        systemImage: model.isCollected(node) ? "checkmark.circle.fill" : "plus.circle"
                    )
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(!model.isCollected(node) && model.rejectionReason(for: node) != nil)
                .help(
                    model.isCollected(node)
                        ? "Remove from Queue"
                        : (model.rejectionReason(for: node) ?? "Add to the Trash queue")
                )
            }
        }
        .padding(16)
        .background(Color.panelElevated.opacity(0.65))
    }
}

private struct ChildRow: View {
    @EnvironmentObject private var model: AppModel
    let node: DiskNode
    let color: Color

    private var isSelected: Bool { model.inspectedNode?.id == node.id }

    var body: some View {
        Button {
            model.inspect(node)
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 7, height: 28)
                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .frame(width: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    Text(node.isVirtual ? "aggregate group" : "\(node.itemCount.formatted()) \(Plural.objects(node.itemCount))")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 4)
                Text(ByteFormat.compact(node.size))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.accentMint : Color.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accentMint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if node.isDirectory && !node.isVirtual {
                Button("Open") { model.enter(node) }
            }
            if node.url != nil {
                Button("Reveal in Finder") { model.revealInFinder(node) }
            }
            Divider()
            Button(model.isCollected(node) ? "Remove from Queue" : "Add to Queue") {
                model.toggleCollection(node)
            }
            .disabled(!model.isCollected(node) && model.rejectionReason(for: node) != nil)
        }
    }
}

private struct CollectionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(model.collection.isEmpty ? Color.white.opacity(0.06) : Color.accentMint.opacity(0.15))
                    Image(systemName: "tray.full.fill")
                        .foregroundStyle(model.collection.isEmpty ? Color.secondaryText : Color.accentMint)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.collection.isEmpty ? "Cleanup queue is empty" : "Selected: \(model.collection.count)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(model.collection.isEmpty ? "Select and review an item first" : ByteFormat.string(model.collectionSize))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryText)
                }

                if !model.collection.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(model.collection) { node in
                                HStack(spacing: 6) {
                                    Text(node.name).lineLimit(1)
                                    Button { model.removeFromCollection(node) } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.white.opacity(0.055), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: 360)
                }

                Spacer()

                Text("Only moves to the Trash")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)

                Button {
                    model.requestTrashReview()
                } label: {
                    if model.isMovingToTrash || model.isReviewingSelection {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Review", systemImage: "trash")
                    }
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(model.collection.isEmpty || model.isMovingToTrash || model.isReviewingSelection)
            }
            .padding(.horizontal, 18)
            .frame(height: 66)
            .background(Color.panel)
        }
    }
}

private struct ScanningView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .trim(from: 0.08 * Double(index), to: 0.58 + 0.1 * Double(index))
                        .stroke(
                            SunburstLayout.paletteColor(branch: index, depth: index),
                            style: StrokeStyle(lineWidth: 13, lineCap: .round)
                        )
                        .frame(width: CGFloat(92 + index * 38), height: CGFloat(92 + index * 38))
                        .rotationEffect(.degrees(Double(index) * 78))
                }
                ProgressView()
                    .controlSize(.large)
                    .tint(Color.accentMint)
            }
            .frame(width: 180, height: 180)

            VStack(spacing: 7) {
                Text("Building the space map")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("\(model.progress.itemCount.formatted()) \(Plural.objects(model.progress.itemCount)) scanned")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentMint)
                Text(model.progress.currentPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: 540)
                    .multilineTextAlignment(.center)
            }

            Text("Scanning is read-only. Inaccessible system folders are marked, not requested via sudo.")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            Button("Cancel") { model.cancelScan() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [Color.accentMint.opacity(0.07), Color.clear],
                center: .center,
                startRadius: 40,
                endRadius: 360
            )
        )
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            AppMark().frame(width: 92, height: 92)
            Text("See where your space went")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            if model.needsInitialAccess {
                Text("DiskBloom reads only the folders you allow. Grant access to your home folder, or choose any folder or disk, and DiskBloom will build an interactive map with no telemetry.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                HStack(spacing: 10) {
                    Button(action: model.grantHomeAccess) {
                        Label("Grant Access to Home Folder", systemImage: "house.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button(action: model.chooseFolder) {
                        Label("Choose Folder", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("Choose a folder or disk and DiskBloom will build an interactive map with no telemetry.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                Button(action: model.chooseFolder) {
                    Label("Choose Folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TrashReviewSheet: View {
    @EnvironmentObject private var model: AppModel
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
                    Text("Review before moving")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("\(model.collection.count) \(Plural.objects(model.collection.count)) · estimated \(ByteFormat.string(model.collectionSize))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
            }
            .padding(22)

            Rectangle().fill(Color.separator).frame(height: 1)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.collection) { node in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(Color.accentMint)
                                Text(node.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(ByteFormat.string(node.size))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            Text(node.url?.path ?? "Path unavailable")
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
                Label("Items will be moved to the system Trash, not deleted permanently.", systemImage: "arrow.uturn.backward.circle")
                Label("Before acting, the path and identity of every item are verified again.", systemImage: "checkmark.shield")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)

            Rectangle().fill(Color.separator).frame(height: 1)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move to Trash") {
                    model.moveReviewedItemsToTrash()
                }
                .buttonStyle(DangerButtonStyle())
            }
            .padding(18)
        }
        .frame(width: 610, height: 520)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }
}

struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.12, green: 0.18, blue: 0.24), Color(red: 0.06, green: 0.09, blue: 0.13)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .trim(from: Double(index) * 0.08, to: 0.58 + Double(index) * 0.08)
                    .stroke(
                        SunburstLayout.paletteColor(branch: index, depth: 0),
                        style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
                    )
                    .padding(CGFloat(7 + index * 5))
                    .rotationEffect(.degrees(Double(index) * 72 - 35))
            }
            Circle().fill(Color.panelElevated).frame(width: 7, height: 7)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.13), lineWidth: 1))
        .shadow(color: Color.accentMint.opacity(0.13), radius: 10, y: 3)
    }
}

struct IconButtonStyle: ButtonStyle {
    var accented = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accented ? Color.accentMint : Color.primaryText)
            .frame(width: 30, height: 30)
            .background(
                (accented ? Color.accentMint.opacity(0.12) : Color.white.opacity(configuration.isPressed ? 0.09 : 0.055)),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(Color(red: 0.035, green: 0.09, blue: 0.09))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Color.accentMint.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, compact ? 10 : 13)
            .frame(height: compact ? 28 : 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(height: 32)
            .background(
                Color.danger.opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.24),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .opacity(isEnabled ? 1 : 0.62)
    }
}
