import Foundation

// Tests the administrator move (Specs/move_rules.t27, mv_admin_*) with a stand-in for Finder.
// Nothing here sends an Apple Event, asks for Automation, touches the real Trash or launches the app:
// every call gets a fake Finder, a fixture mover, a Trash folder inside the fixture and a fixture home.

// MARK: - Fakes

/// Stands in for Finder. Counts its calls and does what the scenario says with the files.
private final class FakeFinder: @unchecked Sendable {
    private let lock = NSLock()
    private var permissionCount = 0
    private var sendCount = 0
    private var urls: [URL] = []
    private var identityAtCall: [Bool] = []

    var permissionStatus: Int64 = 0
    var permissionAction: (@Sendable () -> Void)?
    var sendAction: @Sendable (URL) -> Int64 = { _ in 0 }
    /// The relocation identity the bundle has before the request; the fake records whether the URL it
    /// is given still resolves to an item with this identity.
    var bundleIdentity: String?

    var permissionCalls: Int { lock.withLock { permissionCount } }
    var sendCalls: Int { lock.withLock { sendCount } }
    var receivedURLs: [URL] { lock.withLock { urls } }
    var identityMatchedAtCall: [Bool] { lock.withLock { identityAtCall } }

    var request: FinderTrashRequest {
        FinderTrashRequest(
            permission: { [self] in
                lock.withLock { permissionCount += 1 }
                permissionAction?()
                return permissionStatus
            },
            send: { [self] url in
                let resolvedURL = resolved(url)
                let matched = bundleIdentity.map { FileIdentity.relocationIdentifier(for: resolvedURL) == $0 } ?? false
                lock.withLock {
                    sendCount += 1
                    urls.append(url)
                    identityAtCall.append(matched)
                }
                return sendAction(url)
            }
        )
    }
}

/// Moves into a folder of the fixture, like MoveDifferentialSmoke; can throw on one call.
private final class FixtureMover: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let destination: URL
    let throwOnCall: Int?
    let errorDomain: String
    let errorCode: Int
    let underlyingPOSIX: Int?

    init(destination: URL, throwOnCall: Int? = nil, errorDomain: String = "", errorCode: Int = 0, underlyingPOSIX: Int? = nil) {
        self.destination = destination
        self.throwOnCall = throwOnCall
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.underlyingPOSIX = underlyingPOSIX
    }

    func move(_ source: URL) throws -> URL? {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if let throwOnCall, call == throwOnCall {
            var info: [String: Any] = [:]
            if let underlyingPOSIX {
                info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: underlyingPOSIX)
            }
            throw NSError(domain: errorDomain, code: errorCode, userInfo: info)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent("\(call)-\(source.lastPathComponent)")
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    var mover: MoveSteps.Mover {
        { [self] url in try move(url) }
    }
}

/// A mover that always throws the same error (Cocoa 513 with a POSIX cause, or a plain POSIX error).
private func throwingMover(domain: String, code: Int, underlyingPOSIX: Int? = nil) -> MoveSteps.Mover {
    { _ in
        var info: [String: Any] = [:]
        if let underlyingPOSIX {
            info[NSUnderlyingErrorKey] = NSError(domain: NSPOSIXErrorDomain, code: underlyingPOSIX)
        }
        throw NSError(domain: domain, code: code, userInfo: info)
    }
}

// MARK: - Fixture

private struct Fixture {
    let id: String
    let root: URL
    let applications: URL
    let app: URL
    let home: URL
    let relatedFolder: URL
    let trash: URL
    let moverTrash: URL
    let elsewhere: URL
    let bundleID: String
    let appName: String
}

private struct Built {
    let plan: AppRemovalPlan
    let items: [AppRemovalItem]
    var bundle: AppRemovalItem { items[0] }
    var related: AppRemovalItem { items[1] }
}

private func resolved(_ url: URL) -> URL {
    (url as NSURL).filePathURL ?? url
}

private func realOwner(_ url: URL) -> uid_t? {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return lstat(path, &info)
    }
    return result == 0 ? info.st_uid : nil
}

private func realWritable(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { path -> Bool in
        guard let path else { return false }
        return access(path, W_OK) == 0
    }
}

