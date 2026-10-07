import SwiftUI

@main
struct DiskBloomApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var uninstaller = AppUninstallerModel()
    @StateObject private var orphanedData = OrphanedAppDataModel()
    @StateObject private var duplicateFinder = DuplicateFinderModel()
    @StateObject private var cacheExplorer = CacheExplorerModel()
    @StateObject private var assistant = AssistantModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(uninstaller)
                .environmentObject(orphanedData)
                .environmentObject(duplicateFinder)
                .environmentObject(cacheExplorer)
                .environmentObject(assistant)
                .onAppear {
                    assistant.connect(
                        app: model,
                        caches: cacheExplorer,
                        uninstaller: uninstaller,
                        orphans: orphanedData
                    )
                }
                #if DEBUG
                .onAppear { ScreenshotAutomation.apply(model: model, duplicateFinder: duplicateFinder) }
                #endif
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button(assistant.isPresented ? "Hide Assistant" : "Show Assistant") { assistant.isPresented.toggle() }
                    .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Choose Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.workspaceSection != .diskMap)
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isScanning || model.workspaceSection != .diskMap)
                Divider()
                Button("Disk Map") { model.selectWorkspaceSection(.diskMap) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                            || cacheExplorer.isNavigationLocked
                    )
                Button("App Uninstaller") { model.selectWorkspaceSection(.appUninstaller) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                            || cacheExplorer.isNavigationLocked
                    )
                Button("Possible Leftovers") { model.selectWorkspaceSection(.orphanedAppData) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                            || cacheExplorer.isNavigationLocked
                    )
                Button("Duplicate Files") { model.selectWorkspaceSection(.duplicateFinder) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                            || cacheExplorer.isNavigationLocked
                    )
                Button("Caches") { model.selectWorkspaceSection(.cacheExplorer) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                            || cacheExplorer.isNavigationLocked
                    )
            }
        }
    }
}


#if DEBUG
/// Debug-only hook for producing App Store screenshots without driving the system open panel.
/// Compiled out of every release build (build.sh and the Xcode Release configuration).
///   -DiskBloomAutomationDuplicateRoot <folder>   opens Duplicate Files and scans <folder>
@MainActor
enum ScreenshotAutomation {
    static func apply(model: AppModel, duplicateFinder: DuplicateFinderModel) {
        guard let path = UserDefaults.standard.string(forKey: "DiskBloomAutomationDuplicateRoot") else { return }
        model.selectWorkspaceSection(.duplicateFinder)
        duplicateFinder.startScan(at: URL(fileURLWithPath: path, isDirectory: true))
    }
}
#endif
