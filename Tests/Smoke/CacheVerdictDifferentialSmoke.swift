import Foundation

/// Runs the Swift classifier that existed before Specs/cache_verdict.t27 (the oracle) and the
/// classifier that asks the t27 spec over the same inputs, and fails on the first difference in
/// any field. With DISKBLOOM_DIFF_REAL=1 it also compares every real cache name on this Mac.
@main
@MainActor
struct CacheVerdictDifferentialSmoke {
    static func main() throws {
        var names: [String] = []
        names += CacheClassifier.keepNames
        names += CacheClassifier.keepNames.map { $0.uppercased() }
        names += ["com.apple.FileProviderDaemon.AppStoreService", "com.apple.security.agent", "com.apple.iCloudHelper",
                  "com.apple.keychainaccess", "com.apple.CloudPhotosConfiguration"]
        names += CacheClassifier.packageManagers.keys
        names += ["Homebrew", "HuggingFace", "PIP"]
        names += CacheClassifier.browsers.keys
        names += ["Google", "Mozilla", "com.apple.Safari", "com.google.Chrome"]
        names += ["com.vendor.app.ShipIt", "vendor_app-updater", "@vendor-app-updater", "com.vendor.updater",
                  "chrome_crashpad_handler", "SentryCrash", "com.crashlytics.data", "com.google.Chrome.ShipIt"]
        names += ["com.vendor.app", "com.vendor.app.helper", "com.vendor.gone", "com.apple.dt.Xcode", "com.apple.helpd",
                  "com.apple.Music", "Thunderbird", "Vendor App", "MysteryTool", "image.png", "INSTALLATION",
                  "ModuleCache.noindex", "CompilationCache.noindex", "MyApp-abcdefghijklmnopqrstuvwxyzab",
                  "MyApp-short", "org.swift.swiftpm", "x"]

        let applications = [
            app("Vendor App", "com.vendor.app"),
            app("Google Chrome", "com.google.Chrome"),
            app("Firefox", "org.mozilla.firefox"),
            app("Xcode", "com.apple.dt.Xcode"),
            app("Thunderbird", "org.mozilla.thunderbird"),
            app("Music", "com.apple.Music")
        ]
        let runningChoices: [Set<String>] = [
            [],
            ["com.vendor.app"],
            ["com.google.Chrome"],
            ["org.mozilla.firefox"],
            ["com.apple.dt.Xcode"],
            ["org.mozilla.thunderbird"],
            ["com.apple.Music"],
            Set(applications.compactMap(\.bundleIdentifier))
        ]
        let locations: [CacheLocationKind] = [.userCaches, .derivedData, .dotCache]

        var compared = 0
        for running in runningChoices {
            let context = CacheOwnerContext(applications: applications, runningIdentifiers: running)
            for name in names {
                for location in locations {
                    for isDirectory in [true, false] {
                        for unreadable in [0, 3] {
                            try compare(name, isDirectory, location, unreadable, context)
                            compared += 1
                        }
                    }
                }
            }
        }

        var real = 0
        if ProcessInfo.processInfo.environment["DISKBLOOM_DIFF_REAL"] == "1" {
            let home = UserHome.url
            var context = CacheOwnerContext.capture(homeURL: home)
            let roots: [(String, CacheLocationKind)] = [
                ("Library/Caches", .userCaches),
                ("Library/Developer/Xcode/DerivedData", .derivedData),
                (".cache", .dotCache)
            ]
            let cacheNames = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Caches").path)) ?? []
            context = context.resolvingWithLaunchServices(cacheNames.filter { OrphanBundleIdentifier.canonical($0) != nil })
            for (relative, location) in roots {
                let root = home.appendingPathComponent(relative, isDirectory: true)
                let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                for entry in entries {
                    let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    for unreadable in [0, 1] {
                        try compare(entry.lastPathComponent, isDirectory, location, unreadable, context)
                        real += 1
                    }
                }
            }
        }

        print("CACHE_VERDICT_DIFFERENTIAL_OK cases=\(compared) real=\(real)")
    }

    private static func app(_ name: String, _ identifier: String) -> InstalledApplication {
        InstalledApplication(
            url: URL(fileURLWithPath: "/Applications/\(name).app"),
            name: name,
            bundleIdentifier: identifier,
            version: "1",
            sourceLabel: "Fixture"
        )
    }

    private static func compare(
        _ name: String,
        _ isDirectory: Bool,
        _ location: CacheLocationKind,
        _ unreadable: Int,
        _ context: CacheOwnerContext
    ) throws {
        let old = LegacyCacheClassifier.classify(
            name: name, isDirectory: isDirectory, location: location, unreadableCount: unreadable, context: context
        )
        let new = CacheClassifier.classify(
            name: name, isDirectory: isDirectory, location: location, unreadableCount: unreadable, context: context
        )
        let fields: [(String, String, String)] = [
            ("verdict", old.verdict.rawValue, new.verdict.rawValue),
            ("category", old.category.rawValue, new.category.rawValue),
            ("reason", old.reason, new.reason),
            ("title", old.title, new.title),
            ("owner", old.owner?.name ?? "-", new.owner?.name ?? "-"),
            ("ownerID", old.owner?.bundleIdentifier ?? "-", new.owner?.bundleIdentifier ?? "-"),
            ("hint", old.cleanupHint ?? "-", new.cleanupHint ?? "-")
        ]
        for (field, before, after) in fields where before != after {
            throw NSError(
                domain: "CacheVerdictDifferentialSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MISMATCH \(field) for \(name) location=\(location) dir=\(isDirectory) unreadable=\(unreadable): Swift=\(before) t27=\(after)"]
            )
        }
    }
}
