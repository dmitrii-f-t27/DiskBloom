import AppKit
import Combine
import Foundation

/// How safe it is to clear one cache folder.
enum CacheVerdict: String, CaseIterable, Sendable {
    case safe
    case optional
    case quitFirst
    case keep
    case useTool

    var title: String {
        switch self {
        case .safe: "Safe to clear"
        case .optional: "Clear if you need space"
        case .quitFirst: "Quit the app first"
        case .keep: "Leave it"
        case .useTool: "Clear with its tool"
        }
    }

    var shortTitle: String {
        switch self {
        case .safe: "safe"
        case .optional: "optional"
        case .quitFirst: "in use"
        case .keep: "keep"
        case .useTool: "use tool"
        }
    }

    var explanation: String {
        switch self {
        case .safe:
            "The owner rebuilds it automatically. Nothing personal is stored here."
        case .optional:
            "Rebuilt when needed, but it may be downloaded again or the owner is not certain."
        case .quitFirst:
            "The owner is running and may be writing to it right now."
        case .keep:
            "Holds sign-in, sync or system state, or macOS protects part of it."
        case .useTool:
            "DiskBloom does not move this location. Use the command shown."
        }
    }

    /// The verdict's code in Specs/cache_verdict.t27; codes are also the list order.
    var t27Code: Int32 {
        switch self {
        case .safe: CV_SAFE
        case .optional: CV_OPTIONAL
        case .quitFirst: CV_QUIT_FIRST
        case .useTool: CV_USE_TOOL
        case .keep: CV_KEEP
        }
    }

    init(t27 code: UInt32) {
        self = Self.allCases.first { UInt32($0.t27Code) == code } ?? .keep
    }

    var isSelectable: Bool { cv_selectable(UInt32(t27Code)) }

    /// Sort order in the list: actionable first.
    var rank: Int { Int(t27Code) }
}

enum CacheCategory: String, CaseIterable, Sendable {
    case application
    case browser
    case developer
    case packageManager
    case system
    case updater
    case unknown

    var title: String {
        switch self {
        case .application: "App cache"
        case .browser: "Browser cache"
        case .developer: "Developer"
        case .packageManager: "Downloads & packages"
        case .system: "macOS"
        case .updater: "Updates & crash reports"
        case .unknown: "Unidentified"
        }
    }

    var t27Code: Int32 {
        switch self {
        case .application: CV_CAT_APPLICATION
        case .browser: CV_CAT_BROWSER
        case .developer: CV_CAT_DEVELOPER
        case .packageManager: CV_CAT_PACKAGE
        case .system: CV_CAT_SYSTEM
        case .updater: CV_CAT_UPDATER
        case .unknown: CV_CAT_UNKNOWN
        }
    }

    init(t27 code: UInt32) {
        self = Self.allCases.first { UInt32($0.t27Code) == code } ?? .unknown
    }

    var icon: String {
        switch self {
        case .application: "macwindow"
        case .browser: "globe"
        case .developer: "hammer.fill"
        case .packageManager: "shippingbox.fill"
        case .system: "apple.logo"
        case .updater: "arrow.triangle.2.circlepath"
        case .unknown: "questionmark.folder.fill"
        }
    }
}

/// One folder (or loose file) that holds cached data.
struct CacheItem: Identifiable, Sendable {
    let id: String
    let url: URL
    /// The folder the item lives in. Cleanup is checked against it as the analysis root.
    let locationRoot: URL
    let node: DiskNode
    let title: String
    let ownerName: String?
    let ownerBundleIdentifier: String?
    let category: CacheCategory
    let verdict: CacheVerdict
    let reason: String
    let cleanupHint: String?
    let lastModified: Date?

    var size: Int64 { node.size }
    var isSelectable: Bool { verdict.isSelectable }
}

struct CacheAnalysis: Sendable {
    let items: [CacheItem]
    let scannedAt: Date
    let examinedCount: Int

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func size(of verdict: CacheVerdict) -> Int64 {
        items.filter { $0.verdict == verdict }.reduce(0) { $0 + $1.size }
    }

    func count(of verdict: CacheVerdict) -> Int {
        items.filter { $0.verdict == verdict }.count
    }
}

struct CacheCleanupOutcome: Sendable {
    let movedPaths: [String]
    let failures: [String]
}

/// Everything the classifier needs to know about apps on this Mac.
struct CacheOwnerContext: Sendable {
    struct Owner: Sendable {
        let name: String
        let bundleIdentifier: String
    }