private func makeFixture(root: URL, id: String, appRelativePath: String = "Applications/Admin Fixture.app", appName: String = "Admin Fixture") throws -> Fixture {
    let scenario = root.appendingPathComponent(id, isDirectory: true)
    let fm = FileManager.default
    let app = scenario.appendingPathComponent(appRelativePath, isDirectory: true)
    let bundleID = "io.admin.fixture.\(id)"
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": appName, "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("bin".utf8).write(to: app.appendingPathComponent("Contents/MacOS/\(appName)"))
    let home = scenario.appendingPathComponent("home", isDirectory: true)
    let related = home.appendingPathComponent("Library/Caches/\(bundleID)", isDirectory: true)
    try fm.createDirectory(at: related, withIntermediateDirectories: true)
    try Data("state".utf8).write(to: related.appendingPathComponent("state.bin"))
    let trash = scenario.appendingPathComponent("trash", isDirectory: true)
    try fm.createDirectory(at: trash, withIntermediateDirectories: true)
    return Fixture(
        id: id,
        root: scenario,
        applications: scenario.appendingPathComponent("Applications", isDirectory: true),
        app: app,
        home: home,
        relatedFolder: related,
        trash: trash,
        moverTrash: scenario.appendingPathComponent("mover-trash", isDirectory: true),
        elsewhere: scenario.appendingPathComponent("elsewhere", isDirectory: true),
        bundleID: bundleID,
        appName: appName
    )
}

private func build(_ f: Fixture) throws -> Built {
    let application = InstalledApplication(url: f.app, name: f.appName, bundleIdentifier: f.bundleID, version: nil, sourceLabel: "Fixture")
    var scanner = DiskScanner()
    let appNode = try scanner.scan(root: f.app, counter: ScanCounter()).root
    var relatedScanner = DiskScanner()
    let relatedNode = try relatedScanner.scan(root: f.relatedFolder, counter: ScanCounter()).root
    let items = [
        AppRemovalItem(id: f.app.path, node: appNode, rule: .application, key: f.bundleID, explanation: "",
                       isRequired: true, isDefaultSelected: true, eligibilityIssue: nil, riskOverride: nil),
        AppRemovalItem(id: f.relatedFolder.path, node: relatedNode, rule: .identifierCache, key: f.bundleID, explanation: "",
                       isRequired: false, isDefaultSelected: true, eligibilityIssue: nil, riskOverride: nil)
    ]
    let plan = AppRemovalPlan(
        application: application, items: items, hasDuplicateBundleIdentifier: false,
        bundleIdentifierIsSignatureBacked: false, validatedSignature: nil,
        hasPrivilegedComponents: false, applicationEligibilityIssue: nil
    )
    return Built(plan: plan, items: items)
}

/// The facts of this Mac as a scenario wants them: the bundle belongs to `bundleOwner` (root by default),
/// everything else reports its real owner and real write access.
///
/// `onTrashOwner` is the hook for changes that must happen after ADMIN_ITEM and before the
/// HANDLE_UNCHANGED check: the owner of the Trash is read once in ADMIN_QUEUE (TRASH_READY) and once in
/// ADMIN_SEND (TRASH_READY, right before HANDLE_UNCHANGED). It gets the number of that read, from 1.
private func environment(
    _ f: Fixture,
    sandboxed: Bool = false,
    roots: [URL]? = nil,
    bundleOwner: uid_t = 0,
    trashOwner: uid_t? = nil,
    writable: (@Sendable (URL) -> Bool)? = nil,
    onTrashOwner: (@Sendable (Int) -> Void)? = nil
) -> AdminMoveEnvironment {
    let bundlePath = f.app.standardizedFileURL.path
    let trashPath = f.trash.standardizedFileURL.path
    let trashReads = AttemptCounter()
    return AdminMoveEnvironment(
        applicationRoots: roots ?? [f.applications],
        sandboxed: sandboxed,
        owner: { url in
            let path = url.standardizedFileURL.path
            if T27Text.same(path, bundlePath) { return bundleOwner }
            if T27Text.same(path, trashPath) {
                onTrashOwner?(trashReads.next())
                if let trashOwner { return trashOwner }
            }
            return realOwner(url)
        },
        writable: writable ?? { url in realWritable(url) }
    )
}

private func fakeFinder(_ f: Fixture) -> FakeFinder {
    let fake = FakeFinder()
    fake.bundleIdentity = FileIdentity.relocationIdentifier(for: f.app)
    return fake
}

