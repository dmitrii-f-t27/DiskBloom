import AppKit
import Combine
import Foundation

struct ScanSource: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let url: URL
    let icon: String
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum WorkspaceSection: String, Sendable {
    case diskMap
    case appUninstaller
    case orphanedAppData
    case duplicateFinder
    case cacheExplorer
}

enum SnapshotValidator {
    /// Whether an item still matches its snapshot, decided by Specs/scan_rules.t27; nil when it does.
    static func validate(_ node: DiskNode, candidateURL: URL? = nil) -> String? {
        let originalURL = node.url
        let url = candidateURL ?? originalURL ?? URL(fileURLWithPath: "/")
        let exists = FileManager.default.fileExists(atPath: url.path)
        var valuesError: Error?
        var values: URLResourceValues?
        if exists {
            do { values = try url.resourceValues(forKeys: [.isSymbolicLinkKey]) } catch { valuesError = error }
        }
        let actual = values != nil ? FileIdentity.read(for: url) : nil
        let precheck = sn_precheck(
            node.isVirtual || originalURL == nil,
            candidateURL.map { candidate in originalURL.map { T27Text.same(candidate.standardizedFileURL.path, $0.standardizedFileURL.path) } ?? false } ?? true,
            exists,
            values != nil,
            values?.isSymbolicLink == true,
            node.resourceIdentifier != nil && actual != nil,
            node.resourceIdentifier.flatMap { expected in actual.map { T27Text.same($0, expected) } } ?? false,
            node.fingerprint != nil
        )
        let path = originalURL?.path ?? url.path
        switch precheck {
        case UInt32(SN_OK): break
        case UInt32(SN_AGGREGATE): return "An aggregate group cannot be reviewed as a single item."
        case UInt32(SN_PATH_CHANGED): return "The item’s path changed after confirmation. Rescan: \(path)"
        case UInt32(SN_GONE): return "The item no longer exists: \(url.path)"
        case UInt32(SN_VALUES_UNREADABLE): return "Could not re-verify \(url.path): \(valuesError?.localizedDescription ?? "")"
        case UInt32(SN_BECAME_SYMLINK): return "The item became a symbolic link after scanning: \(url.path)"
        case UInt32(SN_IDENTITY_UNKNOWN): return "Could not confirm the item’s identity: \(url.path). Rescan."
        case UInt32(SN_IDENTITY_CHANGED): return "The item changed after scanning: \(url.path). Rescan."
        default: return "No complete content snapshot exists for the item: \(url.path). Rescan."
        }
        var refreshed: DiskNode?
        var measureError: Error?
        do {
            var scanner = DiskScanner()
            refreshed = try scanner.scan(root: url, counter: ScanCounter()).root
        } catch {
            measureError = error
        }
        let comparison = sn_compare(
            refreshed != nil,
            refreshed?.resourceIdentifier == node.resourceIdentifier,
            refreshed?.isDirectory == node.isDirectory,
            refreshed?.fingerprint == node.fingerprint,
            refreshed?.size == node.size,
            refreshed?.fileCount == node.fileCount,
            refreshed?.directoryCount == node.directoryCount
        )
        switch comparison {
        case UInt32(SN_OK): return nil
        case UInt32(SN_REMEASURE_FAILED): return "Could not re-measure \(url.path): \(measureError?.localizedDescription ?? "")"
        default: return "Contents changed after analysis: \(url.path). Review the updated data before moving."
        }
    }
}

private struct TrashOutcome: Sendable {
    let successfulPaths: [String]
    let failures: [String]
}

private struct NavigationState {
    let snapshot: ScanSnapshot
    let focusStack: [DiskNode]
    let inspectedNode: DiskNode?
    let currentURL: URL
}