    /// Lowercased bundle ID → owner.
    let ownersByIdentifier: [String: Owner]
    /// Lowercased, space-free app name → owner.
    let ownersByName: [String: Owner]
    /// Lowercased bundle IDs of running apps.
    let runningIdentifiers: Set<String>

    /// `runningApplications` pairs a running app's name with its bundle ID, so an app installed
    /// outside the scanned folders still owns its cache while it runs.
    init(
        applications: [InstalledApplication],
        runningIdentifiers: Set<String>,
        runningApplications: [Owner] = []
    ) {
        var byIdentifier: [String: Owner] = [:]
        var byName: [String: Owner] = [:]
        for owner in runningApplications {
            byIdentifier[owner.bundleIdentifier.lowercased()] = owner
            byName[Self.nameKey(owner.name)] = owner
        }
        for application in applications {
            guard let identifier = application.bundleIdentifier, !identifier.isEmpty else { continue }
            let owner = Owner(name: application.name, bundleIdentifier: identifier)
            byIdentifier[identifier.lowercased()] = owner
            byName[Self.nameKey(application.name)] = owner
        }
        ownersByIdentifier = byIdentifier
        ownersByName = byName
        self.runningIdentifiers = Set(
            (runningIdentifiers.map { $0.lowercased() }) + runningApplications.map { $0.bundleIdentifier.lowercased() }
        )
    }

    private init(ownersByIdentifier: [String: Owner], ownersByName: [String: Owner], runningIdentifiers: Set<String>) {
        self.ownersByIdentifier = ownersByIdentifier
        self.ownersByName = ownersByName
        self.runningIdentifiers = runningIdentifiers
    }

    static func capture(homeURL: URL) -> CacheOwnerContext {
        let running = NSWorkspace.shared.runningApplications.compactMap { application -> Owner? in
            guard let identifier = application.bundleIdentifier, !identifier.isEmpty else { return nil }
            let name = application.localizedName ?? application.bundleURL?.deletingPathExtension().lastPathComponent ?? identifier
            return Owner(name: name, bundleIdentifier: identifier)
        }
        return CacheOwnerContext(
            applications: ApplicationCatalog.discover(homeURL: homeURL),
            runningIdentifiers: [],
            runningApplications: running
        )
    }

    /// Asks LaunchServices about bundle IDs the folder scan did not find, so an app installed
    /// anywhere on the Mac is not reported as uninstalled.
    func resolvingWithLaunchServices(_ identifiers: [String]) -> CacheOwnerContext {
        var byIdentifier = ownersByIdentifier
        var byName = ownersByName
        for identifier in identifiers where owner(forIdentifier: identifier) == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            let owner = Owner(name: name, bundleIdentifier: identifier)
            byIdentifier[identifier.lowercased()] = owner
            byName[Self.nameKey(name)] = owner
        }
        return CacheOwnerContext(ownersByIdentifier: byIdentifier, ownersByName: byName, runningIdentifiers: runningIdentifiers)
    }

    static func currentlyRunningIdentifiers() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    static func nameKey(_ name: String) -> String {
        name.lowercased().filter { !$0.isWhitespace }
    }

    /// Exact bundle ID, then the longest installed bundle ID that prefixes the entry
    /// (`com.vendor.app.ShipIt` belongs to `com.vendor.app`).
    func owner(forIdentifier identifier: String) -> Owner? {
        let key = identifier.lowercased()
        if let exact = ownersByIdentifier[key] { return exact }
        var drop = 1
        while let parent = T27Text.identifierPrefix(key, dropping: drop) {
            if let owner = ownersByIdentifier[parent] { return owner }
            drop += 1
        }
        return nil
    }

    func owner(forName name: String) -> Owner? {
        ownersByName[Self.nameKey(name)]
    }

    func isRunning(_ owner: Owner?) -> Bool {
        guard let owner else { return false }
        return isRunning(identifier: owner.bundleIdentifier)
    }

    func isRunning(identifier: String) -> Bool {
        runningIdentifiers.contains(identifier.lowercased())
    }
}

enum CacheLocationKind: Sendable {
    case userCaches
    case derivedData
    case dotCache

    var t27Code: Int32 {
        switch self {
        case .userCaches: CV_LOC_USER_CACHES
        case .derivedData: CV_LOC_DERIVED_DATA
        case .dotCache: CV_LOC_DOT_CACHE
        }
    }
}

