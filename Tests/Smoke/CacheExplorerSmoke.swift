import Foundation

private final class FixtureTrash: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let destination: URL

    init(destination: URL) {
        self.destination = destination
    }

    func move(_ source: URL) throws -> URL? {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("\(current)-\(source.lastPathComponent)")
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }
}

@main
@MainActor
struct CacheExplorerSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw failure("fixture root required")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let derived = home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let dotCache = home.appendingPathComponent(".cache", isDirectory: true)

        try write(caches, "io.cachefixture.installed/data.bin", bytes: 4096)
        try write(caches, "io.cachefixture.running/data.bin", bytes: 2048)
        try write(caches, "io.cachefixture.gone/data.bin", bytes: 1024)
        try write(caches, "io.cachefixture.installed.ShipIt/update.zip", bytes: 512)
        try write(caches, "CloudKit/state.db", bytes: 512)
        try write(caches, "Homebrew/downloads/pkg.tar.gz", bytes: 8192)
        try write(caches, "Google/Chrome/Default/Cache/blob", bytes: 1024)
        try write(caches, "MysteryTool/blob", bytes: 256)
        try write(derived, "MyApp-abcdefghijklmnopqrstuvwxyzab/Build/out.o", bytes: 2048)
        try write(dotCache, "uv/wheels/a.whl", bytes: 1024)
        try write(home, ".npm/_cacache/index", bytes: 128)

        let applications = [
            InstalledApplication(
                url: fixture.appendingPathComponent("Apps/Installed.app"),
                name: "Installed Fixture",
                bundleIdentifier: "io.cachefixture.installed",
                version: "1",
                sourceLabel: "Fixture"
            ),
            InstalledApplication(
                url: fixture.appendingPathComponent("Apps/Running.app"),
                name: "Running Fixture",
                bundleIdentifier: "io.cachefixture.running",
                version: "1",
                sourceLabel: "Fixture"
            )
        ]
        let context = CacheOwnerContext(
            applications: applications,
            runningIdentifiers: ["io.cachefixture.running", "com.google.Chrome"]
        )
        let analysis = try CacheAnalyzer.analyze(homeURL: home, progress: ScanCounter(), contextOverride: context)

        func item(_ name: String) throws -> CacheItem {
            guard let found = analysis.items.first(where: { $0.url.lastPathComponent == name }) else {
                throw failure("missing cache item \(name)")
            }
            return found
        }

        try expect(item("io.cachefixture.installed").verdict == .safe, "installed, idle app cache is safe")
        try expect(item("io.cachefixture.installed").ownerName == "Installed Fixture", "owner resolved by bundle ID")
        try expect(item("io.cachefixture.running").verdict == .quitFirst, "running app cache needs quitting")
        try expect(item("io.cachefixture.gone").verdict == .safe, "cache without an installed app is safe")
        try expect(item("io.cachefixture.gone").reason.contains("not installed"), "uninstalled owner is explained")
        try expect(item("io.cachefixture.installed.ShipIt").category == .updater, "ShipIt is an updater cache")
        try expect(item("io.cachefixture.installed.ShipIt").ownerName == "Installed Fixture", "ShipIt belongs to its parent app")
        try expect(item("CloudKit").verdict == .keep, "CloudKit is kept")
        try expect(item("Homebrew").verdict == .optional, "Homebrew downloads are optional")
        try expect(item("Homebrew").cleanupHint == "brew cleanup --prune=all", "Homebrew hint")
        try expect(item("Google").verdict == .quitFirst, "Chrome cache while Chrome runs")
        try expect(item("MysteryTool").verdict == .optional, "unknown owner is optional")
        try expect(item("MyApp-abcdefghijklmnopqrstuvwxyzab").title == "MyApp", "DerivedData project name")
        try expect(item("MyApp-abcdefghijklmnopqrstuvwxyzab").verdict == .safe, "DerivedData safe while Xcode is closed")
        try expect(item("uv").verdict == .optional, "~/.cache tool cache is optional")
        try expect(item("_cacache").verdict == .useTool, "npm cache is shown with its command only")
        try expect(analysis.items.first?.verdict == .safe, "safe caches are listed first")

        let safeItem = try item("io.cachefixture.installed")
        try expect(CachePolicy.validate(safeItem, runningIdentifiers: []) == nil, "unchanged safe cache passes")
        try expect(
            CachePolicy.validate(safeItem, runningIdentifiers: ["io.cachefixture.installed"]) != nil,
            "owner that started after the scan blocks the move"
        )
        try expect(CachePolicy.validate(try item("CloudKit"), runningIdentifiers: []) != nil, "kept cache is never moved")
        try expect(CachePolicy.validate(try item("_cacache"), runningIdentifiers: []) != nil, "tool-only cache is never moved")
        let derivedItem = try item("MyApp-abcdefghijklmnopqrstuvwxyzab")
        try expect(
            CachePolicy.validate(derivedItem, runningIdentifiers: ["com.apple.dt.xcode"]) != nil,
            "DerivedData is blocked while Xcode runs"
        )

        let changed = try item("io.cachefixture.gone")
        try write(caches, "io.cachefixture.gone/new.bin", bytes: 64)

        let trash = FixtureTrash(destination: fixture.appendingPathComponent("Trash", isDirectory: true))
        let outcome = CacheCleanupCoordinator.moveToTrash(
            items: [safeItem, changed],
            runningResolver: { [] },
            mover: { try trash.move($0) }
        )
        try expect(outcome.movedPaths == [safeItem.url.path], "only the unchanged cache moves")
        try expect(outcome.failures.count == 1, "the changed cache is reported, not moved")
        try expect(!FileManager.default.fileExists(atPath: safeItem.url.path), "moved cache left its place")
        try expect(FileManager.default.fileExists(atPath: changed.url.path), "changed cache stays")

        print("CACHE_EXPLORER_SMOKE_OK")
    }

    private static func write(_ root: URL, _ relativePath: String, bytes: Int) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw failure("FAILED: \(message)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CacheExplorerSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