private func finderMove(
    _ f: Fixture,
    _ b: Built,
    _ fake: FakeFinder,
    _ env: AdminMoveEnvironment,
    trash: URL? = nil,
    openHandle: (URL) -> HeldItem? = { HeldItem(url: $0) }
) -> AppRemovalOutcome {
    let mover = FixtureMover(destination: f.moverTrash)
    return AppRemovalCoordinator.moveApplicationWithFinder(
        items: b.items, plan: b.plan, finder: fake.request, mover: mover.mover,
        trashDirectory: trash ?? f.trash, homeURL: f.home, adminEnvironment: env, openHandle: openHandle
    )
}

private func plainMove(_ f: Fixture, _ b: Built, mover: MoveSteps.Mover, _ env: AdminMoveEnvironment) -> AppRemovalOutcome {
    AppRemovalCoordinator.moveToTrash(
        items: b.items, plan: b.plan, applicationAlreadyMoved: false,
        mover: mover, homeURL: f.home, adminEnvironment: env
    )
}

/// Moves a path like Finder would (best effort; the scenario then asserts the end state).
private func relocate(_ source: URL, to target: URL) {
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.moveItem(at: resolved(source), to: target)
}

private func describe(_ outcome: AppRemovalOutcome) -> String {
    "moved=\(outcome.movedPaths) uncertain=\(outcome.uncertainPaths) failure=\(outcome.failure ?? "-") unattempted=\(outcome.unattemptedPaths) offer=\(outcome.adminOffer) cause=\(outcome.adminCause)"
}

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// Nothing is in the folder (or the folder does not exist).
private func isEmpty(_ url: URL) -> Bool {
    ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
}

// The refusal texts the scenarios expect, written out here so that a refusal that moves to another check
// (or a changed text) fails the test.

/// SnapshotValidator: the identity of a reviewed item changed after the scan (ADMIN_QUEUE VALIDATE_ALL).
private func changedAfterScanning(_ url: URL) -> String {
    "The item changed after scanning: \(url.path). Rescan."
}

/// The gate (Specs/move_rules.t27, mv_admin_offer) refused before any queue step ran. A symlinked path
/// and a flagged bundle both end here: the application is not eligible, or it carries a flag.
private func gateRefusal(_ url: URL) -> String {
    "\(url.path): Administrator move is not available for this item."
}

/// ADMIN_QUEUE TRASH_READY.
private func trashRefusal(bundle: URL, trash: URL) -> String {
    "\(bundle.path): Your Trash folder (\(trash.path)) is missing, is not a normal folder that belongs to you, or is on another volume. Nothing was sent to Finder."
}

/// ADMIN_SEND HANDLE_UNCHANGED.
private func changedBeforeSend(_ url: URL) -> String {
    "The item at \(url.path) changed after the last check. Nothing was sent to Finder."
}

/// ADMIN_ITEM OPEN_HANDLE.
private func handleRefusal(_ url: URL) -> String {
    "Could not hold the reviewed item to follow it: \(url.path)"
}

// MARK: - Scenarios

