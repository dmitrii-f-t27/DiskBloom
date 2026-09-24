import AppKit
import SwiftUI

struct AppUninstallerView: View {
    @EnvironmentObject private var model: AppUninstallerModel

    var body: some View {
        HStack(spacing: 0) {
            applicationList
                .frame(width: 330)
                .allowsHitTesting(!model.isMovingToTrash)
                .opacity(model.isMovingToTrash ? 0.72 : 1)
            Rectangle()
                .fill(Color.separator.opacity(0.55))
                .frame(width: 1)
            detail
        }
        .background(Color.appBackground)
        .onAppear { model.loadApplicationsIfNeeded() }
        .sheet(isPresented: $model.showingReview) {
            AppRemovalReviewSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingOutcomeReport) {
            if let outcome = model.lastOutcome {
                AppRemovalResultView(
                    applicationName: model.lastApplicationName ?? "Application",
                    outcome: outcome,
                    clearsOutcomeOnDone: false
                )
                .environmentObject(model)
                .frame(width: 780, height: 620)
            }
        }
        .alert(item: $model.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var applicationList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("App Uninstaller")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("exact relations, no hidden deletion")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Button(action: model.refreshApplications) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(model.isLoadingApplications || model.isMovingToTrash)
                .help("Refresh list")
            }
            .padding(.horizontal, 16)
            .frame(height: 62)

            Rectangle().fill(Color.separator.opacity(0.5)).frame(height: 1)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                TextField("Search by name or bundle ID", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .padding(12)

            if model.isLoadingApplications && model.applications.isEmpty {
                Spacer()
                ProgressView("Looking for applications…")
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryText)
                Spacer()
            } else if model.filteredApplications.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 25))
                    Text("No applications found")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.secondaryText)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.filteredApplications) { application in
                            ApplicationListRow(
                                application: application,
                                isSelected: model.selectedApplication?.id == application.id
                            )
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 12)
                }
            }

            Rectangle().fill(Color.separator.opacity(0.5)).frame(height: 1)

            Button(action: model.chooseApplication) {
                Label("Choose Another .app", systemImage: "plus.app.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.isMovingToTrash)
            .padding(12)
        }
        .background(Color.panel.opacity(0.78))
    }

    @ViewBuilder
    private var detail: some View {
        if model.needsHomeAccess {
            HomeAccessRequiredView(
                icon: "app.badge.checkmark",
                title: "Allow access to your Library",
                message: "The App Store version of DiskBloom runs in the App Sandbox. To find each app's caches, preferences and other related data, it needs access to your home folder. Nothing is changed until you review and confirm a plan.",
                action: model.grantHomeAccess
            )
        } else if model.isInspecting {
            AppInspectionProgressView()
        } else if let plan = model.plan {
            AppRemovalPlanView(plan: plan)
        } else if let outcome = model.lastOutcome {
            AppRemovalResultView(
                applicationName: model.lastApplicationName ?? "Application",
                outcome: outcome,
                clearsOutcomeOnDone: true
            )
        } else {
            AppUninstallerWelcomeView()
        }
    }
}

private struct ApplicationListRow: View {
    @EnvironmentObject private var model: AppUninstallerModel
    let application: InstalledApplication
    let isSelected: Bool

    private var isProtected: Bool {
        AppRemovalPolicy.applicationEligibilityReason(for: application) != nil
    }

