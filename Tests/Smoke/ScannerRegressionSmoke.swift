import Foundation

@main
struct ScannerRegressionSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "ScannerRegressionSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture root required"])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.bin")
        let second = nested.appendingPathComponent("second.bin")
        let third = nested.appendingPathComponent("third.bin")
        try Data(repeating: 1, count: 900).write(to: first)
        try Data(repeating: 2, count: 1_200).write(to: second)
        try Data(repeating: 3, count: 1_500).write(to: third)
        try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("first-hardlink.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("first-symlink.bin"), withDestinationURL: first)

        var scanner = DiskScanner(maxDepth: 4, maxChildrenPerFolder: 12)
        let snapshot = try scanner.scan(root: root, counter: ScanCounter())
        precondition(snapshot.root.fileCount == 3, "expected 3 unique regular files, got \(snapshot.root.fileCount)")
        precondition(snapshot.skippedSymbolicLinks == 1, "expected one skipped symlink")
        precondition(snapshot.root.size >= 12_288, "allocated size is unexpectedly small: \(snapshot.root.size)")
        precondition(snapshot.root.children.contains(where: { $0.name == "nested" }), "nested directory missing")
        print("SCANNER_REGRESSION_OK files=\(snapshot.root.fileCount) bytes=\(snapshot.root.size) symlinks=\(snapshot.skippedSymbolicLinks)")
    }
}
