import CryptoKit
import Foundation

/// Compares the SHA-256 of Specs/duplicate_rules.t27 with CryptoKit, and the duplicate finder written
/// in Swift before the spec (Tests/Smoke/DuplicatesLegacy.swift) with the one that follows it.
@main
struct DuplicatesDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL

        // SHA-256 against CryptoKit.
        var generator = SplitMix(seed: 0x5A256)
        var hashes = 0
        var lengths = Array(0...300)
        for _ in 0..<200 { lengths.append(Int(generator.next() % 200_000)) }
        lengths += [4095, 4096, 4097, 8191, 8192, 1_048_576]
        for length in lengths {
            let data = (0..<length).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try same("sha256 length \(length)", expected, DuplicateSHA256.hex(of: data))
            var chunked = DuplicateSHA256()
            var start = 0
            while start < data.count {
                let step = 1 + Int(generator.next() % 9000)
                let end = min(data.count, start + step)
                chunked.update(data[start..<end])
                start = end
            }
            try same("sha256 chunked \(length)", expected, chunked.finalizeHex())
            hashes += 1
        }

        // The finder on a fixture with every special case, and on system folders.
        let tree = try buildFixture(at: fixture.appendingPathComponent("tree", isDirectory: true))
        var roots = [tree, URL(fileURLWithPath: "/System/Library/Fonts")]
        if ProcessInfo.processInfo.environment["DISKBLOOM_DIFF_REAL"] == "1" {
            roots.append(URL(fileURLWithPath: "/System/Library/CoreServices/Menu Extras"))
            roots.append(URL(fileURLWithPath: "/Library/Desktop Pictures"))
        }
        var scans = 0
        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            for chunk in [4096, 65_536, 1_048_576, 10] {
                let before = try LegacyDuplicateFinderScanner(chunkSize: chunk).scan(root: root)
                let after = try DuplicateFinderScanner(chunkSize: chunk).scan(root: root)
                try same("\(root.path) counts", counts(before), counts(after))
                try same("\(root.path) groups", before.groups.map { "\($0.id)|\($0.digest)|\($0.logicalSize)|\($0.files.map(\.url.path))|\($0.logicalDuplicateBytes)|\($0.duplicateCount)" },
                         after.groups.map { "\($0.id)|\($0.digest)|\($0.logicalSize)|\($0.files.map(\.url.path))|\($0.logicalDuplicateBytes)|\($0.duplicateCount)" })
                try same("\(root.path) totals", "\(before.duplicateFileCount)|\(before.logicalDuplicateBytes)", "\(after.duplicateFileCount)|\(after.logicalDuplicateBytes)")
                scans += 1
            }
        }
        for invalid in [tree.appendingPathComponent("link-to-dup"), tree.appendingPathComponent("a.txt"), URL(fileURLWithPath: "/nonexistent")] {
            let before = (try? LegacyDuplicateFinderScanner().scan(root: invalid)) == nil
            let after = (try? DuplicateFinderScanner().scan(root: invalid)) == nil
            try same("invalid root \(invalid.path)", before, after)
        }
        print("DUPLICATES_DIFFERENTIAL_OK hashes=\(hashes) scans=\(scans)")
    }

    private static func counts(_ r: LegacyDuplicateScanResult) -> String {
        "\(r.examinedFileCount)|\(r.candidateFileCount)|\(r.hashedFileCount)|\(r.skippedSymbolicLinkCount)|\(r.skippedPackageCount)|\(r.skippedMountCount)|\(r.skippedCloudPlaceholderCount)|\(r.skippedHardLinkCount)|\(r.unreadableOrChangedCount)"
    }

    private static func counts(_ r: DuplicateScanResult) -> String {
        "\(r.examinedFileCount)|\(r.candidateFileCount)|\(r.hashedFileCount)|\(r.skippedSymbolicLinkCount)|\(r.skippedPackageCount)|\(r.skippedMountCount)|\(r.skippedCloudPlaceholderCount)|\(r.skippedHardLinkCount)|\(r.unreadableOrChangedCount)"
    }

    private static func buildFixture(at root: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        let same = Data(repeating: 0x41, count: 70_000)
        try same.write(to: root.appendingPathComponent("a.txt"))
        try same.write(to: root.appendingPathComponent("sub/a-copy.txt"))
        try same.write(to: root.appendingPathComponent("sub/deeper/a-copy-2.txt"))
        var other = same
        other[69_999] = 0x42
        try other.write(to: root.appendingPathComponent("sub/near-miss.txt"))
        try Data("small".utf8).write(to: root.appendingPathComponent("s1"))
        try Data("small".utf8).write(to: root.appendingPathComponent("sub/s2"))
        try Data("smalx".utf8).write(to: root.appendingPathComponent("sub/s3"))
        try Data().write(to: root.appendingPathComponent("empty1"))
        try Data().write(to: root.appendingPathComponent("empty2"))
        let original = root.appendingPathComponent("linked.bin")
        try Data(repeating: 9, count: 3000).write(to: original)
        try fm.linkItem(at: original, to: root.appendingPathComponent("sub/hard.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link-to-dup"), withDestinationURL: root.appendingPathComponent("a.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link-dir"), withDestinationURL: root.appendingPathComponent("sub"))
        for blocked in [".Trash", "Backups.backupdb", "Thing.app"] {
            let folder = root.appendingPathComponent(blocked, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try same.write(to: folder.appendingPathComponent("hidden-copy.txt"))
        }
        try same.write(to: root.appendingPathComponent(".hidden-copy.txt"))
        return root
    }

    private static func same<T: Equatable>(_ label: String, _ before: T, _ after: T) throws {
        guard before == after else { throw failure("MISMATCH \(label): Swift=\(before) t27=\(after)") }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DuplicatesDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