    var body: some View {
        Button { model.inspect(application) } label: {
            HStack(spacing: 10) {
                ApplicationIcon(url: application.url, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    Text(application.bundleIdentifier ?? application.sourceLabel)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isProtected {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.secondaryText)
                        .help("Protected")
                } else if isSelected {
                    Circle().fill(Color.accentMint).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentMint.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

private struct AppUninstallerWelcomeView: View {
    @EnvironmentObject private var model: AppUninstallerModel

    var body: some View {
        VStack(spacing: 19) {
            ZStack {
                Circle().fill(Color.accentMint.opacity(0.08)).frame(width: 132, height: 132)
                Image(systemName: "app.badge.checkmark")
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text("Uninstall without guesswork")
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text("Choose an application. DiskBloom checks the bundle itself and only pre-approved exact paths in your Library. Name-based and shared data stay off until you select them yourself.")
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 570)
                .lineSpacing(3)
            HStack(spacing: 9) {
                Label("local", systemImage: "lock.shield.fill")
                Label("to Trash", systemImage: "trash")
                Label("re-verified", systemImage: "checkmark.shield")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentMint)
            Button(action: model.chooseApplication) {
                Label("Choose Application", systemImage: "plus.app.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RadialGradient(
                colors: [Color.accentMint.opacity(0.06), Color.clear],
                center: .center,
                startRadius: 50,
                endRadius: 380
            )
        )
    }
}

private struct AppInspectionProgressView: View {
    @EnvironmentObject private var model: AppUninstallerModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(Color.accentMint)
            Text("Checking the application and exact relations")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("\(model.progress.itemCount.formatted()) \(Plural.objects(model.progress.itemCount)) scanned")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentMint)
            Text(model.progress.currentPath)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.secondaryText)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AppRemovalPlanView: View {
    @EnvironmentObject private var model: AppUninstallerModel
    let plan: AppRemovalPlan

    var body: some View {
        VStack(spacing: 0) {
            applicationHeader
            Rectangle().fill(Color.separator.opacity(0.5)).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    warnings
                    itemHeader
                    LazyVStack(spacing: 7) {
                        ForEach(plan.items) { item in
                            AppRemovalItemRow(item: item)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
            removalBar
        }
    }

    private var applicationHeader: some View {
        HStack(spacing: 15) {
            ApplicationIcon(url: plan.application.url, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(plan.application.name)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    if let version = plan.application.version {
                        Text("v\(version)")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.secondaryText)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.055), in: Capsule())
                    }
                }
                Text(plan.application.bundleIdentifier ?? "No bundle ID — only the bundle and manual matches are available")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                Text(plan.application.url.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(ByteFormat.string(plan.items.first?.node.size ?? 0))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("bundle size — estimate")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondaryText)
            }
            Button(action: model.reanalyzeSelectedApplication) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(
                model.isReviewing
                    || model.isMovingToTrash
                    || model.applicationWasMoved
                    || !model.confirmedMovedItemIDs.isEmpty
                    || model.hasUncertainOutcome
            )
            .help(model.applicationWasMoved ? "Bundle already moved; the continuation plan is kept" : "Analyze again")
        }
        .padding(.horizontal, 20)
        .frame(height: 82)
    }

    @ViewBuilder
    private var warnings: some View {
        let running = model.runningReason()
        if let block = plan.applicationEligibilityIssue {
            WarningStrip(text: block, icon: "lock.shield.fill", color: .danger)
                .padding(.horizontal, 18)
                .padding(.top, 12)
        } else if let running {
            WarningStrip(text: running, icon: "stop.circle.fill", color: .orange)
                .padding(.horizontal, 18)
                .padding(.top, 12)
        }
        if model.applicationWasMoved {
            WarningStrip(
                text: "The application bundle has already been moved to the Trash. Only unprocessed related paths remain below; you can exclude or re-check them.",
                icon: "trash.circle.fill",
                color: .accentMint
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        if plan.application.bundleIdentifier != nil, !plan.bundleIdentifierIsSignatureBacked {
            WarningStrip(
                text: "The bundle ID is not backed by a signature with an Apple trust anchor and Team ID. All paths built from it are off by default.",
                icon: "signature",
                color: .orange
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        if plan.hasDuplicateBundleIdentifier {
            WarningStrip(
                text: "Several applications share this bundle ID. All related paths are off by default as potentially shared.",
                icon: "square.stack.3d.up.fill",
                color: .orange
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        if plan.hasPrivilegedComponents {
            WarningStrip(
                text: "A system extension, helper or Login Item was found in the bundle. A complete uninstall may require the developer’s official uninstaller.",
                icon: "gearshape.2.fill",
                color: .orange
            )
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        if let uncertainPaths = model.lastOutcome?.uncertainPaths, !uncertainPaths.isEmpty {
            VStack(alignment: .trailing, spacing: 7) {
                WarningStrip(
                    text: "The move result could not be confirmed; automatic retry is blocked:\n\(uncertainPaths.joined(separator: "\n"))",
                    icon: "questionmark.folder.fill",
                    color: .danger
                )
                Button("Re-check Original Paths") {
                    model.recheckUncertainPaths()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.isReviewing || model.isMovingToTrash)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
        if let failure = model.lastOutcome?.failure {
            VStack(alignment: .trailing, spacing: 7) {
                WarningStrip(
                    text: "The previous attempt stopped: \(failure)",
                    icon: "exclamationmark.octagon.fill",
                    color: .danger
                )
                Button("Open Full Report") {
                    model.showingOutcomeReport = true
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
    }

    private var itemHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("FOUND ITEMS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.secondaryText)
                Text("Only exact allowed paths; no substring search is used")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText.opacity(0.82))
            }
            Spacer()
            Text("\(plan.items.count) \(Plural.objects(plan.items.count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 9)
    }

    private var removalBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Color.danger.opacity(0.13))
                    Image(systemName: "trash.fill")
                        .foregroundStyle(Color.danger)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected: \(model.selectedItems.count)")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Selected size — estimate: \(ByteFormat.string(model.selectedSize))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.secondaryText)
                }
                Spacer()
                Text("Space is not freed until the Trash is emptied")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.secondaryText)
                Button(action: model.requestRemovalReview) {
                    if model.isReviewing || model.isMovingToTrash {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Review Uninstall", systemImage: "checkmark.shield.fill")
                    }
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(
                    plan.applicationEligibilityIssue != nil
                        || model.runningReason() != nil
                        || model.selectedItems.isEmpty
                        || model.isReviewing
                        || model.isMovingToTrash
                        || model.hasUncertainOutcome
                )
            }
            .padding(.horizontal, 18)
            .frame(height: 68)
            .background(Color.panel)
        }
    }
}

private struct AppRemovalItemRow: View {
    @EnvironmentObject private var model: AppUninstallerModel
    let item: AppRemovalItem

    private var isSelected: Bool {
        item.isRequired ? !model.applicationWasMoved : model.selectedItemIDs.contains(item.id)
    }

    private var isConfirmedMoved: Bool {
        item.isRequired ? model.applicationWasMoved : model.confirmedMovedItemIDs.contains(item.id)
    }

    private var badgeColor: Color {
        switch item.match {
        case .application: .blue
        case .exactIdentifier: .accentMint
        case .exactName: .orange
        case .declaredGroup: .purple
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Button { model.toggle(item) } label: {
                Image(
                    systemName: item.isRequired
                        ? (model.applicationWasMoved ? "checkmark.circle.fill" : "lock.circle.fill")
                        : (isConfirmedMoved || isSelected ? "checkmark.circle.fill" : "circle")
                )
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        item.isRequired && !model.applicationWasMoved
                            ? Color.blue
                            : ((isSelected || isConfirmedMoved) ? Color.accentMint : Color.secondaryText.opacity(0.65))
                    )
            }
            .buttonStyle(.plain)
            .disabled(item.isRequired || !item.isSelectable || isConfirmedMoved)
            .help(
                isConfirmedMoved
                    ? "Already moved to Trash"
                    : item.isRequired
                    ? (model.applicationWasMoved ? "Already moved to Trash" : "The application bundle is required")
                    : (isSelected ? "Exclude" : "Include")
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(item.rule.title)
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(item.match.title.uppercased())
                        .font(.system(size: 8, weight: .heavy))
                        .tracking(0.45)
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(badgeColor.opacity(0.11), in: Capsule())
                    if item.risk.needsExtraAcknowledgement {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    }
                    if isConfirmedMoved {
                        Text("ALREADY IN TRASH")
                            .font(.system(size: 8, weight: .heavy))
                            .tracking(0.4)
                            .foregroundStyle(Color.accentMint)
                    }
                    Spacer()
                    Text(ByteFormat.string(item.node.size))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                }
                Text(item.url.path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(item.eligibilityIssue ?? item.risk.warning ?? item.explanation)
                    .font(.system(size: 9.5))
                    .foregroundStyle(item.eligibilityIssue == nil ? Color.secondaryText.opacity(0.9) : Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { model.reveal(item) } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(isConfirmedMoved)
            .help("Reveal in Finder")
        }
        .padding(12)
        .background(
            isSelected ? Color.accentMint.opacity(0.055) : Color.panelElevated,
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSelected ? Color.accentMint.opacity(0.16) : Color.white.opacity(0.045), lineWidth: 1)
        )
        .opacity(item.isSelectable && !isConfirmedMoved ? 1 : 0.64)
    }
}

private struct AppRemovalReviewSheet: View {
    @EnvironmentObject private var model: AppUninstallerModel
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledgedSensitiveData = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(Color.danger.opacity(0.14))
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.danger)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Final uninstall review")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text("\(model.selectedItems.count) \(Plural.objects(model.selectedItems.count)) · selected size — estimate \(ByteFormat.string(model.selectedSize))")
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
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.isRequired ? "app.fill" : "doc.badge.gearshape.fill")
                                .foregroundStyle(item.risk.needsExtraAcknowledgement ? Color.orange : Color.accentMint)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(item.rule.title)
                                        .font(.system(size: 12, weight: .semibold))
                                    Spacer()
                                    Text(ByteFormat.string(item.node.size))
                                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                }
                                Text(item.url.path)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Color.secondaryText)
                                    .textSelection(.enabled)
                                if let warning = item.risk.warning {
                                    Text(warning)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(Color.orange)
                                }
                            }
                        }
                        .padding(11)
                        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 310)

            VStack(alignment: .leading, spacing: 7) {
                if model.applicationWasMoved {
                    Label("The .app bundle is already in the Trash; only the remaining selected paths are being checked now.", systemImage: "checkmark.circle.fill")
                } else {
                    Label("The .app is moved first; if that fails, related data is left untouched.", systemImage: "1.circle.fill")
                }
                Label("A multi-path operation is not atomic: on a late failure it stops and shows a report.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                Label("Every path, identity and fingerprint is checked once more inside file coordination.", systemImage: "checkmark.shield")
                Label("Items go to the system Trash; space is freed only after it is emptied.", systemImage: "arrow.uturn.backward.circle")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 22)
            .padding(.bottom, 12)

            if model.needsExtraAcknowledgement {
                Toggle(isOn: $acknowledgedSensitiveData) {
                    Text("I have reviewed the selected paths with potentially important or shared data")
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 22)
                .padding(.bottom, 14)
            }

            Rectangle().fill(Color.separator).frame(height: 1)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move Selected to Trash") {
                    model.moveReviewedItemsToTrash()
                }
                .buttonStyle(DangerButtonStyle())
                .disabled(
                    model.hasUncertainOutcome
                        || (model.needsExtraAcknowledgement && !acknowledgedSensitiveData)
                )
            }
            .padding(18)
        }
        .frame(width: 690, height: model.needsExtraAcknowledgement ? 630 : 590)
        .background(Color.appBackground)
        .preferredColorScheme(.dark)
    }
}