@main
@MainActor
struct AdminMoveSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var scenarios = 0

        // S1: the plain move is refused (a 0555 folder on a volume where chmod is enforced), then the
        // administrator move is checked again on the same reviewed selection.
        do {
            let f = try makeFixture(root: root, id: "s1")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.app.path)
            let b = try build(f)

            let a1 = plainMove(f, b, mover: FixtureMover(destination: f.moverTrash).mover, environment(f))
            try expect(a1.failure != nil, "S1a1 plain move must fail", a1)
            try expect(a1.uncertainPaths.isEmpty, "S1a1 nothing uncertain", a1)
            try expect(a1.unattemptedPaths == [b.related.url.path], "S1a1 related unattempted", a1)
            try expect(a1.adminOffer == .finderWithPassword && a1.adminCause == .rootOwner, "S1a1 offer finder/root", a1)
            scenarios += 1

            let a2 = plainMove(f, b, mover: FixtureMover(destination: f.moverTrash).mover, environment(f, sandboxed: true))
            try expect(a2.adminOffer == .revealInFinder, "S1a2 sandboxed edition only explains", a2)
            scenarios += 1

            let a3 = plainMove(f, b, mover: FixtureMover(destination: f.moverTrash).mover, environment(f, roots: []))
            try expect(a3.adminOffer == .unavailable, "S1a3 not in an application root", a3)
            scenarios += 1

            let a4 = plainMove(f, b, mover: FixtureMover(destination: f.moverTrash).mover, environment(f, bundleOwner: getuid()))
            try expect(a4.adminOffer == .unavailable, "S1a4 the user's own app in a writable folder", a4)
            try expect(a4.failure == a1.failure, "S1a4 same failure text as S1a1", a4)
            scenarios += 1

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.app.path)
            let fake = fakeFinder(f)
            let bOutcome = finderMove(f, b, fake, environment(f))
            try expect(bOutcome.failure == changedAfterScanning(b.bundle.url), "S1b ADMIN_QUEUE VALIDATE_ALL refuses the changed bundle (not the gate)", bOutcome)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S1b Finder is never asked", bOutcome)
            try expect(bOutcome.uncertainPaths.isEmpty && bOutcome.movedPaths.isEmpty, "S1b nothing uncertain, nothing moved", bOutcome)
            try expect(bOutcome.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S1b everything unattempted", bOutcome)
            scenarios += 1
        }

        // S2: synthetic errors through the plain move.
        do {
            let f = try makeFixture(root: root, id: "s2a")
            let b = try build(f)
            let o = plainMove(f, b, mover: throwingMover(domain: NSCocoaErrorDomain, code: 513, underlyingPOSIX: 13), environment(f))
            try expect(o.adminOffer == .finderWithPassword && o.adminCause == .rootOwner, "S2a Cocoa 513 / POSIX 13", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s2b")
            let b = try build(f)
            let o = plainMove(f, b, mover: throwingMover(domain: NSPOSIXErrorDomain, code: 1), environment(f))
            try expect(o.adminOffer == .finderWithPassword && o.adminCause == .rootOwner, "S2b POSIX 1", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s2c")
            let b = try build(f)
            let o = plainMove(f, b, mover: throwingMover(domain: "FixtureMover", code: 7), environment(f))
            try expect(o.failure != nil && o.adminOffer == .unavailable, "S2c other error", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s2d")
            let b = try build(f)
            let mover = FixtureMover(destination: f.moverTrash, throwOnCall: 2, errorDomain: NSCocoaErrorDomain, errorCode: 513, underlyingPOSIX: 13)
            let o = plainMove(f, b, mover: mover.mover, environment(f))
            try expect(o.movedPaths == [b.bundle.url.path], "S2d the bundle moved", o)
            try expect(o.failure != nil && o.adminOffer == .unavailable, "S2d a related item is never offered", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s2e")
            let b = try build(f)
            let o = plainMove(f, b, mover: throwingMover(domain: NSCocoaErrorDomain, code: 513, underlyingPOSIX: 13),
                              environment(f, bundleOwner: getuid(), writable: { _ in false }))
            try expect(o.adminOffer == .finderWithPassword && o.adminCause == .parentLocked, "S2e own app in a protected folder", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s2f")
            let b = try build(f)
            let o = plainMove(f, b, mover: throwingMover(domain: NSCocoaErrorDomain, code: 513, underlyingPOSIX: 13),
                              environment(f, bundleOwner: 502))
            try expect(o.adminOffer == .unavailable, "S2f another user's app", o)
            scenarios += 1
        }

        // S3: Finder moves the bundle into the Trash.
        for (label, trashedName) in [("s3a", "Admin Fixture.app"), ("s3b", "Admin Fixture 10.42.13.app")] {
            let f = try makeFixture(root: root, id: label)
            let b = try build(f)
            let fake = fakeFinder(f)
            let trashed = f.trash.appendingPathComponent(trashedName, isDirectory: true)
            fake.sendAction = { url in
                relocate(url, to: trashed)
                return 0
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.movedPaths == [b.bundle.url.path, b.related.url.path] && o.failure == nil, "\(label) bundle and related moved", o)
            try expect(o.unattemptedPaths.isEmpty && o.uncertainPaths.isEmpty, "\(label) nothing left over", o)
            try expect(exists(trashed) && !exists(f.app), "\(label) the bundle is in the Trash folder, the original is gone", o)
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 1, "\(label) one permission check, one event", o)
            try expect(fake.receivedURLs.count == 1 && fake.receivedURLs[0].isFileURL, "\(label) a file URL was sent", o)
            try expect(fake.identityMatchedAtCall == [true], "\(label) the URL resolved to the reviewed bundle", o)
            scenarios += 1
        }

        // S4: nothing moved, whatever Finder answered.
        for (label, status, expected) in [
            ("s4a", Int64(-128), "cancelled or refused by Finder (code -128)"),
            ("s4b", Int64(0), "Finder answered, but the application is still in place"),
            ("s4c", Int64(-10000), "(code -10000)")
        ] {
            let f = try makeFixture(root: root, id: label)
            let b = try build(f)
            let fake = fakeFinder(f)
            fake.sendAction = { _ in status }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.uncertainPaths.isEmpty, "\(label) nothing uncertain", o)
            try expect(o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "\(label) everything unattempted", o)
            try expect(o.adminOffer == .finderWithPassword, "\(label) retry stays offered", o)
            try expect(o.failure?.contains(expected) == true, "\(label) failure text", o)
            try expect(exists(f.app), "\(label) the bundle is still in place", o)
            scenarios += 1
        }

        // S5: the Automation permission is not given.
        for (label, status, expected) in [
            ("s5a", Int64(-1743), ["Automation", "tccutil reset AppleEvents io.github.dmitrii-f-t27.DiskBloom"]),
            ("s5b", Int64(-600), ["Finder is not running"])
        ] {
            let f = try makeFixture(root: root, id: label)
            let b = try build(f)
            let fake = fakeFinder(f)
            fake.permissionStatus = status
            let o = finderMove(f, b, fake, environment(f))
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 0, "\(label) the event is never sent", o)
            try expect(o.uncertainPaths.isEmpty && o.adminOffer == .finderWithPassword, "\(label) nothing uncertain, offer stays", o)
            for text in expected {
                try expect(o.failure?.contains(text) == true, "\(label) failure mentions \(text)", o)
            }
            scenarios += 1
        }

        // S6: the reviewed bundle is swapped for another item while Finder works.
        do {
            let f = try makeFixture(root: root, id: "s6")
            let b = try build(f)
            let fake = fakeFinder(f)
            let aside = f.applications.appendingPathComponent("aside.app", isDirectory: true)
            let decoy = f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            fake.sendAction = { url in
                relocate(url, to: aside)
                try? FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
                return 0
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.uncertainPaths == [b.bundle.url.path] && o.adminOffer == .unavailable, "S6 uncertain, no retry", o)
            try expect(o.unattemptedPaths == [b.related.url.path], "S6 related unattempted", o)
            scenarios += 1
        }

        // S7: the bundle ended up somewhere that is not the Trash.
        do {
            let f = try makeFixture(root: root, id: "s7")
            let b = try build(f)
            let fake = fakeFinder(f)
            let target = f.elsewhere.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            fake.sendAction = { url in
                relocate(url, to: target)
                return 0
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.uncertainPaths == [b.bundle.url.path] && o.adminOffer == .unavailable, "S7 uncertain, no retry", o)
            scenarios += 1
        }

        // S8: the bundle is in the Trash, but a new item took its path.
        do {
            let f = try makeFixture(root: root, id: "s8")
            let b = try build(f)
            let fake = fakeFinder(f)
            let trashed = f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            let original = f.app
            fake.sendAction = { url in
                relocate(url, to: trashed)
                try? FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
                return 0
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.movedPaths == [b.bundle.url.path], "S8 only the bundle counts as moved", o)
            try expect(o.failure?.contains("new item") == true, "S8 failure names the new item", o)
            try expect(o.unattemptedPaths == [b.related.url.path] && o.adminOffer == .unavailable, "S8 related untouched, no retry", o)
            scenarios += 1
        }

        // S9: Finder does not answer in time.
        do {
            let f = try makeFixture(root: root, id: "s9a")
            let b = try build(f)
            let fake = fakeFinder(f)
            let trashed = f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            fake.sendAction = { url in
                relocate(url, to: trashed)
                return -1712
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.movedPaths == [b.bundle.url.path, b.related.url.path] && o.failure == nil, "S9a moved despite the timeout reply", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s9b")
            let b = try build(f)
            let fake = fakeFinder(f)
            fake.sendAction = { _ in -1712 }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure?.contains("10 minutes") == true && o.failure?.contains("still in place") == true, "S9b timeout text", o)
            try expect(o.adminOffer == .finderWithPassword && o.uncertainPaths.isEmpty, "S9b retry stays offered", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s9c")
            let b = try build(f)
            let fake = fakeFinder(f)
            let target = f.elsewhere.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            fake.sendAction = { url in
                relocate(url, to: target)
                return -1712
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.uncertainPaths == [b.bundle.url.path] && o.adminOffer == .unavailable, "S9c uncertain, no retry", o)
            try expect(o.failure?.contains("10 minutes") == true, "S9c timeout sentence", o)
            scenarios += 1
        }

        // S10: the bundle changes between the permission check and the coordinated check.
        do {
            let f = try makeFixture(root: root, id: "s10")
            let b = try build(f)
            let fake = fakeFinder(f)
            let added = f.app.appendingPathComponent("Contents/added.txt")
            fake.permissionAction = {
                try? Data("late".utf8).write(to: added)
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure != nil && fake.permissionCalls == 1 && fake.sendCalls == 0, "S10 refused before the send", o)
            try expect(o.uncertainPaths.isEmpty, "S10 nothing uncertain", o)
            scenarios += 1
        }

        // S11: a related item changed before the call.
        do {
            let f = try makeFixture(root: root, id: "s11")
            let b = try build(f)
            try Data("changed".utf8).write(to: f.relatedFolder.appendingPathComponent("new.bin"))
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure == changedAfterScanning(b.related.url), "S11 ADMIN_QUEUE VALIDATE_ALL refuses the changed related item (not the gate)", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S11 Finder is never asked", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S11 nothing moved, everything unattempted", o)
            try expect(exists(f.app), "S11 the bundle is still in place", o)
            scenarios += 1
        }

        // S12: a symlink took the path of the bundle.
        do {
            let f = try makeFixture(root: root, id: "s12")
            let b = try build(f)
            let aside = f.applications.appendingPathComponent("aside.app", isDirectory: true)
            try FileManager.default.moveItem(at: f.app, to: aside)
            try FileManager.default.createSymbolicLink(at: f.app, withDestinationURL: aside)
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure == gateRefusal(b.bundle.url), "S12 the gate refuses a symlink at the path (the application is not eligible)", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S12 Finder is never asked", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S12 nothing moved, everything unattempted", o)
            scenarios += 1
        }

        // S13: the sandboxed edition explains and offers Reveal in Finder.
        do {
            let f = try makeFixture(root: root, id: "s13")
            let b = try build(f)
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f, sandboxed: true))
            try expect(o.failure?.contains("not available") == true && o.adminOffer == .revealInFinder, "S13 reveal only", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S13 Finder is never asked", o)
            scenarios += 1
        }

        // S14: where the bundle sits.
        do {
            let f = try makeFixture(root: root, id: "s14a")
            let b = try build(f)
            let fake = fakeFinder(f)
            let other = f.root.appendingPathComponent("Other", isDirectory: true)
            let o = finderMove(f, b, fake, environment(f, roots: [other]))
            try expect(o.failure != nil && o.adminOffer == .unavailable && fake.permissionCalls == 0 && fake.sendCalls == 0, "S14a outside the application roots", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s14b", appRelativePath: "Applications/Outer.app/Contents/Helpers/Inner.app", appName: "Inner")
            let b = try build(f)
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure != nil && o.adminOffer == .unavailable && fake.permissionCalls == 0 && fake.sendCalls == 0, "S14b nested in another bundle", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s14c", appRelativePath: "Applications/Vendor/Tool.app", appName: "Tool")
            let b = try build(f)
            let (offer, _) = AdminMoveFacts.offer(
                errorKind: UInt32(MV_ERR_PERMISSION), required: true, sourceStillExists: true, uncertain: false,
                plan: b.plan, url: f.app, environment: environment(f)
            )
            try expect(offer == .finderWithPassword, "S14c one plain folder inside the root is accepted")
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s14d", appRelativePath: "Applications/Vendor.bundle/Tool.app", appName: "Tool")
            let b = try build(f)
            let (offer, _) = AdminMoveFacts.offer(
                errorKind: UInt32(MV_ERR_PERMISSION), required: true, sourceStillExists: true, uncertain: false,
                plan: b.plan, url: f.app, environment: environment(f)
            )
            try expect(offer == .unavailable, "S14d a package folder is not accepted")
            scenarios += 1
        }

        // S15: the Trash is not a normal folder of the user.
        do {
            let f = try makeFixture(root: root, id: "s15a")
            let b = try build(f)
            let fake = fakeFinder(f)
            let missing = f.root.appendingPathComponent("no-trash", isDirectory: true)
            let o = finderMove(f, b, fake, environment(f), trash: missing)
            try expect(o.failure == trashRefusal(bundle: b.bundle.url, trash: missing), "S15a ADMIN_QUEUE TRASH_READY refuses a missing Trash", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S15a Finder is never asked", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S15a nothing moved, everything unattempted", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s15b")
            let b = try build(f)
            let fake = fakeFinder(f)
            let link = f.root.appendingPathComponent("trash-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.trash)
            let o = finderMove(f, b, fake, environment(f), trash: link)
            try expect(o.failure == trashRefusal(bundle: b.bundle.url, trash: link), "S15b ADMIN_QUEUE TRASH_READY refuses a Trash that is a symlink", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S15b Finder is never asked", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S15b nothing moved, everything unattempted", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s15c")
            let b = try build(f)
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f, trashOwner: 502))
            try expect(o.failure == trashRefusal(bundle: b.bundle.url, trash: f.trash), "S15c ADMIN_QUEUE TRASH_READY refuses a Trash of another user", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S15c Finder is never asked", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S15c nothing moved, everything unattempted", o)
            scenarios += 1
        }

        // S16: the bundle carries a flag that stops moves.
        do {
            let f = try makeFixture(root: root, id: "s16")
            let path = f.app.path
            guard chflags(path, UInt32(UF_IMMUTABLE)) == 0 else { throw failure("S16 could not set uchg") }
            defer { chflags(path, 0) }
            let b = try build(f)
            let fake = fakeFinder(f)
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.failure == gateRefusal(b.bundle.url), "S16 the gate refuses a flagged bundle", o)
            try expect(fake.permissionCalls == 0 && fake.sendCalls == 0, "S16 Finder is never asked", o)
            try expect(o.adminOffer == .unavailable, "S16 nothing offered", o)
            try expect(o.movedPaths.isEmpty && o.unattemptedPaths == [b.bundle.url.path, b.related.url.path], "S16 nothing moved, everything unattempted", o)
            scenarios += 1
        }

        // S17: a retry after a request that moved nothing.
        do {
            let f = try makeFixture(root: root, id: "s17")
            let b = try build(f)
            let fake = fakeFinder(f)
            let trashed = f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            let counter = AttemptCounter()
            fake.sendAction = { url in
                if counter.next() == 1 { return -128 }
                relocate(url, to: trashed)
                return 0
            }
            let env = environment(f)
            let first = finderMove(f, b, fake, env)
            try expect(first.adminOffer == .finderWithPassword && first.uncertainPaths.isEmpty && first.failure != nil, "S17 first attempt may be retried", first)
            let second = finderMove(f, b, fake, env)
            try expect(second.movedPaths == [b.bundle.url.path, b.related.url.path] && second.failure == nil, "S17 second attempt moves everything", second)
            try expect(fake.permissionCalls == 2 && fake.sendCalls == 2, "S17 two permission checks, two events", second)
            scenarios += 1
        }

        // S18: the old dialog is confirmed late, after a timeout.
        do {
            let f = try makeFixture(root: root, id: "s18")
            let b = try build(f)
            let fake = fakeFinder(f)
            fake.sendAction = { _ in -1712 }
            let env = environment(f)
            let first = finderMove(f, b, fake, env)
            try expect(first.adminOffer == .finderWithPassword && first.uncertainPaths.isEmpty, "S18 first attempt timed out in place", first)
            relocate(f.app, to: f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true))
            let second = finderMove(f, b, fake, env)
            try expect(second.failure?.contains("no longer at its path") == true, "S18 the retry sees the bundle is gone", second)
            try expect(second.adminOffer == .unavailable && second.uncertainPaths.isEmpty, "S18 no offer, nothing uncertain", second)
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 1, "S18 no new request", second)
            scenarios += 1
        }

        // S19: a related item changes while Finder works.
        do {
            let f = try makeFixture(root: root, id: "s19")
            let b = try build(f)
            let fake = fakeFinder(f)
            let trashed = f.trash.appendingPathComponent("Admin Fixture.app", isDirectory: true)
            let extra = f.relatedFolder.appendingPathComponent("late.bin")
            fake.sendAction = { url in
                relocate(url, to: trashed)
                try? Data("late".utf8).write(to: extra)
                return 0
            }
            let o = finderMove(f, b, fake, environment(f))
            try expect(o.movedPaths == [b.bundle.url.path], "S19 only the bundle moved", o)
            try expect(o.failure != nil && o.unattemptedPaths == [b.related.url.path] && o.uncertainPaths.isEmpty, "S19 the changed related item is not moved", o)
            scenarios += 1
        }

        // S20: the reviewed bundle is replaced after ADMIN_ITEM and before ADMIN_SEND. The change is made
        // by the environment hook on the second read of the Trash owner (ADMIN_SEND, TRASH_READY), so
        // ADMIN_QUEUE and ADMIN_ITEM have already passed and only HANDLE_UNCHANGED can stop the send.
        do {
            let f = try makeFixture(root: root, id: "s20a")
            let b = try build(f)
            let fake = fakeFinder(f)
            let aside = f.applications.appendingPathComponent("aside.app", isDirectory: true)
            let app = f.app
            let swaps = AttemptCounter()
            let env = environment(f, onTrashOwner: { read in
                guard read == 2 else { return }
                _ = swaps.next()
                relocate(app, to: aside)
                try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            })
            let o = finderMove(f, b, fake, env)
            try expect(swaps.count == 1, "S20a the swap ran once, inside ADMIN_SEND", o)
            try expect(o.failure == changedBeforeSend(b.bundle.url), "S20a HANDLE_UNCHANGED refuses a folder with the same name", o)
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 0, "S20a the permission was checked in the queue, the event is never sent", o)
            try expect(o.movedPaths.isEmpty && o.uncertainPaths.isEmpty, "S20a nothing moved, nothing uncertain", o)
            try expect(o.unattemptedPaths == [b.bundle.url.path, b.related.url.path] && o.adminOffer == .finderWithPassword, "S20a everything unattempted, retry stays offered", o)
            try expect(exists(aside) && exists(f.app) && exists(f.relatedFolder), "S20a the reviewed bundle, the new folder and the related item are untouched", o)
            try expect(isEmpty(f.trash) && !exists(f.moverTrash), "S20a nothing reached the Trash", o)
            scenarios += 1
        }
        do {
            let f = try makeFixture(root: root, id: "s20b")
            let b = try build(f)
            let fake = fakeFinder(f)
            let applications = f.applications
            let relocated = f.root.appendingPathComponent("Applications-real", isDirectory: true)
            let swaps = AttemptCounter()
            let env = environment(f, onTrashOwner: { read in
                guard read == 2 else { return }
                _ = swaps.next()
                try? FileManager.default.moveItem(at: applications, to: relocated)
                try? FileManager.default.createSymbolicLink(at: applications, withDestinationURL: relocated)
            })
            let o = finderMove(f, b, fake, env)
            try expect(swaps.count == 1, "S20b the folder was replaced by a symlink once, inside ADMIN_SEND", o)
            try expect(o.failure == changedBeforeSend(b.bundle.url), "S20b HANDLE_UNCHANGED refuses a symlinked path component", o)
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 0, "S20b the permission was checked in the queue, the event is never sent", o)
            try expect(o.movedPaths.isEmpty && o.uncertainPaths.isEmpty, "S20b nothing moved, nothing uncertain", o)
            try expect(o.unattemptedPaths == [b.bundle.url.path, b.related.url.path] && o.adminOffer == .finderWithPassword, "S20b everything unattempted, retry stays offered", o)
            try expect(exists(relocated.appendingPathComponent("Admin Fixture.app")) && exists(f.relatedFolder), "S20b the reviewed bundle and the related item are untouched", o)
            try expect(isEmpty(f.trash) && !exists(f.moverTrash), "S20b nothing reached the Trash", o)
            scenarios += 1
        }

        // S21: the handle on the reviewed bundle cannot be opened (ADMIN_ITEM, OPEN_HANDLE).
        do {
            let f = try makeFixture(root: root, id: "s21")
            let b = try build(f)
            let fake = fakeFinder(f)
            let opens = AttemptCounter()
            let o = finderMove(f, b, fake, environment(f), openHandle: { _ in
                _ = opens.next()
                return nil
            })
            try expect(opens.count == 1, "S21 the handle was asked for once", o)
            try expect(o.failure == handleRefusal(b.bundle.url), "S21 OPEN_HANDLE refuses when the handle cannot be opened", o)
            try expect(fake.permissionCalls == 1 && fake.sendCalls == 0, "S21 the permission was checked in the queue, the event is never sent", o)
            try expect(o.movedPaths.isEmpty && o.uncertainPaths.isEmpty, "S21 nothing moved, nothing uncertain", o)
            try expect(o.unattemptedPaths == [b.bundle.url.path, b.related.url.path] && o.adminOffer == .finderWithPassword, "S21 everything unattempted, retry stays offered", o)
            try expect(exists(f.app) && exists(f.relatedFolder) && isEmpty(f.trash) && !exists(f.moverTrash), "S21 nothing was touched", o)
            scenarios += 1
        }

        print("ADMIN_MOVE_SMOKE_OK scenarios=\(scenarios)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String, _ outcome: AppRemovalOutcome? = nil) throws {
        if !condition() {
            throw failure("FAILED: \(message)" + (outcome.map { "\n  \(describe($0))" } ?? ""))
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "AdminMoveSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
    var count: Int { lock.withLock { value } }
}
