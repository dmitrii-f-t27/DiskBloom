import Foundation

private final class FixtureMover: @unchecked Sendable {
    enum Mode {
        case succeed
        case failOn(Int)
        case loseResultOn(Int)
    }

    private let lock = NSLock()
    private var invocation = 0
    private let destination: URL
    private let mode: Mode

    init(destination: URL, mode: Mode) {
        self.destination = destination
        self.mode = mode
    }

    func move(_ source: URL) throws -> URL? {
        lock.lock()
        invocation += 1
        let current = invocation
        lock.unlock()

        if case let .failOn(index) = mode, current == index {
            throw NSError(
                domain: "FixtureMover",
                code: 41,
                userInfo: [NSLocalizedDescriptionKey: "injected failure"]
            )
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("\(current)-\(source.lastPathComponent)", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: target)
        if case let .loseResultOn(index) = mode, current == index { return nil }
        return target
    }
}

@main
@MainActor
struct OrphanLeftoversSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(
                domain: "OrphanLeftoversSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture root required"]
            )
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let orphanID = "io.orphanfixture.product.leftover"
        let installedID = "io.installedfixture.product.current"
        let helperID = "io.installedfixture.product.helper"
        let siblingID = "io.installedfixture.session.leftover"
        let daemonID = "io.daemonfixture.product.agent"
        try createBundle(
            at: home.appendingPathComponent("Applications/Current.app", isDirectory: true),
            identifier: installedID,
            nestedHelperIdentifier: helperID
        )

        for rule in [
            OrphanDataRule.cache,
            .applicationSupport,
            .savedState,
            .httpStorage,
            .webKit,
            .log,
            .container,
            .applicationScripts
        ] {
            try createCandidate(rule: rule, identifier: orphanID, home: home)
        }
        for identifier in [installedID, helperID, siblingID] {
            try createCandidate(rule: .cache, identifier: identifier, home: home)
        }
        try createCandidate(rule: .cache, identifier: daemonID, home: home)
        let launchAgent = home.appendingPathComponent("Library/LaunchAgents/\(daemonID).plist")
        try FileManager.default.createDirectory(at: launchAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let launchAgentData = try PropertyListSerialization.data(
            fromPropertyList: ["Label": daemonID, "Program": "/missing/fixture-agent"],
            format: .xml,
            options: 0
        )
        try launchAgentData.write(to: launchAgent)

        let documentsDecoy = home.appendingPathComponent("Documents/\(orphanID)", isDirectory: true)
        try createPlainDirectory(documentsDecoy)
        try createCandidate(rule: .cache, identifier: "com.apple.fixture", home: home)
        try createCandidate(rule: .cache, identifier: "group.io.diskbloom.fixture", home: home)
        try createCandidate(rule: .cache, identifier: "io.diskbloom.fixture_bad", home: home)

        let safeTarget = fixture.appendingPathComponent("important", isDirectory: true)
        try createPlainDirectory(safeTarget)
        let symlink = OrphanDataRule.cache.expectedURL(
            homeURL: home,
            identifier: "io.diskbloom.fixture.link"
        )
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: safeTarget)
        let nestedLinkFolder = OrphanDataRule.cache.expectedURL(
            homeURL: home,
            identifier: "io.diskbloom.fixture.nestedlink"
        )
        try createPlainDirectory(nestedLinkFolder)
        try FileManager.default.createSymbolicLink(
            at: nestedLinkFolder.appendingPathComponent(".hidden-link"),
            withDestinationURL: safeTarget
        )

        let candidates: Set<String> = [orphanID, installedID, helperID, siblingID, daemonID]
        let liveOwners = OrphanOwnerIndex.capture(candidateIdentifiers: candidates, homeURL: home)
        precondition(liveOwners.claimReason(for: installedID) != nil, "installed app must claim its bundle ID")
        precondition(liveOwners.claimReason(for: helperID) != nil, "nested XPC must claim its bundle ID")
        precondition(liveOwners.claimReason(for: siblingID) != nil, "same-vendor sibling must be conservatively claimed")
        precondition(liveOwners.claimReason(for: installedID.uppercased()) != nil, "claims must be case-insensitive")
        precondition(liveOwners.claimReason(for: daemonID) != nil, "launchd label must claim its bundle ID")

        let analysis = try OrphanedAppDataAnalyzer.analyze(homeURL: home, progress: ScanCounter())
        guard let orphanGroup = analysis.groups.first(where: { $0.id == orphanID }) else {
            preconditionFailure("orphan group missing")
        }
        precondition(orphanGroup.items.count == 8, "expected eight exact folder roots")
        precondition(orphanGroup.confidence == .probable, "multi-root group must be probable")
        precondition(orphanGroup.items.allSatisfy(\.isSelectable), "plain fixture folders must be selectable")
        precondition(!analysis.groups.contains(where: { $0.id == installedID }), "installed ID must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id == helperID }), "nested helper ID must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id == siblingID }), "same-vendor sibling must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id == daemonID }), "launchd-owned ID must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id.hasPrefix("com.apple.") }), "Apple IDs must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id.hasPrefix("group.") }), "group IDs must be excluded")
        precondition(!analysis.groups.contains(where: { $0.id.contains("_") }), "legacy unsafe IDs must be excluded")
        precondition(!analysis.groups.flatMap(\.items).contains(where: { $0.url.path == symlink.path }), "symlink must be excluded")
        let nestedLinkItem = analysis.groups
            .first(where: { $0.id == "io.diskbloom.fixture.nestedlink" })?
            .items.first
        precondition(nestedLinkItem?.isSelectable == false, "nested hidden symlink must be view-only")
        precondition(FileManager.default.fileExists(atPath: documentsDecoy.path), "decoy must remain untouched")

        let model = OrphanedAppDataModel()
        precondition(model.selectedItems.isEmpty, "all leftovers must start OFF")

        guard let mutationItem = orphanGroup.items.first(where: { $0.rule == .log }) else {
            preconditionFailure("log fixture missing")
        }
        try Data("changed".utf8).write(to: mutationItem.url.appendingPathComponent("added.txt"))
        precondition(
            OrphanDataPolicy.validate(mutationItem, homeURL: home) != nil,
            "post-analysis mutation must be rejected"
        )

        let coordinatorRoot = fixture.appendingPathComponent("coordinator-home", isDirectory: true)
        let partialItems = try ["a", "b", "c"].map { suffix in
            try makeItem(
                rule: .cache,
                identifier: "io.partialfixture.product.\(suffix)",
                home: coordinatorRoot
            )
        }
        let emptyOwnerResolver: OrphanCleanupCoordinator.OwnerResolver = { _ in OrphanOwnerIndex() }
        let partialMover = FixtureMover(
            destination: fixture.appendingPathComponent("FakeTrashPartial", isDirectory: true),
            mode: .failOn(2)
        )
        let partial = OrphanCleanupCoordinator.moveToTrash(
            items: partialItems,
            homeURL: coordinatorRoot,
            ownerResolver: emptyOwnerResolver,
            mover: { try partialMover.move($0) }
        )
        precondition(partial.movedPaths.count == 1, "one confirmed move expected")
        precondition(partial.uncertainPaths.isEmpty, "failed source still exists, so outcome is not uncertain")
        precondition(partial.unattemptedPaths.count == 1, "third item must stay unattempted")
        precondition(FileManager.default.fileExists(atPath: partialItems[1].url.path), "failed item must remain")
        precondition(FileManager.default.fileExists(atPath: partialItems[2].url.path), "unattempted item must remain")

        let uncertainHome = fixture.appendingPathComponent("uncertain-home", isDirectory: true)
        let uncertainItem = try makeItem(
            rule: .cache,
            identifier: "io.uncertainfixture.product.leftover",
            home: uncertainHome
        )
        let uncertainMover = FixtureMover(
            destination: fixture.appendingPathComponent("FakeTrashUncertain", isDirectory: true),
            mode: .loseResultOn(1)
        )
        let uncertain = OrphanCleanupCoordinator.moveToTrash(
            items: [uncertainItem],
            homeURL: uncertainHome,
            ownerResolver: emptyOwnerResolver,
            mover: { try uncertainMover.move($0) }
        )
        precondition(uncertain.movedPaths.isEmpty, "unverified move must not be confirmed")
        precondition(uncertain.uncertainPaths == [uncertainItem.url.path], "missing source must be uncertain")

        let reappearHome = fixture.appendingPathComponent("reappear-home", isDirectory: true)
        let reappearItem = try makeItem(
            rule: .cache,
            identifier: "io.reappearfixture.product.leftover",
            home: reappearHome
        )
        let blocked = OrphanCleanupCoordinator.moveToTrash(
            items: [reappearItem],
            homeURL: reappearHome,
            ownerResolver: { _ in
                OrphanOwnerIndex(claims: [reappearItem.canonicalIdentifier: "fixture owner reappeared"])
            },
            mover: { _ in preconditionFailure("mover must not run after owner reappears") }
        )
        precondition(blocked.movedPaths.isEmpty, "reappeared owner must block all moves")
        precondition(blocked.unattemptedPaths == [reappearItem.url.path], "blocked item must remain unattempted")

        print(
            "ORPHAN_LEFTOVERS_SMOKE_OK allowlist=exact installed=excluded nested=excluded "
                + "namespace=blocked launchd=blocked symlink=blocked mutation=blocked "
                + "reappear=blocked partial=retained uncertain=locked"
        )
    }

    private static func createBundle(
        at url: URL,
        identifier: String,
        nestedHelperIdentifier: String
    ) throws {
        let executable = url.appendingPathComponent("Contents/MacOS/Current")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try writeInfoPlist(at: url, identifier: identifier, executable: "Current", packageType: "APPL")

        let helper = url.appendingPathComponent("Contents/XPCServices/Helper.xpc", isDirectory: true)
        let helperExecutable = helper.appendingPathComponent("Contents/MacOS/Helper")
        try FileManager.default.createDirectory(at: helperExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: helperExecutable)
        try writeInfoPlist(at: helper, identifier: nestedHelperIdentifier, executable: "Helper", packageType: "XPC!")
    }

    private static func writeInfoPlist(
        at bundle: URL,
        identifier: String,
        executable: String,
        packageType: String
    ) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": executable,
            "CFBundlePackageType": packageType,
            "CFBundleExecutable": executable
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private static func createCandidate(rule: OrphanDataRule, identifier: String, home: URL) throws {
        try createPlainDirectory(rule.expectedURL(homeURL: home, identifier: identifier))
    }

    private static func createPlainDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("fixture-data".utf8).write(to: url.appendingPathComponent("state.bin"))
    }

    private static func makeItem(
        rule: OrphanDataRule,
        identifier: String,
        home: URL
    ) throws -> OrphanDataItem {
        let url = rule.expectedURL(homeURL: home, identifier: identifier)
        try createPlainDirectory(url)
        var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
        let node = try scanner.scan(root: url, counter: ScanCounter()).root
        guard let canonical = OrphanBundleIdentifier.canonical(identifier) else {
            preconditionFailure("fixture identifier must be valid")
        }
        return OrphanDataItem(
            id: url.path,
            identifier: identifier,
            canonicalIdentifier: canonical,
            rule: rule,
            node: node,
            eligibilityIssue: OrphanDataPolicy.treeEligibilityIssue(for: node, homeURL: home)
        )
    }
}
