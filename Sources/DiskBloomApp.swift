import SwiftUI

@main
struct DiskBloomApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var uninstaller = AppUninstallerModel()
    @StateObject private var orphanedData = OrphanedAppDataModel()
    @StateObject private var duplicateFinder = DuplicateFinderModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(uninstaller)
                .environmentObject(orphanedData)
                .environmentObject(duplicateFinder)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Выбрать папку…") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command])
                    .disabled(model.workspaceSection != .diskMap)
                Button("Повторить анализ") { model.rescan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(model.isScanning || model.workspaceSection != .diskMap)
                Divider()
                Button("Карта диска") { model.selectWorkspaceSection(.diskMap) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                    )
                Button("Удаление приложений") { model.selectWorkspaceSection(.appUninstaller) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                    )
                Button("Возможные остатки") { model.selectWorkspaceSection(.orphanedAppData) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                    )
                Button("Дубликаты файлов") { model.selectWorkspaceSection(.duplicateFinder) }
                    .disabled(
                        uninstaller.isMovingToTrash
                            || uninstaller.isReviewing
                            || uninstaller.showingReview
                            || uninstaller.showingOutcomeReport
                            || orphanedData.isNavigationLocked
                    )
            }
        }
    }
}