/// Rules that turn a cache entry into a verdict with a plain-language reason.
enum CacheClassifier {
    struct Result: Sendable {
        let title: String
        let owner: CacheOwnerContext.Owner?
        let category: CacheCategory
        let verdict: CacheVerdict
        let reason: String
        let cleanupHint: String?
    }

    /// Sign-in, sync and system state that lives in Caches but must not be cleared casually.
    static let keepNames: Set<String> = [
        "cloudkit",
        "familycircle",
        "passkit",
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.akd",
        "com.apple.accountsd",
        "com.apple.appleaccountd",
        "com.apple.amsaccountsd",
        "com.apple.containermanagerd",
        "com.apple.nsurlsessiond",
        "com.apple.cache_delete",
        "com.apple.homekit",
        "com.apple.passd",
        "com.apple.trustd",
        "com.apple.screentimeagent",
        "com.apple.icloud.fmfd",
        "com.apple.findmy.fmipcore"
    ]

    static let keepPrefixes = [
        "com.apple.fileprovider",
        "com.apple.security",
        "com.apple.keychain",
        "com.apple.icloud",
        "com.apple.cloudphotos"
    ]

    /// Package managers and model downloaders: safe to clear, but the next install downloads again.
    static let packageManagers: [String: (title: String, hint: String?)] = [
        "homebrew": ("Homebrew downloads", "brew cleanup --prune=all"),
        "pip": ("pip downloads", "pip cache purge"),
        "pypoetry": ("Poetry cache", "poetry cache clear --all ."),
        "yarn": ("Yarn cache", "yarn cache clean"),
        "go-build": ("Go build cache", "go clean -cache"),
        "cocoapods": ("CocoaPods cache", "pod cache clean --all"),
        "ms-playwright": ("Playwright browsers", "npx playwright install (to download again)"),
        "bun": ("Bun cache", "bun pm cache rm"),
        "uv": ("uv cache", "uv cache clean"),
        "pnpm": ("pnpm cache", "pnpm store prune"),
        "deno": ("Deno cache", nil),
        "node-gyp": ("node-gyp headers", nil),
        "electron": ("Electron downloads", nil),
        "electron-builder": ("electron-builder downloads", nil),
        "zig": ("Zig cache", nil),
        "huggingface": ("Hugging Face models", "huggingface-cli delete-cache"),
        "torch": ("PyTorch downloads", nil),
        "prisma": ("Prisma engines", nil),
        "typescript": ("TypeScript type cache", nil),
        "puppeteer": ("Puppeteer browsers", nil),
        "jna": ("JNA native libraries", nil),
        "gradle": ("Gradle cache", nil),
        "composer": ("Composer cache", "composer clear-cache"),
        "codex-runtimes": ("Codex runtimes", nil),
        "gh": ("GitHub CLI cache", nil),
        "opencode": ("opencode cache", nil),
        "scapy": ("Scapy cache", nil)
    ]

    /// Cache folder names that belong to a browser, mapped to the browser's bundle ID.
    static let browsers: [String: (title: String, identifier: String)] = [
        "google": ("Google Chrome", "com.google.chrome"),
        "com.google.chrome": ("Google Chrome", "com.google.chrome"),
        "mozilla": ("Firefox", "org.mozilla.firefox"),
        "firefox": ("Firefox", "org.mozilla.firefox"),
        "com.apple.safari": ("Safari", "com.apple.safari"),
        "com.brave.browser": ("Brave", "com.brave.browser"),
        "com.microsoft.edgemac": ("Microsoft Edge", "com.microsoft.edgemac"),
        "company.thebrowser.browser": ("Arc", "company.thebrowser.browser"),
        "com.operasoftware.opera": ("Opera", "com.operasoftware.opera"),
        "com.vivaldi.vivaldi": ("Vivaldi", "com.vivaldi.vivaldi")
    ]

