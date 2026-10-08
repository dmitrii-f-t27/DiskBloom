import Darwin
import Foundation

/// The Possible Leftovers rules as they were written in Swift before Specs/leftovers_policy.t27.
/// Kept only as the oracle of the differential test.
enum LegacyLeftoversPolicy {
    static func risk(_ rule: OrphanDataRule) -> OrphanDataRisk {
        switch rule {
        case .cache, .savedState, .log:
            .disposable
        case .httpStorage, .webKit:
            .privateState
        case .applicationSupport, .container, .applicationScripts:
            .persistentData
        }
    }


    static func needsExtraAcknowledgement(_ risk: OrphanDataRisk) -> Bool { risk != .disposable }

    static func confidence(_ rules: Set<OrphanDataRule>) -> OrphanDataConfidence {
        rules.count >= 2 ? .probable : .possible
    }

    static func claimReason(_ index: OrphanOwnerIndex, for identifier: String) -> String? {
        let claims = index.claims
        guard let canonical = OrphanBundleIdentifier.canonical(identifier) else {
            return "The bundle ID failed the safety check."
        }
        if let reason = claims[canonical] { return reason }
        if let related = claims.keys.sorted().first(where: {
            $0.hasPrefix(canonical + ".") || canonical.hasPrefix($0 + ".")
        }) {
            return "An installed or active related bundle ID \(related) was found."
        }
        if let namespace = OrphanBundleIdentifier.vendorNamespace(canonical),
           let sibling = claims.keys.sorted().first(where: {
               OrphanBundleIdentifier.vendorNamespace($0) == namespace
           }) {
            return "An installed or active bundle ID \(sibling) from the same namespace \(namespace) was found."
        }
        return nil
    }


    /// The candidate filter of the old analyzer, as one function.
    static func candidate(entry: URL, rule: OrphanDataRule, homeURL normalizedHome: URL) -> (String, String)? {
        guard let rawIdentifier = rule.identifier(from: entry),
                      let canonical = OrphanBundleIdentifier.canonical(rawIdentifier),
                      !canonical.hasPrefix("com.apple."),
                      !canonical.hasPrefix("group."),
                      rule.expectedURL(homeURL: normalizedHome, identifier: rawIdentifier)
                        .standardizedFileURL.path == entry.standardizedFileURL.path,
                      let values = try? entry.resourceValues(forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey,
                          .volumeIsLocalKey,
                          .volumeIsReadOnlyKey,
                          .isUbiquitousItemKey
                      ]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      values.volumeIsLocal == true,
                      values.volumeIsReadOnly != true,
                      values.isUbiquitousItem != true,
                      !AppRemovalPathSafety.pathHasSymlinkedComponent(entry) else {
                    return nil
                }
        return (rawIdentifier, canonical)
    }

    static func validate(
        _ item: OrphanDataItem,
        homeURL: URL = UserHome.url,
        candidateURL: URL? = nil
    ) -> String? {
        if let issue = item.eligibilityIssue { return "\(item.url.path): \(issue)" }
        guard OrphanBundleIdentifier.canonical(item.identifier) == item.canonicalIdentifier else {
            return "The bundle ID no longer passes the safety check: \(item.identifier)"
        }
        let original = item.url.standardizedFileURL
        let candidate = (candidateURL ?? original).standardizedFileURL
        guard candidate.path == original.path else {
            return "The coordinated path changed: \(original.path)"
        }
        let expected = item.rule.expectedURL(homeURL: homeURL, identifier: item.identifier)
            .standardizedFileURL
        guard expected.path == original.path else {
            return "The path does not match an exact allowed rule: \(original.path)"
        }
        if AppRemovalPathSafety.pathHasSymlinkedComponent(candidate) {
            return "The path contains a symbolic link: \(candidate.path)"
        }
        guard let values = try? candidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isUbiquitousItemKey
        ]), values.isDirectory == true, values.isSymbolicLink != true else {
            return "The item is no longer a regular folder: \(candidate.path)"
        }
        if values.volumeIsLocal != true { return "Network or unknown volume is protected: \(candidate.path)" }
        if values.volumeIsReadOnly == true { return "The volume is read-only: \(candidate.path)" }
        if values.isUbiquitousItem == true { return "Cloud item is protected: \(candidate.path)" }
        if let issue = LegacyLeftoversPolicy.treeEligibilityIssue(for: item.node, homeURL: homeURL) { return "\(candidate.path): \(issue)" }
        return SnapshotValidator.validate(item.node, candidateURL: candidate)
    }

    static func treeEligibilityIssue(for node: DiskNode, homeURL: URL) -> String? {
        guard let url = node.url else { return "Could not obtain the exact path." }
        guard node.resourceIdentifier != nil, node.fingerprint != nil else {
            return "The folder snapshot is incomplete; removal is disabled."
        }
        guard node.unreadableCount == 0 else {
            return "It contains inaccessible items; removal is disabled."
        }
        let library = homeURL.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(library + "/") else {
            return "The path is outside the user Library."
        }
        return inspectTree(at: url)
    }

    static func inspectTree(at root: URL) -> String? {
        let rootDevice = FileIdentity.deviceID(for: root)
        var urls: [URL] = [root]
        var enumerationIssue: String?
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationIssue = "Could not read \(url.path): \(error.localizedDescription)"
                return false
            }
        ) {
            for case let url as URL in enumerator { urls.append(url) }
        } else {
            return "Could not enumerate the folder contents."
        }
        if let enumerationIssue { return enumerationIssue }

        let executableBundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
        for url in urls {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &info)
            }
            guard result == 0 else { return "Could not check permissions: \(url.path)" }
            if info.st_uid != geteuid() {
                return "It contains an item owned by another user: \(url.path)"
            }
            let immutableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
            if info.st_flags & immutableFlags != 0 {
                return "It contains an item protected by flags: \(url.path)"
            }
            if FileIdentity.deviceID(for: url) != rootDevice {
                return "A boundary of another volume was found inside: \(url.path)"
            }
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFLNK {
                return "A symbolic link was found inside: \(url.path)"
            }
            if executableBundleExtensions.contains(url.pathExtension.lowercased()) {
                return "An executable bundle was found inside: \(url.path)"
            }
            let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
            if fileType == S_IFREG, info.st_mode & executableBits != 0 {
                return "An executable file was found inside: \(url.path)"
            }
        }
        return nil
    }
}
