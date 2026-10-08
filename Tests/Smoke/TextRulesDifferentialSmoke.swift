import Foundation

/// Compares the Swift text helpers that existed before Specs/text_rules.t27 (LegacyText) with the
/// helpers that ask the spec, over real names, bundle IDs and paths on this Mac and a deterministic
/// corpus of generated strings, and fails on the first difference.
@main
struct TextRulesDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var counts: [String: Int] = [:]
        let home = UserHome.url

        // Names: real Library entries, application names and bundle IDs, plus generated strings.
        var names: [String] = []
        for relative in ["Library/Caches", "Library/Application Support", "Library/Preferences", "Library/Containers",
                         "Library/Logs", "Library/Saved Application State", "Library/Group Containers", ".cache", ""] {
            names += (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(relative).path)) ?? []
        }
        for application in ApplicationCatalog.discover() {
            names.append(application.name)
            names.append(application.url.lastPathComponent)
            if let identifier = application.bundleIdentifier { names.append(identifier) }
        }
        var generator = SplitMix(seed: 0x27_D15C_B100)
        let alphabet = ["a", "Z", "0", "9", ".", ".", "-", "_", "é", "e\u{301}", " ", "/", ":", "\0", "Я", "😀", "@", "\n", "\u{00A0}", "A"]
        for _ in 0..<20_000 {
            let length = Int(generator.next() % 14)
            names.append((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }.joined())
        }
        names += ["", ".", "..", "a.b", "a..b", ".a.b", "a.b.", "ab", "abc", "a-b.c", "-a.b", "a.-b", "a.b-",
                  "com.apple.Safari", "COM.APPLE.x", "group.com.x", String(repeating: "a", count: 254) + ".b",
                  String(repeating: "a", count: 255) + ".b", String(repeating: "é", count: 120) + ".x",
                  String(repeating: "e\u{301}", count: 130) + ".x", "a/b", "a:b", " a.b ", "x.y.z.w", "x..y.z", "a.b..c.d"]

        for name in names {
            try same("safeIdentifier \(debug(name))", LegacyText.safeIdentifier(name), AppRemovalPathSafety.safeIdentifier(name))
            try same("safeDisplayName \(debug(name))", LegacyText.safeDisplayName(name), AppRemovalPathSafety.safeDisplayName(name))
            let canonical = LegacyText.canonical(name)
            try same("canonical \(debug(name))", canonical, OrphanBundleIdentifier.canonical(name))
            if let canonical {
                try same("namespace \(name)", LegacyText.vendorNamespace(canonical), OrphanBundleIdentifier.vendorNamespace(canonical))
            }
            let legacyPrefixes = LegacyText.ownerPrefixes(name)
            var newPrefixes: [String] = []
            var drop = 1
            while let prefix = T27Text.identifierPrefix(name.lowercased(), dropping: drop) {
                newPrefixes.append(prefix)
                drop += 1
            }
            try same("ownerPrefixes \(debug(name))", legacyPrefixes, newPrefixes)
            try same("apple \(debug(name))", name.hasPrefix("com.apple."), T27Text.hasApplePrefix(name))
            try same("group \(debug(name))", name.hasPrefix("group."), T27Text.hasGroupPrefix(name))
            counts["names", default: 0] += 1
        }

        // Order: Swift's < on strings against the spec's byte order on composed text.
        var orders = 0
        var swiftInconsistent = 0
        for (index, a) in names.enumerated() where index % 3 == 0 {
            for offset in [1, 2, 7, 31] {
                let b = names[(index + offset) % names.count]
                // Swift's own < is not an ordering when one string is a prefix of the other in a different
                // Unicode normalisation ("e\u{301}" vs "\u{e9}/": neither <, > nor ==); the spec keeps the
                // consistent order of composed bytes there, so such pairs are counted, not compared.
                if !(a < b), !(b < a), a != b {
                    swiftInconsistent += 1
                    continue
                }
                try same("less \(debug(a)) | \(debug(b))", a < b, T27Text.less(a, b))
                orders += 1
            }
        }
        counts["orders"] = orders
        counts["swiftInconsistentPairs"] = swiftInconsistent

        // Paths: real ones from this Mac, synthetic edge cases and Unicode normalisation variants.
        let root = fixture.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("caf\u{e9}/sub"), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("caf\u{e9}"))
        var paths: [String] = ["/", "/Volumes", "/Volumes/X", "/Volumes/X/y", "/Volumes//X/y", "/VolumesX/a/b",
                               home.path, home.path + "/Library", home.path + "/Libraryx", home.path + "/.Trash/a",
                               home.path + "/a/.Trashes", home.path + "/a/.Trashx", "/x/A.app", "/x/A.APP", "/x/.app",
                               "/x/A.app.zip", "/x/a.b.app", "/x/app", "/x/..app", root.path, link.path,
                               root.path + "/caf\u{e9}", root.path + "/cafe\u{301}", root.path + "/caf\u{e9}/sub",
                               root.path + "/cafe\u{301}/sub", link.path + "/sub"]
        for base in [home.path, "/Applications", "/System/Library", "/Volumes", home.path + "/Library"] {
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                paths.append(base + "/" + entry)
                if paths.count % 7 == 0 {
                    for inner in ((try? FileManager.default.contentsOfDirectory(atPath: base + "/" + entry)) ?? []).prefix(10) {
                        paths.append(base + "/" + entry + "/" + inner)
                    }
                }
            }
        }
        for path in paths {
            try same("trash \(path)", LegacyText.hasTrashComponent(path), T27Text.hasTrashComponent(path))
            try same("external \(path)", LegacyText.onExternalVolume(path), T27Text.onExternalVolume(path))
            try same("app \(path)", LegacyText.hasAppExtension(path), T27Text.hasAppExtension(path))
            let url = URL(fileURLWithPath: path)
            try same("symlink \(path)", LegacyText.pathHasSymlinkedComponent(url), AppRemovalPathSafety.pathHasSymlinkedComponent(url))
            if path.hasPrefix(home.path + "/") {
                let relative = String(path.dropFirst(home.path.count + 1))
                try same("library \(relative)", LegacyText.libraryArea(relative: relative), Int(T27Text.libraryArea(relative: relative)))
                try same("hidden \(relative)", LegacyText.hiddenFirstComponent(relative: relative), T27Text.hiddenFirstComponent(relative: relative))
            }
            counts["paths", default: 0] += 1
        }
        for relative in ["Library", "Library/", "Library/Caches", "Library/CachesX", "Library/Caches/a", "Library/Developer/Xcode/DerivedData",
                         "Library/Developer/Xcode/DerivedDataX", "Library/Developer/Xcode/DerivedData/x", "Library/Developer", "LibraryX",
                         ".cache", ".cache/x", ".cachex", ".ssh", ".", "", "a/.b", "library/caches"] {
            try same("library \(relative)", LegacyText.libraryArea(relative: relative), Int(T27Text.libraryArea(relative: relative)))
            try same("hidden \(relative)", LegacyText.hiddenFirstComponent(relative: relative), T27Text.hiddenFirstComponent(relative: relative))
        }
        var pairs = 0
        for (index, a) in paths.enumerated() {
            for offset in [0, 1, 2, 3, 5, 8, 13, 21, 34] {
                let b = paths[(index + offset) % paths.count]
                try same("within \(a) | \(b)", LegacyText.within(a, b), T27Text.within(a, b))
                try same("inside \(a) | \(b)", LegacyText.inside(a, b), T27Text.inside(a, b))
                try same("same \(a) | \(b)", a == b, T27Text.same(a, b))
                try same("descendant \(a) | \(b)", LegacyText.strictDescendant(a, of: b), T27Text.strictDescendant(a, of: b))
                pairs += 1
            }
            try same("descendant of root \(a)", LegacyText.strictDescendant(a, of: "/"), T27Text.strictDescendant(a, of: "/"))
            let parent = (a as NSString).deletingLastPathComponent
            try same("within parent \(a)", LegacyText.within(a, parent), T27Text.within(a, parent))
            try same("contains child \(a)", LegacyText.within(parent, a), T27Text.within(parent, a))
            pairs += 2
        }
        counts["pairs"] = pairs

        let summary = counts.keys.sorted().map { "\($0)=\(counts[$0]!)" }.joined(separator: " ")
        print("TEXT_RULES_DIFFERENTIAL_OK \(summary)")
    }

    private static func debug(_ text: String) -> String {
        text.unicodeScalars.map { $0.value < 32 || $0.value > 126 ? "\\u{\(String($0.value, radix: 16))}" : String($0) }.joined()
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else { throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TextRulesDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