    /// Collects the facts about one cache entry and lets Specs/cache_verdict.t27 decide.
    static func classify(
        name: String,
        isDirectory: Bool,
        location: CacheLocationKind,
        unreadableCount: Int,
        context: CacheOwnerContext
    ) -> Result {
        let lower = name.lowercased()
        let isApple = T27Text.hasApplePrefix(lower)
        let looksLikeBundleIdentifier = OrphanBundleIdentifier.canonical(name) != nil
        var kind = UInt32(CV_KIND_OTHER)
        var owner: CacheOwnerContext.Owner?
        var ownerRunning = false
        var knownTitle: String?
        var hint: String?

        switch location {
        case .derivedData:
            owner = context.owner(forIdentifier: "com.apple.dt.Xcode")
                ?? CacheOwnerContext.Owner(name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
            ownerRunning = context.isRunning(identifier: "com.apple.dt.Xcode")
        case .dotCache:
            if let known = packageManagers[lower] {
                kind = UInt32(lower == "huggingface" ? CV_KIND_MODELS : CV_KIND_PACKAGE)
                knownTitle = known.title
                hint = known.hint
            }
        case .userCaches:
            if keepNames.contains(lower) || keepPrefixes.contains(where: { lower.hasPrefix($0) }) {
                kind = UInt32(CV_KIND_KEEP)
            } else if let known = packageManagers[lower] {
                kind = UInt32(lower == "huggingface" ? CV_KIND_MODELS : CV_KIND_PACKAGE)
                knownTitle = known.title
                hint = known.hint
            } else if let browser = browsers[lower] {
                kind = UInt32(CV_KIND_BROWSER)
                owner = context.owner(forIdentifier: browser.identifier)
                    ?? CacheOwnerContext.Owner(name: browser.title, bundleIdentifier: browser.identifier)
                ownerRunning = context.isRunning(owner)
                knownTitle = "\(browser.title) web cache"
            } else if lower.hasSuffix(".shipit") || lower.contains("updater") {
                kind = UInt32(CV_KIND_UPDATE_DOWNLOAD)
                owner = updaterOwner(name, context: context)
                ownerRunning = context.isRunning(owner)
            } else if lower.contains("crashpad") || lower == "sentrycrash" || lower.hasPrefix("com.crashlytics") {
                kind = UInt32(CV_KIND_CRASH_REPORTS)
                owner = updaterOwner(name, context: context)
                ownerRunning = context.isRunning(owner)
            } else {
                owner = looksLikeBundleIdentifier ? context.owner(forIdentifier: name) : context.owner(forName: name)
                ownerRunning = context.isRunning(owner)
            }
        }

        let facts = (
            UInt32(location.t27Code), kind, unreadableCount > 0, isApple, isDirectory,
            looksLikeBundleIdentifier, owner != nil, ownerRunning
        )
        let reason = cv_reason(facts.0, facts.1, facts.2, facts.3, facts.4, facts.5, facts.6, facts.7)
        let verdict = CacheVerdict(t27: cv_verdict_of_reason(reason))
        let category = CacheCategory(t27: cv_category(facts.0, facts.1, facts.2, facts.3, facts.4, facts.5, facts.6, facts.7))
        let friendly = friendlyTitle(for: name, location: location)
        let ownerName = owner?.name ?? "the app"

        switch reason {
        case UInt32(CV_R_PROTECTED):
            return Result(title: friendly, owner: nil, category: category, verdict: verdict,
                          reason: "macOS protects part of this folder, so its size is incomplete and DiskBloom will not move it.",
                          cleanupHint: nil)
        case UInt32(CV_R_XCODE_RUNNING):
            return Result(title: friendly, owner: owner, category: category, verdict: verdict,
                          reason: "Quit Xcode first: it may be building or indexing this project right now.", cleanupHint: nil)
        case UInt32(CV_R_XCODE_BUILD):
            return Result(title: friendly, owner: owner, category: category, verdict: verdict,
                          reason: "Xcode build products and indexes. Xcode rebuilds them on the next build.", cleanupHint: nil)
        case UInt32(CV_R_MODELS):
            return Result(title: knownTitle ?? name, owner: nil, category: category, verdict: verdict,
                          reason: "Downloaded AI models. Safe to clear, but each model downloads again the next time it is used, which can take long.",
                          cleanupHint: hint)
        case UInt32(CV_R_TOOL_CACHE):
            return Result(title: knownTitle ?? name, owner: nil, category: category, verdict: verdict,
                          reason: "Tool cache. Rebuilt on next use; files may be downloaded again.", cleanupHint: hint)
        case UInt32(CV_R_DOT_CACHE):
            return Result(title: name, owner: nil, category: category, verdict: verdict,
                          reason: "Command-line tool cache in ~/.cache. Rebuilt on next use; files may be downloaded again.",
                          cleanupHint: nil)
        case UInt32(CV_R_SYSTEM_STATE):
            return Result(title: friendly, owner: nil, category: category, verdict: verdict,
                          reason: "Holds iCloud, sign-in, sync or system state. macOS manages it; clearing it can sign you out or restart a sync.",
                          cleanupHint: nil)
        case UInt32(CV_R_PACKAGE_DOWNLOADS):
            return Result(title: knownTitle ?? name, owner: nil, category: category, verdict: verdict,
                          reason: "Package downloads. Safe to clear; the next install downloads them again.", cleanupHint: hint)
        case UInt32(CV_R_BROWSER_RUNNING), UInt32(CV_R_APP_RUNNING):
            return Result(title: knownTitle ?? ownerName, owner: owner, category: category, verdict: verdict,
                          reason: "Quit \(ownerName) first: it is using this cache right now.", cleanupHint: nil)
        case UInt32(CV_R_BROWSER_CACHE):
            return Result(title: knownTitle ?? ownerName, owner: owner, category: category, verdict: verdict,
                          reason: "Web page cache. Sign-ins, passwords and history are stored elsewhere and stay; pages load a little slower the first time.",
                          cleanupHint: nil)
        case UInt32(CV_R_UPDATE_IN_PROGRESS):
            return Result(title: owner.map { "\($0.name) updates" } ?? friendly, owner: owner, category: category, verdict: verdict,
                          reason: "Quit \(ownerName) first: an update may be in progress.", cleanupHint: nil)
        case UInt32(CV_R_UPDATES):
            return Result(title: owner.map { "\($0.name) updates" } ?? friendly, owner: owner, category: category, verdict: verdict,
                          reason: "Downloaded updates or crash reports. Apps download a fresh update when one is needed.", cleanupHint: nil)
        case UInt32(CV_R_APPLE):
            return Result(title: owner?.name ?? friendly, owner: owner, category: category, verdict: verdict,
                          reason: "Created by macOS or an Apple app. It is rebuilt when needed, so clearing it rarely frees space for long.",
                          cleanupHint: nil)
        case UInt32(CV_R_LOOSE_FILE):
            return Result(title: name, owner: owner, category: category, verdict: verdict,
                          reason: "A single cached file. Its owner recreates it if needed.", cleanupHint: nil)
        case UInt32(CV_R_APP_CACHE):
            return Result(title: ownerName, owner: owner, category: category, verdict: verdict,
                          reason: "App cache. \(ownerName) rebuilds it when needed; documents and settings are stored elsewhere.",
                          cleanupHint: nil)
        case UInt32(CV_R_UNINSTALLED):
            return Result(title: friendly, owner: nil, category: category, verdict: verdict,
                          reason: "Cache of an app that is not installed any more. Nothing will rebuild it.", cleanupHint: nil)
        default:
            return Result(title: name, owner: nil, category: category, verdict: verdict,
                          reason: "The owner could not be identified. Usually a cache, but look at the contents before clearing.",
                          cleanupHint: nil)
        }
    }

    /// Updater folders are named after the app (`com.vendor.app.ShipIt`, `vendor_app-updater`).
    private static func updaterOwner(_ name: String, context: CacheOwnerContext) -> CacheOwnerContext.Owner? {
        let strippedName = name
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "-updater", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
        return context.owner(forIdentifier: name) ?? context.owner(forName: strippedName)
    }

    static func friendlyTitle(for name: String, location: CacheLocationKind) -> String {
        if location == .derivedData {
            switch name {
            case "ModuleCache.noindex": return "Module cache"
            case "CompilationCache.noindex": return "Compilation cache"
            case "SymbolCache.noindex": return "Symbol cache"
            default: break
            }
            // Xcode names project folders "<Project>-<28 lowercase letters>".
            if let dash = name.lastIndex(of: "-") {
                let suffix = name[name.index(after: dash)...]
                if suffix.count == 28, suffix.allSatisfy({ $0.isLowercase && $0.isLetter }) {
                    return String(name[..<dash])
                }
            }
            return name
        }
        return name
    }
}

/// Locations DiskBloom never moves, shown with the command that clears them properly.
struct CacheToolHint: Sendable {
    let relativePath: String
    let title: String
    let hint: String
    let category: CacheCategory

