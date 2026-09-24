import Foundation

@main
struct AppRemovalSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "AppRemovalSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture root required"])
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let app = fixture.appendingPathComponent("SafeTool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appendingPathComponent("Contents/MacOS/SafeTool"))

        let identifier = "com.example.safetool"
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "SafeTool",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "SafeTool"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exactPaths = [
            home.appendingPathComponent("Library/Caches/\(identifier)", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/\(identifier)", isDirectory: true)
        ]
        for path in exactPaths {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            try Data(path.lastPathComponent.utf8).write(to: path.appendingPathComponent("state.bin"))
        }
        let preference = home.appendingPathComponent("Library/Preferences/\(identifier).plist")
        try FileManager.default.createDirectory(at: preference.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preference".utf8).write(to: preference)

        let profile = InstalledApplication(
            url: app,
            name: "SafeTool",
            bundleIdentifier: identifier,
            version: "1",
            sourceLabel: "Fixture"
        )
        let plan = try ApplicationRemovalAnalyzer.buildPlan(
            for: profile,
            knownApplications: [profile],
            homeURL: home,
            progress: ScanCounter()
        )
        precondition(plan.items.count == 4, "expected app plus 3 exact candidates, got \(plan.items.count)")
        let cache = plan.items.first { $0.rule == .identifierCache }
        let support = plan.items.first { $0.rule == .identifierApplicationSupport }
        let pref = plan.items.first { $0.rule == .identifierPreference }
        precondition(!plan.bundleIdentifierIsSignatureBacked, "unsigned fixture must not be treated as signature-backed")
        precondition(cache?.isDefaultSelected == false, "unsigned exact cache should default off")
        precondition(pref?.isDefaultSelected == false, "unsigned exact preference should default off")
        precondition(support?.isDefaultSelected == false, "persistent support data should default off")
        for item in plan.items {
            precondition(
                AppRemovalPolicy.validate(item, application: profile, homeURL: home) == nil,
                "unchanged allowlisted item should validate: \(item.id)"
            )
        }

        guard let cacheItem = cache else { preconditionFailure("cache candidate missing") }
        let stagedApp = fixture.appendingPathComponent("SafeTool-staged.app", isDirectory: true)
        try FileManager.default.moveItem(at: app, to: stagedApp)
        precondition(
            AppRemovalPolicy.continuationEligibilityReason(for: plan) == nil,
            "continuation should remain eligible while the original app is absent and no replacement is installed"
        )
        precondition(
            AppRemovalPolicy.validate(
                cacheItem,
                application: profile,
                homeURL: home,
                requireApplicationPresence: false
            ) == nil,
            "captured related item must remain independently verifiable after the app move"
        )
        precondition(
            AppRemovalPolicy.validate(cacheItem, application: profile, homeURL: home) != nil,
            "normal preflight must still require the app before its move"
        )
        try FileManager.default.moveItem(at: stagedApp, to: app)
        precondition(
            AppRemovalPolicy.continuationEligibilityReason(for: plan) != nil,
            "continuation must be blocked if an app reappears at the original path"
        )

        let duplicate = InstalledApplication(
            url: fixture.appendingPathComponent("Duplicate.app", isDirectory: true),
            name: "Duplicate",
            bundleIdentifier: identifier,
            version: nil,
            sourceLabel: "Fixture"
        )
        let duplicatePlan = try ApplicationRemovalAnalyzer.buildPlan(
            for: profile,
            knownApplications: [profile, duplicate],
            homeURL: home,
            progress: ScanCounter()
        )
        precondition(duplicatePlan.hasDuplicateBundleIdentifier, "duplicate bundle ID must be detected")
        precondition(
            duplicatePlan.items.filter { $0.match == .exactIdentifier }.allSatisfy { !$0.isDefaultSelected },
            "duplicate-ID leftovers must default off"
        )

        precondition(AppRemovalPathSafety.safeIdentifier("../../Documents") == nil)
        precondition(AppRemovalPathSafety.safeIdentifier("com.example/escape") == nil)
        precondition(AppRemovalPathSafety.safeIdentifier("com..example") == nil)
        precondition(AppRemovalPathSafety.safeIdentifier(identifier) == identifier)

        let link = home.appendingPathComponent("Library/Caches/com.example.link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exactPaths[0])
        var linkScanner = DiskScanner()
        let linkNode = try linkScanner.scan(root: link, counter: ScanCounter()).root
        let linkItem = AppRemovalItem(
            id: link.path,
            node: linkNode,
            rule: .identifierCache,
            key: "com.example.link",
            explanation: "fixture",
            isRequired: false,
            isDefaultSelected: false,
            eligibilityIssue: nil,
            riskOverride: nil
        )
        precondition(
            AppRemovalPolicy.validate(linkItem, application: profile, homeURL: home) != nil,
            "symlinked candidate must be rejected"
        )

        let moveSource = fixture.appendingPathComponent("move-source.bin")
        let moveDestination = fixture.appendingPathComponent("move-destination.bin")
        try Data("relocation".utf8).write(to: moveSource)
        let relocationIdentity = FileIdentity.relocationIdentifier(for: moveSource)
        try FileManager.default.moveItem(at: moveSource, to: moveDestination)
        precondition(
            relocationIdentity != nil && relocationIdentity == FileIdentity.relocationIdentifier(for: moveDestination),
            "stable relocation identity must survive a same-volume move"
        )

        print("APP_REMOVAL_SMOKE_OK allowlist=3 unsigned=off duplicate=shared related-after-app=valid replacement=blocked malicious-id=blocked symlink=blocked relocation=stable")
    }
}
