import AppKit
import Foundation

/// The current user's real home folder.
///
/// Inside the App Sandbox `NSHomeDirectory()` returns the app container
/// (`~/Library/Containers/<bundle id>/Data`), so every safety rule that talks about
/// "the home folder" or "the user Library" resolves the path from the user database instead.
enum UserHome {
    static let url: URL = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            let path = String(cString: directory)
            if path.hasPrefix("/") {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
    }()

    static var path: String { url.path }
}

enum AppSandbox {
    /// True for the Mac App Store build, which runs with the App Sandbox entitlement.
    static let isActive: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
}

/// Folder permissions for the sandboxed (Mac App Store) build.
///
/// A sandboxed app can read or change a user location only after the person selects it in an
/// open panel. DiskBloom keeps a security-scoped bookmark for every granted folder, so the grant
/// survives relaunches. Outside the sandbox every check returns `true` and nothing is stored.
@MainActor
final class FolderAccess {
    static let shared = FolderAccess()

    private let defaultsKey = "DiskBloom.grantedFolderBookmarks"
    private var grantedPaths: Set<String> = []

    private init() {
        guard AppSandbox.isActive else { return }
        restoreBookmarks()
    }

    var isRestricted: Bool { AppSandbox.isActive }

    func hasAccess(to url: URL) -> Bool {
        guard AppSandbox.isActive else { return true }
        let path = url.standardizedFileURL.path
        return grantedPaths.contains { root in
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }

    var hasHomeAccess: Bool { hasAccess(to: UserHome.url) }

    /// Shows an open panel that starts at `url` and records the folder the person grants.
    /// Returns the granted folder, which can differ from `url` if the person picked another one.
    func requestAccess(to url: URL, title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.directoryURL = url
        guard panel.runModal() == .OK, let chosen = panel.url else { return nil }
        remember(chosen)
        return chosen.standardizedFileURL
    }

    /// Makes sure `folder` is covered by a grant, asking once if needed.
    func ensureAccess(to folder: URL, title: String, message: String) -> Bool {
        if hasAccess(to: folder) { return true }
        _ = requestAccess(to: folder, title: title, message: message)
        return hasAccess(to: folder)
    }

    func ensureHomeAccess(message: String) -> Bool {
        ensureAccess(
            to: UserHome.url,
            title: "Allow access to your home folder",
            message: message
        )
    }

    /// Records a folder the person selected in any open panel, so access survives relaunches.
    func remember(_ url: URL) {
        guard AppSandbox.isActive else { return }
        let normalized = url.standardizedFileURL
        grantedPaths.insert(normalized.path)
        guard let bookmark = try? normalized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        var stored = storedBookmarks()
        stored[normalized.path] = bookmark
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    private func storedBookmarks() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private func restoreBookmarks() {
        var refreshed: [String: Data] = [:]
        for (_, bookmark) in storedBookmarks() {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), url.startAccessingSecurityScopedResource() else { continue }
            let normalized = url.standardizedFileURL
            grantedPaths.insert(normalized.path)
            if isStale, let renewed = try? normalized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                refreshed[normalized.path] = renewed
            } else {
                refreshed[normalized.path] = bookmark
            }
        }
        UserDefaults.standard.set(refreshed, forKey: defaultsKey)
    }
}