    static let all: [CacheToolHint] = [
        CacheToolHint(relativePath: ".npm/_cacache", title: "npm cache", hint: "npm cache clean --force", category: .packageManager),
        CacheToolHint(relativePath: ".cargo/registry/cache", title: "Cargo downloads", hint: "cargo install cargo-cache && cargo cache --autoclean", category: .packageManager),
        CacheToolHint(relativePath: ".gradle/caches", title: "Gradle cache", hint: "gradle --stop, then remove ~/.gradle/caches", category: .packageManager),
        CacheToolHint(relativePath: "Library/Developer/CoreSimulator/Caches", title: "Simulator caches", hint: "xcrun simctl delete unavailable", category: .developer),
        CacheToolHint(relativePath: "Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device support", hint: "Remove versions you no longer debug in Finder (Xcode downloads them again)", category: .developer)
    ]
}

enum CacheAnalyzer {
    static func analyze(
        homeURL: URL = UserHome.url,
        progress: ScanCounter,
        contextOverride: CacheOwnerContext? = nil
    ) throws -> CacheAnalysis {
        let home = homeURL.standardizedFileURL
        var context = contextOverride ?? CacheOwnerContext.capture(homeURL: home)
        let locations: [(URL, CacheLocationKind)] = [
            (home.appendingPathComponent("Library/Caches", isDirectory: true), .userCaches),
            (home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true), .derivedData),
            (home.appendingPathComponent(".cache", isDirectory: true), .dotCache)
        ]
        var items: [CacheItem] = []
        var examined = 0