enum DeletionPolicy {
    /// The facts Specs/deletion_policy.t27 decides from. Missing facts are filled conservatively.
    static func rejectionReason(
        for node: DiskNode,
        scanRootURL: URL,
        activeScanURL: URL? = nil,
        candidateURL: URL? = nil,
        appURL: URL = Bundle.main.bundleURL
    ) -> String? {
        let originalNodeURL = node.url
        let url = candidateURL ?? originalNodeURL ?? scanRootURL
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        let scanRoot = scanRootURL.standardizedFileURL.resolvingSymlinksInPath()
        let home = UserHome.path
        let isInsideHome = T27Text.inside(original.path, home)
        let relativePath = isInsideHome ? String(original.path.dropFirst(home.count + 1)) : ""

        var library = UInt32(DP_LIB_NONE)
        if isInsideHome {
            switch T27Text.libraryArea(relative: relativePath) {
            case UInt32(TX_LIB_ALLOWED_CACHE): library = UInt32(DP_LIB_ALLOWED_CACHE)
            case UInt32(TX_LIB_OTHER): library = UInt32(DP_LIB_OTHER)
            default: break
            }
        }
        let protectedHomePaths = ["mlx/profiles", "My Drive"].map { home + "/" + $0 }
        let activePath = activeScanURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let appPath = appURL.standardizedFileURL.path
        let volumeValues = try? original.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])

        let reason = dp_rejection(
            node.isVirtual || originalNodeURL == nil,
            candidateURL.map { candidate in
                originalNodeURL.map { !T27Text.same(candidate.standardizedFileURL.path, $0.standardizedFileURL.path) } ?? true
            } ?? false,
            !T27Text.same(original.path, resolved.path),
            T27Text.same(original.path, home),
            T27Text.same(scanRoot.path, "/"),
            T27Text.same(original.path, scanRoot.path),
            T27Text.inside(original.path, scanRoot.path),
            activePath.map { T27Text.within($0, original.path) } ?? false,
            isInsideHome,
            T27Text.onExternalVolume(original.path),
            library,
            isInsideHome && T27Text.hiddenFirstComponent(relative: relativePath),
            protectedHomePaths.contains { T27Text.within(original.path, $0) },
            T27Text.hasTrashComponent(original.path),
            volumeValues?.volumeIsLocal == true,
            volumeValues?.volumeIsReadOnly == true,
            FileIdentity.deviceID(for: original) == FileIdentity.deviceID(for: scanRoot),
            T27Text.within(appPath, original.path),
            node.resourceIdentifier != nil
        )
        return message(for: reason)
    }

    /// The sentence shown for each refusal code of Specs/deletion_policy.t27.
    static func message(for reason: UInt32) -> String? {
        switch reason {
        case UInt32(DP_ALLOWED): nil
        case UInt32(DP_AGGREGATE): "An aggregate group cannot be moved to the Trash. Open the folder and choose a specific item."
        case UInt32(DP_PATH_CHANGED): "The item’s path changed after confirmation. Rescan and confirm the new path."
        case UInt32(DP_SYMLINK): "Symbolic links and redirected paths are view-only."
        case UInt32(DP_HOME_ROOT): "The home folder is protected. Choose an item inside it."
        case UInt32(DP_WHOLE_DISK): "Cleanup is disabled while viewing the entire system disk. Choose a specific user folder."
        case UInt32(DP_SCAN_ROOT): "The root of the current analysis is protected. Choose a specific item inside it."
        case UInt32(DP_OUTSIDE_SCAN): "The item is no longer inside the selected analysis area. Rescan."
        case UInt32(DP_CONTAINS_ACTIVE_SCAN): "The item contains the current analysis area. Go back to the parent map first."
        case UInt32(DP_SYSTEM_AREA): "System directories are available for analysis only. Cleanup is allowed inside the home folder or a selected external disk."
        case UInt32(DP_LIBRARY): "The Library folder holds app state, profiles and cloud data. DiskBloom allows cleanup only for Caches and Xcode DerivedData."
        case UInt32(DP_HIDDEN): "Hidden settings and credential directories are protected. Use Finder for them only after checking your backup."
        case UInt32(DP_PROTECTED_HOME): "Profiles and cloud data are protected. DiskBloom does not move them to the Trash."
        case UInt32(DP_TRASH): "Cloud data, profiles, credentials and app state are protected. DiskBloom does not move them to the Trash."
        case UInt32(DP_NETWORK): "Cleanup on network and unknown volumes is disabled."
        case UInt32(DP_READ_ONLY): "This volume is read-only."
        case UInt32(DP_OTHER_VOLUME): "The item is on a different volume than the selected analysis root."
        case UInt32(DP_RUNNING_APP): "A running application and the folder that contains it are protected."
        default: "The item could not be reliably identified. It is view-only."
        }
    }

    static func validateImmediatelyBeforeTrash(
        _ node: DiskNode,
        scanRootURL: URL,
        activeScanURL: URL? = nil,
        candidateURL: URL? = nil
    ) -> String? {
        if let reason = rejectionReason(
            for: node,
            scanRootURL: scanRootURL,
            activeScanURL: activeScanURL,
            candidateURL: candidateURL
        ) { return reason }
        return SnapshotValidator.validate(node, candidateURL: candidateURL)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var workspaceSection: WorkspaceSection = .diskMap
    @Published private(set) var snapshot: ScanSnapshot?
    @Published private(set) var focusStack: [DiskNode] = []
    @Published var inspectedNode: DiskNode?
    @Published private(set) var collection: [DiskNode] = []
    @Published private(set) var sources: [ScanSource] = []
    @Published private(set) var currentURL: URL
    @Published private(set) var analysisRootURL: URL
    @Published private(set) var volumeStats = VolumeStats(total: 0, available: 0)
    @Published private(set) var isScanning = false
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var isReviewingSelection = false
    @Published private(set) var progress = ScanProgress(itemCount: 0, currentPath: "")
    @Published var notice: AppNotice?
    @Published var showingTrashReview = false

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var navigationHistory: [NavigationState] = []
    private var reviewTask: Task<Void, Never>?
    private var reviewGeneration = UUID()

    init() {
        let home = UserHome.url
        currentURL = home
        analysisRootURL = home
        sources = Self.discoverSources(home: home)
        volumeStats = Self.readVolumeStats(for: home)
    }

    var focusNode: DiskNode? { focusStack.last ?? snapshot?.root }
    var collectionSize: Int64 { collection.reduce(0) { $0 + $1.size } }
    var canGoBack: Bool { focusStack.count > 1 || !navigationHistory.isEmpty }

    func startInitialScan() {
        guard snapshot == nil, !isScanning else { return }
        // The sandboxed build waits on the welcome screen until the person grants a folder.
        guard FolderAccess.shared.hasAccess(to: currentURL) else { return }
        startScan(at: currentURL)
    }

    var needsInitialAccess: Bool { !FolderAccess.shared.hasAccess(to: currentURL) }

    /// Opens a sidebar source, asking for access first in the sandboxed build.
    func open(source url: URL) {
        if FolderAccess.shared.hasAccess(to: url) {
            startScan(at: url)
            return
        }
        let name = url.path == UserHome.path ? "your home folder" : "“\(FileManager.default.displayName(atPath: url.path))”"
        guard let granted = FolderAccess.shared.requestAccess(
            to: url,
            title: "Allow access to \(name)",
            message: "DiskBloom reads only the folders you allow. Keep \(name) selected and click Grant Access to build the map."
        ) else { return }
        startScan(at: granted)
    }

    func grantHomeAccess() {
        open(source: UserHome.url)
    }

    func selectWorkspaceSection(_ section: WorkspaceSection) {
        workspaceSection = section
        if section != .diskMap, isScanning {
            cancelScan()
        } else if section == .diskMap, snapshot == nil {
            startInitialScan()
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder or disk to analyze"
        panel.prompt = "Analyze"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = currentURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderAccess.shared.remember(url)
        startScan(at: url)
    }

    func startScan(at url: URL, resetNavigation: Bool = true, rememberCurrent: Bool = false) {
        guard !isMovingToTrash else {
            notice = AppNotice(title: "Operation still in progress", message: "Wait for the move to the Trash to finish.")
            return
        }
        scanTask?.cancel()
        invalidatePendingReview()
        let normalized = url.standardizedFileURL
        let generation = UUID()
        scanGeneration = generation

        if rememberCurrent,
           let snapshot,
           !focusStack.isEmpty {
            navigationHistory.append(
                NavigationState(
                    snapshot: snapshot,
                    focusStack: focusStack,
                    inspectedNode: inspectedNode,
                    currentURL: currentURL
                )
            )
        } else if resetNavigation {
            navigationHistory = []
        }
        if resetNavigation {
            analysisRootURL = normalized
            collection = []
        }

        currentURL = normalized
        volumeStats = Self.readVolumeStats(for: normalized)
        isScanning = true
        progress = ScanProgress(itemCount: 0, currentPath: normalized.path)
        snapshot = nil
        focusStack = []
        inspectedNode = nil

        let counter = ScanCounter()
        let worker = Task.detached(priority: .userInitiated) { () throws -> ScanSnapshot in
            var scanner = DiskScanner()
            return try scanner.scan(root: normalized, counter: counter)
        }

        scanTask = Task { [weak self] in
            guard let self else {
                worker.cancel()
                return
            }
            let progressPoller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled else { break }
                    guard let self, self.scanGeneration == generation else { break }
                    self.progress = counter.snapshot()
                }
            }
            defer { progressPoller.cancel() }

            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                snapshot = result
                focusStack = [result.root]
                inspectedNode = result.root.children.first ?? result.root
                progress = counter.snapshot()
                volumeStats = Self.readVolumeStats(for: normalized)
                isScanning = false
            } catch is CancellationError {
                if scanGeneration == generation { isScanning = false }
            } catch {
                if scanGeneration == generation {
                    isScanning = false
                    notice = AppNotice(title: "Analysis could not be completed", message: error.localizedDescription)
                }
            }
        }
    }

    func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func rescan() {
        guard FolderAccess.shared.hasAccess(to: currentURL) else {
            open(source: currentURL)
            return
        }
        startScan(at: currentURL, resetNavigation: false)
    }

    func enter(_ node: DiskNode) {
        guard node.isDirectory, !node.isVirtual else {
            inspectedNode = node
            return
        }
        inspectedNode = node
        if node.children.isEmpty, let url = node.url {
            let targetPath = url.standardizedFileURL.path
            let previousCount = collection.count
            collection.removeAll { selected in
                guard let selectedPath = selected.url?.standardizedFileURL.path else { return false }
                return T27Text.within(targetPath, selectedPath)
            }
            if collection.count != previousCount {
                invalidatePendingReview()
                notice = AppNotice(
                    title: "Removed from queue",
                    message: "The current folder cannot be inside an item from the cleanup queue. Conflicting items were removed."
                )
            }
            startScan(at: url, resetNavigation: false, rememberCurrent: true)
        } else {
            focusStack.append(node)
        }
    }

    func goBack() {
        if focusStack.count > 1 {
            focusStack.removeLast()
            inspectedNode = focusStack.last
            return
        }
        guard let previous = navigationHistory.popLast() else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        snapshot = previous.snapshot
        focusStack = previous.focusStack
        inspectedNode = previous.inspectedNode
        currentURL = previous.currentURL
        volumeStats = Self.readVolumeStats(for: previous.currentURL)
    }

    func goToBreadcrumb(_ node: DiskNode) {
        guard let index = focusStack.firstIndex(where: { $0.id == node.id }) else { return }
        focusStack = Array(focusStack.prefix(index + 1))
        inspectedNode = node
    }

    func inspect(_ node: DiskNode) {
        inspectedNode = node
    }

    /// The chain of real nodes from the scan root down to `path`, if the current snapshot holds it.
    private func nodeChain(toPath path: String) -> [DiskNode]? {
        guard let root = snapshot?.root, let rootPath = root.url?.standardizedFileURL.path else { return nil }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard T27Text.within(target, rootPath) else { return nil }
        var chain = [root]
        var current = root
        while current.url?.standardizedFileURL.path != target {
            guard let next = current.children.first(where: { child in
                guard !child.isVirtual, let childPath = child.url?.standardizedFileURL.path else { return false }
                return T27Text.within(target, childPath)
            }) else { return nil }
            chain.append(next)
            current = next
        }
        return chain
    }

    func node(atPath path: String) -> DiskNode? {
        nodeChain(toPath: path)?.last
    }

    /// Moves the map to an item that is already in the current snapshot. Returns false if it is not.
    @discardableResult
    func focus(onPath path: String) -> Bool {
        guard !isScanning, var chain = nodeChain(toPath: path), let target = chain.last else { return false }
        if target.isDirectory, !target.isPackage {
            // A folder below the scan depth has no children in the snapshot; it needs its own scan.
            guard !target.children.isEmpty else { return false }
            focusStack = chain
            inspectedNode = target.children.first ?? target
        } else {
            if chain.count > 1 { chain.removeLast() }
            focusStack = chain
            inspectedNode = target
        }
        return true
    }

    func revealInFinder(_ node: DiskNode) {
        guard let url = node.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func rejectionReason(for node: DiskNode) -> String? {
        DeletionPolicy.rejectionReason(
            for: node,
            scanRootURL: analysisRootURL,
            activeScanURL: currentURL
        )
    }

    func isCollected(_ node: DiskNode) -> Bool {
        collection.contains { samePath($0, node) }
    }

    func toggleCollection(_ node: DiskNode) {
        invalidatePendingReview()
        if let index = collection.firstIndex(where: { samePath($0, node) }) {
            collection.remove(at: index)
            return
        }
        if let reason = rejectionReason(for: node) {
            notice = AppNotice(title: "View only", message: reason)
            return
        }
        guard let url = node.url else { return }
        let path = url.standardizedFileURL.path
        if let parent = collection.first(where: { selected in
            guard let selectedPath = selected.url?.standardizedFileURL.path else { return false }
            return T27Text.inside(path, selectedPath)
        }) {
            notice = AppNotice(
                title: "Already included",
                message: "The item is already part of the selected folder “\(parent.name)”."
            )
            return
        }
        collection.removeAll { selected in
            guard let selectedPath = selected.url?.standardizedFileURL.path else { return false }
            return T27Text.inside(selectedPath, path)
        }
        collection.append(node)
    }

    func removeFromCollection(_ node: DiskNode) {
        invalidatePendingReview()
        collection.removeAll { samePath($0, node) }
    }

    func requestTrashReview() {
        guard !collection.isEmpty, !isReviewingSelection else { return }
        reviewTask?.cancel()
        let generation = UUID()
        reviewGeneration = generation
        isReviewingSelection = true
        let candidates = collection
        let protectedRootURL = analysisRootURL
        let activeScanURL = currentURL

        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                var result: [String] = []
                for node in candidates {
                    if Task.isCancelled { break }
                    if let reason = DeletionPolicy.validateImmediatelyBeforeTrash(
                        node,
                        scanRootURL: protectedRootURL,
                        activeScanURL: activeScanURL
                    ) {
                        result.append(reason)
                    }
                }
                return result
            }.value
            guard reviewGeneration == generation, !Task.isCancelled else { return }
            isReviewingSelection = false
            if failures.isEmpty {
                showingTrashReview = true
            } else {
                notice = AppNotice(
                    title: "Rescan needed",
                    message: failures.joined(separator: "\n")
                )
            }
        }
    }

    func moveReviewedItemsToTrash() {
        guard !collection.isEmpty, !isMovingToTrash else { return }
        showingTrashReview = false
        isMovingToTrash = true
        let candidates = collection
        let rescanURL = currentURL
        let protectedRootURL = analysisRootURL

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                var successful: [String] = []
                var failures: [String] = []
                for node in candidates {
                    guard let url = node.url else { continue }
                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    var coordinationError: NSError?
                    var localFailure: String?
                    var didMove = false
                    coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                        if let reason = DeletionPolicy.validateImmediatelyBeforeTrash(
                            node,
                            scanRootURL: protectedRootURL,
                            activeScanURL: rescanURL,
                            candidateURL: coordinatedURL
                        ) {
                            localFailure = reason
                            return
                        }
                        guard let expectedRelocationIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                            localFailure = "Could not capture the identity before moving: \(url.path)"
                            return
                        }
                        do {
                            var resultingURL: NSURL?
                            try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: &resultingURL)
                            guard let movedURL = resultingURL as URL?,
                                  FileIdentity.relocationIdentifier(for: movedURL) == expectedRelocationIdentity,
                                  (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == node.isDirectory else {
                                let resultPath = (resultingURL as URL?)?.path ?? "no Trash path was returned"
                                localFailure = "Could not confirm the item’s identity after moving: \(url.path). Result: \(resultPath). No automatic restore of an unknown item was attempted."
                                return
                            }
                            didMove = true
                        } catch {
                            localFailure = "\(url.path): \(error.localizedDescription)"
                        }
                    }
                    if let coordinationError {
                        failures.append("\(url.path): \(coordinationError.localizedDescription)")
                    } else if let localFailure {
                        failures.append(localFailure)
                    } else if didMove {
                        successful.append(url.path)
                    }
                }
                return TrashOutcome(successfulPaths: successful, failures: failures)
            }.value

            collection.removeAll { node in
                guard let path = node.url?.path else { return false }
                return outcome.successfulPaths.contains(path)
            }
            isMovingToTrash = false
            if outcome.failures.isEmpty {
                notice = AppNotice(
                    title: "Moved to Trash",
                    message: "Items: \(outcome.successfulPaths.count). The data can be restored from Finder until the Trash is emptied."
                )
            } else {
                let successLine = outcome.successfulPaths.isEmpty ? "" : "Succeeded: \(outcome.successfulPaths.count).\n\n"
                notice = AppNotice(
                    title: "Operation finished with issues",
                    message: successLine + outcome.failures.joined(separator: "\n")
                )
            }
            startScan(at: rescanURL, resetNavigation: false)
        }
    }

    private func samePath(_ lhs: DiskNode, _ rhs: DiskNode) -> Bool {
        guard let left = lhs.url?.standardizedFileURL.path,
              let right = rhs.url?.standardizedFileURL.path else {
            return lhs.id == rhs.id
        }
        return T27Text.same(left, right)
    }

    private func invalidatePendingReview() {
        reviewGeneration = UUID()
        reviewTask?.cancel()
        reviewTask = nil
        isReviewingSelection = false
        showingTrashReview = false
    }

    private static func discoverSources(home: URL) -> [ScanSource] {
        var result = [
            ScanSource(
                id: "home",
                name: "Home Folder",
                subtitle: home.path,
                url: home,
                icon: "house.fill"
            )
        ]
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            let values = try? volume.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? volume.lastPathComponent
            let subtitle: String
            let icon: String
            if values?.volumeIsLocal == false {
                subtitle = "Network volume"
                icon = "network"
            } else if values?.volumeIsInternal == true {
                subtitle = "Internal disk"
                icon = "internaldrive.fill"
            } else if values?.volumeIsRemovable == true {
                subtitle = "Removable volume"
                icon = "externaldrive.badge.plus"
            } else if values?.volumeIsInternal == false {
                subtitle = "External disk"
                icon = "externaldrive.fill"
            } else {
                subtitle = "Other volume"
                icon = "externaldrive"
            }
            let labeledSubtitle = values?.volumeIsReadOnly == true ? subtitle + " · read-only" : subtitle
            result.append(
                ScanSource(
                    id: volume.standardizedFileURL.path,
                    name: name.isEmpty ? "Disk" : name,
                    subtitle: labeledSubtitle,
                    url: volume,
                    icon: icon
                )
            )
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    private static func readVolumeStats(for url: URL) -> VolumeStats {
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let available = values?.volumeAvailableCapacityForImportantUsage
            ?? Int64(values?.volumeAvailableCapacity ?? 0)
        return VolumeStats(total: total, available: available)
    }
}