private struct AppRemovalResultView: View {
    @EnvironmentObject private var model: AppUninstallerModel
    @Environment(\.dismiss) private var dismiss
    let applicationName: String
    let outcome: AppRemovalOutcome
    let clearsOutcomeOnDone: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((outcome.failure == nil ? Color.accentMint : Color.orange).opacity(0.11))
                    Image(systemName: outcome.failure == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(outcome.failure == nil ? Color.accentMint : Color.orange)
                }
                .frame(width: 72, height: 72)
                Text(outcome.failure == nil ? "Move completed" : "Operation stopped")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(applicationName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
            }
            .padding(.top, 28)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !outcome.movedPaths.isEmpty {
                        ResultPathSection(
                            title: "MOVED TO TRASH",
                            paths: outcome.movedPaths,
                            color: .accentMint
                        )
                    }
                    if !outcome.uncertainPaths.isEmpty {
                        ResultPathSection(
                            title: "RESULT UNCONFIRMED — RETRY BLOCKED",
                            paths: outcome.uncertainPaths,
                            color: .danger
                        )
                    }
                    if let failure = outcome.failure {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("ERROR")
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(1)
                                .foregroundStyle(Color.danger)
                            Text(failure)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .background(Color.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !outcome.unattemptedPaths.isEmpty {
                        ResultPathSection(
                            title: "NOT PROCESSED",
                            paths: outcome.unattemptedPaths,
                            color: .orange
                        )
                    }
                    Label("Space is freed only after the system Trash is emptied.", systemImage: "trash")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 760)
            }

