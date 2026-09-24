import Foundation

@main
struct SafetySmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(domain: "SafetySmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "fixture and mutation paths required"])
        }
        let rootURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        var scanner = DiskScanner(maxDepth: 4, maxChildrenPerFolder: 12)
        let snapshot = try scanner.scan(root: rootURL, counter: ScanCounter())
        precondition(
            DeletionPolicy.rejectionReason(for: snapshot.root, scanRootURL: rootURL) != nil,
            "scan root must be protected"
        )
        guard let firstChild = snapshot.root.children.first else {
            preconditionFailure("fixture needs a child")
        }
        precondition(
            DeletionPolicy.rejectionReason(for: firstChild, scanRootURL: rootURL) == nil,
            "concrete child inside the selected home folder should be eligible"
        )
        precondition(
            DeletionPolicy.validateImmediatelyBeforeTrash(firstChild, scanRootURL: rootURL) == nil,
            "unchanged child must pass the refreshed manifest check"
        )
        let virtual = DiskNode(
            url: nil,
            name: "Other",
            size: 1,
            fileCount: 1,
            directoryCount: 0,
            unreadableCount: 0,
            isDirectory: true,
            isVirtual: true
        )
        precondition(
            DeletionPolicy.rejectionReason(for: virtual, scanRootURL: rootURL) != nil,
            "virtual aggregate must be protected"
        )
        let systemNode = DiskNode(
            url: URL(fileURLWithPath: "/System/Library"),
            name: "Library",
            size: 1,
            fileCount: 0,
            directoryCount: 1,
            unreadableCount: 0,
            isDirectory: true
        )
        precondition(
            DeletionPolicy.rejectionReason(for: systemNode, scanRootURL: rootURL) != nil,
            "system path must be protected"
        )

        let mutationRoot = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
        var mutationScanner = DiskScanner(maxDepth: 4, maxChildrenPerFolder: 12)
        let beforeMutation = try mutationScanner.scan(root: mutationRoot, counter: ScanCounter())
        guard let candidate = beforeMutation.root.children.first(where: { $0.name == "Candidate" }) else {
            preconditionFailure("mutation candidate missing")
        }
        let addedURL = mutationRoot.appendingPathComponent("Candidate/added-\(UUID().uuidString).txt")
        try Data("changed after scan".utf8).write(to: addedURL)
        precondition(
            DeletionPolicy.validateImmediatelyBeforeTrash(candidate, scanRootURL: mutationRoot) != nil,
            "changed directory manifest must be rejected"
        )
        precondition(
            DeletionPolicy.rejectionReason(
                for: candidate,
                scanRootURL: mutationRoot,
                candidateURL: mutationRoot.appendingPathComponent("RenamedCandidate")
            ) != nil,
            "coordinated URL path drift must be rejected"
        )
        print("SAFETY_SMOKE_OK root=blocked child=eligible virtual=blocked system=blocked manifest-change=blocked path-drift=blocked")
    }
}