        if contextOverride == nil {
            let cacheNames = (try? FileManager.default.contentsOfDirectory(atPath: locations[0].0.path)) ?? []
            context = context.resolvingWithLaunchServices(
                cacheNames.filter { OrphanBundleIdentifier.canonical($0) != nil }
            )
        }

        for (root, kind) in locations {
            try checkCancellation()
            guard !AppRemovalPathSafety.pathHasSymlinkedComponent(root),
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: root,
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try checkCancellation()
                examined += 1
                guard let values = try? entry.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
                ]), values.isSymbolicLink != true else { continue }
                var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
                let node = try scanner.scan(root: entry, counter: progress).root
                guard node.size > 0 else { continue }
                let result = CacheClassifier.classify(
                    name: entry.lastPathComponent,
                    isDirectory: values.isDirectory == true,
                    location: kind,
                    unreadableCount: node.unreadableCount,
                    context: context
                )
                items.append(
                    CacheItem(
                        id: entry.standardizedFileURL.path,
                        url: entry.standardizedFileURL,
                        locationRoot: root.standardizedFileURL,
                        node: node,
                        title: result.title,
                        ownerName: result.owner?.name,
                        ownerBundleIdentifier: result.owner?.bundleIdentifier,
                        category: result.category,
                        verdict: result.verdict,
                        reason: result.reason,
                        cleanupHint: result.cleanupHint,
                        lastModified: values.contentModificationDate
                    )
                )
            }
        }

        for hint in CacheToolHint.all {
            try checkCancellation()
            let url = home.appendingPathComponent(hint.relativePath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !AppRemovalPathSafety.pathHasSymlinkedComponent(url) else { continue }
            examined += 1
            var scanner = DiskScanner(maxDepth: 3, maxChildrenPerFolder: 24)
            let node = try scanner.scan(root: url, counter: progress).root
            guard node.size > 0 else { continue }
            items.append(
                CacheItem(
                    id: url.path,
                    url: url,
                    locationRoot: url.deletingLastPathComponent(),
                    node: node,
                    title: hint.title,
                    ownerName: nil,
                    ownerBundleIdentifier: nil,
                    category: hint.category,
                    verdict: .useTool,
                    reason: "DiskBloom does not move this location; its tool keeps an index of it.",
                    cleanupHint: hint.hint,
                    lastModified: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                )
            )
        }

        items.sort {
            if $0.verdict.rank != $1.verdict.rank { return $0.verdict.rank < $1.verdict.rank }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.id < $1.id
        }
        return CacheAnalysis(items: items, scannedAt: Date(), examinedCount: examined)
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}

