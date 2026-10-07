import Darwin
import Foundation

/// Scans the same folders with the scanner written in Swift before Specs/scan_rules.t27 and
/// Specs/fingerprint.t27 (Tests/Smoke/ScannerLegacy.swift) and with the scanner that asks the specs,
/// and fails on the first difference anywhere in the two trees. Also compares SnapshotValidator.
@main
struct ScannerDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let tree = try buildFixture(at: fixture.appendingPathComponent("tree", isDirectory: true))
        var nodes = 0
        var roots: [URL] = [tree, URL(fileURLWithPath: "/System/Library/CoreServices"), URL(fileURLWithPath: "/Applications")]
        if ProcessInfo.processInfo.environment["DISKBLOOM_DIFF_REAL"] == "1" {
            roots.append(URL(fileURLWithPath: "/System/Library/Frameworks"))
            roots.append(UserHome.url.appendingPathComponent("Library/Caches/Homebrew"))
        }
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            for (depth, children) in [(6, 72), (2, 12), (8, 96), (3, 5)] {
                var legacy = LegacyDiskScanner(maxDepth: depth, maxChildrenPerFolder: children)
                var current = DiskScanner(maxDepth: depth, maxChildrenPerFolder: children)
                let before = try legacy.scan(root: root, counter: ScanCounter())
                let after = try current.scan(root: root, counter: ScanCounter())
                try same("\(root.path) skipped links", before.skippedSymbolicLinks, after.skippedSymbolicLinks)
                try same("\(root.path) skipped mounts", before.skippedMountPoints, after.skippedMountPoints)
                nodes += try compare(before.root, after.root, path: root.path)
            }
        }

        // SnapshotValidator: unchanged, changed, gone, moved path, link, aggregate, no identity, no fingerprint.
        var validations = 0
        let subject = tree.appendingPathComponent("subject", isDirectory: true)
        try FileManager.default.createDirectory(at: subject, withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: subject.appendingPathComponent("f.txt"))
        var scanner = DiskScanner()
        let node = try scanner.scan(root: subject, counter: ScanCounter()).root
        let variants: [(String, DiskNode, URL?)] = [
            ("unchanged", node, nil),
            ("same candidate", node, subject),
            ("other candidate", node, tree),
            ("aggregate", DiskNode(url: subject, name: "g", size: 1, fileCount: 1, directoryCount: 0, unreadableCount: 0, isDirectory: true, isVirtual: true), nil),
            ("no url", DiskNode(url: nil, name: "n", size: 1, fileCount: 1, directoryCount: 0, unreadableCount: 0, isDirectory: false), nil),
            ("no identity", DiskNode(url: subject, fingerprint: node.fingerprint, name: "s", size: node.size, fileCount: node.fileCount, directoryCount: node.directoryCount, unreadableCount: 0, isDirectory: true), nil),
            ("wrong identity", DiskNode(url: subject, resourceIdentifier: "1:2:3", fingerprint: node.fingerprint, name: "s", size: node.size, fileCount: node.fileCount, directoryCount: node.directoryCount, unreadableCount: 0, isDirectory: true), nil),
            ("no fingerprint", DiskNode(url: subject, resourceIdentifier: node.resourceIdentifier, name: "s", size: node.size, fileCount: node.fileCount, directoryCount: node.directoryCount, unreadableCount: 0, isDirectory: true), nil),
            ("wrong size", DiskNode(url: subject, resourceIdentifier: node.resourceIdentifier, fingerprint: node.fingerprint, name: "s", size: node.size + 1, fileCount: node.fileCount, directoryCount: node.directoryCount, unreadableCount: 0, isDirectory: true), nil),
            ("gone", DiskNode(url: tree.appendingPathComponent("missing"), resourceIdentifier: "x", fingerprint: node.fingerprint, name: "m", size: 0, fileCount: 0, directoryCount: 0, unreadableCount: 0, isDirectory: false), nil),
            ("link", DiskNode(url: tree.appendingPathComponent("link-to-sub"), resourceIdentifier: "x", fingerprint: node.fingerprint, name: "l", size: 0, fileCount: 0, directoryCount: 0, unreadableCount: 0, isDirectory: false), nil)
        ]
        for (label, variant, candidate) in variants {
            try same("snapshot \(label)", LegacySnapshotValidator.validate(variant, candidateURL: candidate), SnapshotValidator.validate(variant, candidateURL: candidate))
            validations += 1
        }
        try Data("v2 changed".utf8).write(to: subject.appendingPathComponent("f.txt"))
        try same("snapshot changed", LegacySnapshotValidator.validate(node), SnapshotValidator.validate(node))
        validations += 1

        print("SCANNER_DIFFERENTIAL_OK nodes=\(nodes) snapshots=\(validations)")
    }

    private static func buildFixture(at root: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        var deep = root
        for level in 0..<9 {
            deep = deep.appendingPathComponent("level\(level)", isDirectory: true)
            try fm.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data(repeating: UInt8(level), count: 100 * (level + 1)).write(to: deep.appendingPathComponent("data.bin"))
        }
        let many = root.appendingPathComponent("many", isDirectory: true)
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<110 {
            let size = index < 20 ? 4096 : 512 * (index % 13 + 1)
            try Data(repeating: 7, count: size).write(to: many.appendingPathComponent(String(format: "file-%03d.bin", index)))
        }
        let links = root.appendingPathComponent("links", isDirectory: true)
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        let original = links.appendingPathComponent("original.bin")
        try Data(repeating: 1, count: 9000).write(to: original)
        try fm.linkItem(at: original, to: links.appendingPathComponent("hard-a.bin"))
        try fm.linkItem(at: original, to: links.appendingPathComponent("hard-b.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link-to-sub"), withDestinationURL: many)
        try fm.createSymbolicLink(at: links.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("nowhere"))
        let package = root.appendingPathComponent("Tool.app/Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 3000).write(to: package.appendingPathComponent("Tool"))
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try Data("s".utf8).write(to: locked.appendingPathComponent("inner/secret"))
        chmod(locked.appendingPathComponent("inner").path, 0o000)
        return root
    }

    private static func compare(_ a: LegacyDiskNode, _ b: DiskNode, path: String) throws -> Int {
        let label = "\(path)/\(a.name)"
        try same("\(label) url", a.url?.path, b.url?.path)
        try same("\(label) identity", a.resourceIdentifier, b.resourceIdentifier)
        try same("\(label) fingerprint", a.fingerprint.map { "\($0.xor)|\($0.sum)|\($0.itemCount)" },
                 b.fingerprint.map { "\($0.xor)|\($0.sum)|\($0.itemCount)" })
        try same("\(label) name", a.name, b.name)
        try same("\(label) size", a.size, b.size)
        try same("\(label) counts", "\(a.fileCount)|\(a.directoryCount)|\(a.unreadableCount)",
                 "\(b.fileCount)|\(b.directoryCount)|\(b.unreadableCount)")
        try same("\(label) flags", "\(a.isDirectory)|\(a.isVirtual)|\(a.isPackage)", "\(b.isDirectory)|\(b.isVirtual)|\(b.isPackage)")
        try same("\(label) children", a.children.map(\.name), b.children.map(\.name))
        var count = 1
        for (left, right) in zip(a.children, b.children) {
            count += try compare(left, right, path: label)
        }
        return count
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else { throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ScannerDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
