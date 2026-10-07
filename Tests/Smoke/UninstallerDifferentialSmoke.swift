import AppKit
import Foundation

/// Compares the App Uninstaller rules that existed in Swift before Specs/uninstaller_policy.t27
/// (Tests/Smoke/UninstallerLegacy.swift) with the rules that ask the spec, and fails on the first
/// difference.
@main
@MainActor
struct UninstallerDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var counts: [String: Int] = [:]

        // 1. Rule tables, every rule.
        for rule in AppRemovalRule.allCases {
            try same("match \(rule)", LegacyUninstallerPolicy.match(rule).rawValue, rule.match.rawValue)
            try same("risk \(rule)", LegacyUninstallerPolicy.risk(rule).rawValue, rule.risk.rawValue)
            try same("selected \(rule)", LegacyUninstallerPolicy.normallySelected(rule), rule.normallySelected)
            counts["tables", default: 0] += 1
        }
        for risk in AppRemovalRisk.allCases {
            try same("ack \(risk)", LegacyUninstallerPolicy.needsExtraAcknowledgement(risk), risk.needsExtraAcknowledgement)
        }

        // 2. Plan item decisions, exhaustively.
        for rule in AppRemovalRule.allCases {
            let required = rule == .application
            for duplicate in [false, true] {
                for signed in [false, true] {
                    for complete in [false, true] {
                        for unreadable in [0, 2] {
                            for mounts in [0, 1] {
                                for appIssue in [nil, "The volume is read-only."] as [String?] {
                                    let key = rule.match == .exactName ? "Vendor App" : "com.vendor.app"
                                    let before = LegacyUninstallerPolicy.itemDecision(
                                        rule: rule, key: key, required: required, duplicate: duplicate,
                                        signatureBacked: signed, complete: complete, unreadableCount: unreadable,
                                        foreignMounts: mounts, applicationIssue: required ? appIssue : nil
                                    )
                                    let after = AppRemovalDecisions.item(
                                        rule: rule, key: key, required: required, duplicate: duplicate,
                                        signatureBacked: signed, complete: complete, unreadableCount: unreadable,
                                        foreignMounts: mounts, applicationIssue: required ? appIssue : nil
                                    )
                                    try same("decision \(rule) dup=\(duplicate) signed=\(signed) complete=\(complete) unreadable=\(unreadable) mounts=\(mounts) appIssue=\(appIssue ?? "-")", before, after)
                                    counts["decisions", default: 0] += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Application eligibility: every real application, plus edge paths.
        let home = UserHome.url
        let apps = fixture.appendingPathComponent("Apps", isDirectory: true)
        let goodApp = apps.appendingPathComponent("Good.app", isDirectory: true)
        try FileManager.default.createDirectory(at: goodApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let fileApp = apps.appendingPathComponent("File.app")
        try Data("x".utf8).write(to: fileApp)
        let linkApp = apps.appendingPathComponent("Link.app")
        try? FileManager.default.removeItem(at: linkApp)
        try FileManager.default.createSymbolicLink(at: linkApp, withDestinationURL: goodApp)
        var appURLs = ApplicationCatalog.discover().map(\.url)
        appURLs += [goodApp, fileApp, linkApp, linkApp.appendingPathComponent("Contents"), apps,
                    home.appendingPathComponent("Library/Thing.app"), home.appendingPathComponent(".Trash/Old.app"),
                    home.appendingPathComponent("Dropbox/Tool.app"), home.appendingPathComponent("Documents/.Trashes/X.app"),
                    URL(fileURLWithPath: "/Volumes/NoSuchDisk/App.app"), URL(fileURLWithPath: "/usr/local/Thing.app"),
                    URL(fileURLWithPath: "/Library/Thing.app"), Bundle.main.bundleURL, Bundle.main.bundleURL.deletingLastPathComponent()]
        for url in appURLs {
            for identifier in [nil, "com.vendor.tool", "com.apple.thing"] as [String?] {
                let application = InstalledApplication(url: url, name: url.deletingPathExtension().lastPathComponent,
                                                       bundleIdentifier: identifier, version: nil, sourceLabel: "Fixture")
                try same("app \(url.path) id=\(identifier ?? "-")",
                         LegacyUninstallerPolicy.applicationEligibilityReason(for: application),
                         AppRemovalPolicy.applicationEligibilityReason(for: application))
                counts["applications", default: 0] += 1
            }
        }

        // 4. Item validation on fixture paths built by every rule.
        let fakeHome = fixture.appendingPathComponent("home", isDirectory: true)
        let application = InstalledApplication(url: goodApp, name: "Good", bundleIdentifier: "com.vendor.good",
                                               version: "1", sourceLabel: "Fixture")
        var items: [AppRemovalItem] = []
        for rule in AppRemovalRule.allCases {
            for key in ["com.vendor.good", "Good", "../escape", "group.com.vendor"] {
                guard let url = rule.expectedURL(applicationURL: goodApp, homeURL: fakeHome, key: key)?.standardizedFileURL else { continue }
                if rule != .application {
                    if url.pathExtension.isEmpty || url.pathExtension == "savedState" {
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        try Data("v".utf8).write(to: url.appendingPathComponent("data"))
                    } else {
                        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data("v".utf8).write(to: url)
                    }
                }
                var scanner = DiskScanner()
                let node = try scanner.scan(root: url, counter: ScanCounter()).root
                for issue in [nil, "Could not capture a complete snapshot of the item."] as [String?] {
                    items.append(AppRemovalItem(id: url.path, node: node, rule: rule, key: key, explanation: "",
                                                isRequired: rule == .application, isDefaultSelected: false,
                                                eligibilityIssue: issue, riskOverride: nil))
                }
            }
        }
        // An item whose recorded path does not match its rule.
        let stray = fakeHome.appendingPathComponent("Library/Caches/stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        var strayScanner = DiskScanner()
        items.append(AppRemovalItem(id: stray.path, node: try strayScanner.scan(root: stray, counter: ScanCounter()).root,
                                    rule: .identifierCache, key: "com.vendor.good", explanation: "", isRequired: false,
                                    isDefaultSelected: false, eligibilityIssue: nil, riskOverride: nil))
        for item in items {
            for candidate in [nil, item.url, item.url.deletingLastPathComponent()] as [URL?] {
                for requirePresence in [true, false] {
                    for app in [application,
                                InstalledApplication(url: fileApp, name: "File", bundleIdentifier: "com.vendor.good", version: nil, sourceLabel: "Fixture"),
                                InstalledApplication(url: goodApp, name: "Good", bundleIdentifier: "com.other.id", version: nil, sourceLabel: "Fixture")] {
                        try same("item \(item.rule) \(item.url.path) candidate=\(candidate?.path ?? "-") presence=\(requirePresence) app=\(app.url.lastPathComponent)/\(app.bundleIdentifier ?? "-") issue=\(item.eligibilityIssue != nil)",
                                 LegacyUninstallerPolicy.validate(item, application: app, homeURL: fakeHome, candidateURL: candidate, requireApplicationPresence: requirePresence),
                                 AppRemovalPolicy.validate(item, application: app, homeURL: fakeHome, candidateURL: candidate, requireApplicationPresence: requirePresence))
                        counts["items", default: 0] += 1
                    }
                }
            }
        }

        // 5. Continuing an old plan against the real state of this Mac.
        let installed = ApplicationCatalog.discover()
        var plans: [InstalledApplication] = Array(installed.prefix(6))
        plans += [
            InstalledApplication(url: fixture.appendingPathComponent("Gone.app"), name: "Gone", bundleIdentifier: "com.vendor.gone", version: nil, sourceLabel: "Fixture"),
            InstalledApplication(url: fixture.appendingPathComponent("Gone.app"), name: "Gone", bundleIdentifier: nil, version: nil, sourceLabel: "Fixture"),
            InstalledApplication(url: fixture.appendingPathComponent("Gone.app"), name: installed.first?.name ?? "Safari", bundleIdentifier: nil, version: nil, sourceLabel: "Fixture"),
            InstalledApplication(url: goodApp, name: "Good", bundleIdentifier: "com.vendor.good", version: nil, sourceLabel: "Fixture"),
            InstalledApplication(url: goodApp, name: "Good", bundleIdentifier: "", version: nil, sourceLabel: "Fixture")
        ]
        // Apps LaunchServices knows outside the standard folders (nested, running elsewhere, this build).
        let catalogPaths = Set(installed.map(\.id))
        var registeredElsewhere = NSWorkspace.shared.runningApplications.compactMap { running -> String? in
            guard let url = running.bundleURL?.standardizedFileURL, !catalogPaths.contains(url.path) else { return nil }
            return running.bundleIdentifier
        }
        registeredElsewhere += ["io.github.dmitrii-f-t27.DiskBloom", "com.apple.iphonesimulator", "com.apple.dt.instruments"]
        for identifier in Set(registeredElsewhere).sorted() where !installed.contains(where: { $0.bundleIdentifier == identifier }) {
            plans.append(InstalledApplication(url: fixture.appendingPathComponent("Gone.app"), name: "Gone",
                                              bundleIdentifier: identifier, version: nil, sourceLabel: "Fixture"))
        }
        for planApplication in plans {
            let plan = AppRemovalPlan(application: planApplication, items: [], hasDuplicateBundleIdentifier: false,
                                      bundleIdentifierIsSignatureBacked: false, validatedSignature: nil,
                                      hasPrivilegedComponents: false, applicationEligibilityIssue: nil)
            try same("continuation \(planApplication.url.path) id=\(planApplication.bundleIdentifier ?? "-")",
                     LegacyUninstallerPolicy.continuationEligibilityReason(for: plan),
                     AppRemovalPolicy.continuationEligibilityReason(for: plan))
            counts["continuations", default: 0] += 1
        }

        let summary = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        print("UNINSTALLER_DIFFERENTIAL_OK \(summary)")
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else {
            throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "UninstallerDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