enum CachePolicy {
    /// Re-checks one cache item immediately before it is moved to the Trash.
    static func validate(
        _ item: CacheItem,
        runningIdentifiers: Set<String>,
        candidateURL: URL? = nil
    ) -> String? {
        let candidate = (candidateURL ?? item.url).standardizedFileURL
        let block = cv_move_block(
            UInt32(item.verdict.t27Code),
            item.ownerBundleIdentifier.map { runningIdentifiers.contains($0.lowercased()) } ?? false,
            item.category == .developer,
            runningIdentifiers.contains("com.apple.dt.xcode"),
            T27Text.same(candidate.path, item.url.standardizedFileURL.path),
            T27Text.same(candidate.deletingLastPathComponent().standardizedFileURL.path, item.locationRoot.path),
            AppRemovalPathSafety.pathHasSymlinkedComponent(candidate)
        )
        switch block {
        case UInt32(CV_MOVE_ALLOWED):
            break
        case UInt32(CV_MOVE_NOT_SELECTABLE):
            return "\(item.url.path): \(item.verdict.title.lowercased()) — DiskBloom does not move it."
        case UInt32(CV_MOVE_OWNER_RUNNING):
            return "Quit \(item.ownerName ?? item.ownerBundleIdentifier ?? "the app") first: it started using \(item.url.path)."
        case UInt32(CV_MOVE_XCODE_RUNNING):
            return "Quit Xcode first: \(item.url.path) belongs to its build data."
        case UInt32(CV_MOVE_PATH_CHANGED):
            return "The coordinated path changed: \(item.url.path)"
        case UInt32(CV_MOVE_NOT_DIRECT_CHILD):
            return "The item is no longer directly inside \(item.locationRoot.path)."
        default:
            return "The path contains a symbolic link: \(candidate.path)"
        }
        return DeletionPolicy.validateImmediatelyBeforeTrash(
            item.node,
            scanRootURL: item.locationRoot,
            candidateURL: candidate
        )
    }
}

enum CacheCleanupCoordinator {
    typealias TrashMover = @Sendable (URL) throws -> URL?
    typealias RunningResolver = @Sendable () -> Set<String>

    static let systemTrashMover: TrashMover = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    /// Items are independent caches, so one failure does not stop the rest.
    static func moveToTrash(
        items: [CacheItem],
        runningResolver: RunningResolver,
        mover: TrashMover = systemTrashMover
    ) -> CacheCleanupOutcome {
        var moved: [String] = []
        var failures: [String] = []
        for item in items.sorted(by: { $0.url.path < $1.url.path }) {
            let url = item.url
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var localFailure: String?
            var didMove = false
            coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                if let reason = CachePolicy.validate(
                    item,
                    runningIdentifiers: runningResolver(),
                    candidateURL: coordinatedURL
                ) {
                    localFailure = reason
                    return
                }
                guard let expectedIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                    localFailure = "Could not capture the identity before moving: \(url.path)"
                    return
                }
                do {
                    let movedURL = try mover(coordinatedURL)
                    guard let movedURL,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedIdentity else {
                        let result = movedURL?.path ?? "no Trash path was returned"
                        localFailure = "Could not confirm the item after moving: \(url.path). Result: \(result). Check the Trash."
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
                moved.append(url.path)
            }
        }
        return CacheCleanupOutcome(movedPaths: moved, failures: failures)
    }
}

@MainActor
final class CacheExplorerModel: ObservableObject {
    @Published private(set) var analysis: CacheAnalysis?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isReviewing = false
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var progress = ScanProgress(itemCount: 0, currentPath: "")
    @Published var verdictFilter: CacheVerdict?
    @Published var highlightedIDs: Set<String> = []
    @Published var showingReview = false
    @Published var notice: AppNotice?

    private var analysisTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var generation = UUID()
    private let homeURL = UserHome.url

    var items: [CacheItem] { analysis?.items ?? [] }

    var visibleItems: [CacheItem] {
        guard let verdictFilter else { return items }
        return items.filter { $0.verdict == verdictFilter }
    }

