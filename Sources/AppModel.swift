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
}

enum SnapshotValidator {
    static func validate(_ node: DiskNode, candidateURL: URL? = nil) -> String? {
        guard !node.isVirtual, let originalURL = node.url else {
            return "Сводную группу нельзя проверить как отдельный объект."
        }
        if let candidateURL,
           candidateURL.standardizedFileURL.path != originalURL.standardizedFileURL.path {
            return "Путь объекта изменился после подтверждения. Выполните повторный анализ: \(originalURL.path)"
        }
        let url = candidateURL ?? originalURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "Объект уже не существует: \(url.path)"
        }
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                return "Объект стал символической ссылкой после сканирования: \(url.path)"
            }
            guard let expected = node.resourceIdentifier,
                  let actual = FileIdentity.read(for: url) else {
                return "Не удалось подтвердить идентичность объекта: \(url.path). Выполните повторный анализ."
            }
            if actual != expected {
                return "Объект изменился после сканирования: \(url.path). Выполните повторный анализ."
            }
        } catch {
            return "Не удалось повторно проверить \(url.path): \(error.localizedDescription)"
        }
        guard let expectedFingerprint = node.fingerprint else {
            return "Для объекта нет полного снимка содержимого: \(url.path). Выполните повторный анализ."
        }
        do {
            var scanner = DiskScanner()
            let refreshed = try scanner.scan(root: url, counter: ScanCounter()).root
            guard refreshed.resourceIdentifier == node.resourceIdentifier,
                  refreshed.isDirectory == node.isDirectory,
                  refreshed.fingerprint == expectedFingerprint,
                  refreshed.size == node.size,
                  refreshed.fileCount == node.fileCount,
                  refreshed.directoryCount == node.directoryCount else {
                return "Содержимое изменилось после анализа: \(url.path). Просмотрите обновлённые данные перед перемещением."
            }
        } catch {
            return "Не удалось повторно измерить \(url.path): \(error.localizedDescription)"
        }
        return nil
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
    static func rejectionReason(
        for node: DiskNode,
        scanRootURL: URL,
        activeScanURL: URL? = nil,
        candidateURL: URL? = nil,
        appURL: URL = Bundle.main.bundleURL
    ) -> String? {
        guard !node.isVirtual, let originalNodeURL = node.url else {
            return "Сводную группу нельзя перемещать в Корзину. Откройте папку и выберите конкретный объект."
        }
        if let candidateURL,
           candidateURL.standardizedFileURL.path != originalNodeURL.standardizedFileURL.path {
            return "Путь объекта изменился после подтверждения. Выполните повторный анализ и подтвердите новый путь."
        }
        let url = candidateURL ?? originalNodeURL
        let original = url.standardizedFileURL
        let resolved = original.resolvingSymlinksInPath()
        guard original.path == resolved.path else {
            return "Символические ссылки и перенаправленные пути доступны только для просмотра."
        }
        guard original.path != NSHomeDirectory() else {
            return "Домашняя папка защищена. Выберите объект внутри неё."
        }
        let scanRoot = scanRootURL.standardizedFileURL.resolvingSymlinksInPath()
        if scanRoot.path == "/" {
            return "В режиме обзора всего системного диска очистка отключена. Выберите конкретную папку пользователя."
        }
        if original.path == scanRoot.path {
            return "Корень текущего анализа защищён. Выберите конкретный объект внутри него."
        }
        guard original.path.hasPrefix(scanRoot.path + "/") else {
            return "Объект больше не находится внутри выбранной области анализа. Выполните повторное сканирование."
        }
        if let activeScanURL {
            let activePath = activeScanURL.standardizedFileURL.resolvingSymlinksInPath().path
            if original.path == activePath || activePath.hasPrefix(original.path + "/") {
                return "Объект содержит текущую область анализа. Сначала вернитесь к родительской карте."
            }
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
        let isInsideHome = original.path.hasPrefix(home + "/")
        let components = original.pathComponents
        let isInsideExternalVolume = components.count >= 4 && components[1] == "Volumes"
        guard isInsideHome || isInsideExternalVolume else {
            return "Системные каталоги доступны только для анализа. Очистка разрешена внутри домашней папки или выбранного внешнего диска."
        }
        if isInsideHome {
            let relativePath = String(original.path.dropFirst(home.count + 1))
            let allowedLibraryPaths = [
                "Library/Caches",
                "Library/Developer/Xcode/DerivedData"
            ]
            let isAllowedLibraryCache = allowedLibraryPaths.contains { allowedPath in
                relativePath == allowedPath || relativePath.hasPrefix(allowedPath + "/")
            }
            if (relativePath == "Library" || relativePath.hasPrefix("Library/")) && !isAllowedLibraryCache {
                return "Папка Library содержит состояние приложений, профили и облачные данные. DiskBloom разрешает очистку только Caches и Xcode DerivedData."
            }
            let firstComponent = relativePath.split(separator: "/").first.map(String.init) ?? ""
            if firstComponent.hasPrefix(".") && firstComponent != ".cache" {
                return "Скрытые каталоги настроек и учётных данных защищены. Для них используйте Finder только после проверки резервной копии."
            }
            let protectedHomePaths = ["mlx/profiles", "My Drive"].map { home + "/" + $0 }
            if protectedHomePaths.contains(where: { protectedPath in
                original.path == protectedPath || original.path.hasPrefix(protectedPath + "/")
            }) {
                return "Профили и облачные данные защищены. DiskBloom не перемещает их в Корзину."
            }
        }
        if original.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            return "Облачные данные, профили, учётные данные и состояние приложений защищены. DiskBloom не перемещает их в Корзину."
        }
        let volumeValues = try? original.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
        if volumeValues?.volumeIsLocal != true {
            return "Очистка сетевых и неопределённых томов отключена."
        }
        if volumeValues?.volumeIsReadOnly == true {
            return "Этот том доступен только для чтения."
        }
        guard FileIdentity.deviceID(for: original) == FileIdentity.deviceID(for: scanRoot) else {
            return "Объект находится на другом томе, чем выбранный корень анализа."
        }
        let appPath = appURL.standardizedFileURL.path
        if original.path == appPath || appPath.hasPrefix(original.path + "/") {
            return "Работающее приложение и папка, в которой оно находится, защищены."
        }
        guard node.resourceIdentifier != nil else {
            return "Не удалось надёжно идентифицировать объект. Он доступен только для просмотра."
        }
        return nil
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
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
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
        startScan(at: currentURL)
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
        panel.title = "Выберите папку или диск для анализа"
        panel.prompt = "Анализировать"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = currentURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(at: url)
    }

    func startScan(at url: URL, resetNavigation: Bool = true, rememberCurrent: Bool = false) {
        guard !isMovingToTrash else {
            notice = AppNotice(title: "Операция ещё выполняется", message: "Дождитесь завершения перемещения в Корзину.")
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
                    notice = AppNotice(title: "Не удалось завершить анализ", message: error.localizedDescription)
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
                return targetPath == selectedPath || targetPath.hasPrefix(selectedPath + "/")
            }
            if collection.count != previousCount {
                invalidatePendingReview()
                notice = AppNotice(
                    title: "Убрано из очереди",
                    message: "Текущая папка не может находиться внутри объекта из очереди очистки. Конфликтующие элементы убраны."
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
            notice = AppNotice(title: "Только просмотр", message: reason)
            return
        }
        guard let url = node.url else { return }
        let path = url.standardizedFileURL.path
        if let parent = collection.first(where: { selected in
            guard let selectedPath = selected.url?.standardizedFileURL.path else { return false }
            return path.hasPrefix(selectedPath + "/")
        }) {
            notice = AppNotice(
                title: "Уже включено",
                message: "Объект уже входит в выбранную папку «\(parent.name)»."
            )
            return
        }
        collection.removeAll { selected in
            guard let selectedPath = selected.url?.standardizedFileURL.path else { return false }
            return selectedPath.hasPrefix(path + "/")
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
                    title: "Нужен повторный анализ",
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
                            localFailure = "Не удалось зафиксировать идентичность перед перемещением: \(url.path)"
                            return
                        }
                        do {
                            var resultingURL: NSURL?
                            try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: &resultingURL)
                            guard let movedURL = resultingURL as URL?,
                                  FileIdentity.relocationIdentifier(for: movedURL) == expectedRelocationIdentity,
                                  (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == node.isDirectory else {
                                let resultPath = (resultingURL as URL?)?.path ?? "путь в Корзине не возвращён"
                                localFailure = "Не удалось подтвердить идентичность объекта после перемещения: \(url.path). Результат: \(resultPath). Автоматический возврат неизвестного объекта не выполнялся."
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
                    title: "Перемещено в Корзину",
                    message: "Объектов: \(outcome.successfulPaths.count). Данные можно восстановить через Finder, пока Корзина не очищена."
                )
            } else {
                let successLine = outcome.successfulPaths.isEmpty ? "" : "Успешно: \(outcome.successfulPaths.count).\n\n"
                notice = AppNotice(
                    title: "Операция завершена с замечаниями",
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
        return left == right
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
                name: "Домашняя папка",
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
                subtitle = "Сетевой том"
                icon = "network"
            } else if values?.volumeIsInternal == true {
                subtitle = "Внутренний диск"
                icon = "internaldrive.fill"
            } else if values?.volumeIsRemovable == true {
                subtitle = "Съёмный том"
                icon = "externaldrive.badge.plus"
            } else if values?.volumeIsInternal == false {
                subtitle = "Внешний диск"
                icon = "externaldrive.fill"
            } else {
                subtitle = "Другой том"
                icon = "externaldrive"
            }
            let labeledSubtitle = values?.volumeIsReadOnly == true ? subtitle + " · только чтение" : subtitle
            result.append(
                ScanSource(
                    id: volume.standardizedFileURL.path,
                    name: name.isEmpty ? "Диск" : name,
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
