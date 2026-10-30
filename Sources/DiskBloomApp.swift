import AppKit
import SwiftUI

@main
struct DiskBloomApp: App {
    @NSApplicationDelegateAdaptor(DiskBloomAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var uninstaller: AppUninstallerModel
    @StateObject private var orphanedData: OrphanedAppDataModel
    @StateObject private var duplicateFinder = DuplicateFinderModel()
    @StateObject private var cacheExplorer: CacheExplorerModel
    @StateObject private var assistant = AssistantModel()
    @State private var memoryMonitor: MemoryMonitorModel
    @State private var menuBarLabel: MenuBarLabelModel
    @State private var monitorController = MonitorModeController()

    init() {
        // The models the menu bar controller reads are made here, so it can start before any window exists.
        // Their inits only set properties. No AppKit call here: NSApp may still be nil.
        let app = AppModel()
        let uninstallerModel = AppUninstallerModel()
        let orphanedModel = OrphanedAppDataModel()
        let cacheModel = CacheExplorerModel()
        _model = StateObject(wrappedValue: app)
        _uninstaller = StateObject(wrappedValue: uninstallerModel)
        _orphanedData = StateObject(wrappedValue: orphanedModel)
        _cacheExplorer = StateObject(wrappedValue: cacheModel)

        let monitor = MemoryMonitorModel()
        let label = MenuBarLabelModel()
        _memoryMonitor = State(initialValue: monitor)
        _menuBarLabel = State(initialValue: label)
        if MenuBarController.shared == nil {
            let facts: @MainActor () -> RelaunchFacts = {
                let windowOpen = NSApp?.windows.contains {
                    mm_window_open($0.canBecomeMain, $0 is NSPanel, $0.isVisible, $0.isMiniaturized)
                } ?? true
                let keepsToolState = app.notice != nil || app.isReviewingSelection || app.showingTrashReview
                    || !uninstallerModel.selectedItemIDs.isEmpty || uninstallerModel.isReviewing
                    || uninstallerModel.showingReview || uninstallerModel.showingOutcomeReport
                    || uninstallerModel.notice != nil
                    || !orphanedModel.selectedItemIDs.isEmpty || orphanedModel.isNavigationLocked
                    || orphanedModel.notice != nil
                    || !cacheModel.selectedIDs.isEmpty || cacheModel.isNavigationLocked || cacheModel.notice != nil
                return RelaunchFacts(
                    windowOpen: windowOpen,
                    appHidden: NSApp?.isHidden ?? true,
                    canQuit: mm_can_quit(app.isMovingToTrash, uninstallerModel.isMovingToTrash,
                                         orphanedModel.isMovingToTrash, cacheModel.isMovingToTrash),
                    queued: Int64(app.collection.count),
                    keepsToolState: keepsToolState
                )
            }
            #if DEBUG
            let debugMarker = UserDefaults.standard.bool(forKey: "DiskBloomAutomationMenuBar")
            #else
            let debugMarker = false
            #endif
            MenuBarController.shared = MenuBarController(
                monitor: monitor,
                display: label,
                sampler: { MemorySampler.system() },
                clock: { MenuBarClock.now() },
                heartbeat: MenuBarHeartbeat(now: MenuBarClock.now()),
                scheduler: RunLoopTickScheduler(),
                log: MenuBarLog.system,
                facts: facts,
                debugMarker: debugMarker
            )
        }
    }

    var body: some Scene {
        mainWindowForThisSystem

        // The memory monitor in the menu bar (Specs/memory_rules.t27).
        MenuBarExtra {
            MemoryMenuPanel(
                monitor: memoryMonitor,
                canQuit: mm_can_quit(model.isMovingToTrash, uninstaller.isMovingToTrash,
                                     orphanedData.isMovingToTrash, cacheExplorer.isMovingToTrash),
                opened: { MenuBarController.shared?.panelOpened() },
                closed: { MenuBarController.shared?.panelClosed() }
            )
        } label: {
            MemoryMenuLabel(model: menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }

    /// A relaunched copy starts without its window on macOS 15 and later (`defaultLaunchBehavior`); macOS 14
    /// always gets the plain scene. A SceneBuilder has no `if #available ... else` and rejects
    /// `if #unavailable`, so this builds by hand what the compiler generates for `if #available`.
    private var mainWindowForThisSystem: some Scene {
        let scene: any Scene & _LimitedAvailabilitySceneMarker
        if #available(macOS 15.0, *) {
            scene = SceneBuilder.buildLimitedAvailability(
                mainWindow.defaultLaunchBehavior(MenuBarRelaunch.suppressesLaunchWindow ? .suppressed : .automatic))
        } else {
            scene = SceneBuilder.buildLimitedAvailability(mainWindow)
        }
        return SceneBuilder.buildOptional(scene)
    }

    private var mainWindow: some Scene {
        WindowGroup(id: MainWindow.sceneID) {
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
                .onAppear {
                    monitorController.attach(app: model)
                    monitorController.windowAppeared()
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

/// Starts the menu bar controller once AppKit is up (`NSApp` is nil while `DiskBloomApp.init` runs). When
/// DiskBloom is opened again in a copy started without its window, it brings the window up
/// (`mm_reopen_opens`); every other copy keeps the macOS default. It implements no terminate, untitled-file
/// or last-window method.
@MainActor
final class DiskBloomAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuBarController.shared?.install()
    }

    /// macOS sends this when DiskBloom is opened again while it runs (Finder, an alias, Spotlight, the Dock).
    /// A copy started without its window (`.defaultLaunchBehavior(.suppressed)`) gets no window from it:
    /// SwiftUI presents none for a suppressed scene (live check 2026-10-30), so DiskBloom brings the window up
    /// itself, unless one is already on screen. It returns false then, so that macOS does not also act.
    /// For every other copy (all of macOS 14, and every copy the watchdog did not start) it returns true and
    /// does nothing else: the macOS default stays as in DiskBloom 1.6. The system's `hasVisibleWindows` is not
    /// used for the decision, because the menu bar item's own windows can make it true.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let shown = MainWindow.find().shown != nil
        let opens = MainWindow.reopenOpens(launchSuppressed: MenuBarRelaunch.launchSuppressed, windowShown: shown)
        #if DEBUG
        MenuBarAutomation.note(
            "reopen visible=\(flag ? 1 : 0) shown=\(shown ? 1 : 0) "
                + "suppressed=\(MenuBarRelaunch.launchSuppressed ? 1 : 0) opens=\(opens ? 1 : 0)"
        )
        #endif
        if opens { MainWindow.open() }
        return !opens
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
