import Foundation

/// SnapshotValidator as written in Swift before Specs/scan_rules.t27. Oracle only.
enum LegacySnapshotValidator {
    static func validate(_ node: DiskNode, candidateURL: URL? = nil) -> String? {
        guard !node.isVirtual, let originalURL = node.url else {
            return "An aggregate group cannot be reviewed as a single item."
        }
        if let candidateURL,
           candidateURL.standardizedFileURL.path != originalURL.standardizedFileURL.path {
            return "The item’s path changed after confirmation. Rescan: \(originalURL.path)"
        }
        let url = candidateURL ?? originalURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "The item no longer exists: \(url.path)"
        }
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                return "The item became a symbolic link after scanning: \(url.path)"
            }
            guard let expected = node.resourceIdentifier,
                  let actual = FileIdentity.read(for: url) else {
                return "Could not confirm the item’s identity: \(url.path). Rescan."
            }
            if actual != expected {
                return "The item changed after scanning: \(url.path). Rescan."
            }
        } catch {
            return "Could not re-verify \(url.path): \(error.localizedDescription)"
        }
        guard let expectedFingerprint = node.fingerprint else {
            return "No complete content snapshot exists for the item: \(url.path). Rescan."
        }
        do {
            var scanner = DiskScanner()
            let refreshed = try scanner.scan(root: url, counter: ScanCounter()).root
            guard refreshed.resourceIdentifier == node.resourceIdentifier,
                  refreshed.isDirectory == node.isDirectory,
                  refreshed.fingerprint == expectedFingerprint,
                  refreshed.size == node.size,
                  refreshed.fileCount == node.fileCount,
                  refreshed.directoryCount == node.directoryCount else {
                return "Contents changed after analysis: \(url.path). Review the updated data before moving."
            }
        } catch {
            return "Could not re-measure \(url.path): \(error.localizedDescription)"
        }
        return nil
    }
}

