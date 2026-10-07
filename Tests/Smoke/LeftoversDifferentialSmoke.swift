import Darwin
import Foundation

/// Compares the Possible Leftovers rules that existed in Swift before Specs/leftovers_policy.t27
/// (Tests/Smoke/LeftoversLegacy.swift) with the rules that ask the spec, and fails on the first
/// difference. With DISKBLOOM_DIFF_REAL=1 it also compares every real candidate in ~/Library.
@main
@MainActor
struct LeftoversDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var counts: [String: Int] = [:]

        // 1. Tables.
        for rule in OrphanDataRule.allCases {
            try same("risk \(rule)", LegacyLeftoversPolicy.risk(rule).rawValue, rule.risk.rawValue)
            counts["tables", default: 0] += 1
        }
        for risk in OrphanDataRisk.allCases {
            try same("ack \(risk)", LegacyLeftoversPolicy.needsExtraAcknowledgement(risk), risk.needsExtraAcknowledgement)
        }
        for size in 0...OrphanDataRule.allCases.count {
            let rules = Set(OrphanDataRule.allCases.prefix(size))
            try same("confidence \(size)", LegacyLeftoversPolicy.confidence(rules).rawValue,
                     OrphanDataConfidence(distinctRules: rules.count).rawValue)
        }

        // 2. Owner claims.
        let index = OrphanOwnerIndex(claims: [
            "com.vendor.app": "Installed application found: /Applications/App.app",
            "com.vendor.app.helper": "Embedded component found",
            "io.other.tool": "Running application found: Tool",
            "org.single": "Launch agent found"
        ])
        let identifiers = ["com.vendor.app", "COM.VENDOR.APP", "com.vendor.app.helper", "com.vendor.app.helper.x",
                           "com.vendor", "com.vendor.other", "io.other.tool.agent", "io.other", "io.other.thing",
                           "org.single", "org.single.sub", "net.free.app", "x", "..bad", "bad id", "com.apple.thing",
                           "", "a.b", "org.singleton"]
        for identifier in identifiers {
            try same("claim \(identifier)", LegacyLeftoversPolicy.claimReason(index, for: identifier), index.claimReason(for: identifier))
            counts["claims", default: 0] += 1
        }

        // 3. Candidate filter over fixture entries and every real ~/Library entry.
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        func folder(_ relative: String) throws -> URL {
            let url = home.appendingPathComponent(relative, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        _ = try folder("Library/Caches/io.fixture.plain")
        _ = try folder("Library/Caches/com.apple.fixture")
        _ = try folder("Library/Caches/group.io.fixture")
        _ = try folder("Library/Caches/Not An ID")
        _ = try folder("Library/Saved Application State/io.fixture.plain.savedState")
        _ = try folder("Library/Saved Application State/io.fixture.nosuffix")
        _ = try folder("Library/Containers/IO.Fixture.Upper")
        try Data("f".utf8).write(to: home.appendingPathComponent("Library/Caches/io.fixture.file"))
        let linkEntry = home.appendingPathComponent("Library/Logs/io.fixture.link")
        try FileManager.default.createDirectory(at: linkEntry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: linkEntry)
        try FileManager.default.createSymbolicLink(at: linkEntry, withDestinationURL: home.appendingPathComponent("Library/Caches/io.fixture.plain"))
        for root in [home, UserHome.url] {
            for rule in OrphanDataRule.allCases {
                let directory = root.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(rule.relativeRoot, isDirectory: true)
                let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for entry in entries {
                    for checkedRule in [rule, OrphanDataRule.allCases[(rule.t27Code == 0 ? 1 : 0)]] {
                        let before = LegacyLeftoversPolicy.candidate(entry: entry, rule: checkedRule, homeURL: root)
                        let after = OrphanedAppDataAnalyzer.candidate(entry: entry, rule: checkedRule, homeURL: root)
                        try same("candidate \(entry.path) rule=\(checkedRule)", before.map { "\($0.0)|\($0.1)" }, after.map { "\($0.0)|\($0.1)" })
                        counts["candidates", default: 0] += 1
                    }
                }
            }
        }

        // 4. Tree checks and the move check on fixture folders with unsafe contents.
        let kinds = ["clean", "executable", "symlink", "bundle", "flagged", "unreadable", "empty"]
        var lockedPaths: [URL] = []
        var items: [OrphanDataItem] = []
        for kind in kinds {
            let identifier = "io.fixture.\(kind)"
            let url = try folder("Library/Application Support/\(identifier)")
            switch kind {
            case "clean":
                try Data("data".utf8).write(to: url.appendingPathComponent("state.json"))
            case "executable":
                let tool = url.appendingPathComponent("tool")
                try Data("#!/bin/sh\n".utf8).write(to: tool)
                chmod(tool.path, 0o755)
            case "symlink":
                try? FileManager.default.createSymbolicLink(at: url.appendingPathComponent("link"), withDestinationURL: home)
            case "bundle":
                try FileManager.default.createDirectory(at: url.appendingPathComponent("Helper.app/Contents"), withIntermediateDirectories: true)
            case "flagged":
                let file = url.appendingPathComponent("locked.txt")
                try Data("x".utf8).write(to: file)
                chflags(file.path, UInt32(UF_IMMUTABLE))
                lockedPaths.append(file)
            case "unreadable":
                let inner = url.appendingPathComponent("private", isDirectory: true)
                try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: inner.appendingPathComponent("secret"))
                chmod(inner.path, 0o000)
                lockedPaths.append(inner)
            default:
                break
            }
            var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
            let node = try scanner.scan(root: url, counter: ScanCounter()).root
            for issue in [nil, "It contains inaccessible items; removal is disabled."] as [String?] {
                for canonical in [identifier, "io.fixture.other"] {
                    items.append(OrphanDataItem(id: url.path, identifier: identifier, canonicalIdentifier: canonical,
                                                rule: .applicationSupport, node: node, eligibilityIssue: issue))
                }
            }
        }
        defer {
            for path in lockedPaths {
                chflags(path.path, 0)
                chmod(path.path, 0o755)
            }
        }
        for item in items {
            for homeURL in [home, UserHome.url] {
                try same("tree \(item.url.path) home=\(homeURL.path)",
                         LegacyLeftoversPolicy.treeEligibilityIssue(for: item.node, homeURL: homeURL),
                         OrphanDataPolicy.treeEligibilityIssue(for: item.node, homeURL: homeURL))
                for candidate in [nil, item.url, item.url.deletingLastPathComponent()] as [URL?] {
                    try same("move \(item.url.path) home=\(homeURL.path) candidate=\(candidate?.path ?? "-") issue=\(item.eligibilityIssue != nil) canonical=\(item.canonicalIdentifier)",
                             LegacyLeftoversPolicy.validate(item, homeURL: homeURL, candidateURL: candidate),
                             OrphanDataPolicy.validate(item, homeURL: homeURL, candidateURL: candidate))
                    counts["moves", default: 0] += 1
                }
            }
        }

        // 5. Every real unclaimed candidate on this Mac.
        if ProcessInfo.processInfo.environment["DISKBLOOM_DIFF_REAL"] == "1" {
            let realHome = UserHome.url
            var candidates: [(URL, String, String, OrphanDataRule)] = []
            for rule in OrphanDataRule.allCases {
                let directory = realHome.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(rule.relativeRoot, isDirectory: true)
                for entry in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                    if let (raw, canonical) = OrphanedAppDataAnalyzer.candidate(entry: entry, rule: rule, homeURL: realHome) {
                        candidates.append((entry, raw, canonical, rule))
                    }
                }
            }
            let owners = OrphanOwnerIndex.capture(candidateIdentifiers: Set(candidates.map(\.2)), homeURL: realHome)
            for (entry, raw, canonical, rule) in candidates {
                try same("real claim \(canonical)", LegacyLeftoversPolicy.claimReason(owners, for: canonical), owners.claimReason(for: canonical))
                counts["realClaims", default: 0] += 1
                guard owners.claimReason(for: canonical) == nil else { continue }
                var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
                let node = try scanner.scan(root: entry, counter: ScanCounter()).root
                let item = OrphanDataItem(id: entry.path, identifier: raw, canonicalIdentifier: canonical, rule: rule, node: node, eligibilityIssue: nil)
                try same("real tree \(entry.path)", LegacyLeftoversPolicy.treeEligibilityIssue(for: node, homeURL: realHome),
                         OrphanDataPolicy.treeEligibilityIssue(for: node, homeURL: realHome))
                try same("real move \(entry.path)", LegacyLeftoversPolicy.validate(item, homeURL: realHome),
                         OrphanDataPolicy.validate(item, homeURL: realHome))
                counts["realFolders", default: 0] += 1
            }
        }

        let summary = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        print("LEFTOVERS_DIFFERENTIAL_OK \(summary)")
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else { throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LeftoversDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
