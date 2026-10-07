import Foundation

/// Compares the Swift deletion policy that existed before Specs/deletion_policy.t27 (the oracle)
/// with the policy that asks the t27 spec, over real paths of many kinds, and fails on the first
/// difference in the refusal message.
@main
@MainActor
struct DeletionPolicyDifferentialSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw failure("fixture root required") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let root = fixture.appendingPathComponent("root", isDirectory: true)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: sub.appendingPathComponent("b.txt"))
        let link = root.appendingPathComponent("link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sub)

        let home = UserHome.url
        let items: [URL] = [
            root, sub, root.appendingPathComponent("a.txt"), sub.appendingPathComponent("b.txt"), link,
            link.appendingPathComponent("b.txt"),
            home,
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Library"),
            home.appendingPathComponent("Library/Caches"),
            home.appendingPathComponent("Library/Caches/com.example.app"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData"),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc"),
            home.appendingPathComponent("Library/Preferences/com.example.plist"),
            home.appendingPathComponent("Library/CachesExtra"),
            home.appendingPathComponent(".ssh/id_ed25519"),
            home.appendingPathComponent(".cache/uv"),
            home.appendingPathComponent(".cachefoo/x"),
            home.appendingPathComponent("My Drive/file"),
            home.appendingPathComponent("mlx/profiles/a"),
            home.appendingPathComponent(".Trash/old"),
            home.appendingPathComponent("Documents/.Trashes/x"),
            URL(fileURLWithPath: "/System/Library"),
            URL(fileURLWithPath: "/Applications/Safari.app"),
            URL(fileURLWithPath: "/Volumes/NoSuchDisk/folder"),
            URL(fileURLWithPath: "/Volumes/NoSuchDisk"),
            URL(fileURLWithPath: "/private/tmp/x")
        ]
        let scanRoots: [URL] = [URL(fileURLWithPath: "/"), home, root, home.appendingPathComponent("Library"),
                                URL(fileURLWithPath: "/Volumes/NoSuchDisk"), link]
        let fakeApp = sub.appendingPathComponent("DiskBloom.app")

        var compared = 0
        for item in items {
            let identity = FileIdentity.read(for: item)
            let nodes = [
                DiskNode(url: item, resourceIdentifier: identity ?? "fixture", name: item.lastPathComponent, size: 1,
                         fileCount: 1, directoryCount: 0, unreadableCount: 0, isDirectory: false),
                DiskNode(url: item, resourceIdentifier: nil, name: item.lastPathComponent, size: 1,
                         fileCount: 1, directoryCount: 0, unreadableCount: 0, isDirectory: false),
                DiskNode(url: item, name: "group", size: 1, fileCount: 1, directoryCount: 0,
                         unreadableCount: 0, isDirectory: true, isVirtual: true),
                DiskNode(url: nil, name: "none", size: 1, fileCount: 1, directoryCount: 0,
                         unreadableCount: 0, isDirectory: false)
            ]
            let actives: [URL?] = [nil, item, item.appendingPathComponent("child"), root]
            let candidates: [URL?] = [nil, item, item.deletingLastPathComponent()]
            for node in nodes {
                for scanRoot in scanRoots {
                    for active in actives {
                        for candidate in candidates {
                            for appURL in [Bundle.main.bundleURL, fakeApp, item] {
                                let before = LegacyDeletionPolicy.rejectionReason(
                                    for: node, scanRootURL: scanRoot, activeScanURL: active,
                                    candidateURL: candidate, appURL: appURL
                                )
                                let after = DeletionPolicy.rejectionReason(
                                    for: node, scanRootURL: scanRoot, activeScanURL: active,
                                    candidateURL: candidate, appURL: appURL
                                )
                                guard before == after else {
                                    throw failure("MISMATCH \(item.path) root=\(scanRoot.path) active=\(active?.path ?? "-") candidate=\(candidate?.path ?? "-") node=\(node.name) virtual=\(node.isVirtual) identity=\(node.resourceIdentifier != nil): Swift=\(before ?? "allowed") t27=\(after ?? "allowed")")
                                }
                                compared += 1
                            }
                        }
                    }
                }
            }
        }
        print("DELETION_POLICY_DIFFERENTIAL_OK cases=\(compared)")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "DeletionPolicyDifferentialSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
