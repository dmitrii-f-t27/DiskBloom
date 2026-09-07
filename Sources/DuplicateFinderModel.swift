import AppKit
import Combine
import Foundation

@MainActor
final class DuplicateFinderModel: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var result: DuplicateScanResult?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = DuplicateScanProgress(
        stage: .enumerating,
        examinedFileCount: 0,
        candidateFileCount: 0,
        processedCandidateCount: 0,
        bytesRead: 0,
        currentPath: ""
    )
    @Published var notice: AppNotice?

    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Выберите папку или локальный диск для поиска дубликатов"
        panel.prompt = "Найти дубликаты"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.directoryURL = rootURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startScan(at: url)
    }

    func startScan(at url: URL) {
        cancelScan()
        let normalized = url.standardizedFileURL
        let generation = UUID()
        let counter = DuplicateScanCounter()
        scanGeneration = generation
        rootURL = normalized
        result = nil
        isScanning = true
        progress = counter.snapshot()

        let worker = Task.detached(priority: .userInitiated) {
            try DuplicateFinderScanner().scan(root: normalized, counter: counter)
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
                let completed = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, scanGeneration == generation else { return }
                progress = counter.snapshot()
                result = completed
                isScanning = false
                scanTask = nil
            } catch is CancellationError {
                if scanGeneration == generation {
                    isScanning = false
                    scanTask = nil
                }
            } catch {
                if scanGeneration == generation {
                    isScanning = false
                    scanTask = nil
                    notice = AppNotice(
                        title: "Не удалось завершить поиск",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    func repeatScan() {
        guard let rootURL, !isScanning else { return }
        startScan(at: rootURL)
    }

    func cancelScan() {
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func revealInFinder(_ file: DuplicateFileSnapshot) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }
}
