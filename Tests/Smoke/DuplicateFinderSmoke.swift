import Darwin
import Foundation

private enum SmokeFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case .assertion(let message): message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure.assertion(message) }
}

private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

private func makeHardLink(from source: URL, to destination: URL) throws {
    let result = source.withUnsafeFileSystemRepresentation { sourcePath in
        destination.withUnsafeFileSystemRepresentation { destinationPath in
            guard let sourcePath, let destinationPath else { return Int32(-1) }
            return Darwin.link(sourcePath, destinationPath)
        }
    }
    guard result == 0 else {
        throw SmokeFailure.assertion("hard link fixture creation failed: \(errno)")
    }
}

@main
private struct DuplicateFinderSmoke {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("DiskBloomDuplicateSmoke-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let identical = Data(repeating: 0x4D, count: 8_193)
        let duplicateURLs = [
            root.appendingPathComponent("A/original.bin"),
            root.appendingPathComponent("B/copy-with-another-name.dat"),
            root.appendingPathComponent("C/third-copy.bin")
        ]
        for url in duplicateURLs { try write(identical, to: url) }

        try write(Data(repeating: 0x7E, count: identical.count), to: root.appendingPathComponent("same-size-different.bin"))
        try write(Data(repeating: 0x11, count: 4_096), to: root.appendingPathComponent("sample-collision-a.bin"))
        var middleDiff = Data(repeating: 0x11, count: 4_096)
        middleDiff[2_048] = 0x12
        try write(middleDiff, to: root.appendingPathComponent("sample-collision-b.bin"))
        try write(Data(repeating: 0xA5, count: 123), to: root.appendingPathComponent("unique-size.bin"))
        try write(Data(), to: root.appendingPathComponent("empty-a"))
        try write(Data(), to: root.appendingPathComponent("empty-b"))

        let hardLinkSource = root.appendingPathComponent("hard-link-source.bin")
        let hardLinkAlias = root.appendingPathComponent("hard-link-alias.bin")
        try write(Data(repeating: 0x31, count: 777), to: hardLinkSource)
        try makeHardLink(from: hardLinkSource, to: hardLinkAlias)

        let symlink = root.appendingPathComponent("visible-symlink.bin")
        try manager.createSymbolicLink(at: symlink, withDestinationURL: duplicateURLs[0])

        let package = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try write(identical, to: package.appendingPathComponent("Contents/Resources/inside.bin"))

        let actual = try DuplicateFinderScanner(chunkSize: 4_096).scan(root: root)
        try require(actual.groups.count == 1, "expected exactly one confirmed content group")
        guard let group = actual.groups.first else {
            throw SmokeFailure.assertion("missing duplicate group")
        }
        try require(group.files.count == 3, "expected three independent identical files")
        try require(group.duplicateCount == 2, "duplicate count must preserve one copy")
        try require(group.logicalDuplicateBytes == Int64(identical.count * 2), "logical duplicate byte formula is wrong")
        try require(Set(group.files.map(\.url.path)) == Set(duplicateURLs.map(\.path)), "unexpected path in confirmed group")
        try require(!group.files.contains(where: { $0.url.path.contains("Fixture.app") }), "package descendant was scanned")
        try require(!group.files.contains(where: { $0.url == symlink }), "symlink was treated as a file")
        try require(actual.skippedHardLinkCount == 2, "both hard-link paths must be excluded")
        try require(actual.skippedSymbolicLinkCount >= 1, "symlink skip was not counted")

        let repeated = try DuplicateFinderScanner(chunkSize: 4_096).scan(root: root)
        try require(
            repeated.groups.map { $0.files.map(\.url.path) } == actual.groups.map { $0.files.map(\.url.path) },
            "result ordering is not deterministic"
        )

        let collision = try DuplicateFinderScanner(
            chunkSize: 4_096,
            digestOverride: { _ in "forced-collision" }
        ).scan(root: root)
        try require(collision.groups.count == 1, "byte comparison did not split a forced digest collision")
        try require(collision.groups[0].files.count == 3, "forced collision created a false duplicate")

        let mutationRoot = root.appendingPathComponent("Mutation", isDirectory: true)
        let changing = mutationRoot.appendingPathComponent("a-changing.bin")
        let stable = mutationRoot.appendingPathComponent("b-stable.bin")
        try write(Data(repeating: 0x20, count: 5_000), to: changing)
        try write(Data(repeating: 0x20, count: 5_000), to: stable)
        let mutationScanner = DuplicateFinderScanner(
            chunkSize: 4_096,
            digestOverride: { url in
                if url.path == changing.path {
                    usleep(2_000)
                    try Data(repeating: 0x21, count: 5_000).write(to: url)
                }
                return "mutation-fixture"
            }
        )
        let mutationResult = try mutationScanner.scan(root: mutationRoot)
        try require(mutationResult.groups.isEmpty, "changed file was published as a duplicate")
        try require(mutationResult.unreadableOrChangedCount >= 1, "changed file was not reported as skipped")

        print("DUPLICATE_FINDER_SMOKE_OK")
    }
}