    var selectedItems: [CacheItem] { items.filter { selectedIDs.contains($0.id) } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var isNavigationLocked: Bool { isReviewing || isMovingToTrash || showingReview }

    func startAnalysis() {
        guard !isReviewing, !isMovingToTrash else { return }
        guard FolderAccess.shared.ensureHomeAccess(
            message: "DiskBloom measures the caches in your Library and ~/.cache. Select your home folder and click Grant Access."
        ) else {
            notice = AppNotice(
                title: "Home folder access needed",
                message: "Caches can be measured only with access to your home folder. Choose your home folder itself in the panel."
            )
            return
        }
        analysisTask?.cancel()
        let current = UUID()
        generation = current
        isScanning = true
        selectedIDs = []
        highlightedIDs = []
        progress = ScanProgress(itemCount: 0, currentPath: homeURL.appendingPathComponent("Library/Caches").path)
        let counter = ScanCounter()
        let localHome = homeURL
        let worker = Task.detached(priority: .userInitiated) {
            try CacheAnalyzer.analyze(homeURL: localHome, progress: counter)
        }
        analysisTask = Task { [weak self] in
            guard let self else {
                worker.cancel()
                return
            }
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let self, self.generation == current else { break }
                    self.progress = counter.snapshot()
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard generation == current, !Task.isCancelled else { return }
                analysis = result
                isScanning = false
            } catch is CancellationError {
                if generation == current { isScanning = false }
            } catch {
                guard generation == current else { return }
                isScanning = false
                notice = AppNotice(title: "Caches could not be measured", message: error.localizedDescription)
            }
        }
    }

    /// Waits until the running analysis finishes (used by the assistant).
    func waitForAnalysis(timeout: Duration = .seconds(180)) async {
        let deadline = ContinuousClock.now + timeout
        while isScanning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func cancelAnalysis() {
        generation = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        isScanning = false
    }

    func toggle(_ item: CacheItem) {
        guard item.isSelectable, !isNavigationLocked else { return }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    /// Selects items by ID; returns the ones that were selectable.
    @discardableResult
    func select(ids: [String]) -> [CacheItem] {
        guard !isNavigationLocked else { return [] }
        let wanted = Set(ids)
        let chosen = items.filter { wanted.contains($0.id) && $0.isSelectable }
        selectedIDs.formUnion(chosen.map(\.id))
        highlightedIDs = Set(chosen.map(\.id))
        return chosen
    }

    func selectAll(verdict: CacheVerdict) {
        guard verdict.isSelectable, !isNavigationLocked else { return }
        let ids = items.filter { $0.verdict == verdict }.map(\.id)
        selectedIDs.formUnion(ids)
        highlightedIDs = Set(ids)
    }

    func clearSelection() {
        guard !isNavigationLocked else { return }
        selectedIDs = []
    }

    func reveal(_ item: CacheItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func copyHint(_ item: CacheItem) {
        guard let hint = item.cleanupHint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint, forType: .string)
    }

    func requestReview() {
        let chosen = selectedItems
        guard !chosen.isEmpty, !isScanning, !isMovingToTrash, !isReviewing else { return }
        reviewTask?.cancel()
        isReviewing = true
        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                let running = CacheOwnerContext.currentlyRunningIdentifiers()
                return chosen.compactMap { CachePolicy.validate($0, runningIdentifiers: running) }
            }.value
            guard !Task.isCancelled else { return }
            isReviewing = false
            if failures.isEmpty {
                showingReview = true
            } else {
                notice = AppNotice(
                    title: "Measure again",
                    message: failures.joined(separator: "\n\n") + "\n\nCaches change while apps run. Click Measure Again, then review."
                )
            }
        }
    }

    func moveReviewedItemsToTrash() {
        let chosen = selectedItems
        guard showingReview, !chosen.isEmpty, !isMovingToTrash else { return }
        showingReview = false
        isMovingToTrash = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                CacheCleanupCoordinator.moveToTrash(
                    items: chosen,
                    runningResolver: { CacheOwnerContext.currentlyRunningIdentifiers() }
                )
            }.value
            isMovingToTrash = false
            let movedIDs = Set(outcome.movedPaths)
            selectedIDs.subtract(movedIDs)
            if let current = analysis {
                analysis = CacheAnalysis(
                    items: current.items.filter { !movedIDs.contains($0.id) },
                    scannedAt: current.scannedAt,
                    examinedCount: current.examinedCount
                )
            }
            let movedSize = chosen.filter { movedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
            if outcome.failures.isEmpty {
                notice = AppNotice(
                    title: "Moved to Trash",
                    message: "\(outcome.movedPaths.count) \(Plural.objects(outcome.movedPaths.count)), \(ByteFormat.string(movedSize)). Space is freed when you empty the Trash; until then everything can be put back from Finder."
                )
            } else {
                let successLine = outcome.movedPaths.isEmpty ? "" : "Moved: \(outcome.movedPaths.count) (\(ByteFormat.string(movedSize))).\n\n"
                notice = AppNotice(
                    title: "Finished with issues",
                    message: successLine + outcome.failures.joined(separator: "\n\n")
                )
            }
        }
    }
}