            Spacer(minLength: 0)
            Rectangle().fill(Color.separator.opacity(0.55)).frame(height: 1)
            HStack {
                Spacer()
                Button(clearsOutcomeOnDone ? "Done" : "Close") {
                    if clearsOutcomeOnDone {
                        model.clearLastOutcome()
                    } else {
                        dismiss()
                    }
                }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(18)
            .background(Color.panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ResultPathSection: View {
    let title: String
    let paths: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1)
                .foregroundStyle(color)
            ForEach(paths, id: \.self) { path in
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
        }
        .padding(12)
        .background(Color.panelElevated, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct WarningStrip: View {
    let text: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(color.opacity(0.085), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.18), lineWidth: 1))
    }
}

private struct ApplicationIcon: View {
    let url: URL
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}


/// Shown by the sandboxed build before the home folder has been granted.
struct HomeAccessRequiredView: View {
    let icon: String
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentMint.opacity(0.08)).frame(width: 132, height: 132)
                Image(systemName: icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.accentMint)
            }
            Text(title)
                .font(.system(size: 25, weight: .bold, design: .rounded))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .lineSpacing(3)
            HStack(spacing: 9) {
                Label("your choice", systemImage: "hand.tap.fill")
                Label("remembered", systemImage: "bookmark.fill")
                Label("local only", systemImage: "lock.shield.fill")
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.accentMint)
            Button(action: action) {
                Label("Grant Access to Home Folder", systemImage: "house.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
