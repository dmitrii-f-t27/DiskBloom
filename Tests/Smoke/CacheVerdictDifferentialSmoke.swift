import Foundation

/// Runs the Swift classifier that existed before Specs/cache_verdict.t27 (the oracle) and the
/// classifier that asks the t27 spec over the same inputs, and fails on the first difference in
/// any field. With DISKBLOOM_DIFF_REAL=1 it also compares every real cache name on this Mac.
@main
@MainActor
struct CacheVerdictDifferentialSmoke {
    static func main() throws {
        var names: [String] = []
        names += LegacyCacheTables.keepNames
        names += LegacyCacheTables.keepNames.map { $0.uppercased() }
        names += ["com.apple.FileProviderDaemon.AppStoreService", "com.apple.security.agent", "com.apple.iCloudHelper",
                  "com.apple.keychainaccess", "com.apple.CloudPhotosConfiguration"]
        names += LegacyCacheTables.packageManagers.keys
        names += ["Homebrew", "HuggingFace", "PIP"]
        names += LegacyCacheTables.browsers.keys
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

        // The tables themselves, row by row, and the name rules on a generated corpus.
        var tableRows = 0
        for name in LegacyCacheTables.keepNames {
            try check("keep \(name)", true, CacheClassifier.find(CV_TABLE_KEEP, name) != nil)
            tableRows += 1
        }
        for prefix in LegacyCacheTables.keepPrefixes {
            try check("keep prefix \(prefix)", true, CacheClassifier.find(CV_TABLE_KEEP_PREFIX, prefix + ".x") != nil)
            tableRows += 1
        }
        for (name, entry) in LegacyCacheTables.packageManagers {
            let row = CacheClassifier.find(CV_TABLE_PACKAGE, name)
            try check("package \(name)", entry.title, row.flatMap { CacheClassifier.rowText($0, 1) } ?? "-")
            try check("package hint \(name)", entry.hint ?? "-", row.flatMap { CacheClassifier.rowText($0, 2) } ?? "-")
            tableRows += 1
        }
        for (name, entry) in LegacyCacheTables.browsers {
            let row = CacheClassifier.find(CV_TABLE_BROWSER, name)
            try check("browser \(name)", entry.title, row.flatMap { CacheClassifier.rowText($0, 1) } ?? "-")
            try check("browser id \(name)", entry.identifier, row.flatMap { CacheClassifier.rowText($0, 2) } ?? "-")
            tableRows += 1
        }
        try check("tool count", LegacyCacheToolHint.all.count, CacheToolHint.all.count)
        for (before, after) in zip(LegacyCacheToolHint.all, CacheToolHint.all) {
            try check("tool \(before.relativePath)", "\(before.relativePath)|\(before.title)|\(before.hint)|\(before.category)",
                      "\(after.relativePath)|\(after.title)|\(after.hint)|\(after.category)")
            tableRows += 1
        }
        var generator = SplitMix(seed: 0xCAC4E)
        let alphabet = ["a", "z", "q", "A", "-", "_", "@", ".", "é", "e\u{301}", "ß", "Я", "1", " ", "U", "P", "D", "-updater", "-UPDATER", "updater"]
        var corpus = names
        for _ in 0..<12_000 {
            let length = Int(generator.next() % 12)
            corpus.append((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }.joined())
        }
        let lower = "abcdefghijklmnopqrstuvwxyz"
        for _ in 0..<2_000 {
            let suffixLength = 26 + Int(generator.next() % 5)
            let suffix = String((0..<suffixLength).map { _ in lower.randomElement(using: &generator)! })
            corpus.append("Proj\(generator.next() % 3 == 0 ? "é" : "")-\(suffix)")
            corpus.append("A-B-\(suffix)")
            corpus.append("X-\(suffix.uppercased())")
        }
        for name in corpus {
            try check("friendly \(name)", LegacyCacheTables.friendlyTitle(for: name, location: .derivedData),
                      CacheClassifier.friendlyTitle(for: name, location: .derivedData))
            let legacyStripped = name
                .replacingOccurrences(of: "@", with: "")
                .replacingOccurrences(of: "-updater", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "_", with: " ")
            let newStripped = T27Text.withBytes(name) { text, length in T27Text.output { cv_updater_owner_name(text, length, $0) } } ?? ""
            try check("stripped \(name)", legacyStripped, newStripped)
            let context = CacheOwnerContext(applications: applications, runningIdentifiers: [])
            for location in locations {
                try compare(name, true, location, 0, context)
            }
            tableRows += 1
        }

        print("CACHE_VERDICT_DIFFERENTIAL_OK cases=\(compared) real=\(real) tables+corpus=\(tableRows)")
    }

    private static func check<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else {
            throw NSError(domain: "CacheVerdictDifferentialSmoke", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "MISMATCH \(label): Swift=\(before) t27=\(after)"])
        }
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
