import Foundation

private final class FixtureMover: @unchecked Sendable {
    enum Mode: CaseIterable {
        case succeed, noResult, wrongPath, throwKeep, throwAfterMove, failSecond, claimWithoutMoving
    }

    private let lock = NSLock()
    private var calls = 0
    let trash: URL
    let decoy: URL
    let mode: Mode

    init(trash: URL, decoy: URL, mode: Mode) {
        self.trash = trash
        self.decoy = decoy
        self.mode = mode
    }

    func move(_ source: URL) throws -> URL? {
        lock.lock()
        calls += 1
        let call = calls
        lock.unlock()
        let failure = NSError(domain: "FixtureMover", code: 7, userInfo: [NSLocalizedDescriptionKey: "injected failure"])
        if mode == .throwKeep || (mode == .failSecond && call == 2) { throw failure }
        if mode == .claimWithoutMoving { return decoy }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let target = trash.appendingPathComponent("\(call)-\(source.lastPathComponent)")
        try FileManager.default.moveItem(at: source, to: target)
        switch mode {
        case .noResult: return nil
        case .wrongPath: return decoy
        case .throwAfterMove: throw failure
        default: return target
        }
    }
}

/// Runs the same move scenarios through the Trash coordinators written in Swift before
/// Specs/move_rules.t27 (Tests/Smoke/MoveLegacy.swift) and through the coordinators that follow the
/// spec, each on a fresh identical fixture, and fails on the first difference in the outcome.
@main
@MainActor
struct MoveDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var scenarios = 0
        var run = 0

        func fresh() throws -> URL {
            run += 1
            let root = fixture.appendingPathComponent("run\(run)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        }
        func mover(_ root: URL, _ mode: FixtureMover.Mode) throws -> FixtureMover {
            let decoy = root.appendingPathComponent("decoy.txt")
            try Data("decoy".utf8).write(to: decoy)
            return FixtureMover(trash: root.appendingPathComponent("Trash", isDirectory: true), decoy: decoy, mode: mode)
        }
        func normalized(_ text: String, _ root: URL) -> String {
            text.replacingOccurrences(of: root.path, with: "<ROOT>")
        }

        for mode in FixtureMover.Mode.allCases {
            for variant in 0..<3 {
                // Disk Map
                var results: [String] = []
                for side in 0..<2 {
                    let root = try fresh()
                    let area = root.appendingPathComponent("area", isDirectory: true)
                    try FileManager.default.createDirectory(at: area.appendingPathComponent("folder"), withIntermediateDirectories: true)
                    try Data("a".utf8).write(to: area.appendingPathComponent("a.txt"))
                    try Data("b".utf8).write(to: area.appendingPathComponent("folder/b.txt"))
                    try Data("c".utf8).write(to: area.appendingPathComponent("c.txt"))
                    var scanner = DiskScanner()
                    let snapshot = try scanner.scan(root: area, counter: ScanCounter())
                    var candidates = snapshot.root.children.filter { !$0.isVirtual }.sorted { ($0.url?.path ?? "") < ($1.url?.path ?? "") }
                    if variant == 1 { try Data("changed".utf8).write(to: area.appendingPathComponent("c.txt")) }
                    if variant == 2 { candidates.append(DiskNode(url: nil, name: "group", size: 1, fileCount: 1, directoryCount: 0, unreadableCount: 0, isDirectory: true, isVirtual: true)) }
                    let fixtureMover = try mover(root, mode)
                    if side == 0 {
                        let outcome = LegacyDiskMapMove.moveToTrash(candidates: candidates, rescanURL: area, protectedRootURL: area, mover: { try fixtureMover.move($0) })
                        results.append(normalized("\(outcome.successful)|\(outcome.failures)", root))
                    } else {
                        let outcome = DiskMapCleanupCoordinator.moveToTrash(candidates: candidates, rescanURL: area, protectedRootURL: area, mover: { try fixtureMover.move($0) })
                        results.append(normalized("\(outcome.successfulPaths)|\(outcome.failures)", root))
                    }
                }
                try same("disk map \(mode) v\(variant)", results[0], results[1])
                scenarios += 1

                // Caches
                results = []
                for side in 0..<2 {
                    let root = try fresh()
                    let home = root.appendingPathComponent("home", isDirectory: true)
                    for name in ["io.move.one", "io.move.two", "io.move.three"] {
                        let folder = home.appendingPathComponent("Library/Caches/\(name)", isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try Data(name.utf8).write(to: folder.appendingPathComponent("data"))
                    }
                    let context = CacheOwnerContext(applications: [], runningIdentifiers: [])
                    let analysis = try CacheAnalyzer.analyze(homeURL: home, progress: ScanCounter(), contextOverride: context)
                    let items = analysis.items.filter(\.isSelectable)
                    if variant == 1 { try Data("new".utf8).write(to: home.appendingPathComponent("Library/Caches/io.move.two/extra")) }
                    let running: Set<String> = variant == 2 ? ["io.move.three"] : []
                    let fixtureMover = try mover(root, mode)
                    let outcome = side == 0
                        ? LegacyCacheCleanupCoordinator.moveToTrash(items: items, runningResolver: { running }, mover: { try fixtureMover.move($0) })
                        : CacheCleanupCoordinator.moveToTrash(items: items, runningResolver: { running }, mover: { try fixtureMover.move($0) })
                    results.append(normalized("\(outcome.movedPaths)|\(outcome.failures)", root))
                }
                try same("caches \(mode) v\(variant)", results[0], results[1])
                scenarios += 1

                // Possible Leftovers
                results = []
                for side in 0..<2 {
                    let root = try fresh()
                    let home = root.appendingPathComponent("home", isDirectory: true)
                    var items: [OrphanDataItem] = []
                    for name in ["io.left.alpha", "io.left.beta", "io.left.gamma"] {
                        let folder = home.appendingPathComponent("Library/Application Support/\(name)", isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try Data(name.utf8).write(to: folder.appendingPathComponent("state"))
                        var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
                        let node = try scanner.scan(root: folder, counter: ScanCounter()).root
                        items.append(OrphanDataItem(id: folder.path, identifier: name, canonicalIdentifier: name,
                                                    rule: .applicationSupport, node: node, eligibilityIssue: nil))
                    }
                    if variant == 1 { try Data("x".utf8).write(to: home.appendingPathComponent("Library/Application Support/io.left.gamma/new")) }
                    let calls = CallCounter()
                    let resolver: OrphanCleanupCoordinator.OwnerResolver = { _ in
                        let call = calls.next()
                        if variant == 2 && call >= 4 { return OrphanOwnerIndex(claims: ["io.left.beta": "Running application found: Beta"]) }
                        return OrphanOwnerIndex(claims: [:])
                    }
                    let fixtureMover = try mover(root, mode)
                    let outcome = side == 0
                        ? LegacyOrphanCleanupCoordinator.moveToTrash(items: items, homeURL: home, ownerResolver: resolver, mover: { try fixtureMover.move($0) })
                        : OrphanCleanupCoordinator.moveToTrash(items: items, homeURL: home, ownerResolver: resolver, mover: { try fixtureMover.move($0) })
                    results.append(normalized("\(outcome.movedPaths)|\(outcome.uncertainPaths)|\(outcome.failure ?? "-")|\(outcome.unattemptedPaths)", root))
                }
                try same("leftovers \(mode) v\(variant)", results[0], results[1])
                scenarios += 1

                // App Uninstaller
                results = []
                for side in 0..<2 {
                    let root = try fresh()
                    let app = root.appendingPathComponent("Move Fixture.app", isDirectory: true)
                    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                    let plist: [String: Any] = ["CFBundleIdentifier": "io.move.fixture", "CFBundleName": "Move Fixture", "CFBundlePackageType": "APPL"]
                    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
                    try Data("bin".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Move Fixture"))
                    let application = InstalledApplication(url: app, name: "Move Fixture", bundleIdentifier: "io.move.fixture", version: nil, sourceLabel: "Fixture")
                    var scanner = DiskScanner()
                    let appNode = try scanner.scan(root: app, counter: ScanCounter()).root
                    var items = [AppRemovalItem(id: app.path, node: appNode, rule: .application, key: "io.move.fixture", explanation: "",
                                                isRequired: true, isDefaultSelected: true, eligibilityIssue: nil, riskOverride: nil)]
                    let related = root.appendingPathComponent("related", isDirectory: true)
                    try FileManager.default.createDirectory(at: related, withIntermediateDirectories: true)
                    var relatedScanner = DiskScanner()
                    let relatedNode = try relatedScanner.scan(root: related, counter: ScanCounter()).root
                    items.append(AppRemovalItem(id: related.path, node: relatedNode, rule: .identifierCache, key: "io.move.fixture", explanation: "",
                                                isRequired: false, isDefaultSelected: true, eligibilityIssue: nil, riskOverride: nil))
                    if variant == 1 { items = [items[0]] }
                    let plan = AppRemovalPlan(application: application, items: items, hasDuplicateBundleIdentifier: false,
                                              bundleIdentifierIsSignatureBacked: false, validatedSignature: nil,
                                              hasPrivilegedComponents: false, applicationEligibilityIssue: nil)
                    let fixtureMover = try mover(root, mode)
                    let alreadyMoved = variant == 2
                    let outcome = side == 0
                        ? LegacyAppRemovalCoordinator.moveToTrash(items: items, plan: plan, applicationAlreadyMoved: alreadyMoved, mover: { try fixtureMover.move($0) })
                        : AppRemovalCoordinator.moveToTrash(items: items, plan: plan, applicationAlreadyMoved: alreadyMoved, mover: { try fixtureMover.move($0) })
                    results.append(normalized("\(outcome.movedPaths)|\(outcome.uncertainPaths)|\(outcome.failure ?? "-")|\(outcome.unattemptedPaths)", root))
                }
                try same("uninstaller \(mode) v\(variant)", results[0], results[1])
                scenarios += 1
            }
        }
        print("MOVE_DIFFERENTIAL_OK scenarios=\(scenarios)")
    }

    private static func same(_ label: String, _ before: String, _ after: String) throws {
        guard before == after else { throw failure("MISMATCH \(label):\n Swift=\(before)\n t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MoveDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
