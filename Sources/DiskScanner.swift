import Foundation

struct DiskScanner: Sendable {
    let maxDepth: Int
    let maxChildrenPerFolder: Int

    private var seenFileIdentifiers: Set<String> = []
    private var seenDirectoryIdentifiers: Set<String> = []
    private var skippedSymbolicLinks = 0
    private var skippedMountPoints = 0
    private var incompleteManifestEvents = 0

    init(maxDepth: Int = 6, maxChildrenPerFolder: Int = 72) {
        self.maxDepth = Int(sr_depth_limit(Int64(maxDepth)))
        self.maxChildrenPerFolder = Int(sr_visible_children_limit(Int64(maxChildrenPerFolder)))
    }

    mutating func scan(root: URL, counter: ScanCounter) throws -> ScanSnapshot {
        let startedAt = Date()
        let normalizedRoot = root.standardizedFileURL
        if let identity = FileIdentity.read(for: normalizedRoot) {
            seenDirectoryIdentifiers.insert(identity)
        }
        let node = try scanNode(normalizedRoot, depth: 0, counter: counter)
            ?? DiskNode(
                url: normalizedRoot,
                name: normalizedRoot.lastPathComponent.isEmpty ? normalizedRoot.path : normalizedRoot.lastPathComponent,
                size: 0,
                fileCount: 0,
                directoryCount: 0,
                unreadableCount: 1,
                isDirectory: true
            )
        return ScanSnapshot(
            root: node,
            startedAt: startedAt,
            finishedAt: Date(),
            skippedSymbolicLinks: skippedSymbolicLinks,
            skippedMountPoints: skippedMountPoints
        )
    }

    /// Maps one entry; what to do with it is decided by Specs/scan_rules.t27 (sr_map_action).
    private mutating func scanNode(_ url: URL, depth: Int, counter: ScanCounter) throws -> DiskNode? {
        try checkCancellation()
        counter.record(url)

        let values = try? url.resourceValues(forKeys: resourceKeys)
        let isDirectory = values?.isDirectory == true
        let isPackage = values?.isPackage == true
        let capturedIdentity = values == nil ? nil : FileIdentity.read(for: url)
        let linkKey = values != nil && !isDirectory && values?.isSymbolicLink != true
            ? FileIdentity.hardLinkKeyIfNeeded(for: url)
            : nil
        let action = sr_map_action(
            values != nil,
            values?.isSymbolicLink == true,
            values?.isVolume == true,
            isDirectory,
            isPackage,
            UInt32(depth),
            UInt32(maxDepth),
            linkKey.map { seenFileIdentifiers.contains($0) } ?? false,
            capturedIdentity != nil,
            capturedIdentity.map { seenDirectoryIdentifiers.contains($0) } ?? false
        )

        switch action {
        case UInt32(SR_UNREADABLE):
            return DiskNode(
                url: url,
                name: displayName(for: url),
                size: 0,
                fileCount: 0,
                directoryCount: 0,
                unreadableCount: 1,
                isDirectory: false
            )
        case UInt32(SR_SYMLINK):
            skippedSymbolicLinks += 1
            return DiskNode(
                url: url,
                resourceIdentifier: capturedIdentity,
                fingerprint: ContentFingerprint.node(
                    name: displayName(for: url),
                    identity: capturedIdentity,
                    size: 0,
                    modificationDate: values?.contentModificationDate,
                    isDirectory: false,
                    children: nil
                ),
                name: displayName(for: url),
                size: 0,
                fileCount: 0,
                directoryCount: 0,
                unreadableCount: 0,
                isDirectory: false
            )
        case UInt32(SR_SKIP_MOUNT):
            skippedMountPoints += 1
            incompleteManifestEvents += 1
            return nil
        case UInt32(SR_FILE_REPEAT_LINK), UInt32(SR_FILE):
            let size = values.map(allocatedSize(from:)) ?? 0
            let repeated = action == UInt32(SR_FILE_REPEAT_LINK)
            if !repeated, let linkKey { seenFileIdentifiers.insert(linkKey) }
            return DiskNode(
                url: url,
                resourceIdentifier: capturedIdentity,
                fingerprint: ContentFingerprint.node(
                    name: displayName(for: url),
                    identity: capturedIdentity,
                    size: size,
                    modificationDate: values?.contentModificationDate,
                    isDirectory: false,
                    children: nil
                ),
                name: displayName(for: url),
                size: repeated ? 0 : size,
                fileCount: repeated ? 0 : 1,
                directoryCount: 0,
                unreadableCount: 0,
                isDirectory: false
            )
        case UInt32(SR_SKIP_SEEN_FOLDER):
            incompleteManifestEvents += 1
            return nil
        default:
            break
        }

        if depth > 0, let capturedIdentity { seenDirectoryIdentifiers.insert(capturedIdentity) }
        guard let values else { return nil }

        if action == UInt32(SR_MEASURE) {
            let measured = try measureDirectory(
                url,
                capturedIdentity: capturedIdentity,
                capturedValues: values,
                counter: counter
            )
            return DiskNode(
                url: url,
                resourceIdentifier: capturedIdentity,
                fingerprint: measured.fingerprint,
                name: displayName(for: url),
                size: measured.size,
                fileCount: measured.fileCount,
                directoryCount: measured.directoryCount,
                unreadableCount: measured.unreadableCount,
                isDirectory: true,
                isPackage: isPackage
            )
        }

        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch {
            return DiskNode(
                url: url,
                resourceIdentifier: FileIdentity.read(for: url),
                name: displayName(for: url),
                size: 0,
                fileCount: 0,
                directoryCount: 1,
                unreadableCount: 1,
                isDirectory: true,
                isPackage: isPackage
            )
        }

        var accumulator = ChildAccumulator(maxVisibleChildren: maxChildrenPerFolder)
        for entry in entries {
            try checkCancellation()
            let incompleteBefore = incompleteManifestEvents
            if let child = try scanNode(entry, depth: depth + 1, counter: counter) {
                accumulator.add(child)
            }
            if incompleteManifestEvents != incompleteBefore {
                accumulator.invalidateFingerprint()
            }
        }

        let identityAfter = FileIdentity.read(for: url)
        let identityStayedStable = sr_folder_fingerprint_holds(
            capturedIdentity != nil,
            identityAfter != nil,
            identityAfter == capturedIdentity
        )
        return DiskNode(
            url: url,
            resourceIdentifier: capturedIdentity,
            fingerprint: identityStayedStable ? ContentFingerprint.node(
                name: displayName(for: url),
                identity: capturedIdentity,
                size: accumulator.totalSize,
                modificationDate: values.contentModificationDate,
                isDirectory: true,
                children: accumulator.totalFingerprint
            ) : nil,
            name: displayName(for: url),
            size: accumulator.totalSize,
            fileCount: accumulator.totalFileCount,
            directoryCount: 1 + accumulator.totalDirectoryCount,
            unreadableCount: accumulator.totalUnreadableCount,
            isDirectory: true,
            isPackage: isPackage,
            children: accumulator.finishedChildren()
        )
    }

    private mutating func measureDirectory(
        _ url: URL,
        capturedIdentity: String?,
        capturedValues: URLResourceValues,
        counter: ScanCounter
    ) throws -> Measurement {
        try checkCancellation()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch {
            return Measurement(size: 0, fileCount: 0, directoryCount: 1, unreadableCount: 1, fingerprint: nil)
        }

        var result = Measurement(
            size: 0,
            fileCount: 0,
            directoryCount: 1,
            unreadableCount: 0,
            fingerprint: .empty
        )
        for entry in entries {
            try checkCancellation()
            counter.record(entry)
            let values = try? entry.resourceValues(forKeys: resourceKeys)
            let isDirectory = values?.isDirectory == true
            let nestedIdentity = values != nil && isDirectory && values?.isSymbolicLink != true && values?.isVolume != true
                ? FileIdentity.read(for: entry)
                : nil
            let linkKey = values != nil && !isDirectory && values?.isSymbolicLink != true && values?.isVolume != true
                ? FileIdentity.hardLinkKeyIfNeeded(for: entry)
                : nil
            let action = sr_measure_action(
                values != nil,
                values?.isSymbolicLink == true,
                values?.isVolume == true,
                isDirectory,
                linkKey.map { seenFileIdentifiers.contains($0) } ?? false,
                nestedIdentity != nil,
                nestedIdentity.map { seenDirectoryIdentifiers.contains($0) } ?? false
            )
            switch action {
            case UInt32(SR_UNREADABLE):
                result.unreadableCount += 1
            case UInt32(SR_SYMLINK):
                skippedSymbolicLinks += 1
                result.addFingerprint(
                    ContentFingerprint.node(
                        name: displayName(for: entry),
                        identity: FileIdentity.read(for: entry),
                        size: 0,
                        modificationDate: values?.contentModificationDate,
                        isDirectory: false,
                        children: nil
                    )
                )
            case UInt32(SR_SKIP_MOUNT):
                skippedMountPoints += 1
                incompleteManifestEvents += 1
                result.addFingerprint(nil)
            case UInt32(SR_SKIP_SEEN_FOLDER):
                incompleteManifestEvents += 1
                result.addFingerprint(nil)
            case UInt32(SR_MEASURE):
                if let nestedIdentity { seenDirectoryIdentifiers.insert(nestedIdentity) }
                if let values {
                    let nested = try measureDirectory(
                        entry,
                        capturedIdentity: nestedIdentity,
                        capturedValues: values,
                        counter: counter
                    )
                    result.add(nested)
                }
            case UInt32(SR_FILE_REPEAT_LINK):
                result.addFingerprint(
                    ContentFingerprint.node(
                        name: displayName(for: entry),
                        identity: FileIdentity.read(for: entry),
                        size: values.map(allocatedSize(from:)) ?? 0,
                        modificationDate: values?.contentModificationDate,
                        isDirectory: false,
                        children: nil
                    )
                )
            default:
                if let linkKey { seenFileIdentifiers.insert(linkKey) }
                let size = values.map(allocatedSize(from:)) ?? 0
                result.size += size
                result.fileCount += 1
                result.addFingerprint(
                    ContentFingerprint.node(
                        name: displayName(for: entry),
                        identity: FileIdentity.read(for: entry),
                        size: size,
                        modificationDate: values?.contentModificationDate,
                        isDirectory: false,
                        children: nil
                    )
                )
            }
        }
        let identityAfter = FileIdentity.read(for: url)
        if sr_folder_fingerprint_holds(capturedIdentity != nil, identityAfter != nil, identityAfter == capturedIdentity) {
            result.fingerprint = ContentFingerprint.node(
                name: displayName(for: url),
                identity: capturedIdentity,
                size: result.size,
                modificationDate: capturedValues.contentModificationDate,
                isDirectory: true,
                children: result.fingerprint
            )
        } else {
            result.fingerprint = nil
        }
        return result
    }

    private var resourceKeys: Set<URLResourceKey> {
        [
            .nameKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isVolumeKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileSizeKey,
            .totalFileAllocatedSizeKey
        ]
    }

    private func allocatedSize(from values: URLResourceValues) -> Int64 {
        sr_allocated_size(
            values.totalFileAllocatedSize != nil, Int64(values.totalFileAllocatedSize ?? 0),
            values.fileAllocatedSize != nil, Int64(values.fileAllocatedSize ?? 0),
            values.totalFileSize != nil, Int64(values.totalFileSize ?? 0),
            values.fileSize != nil, Int64(values.fileSize ?? 0)
        )
    }

    private func displayName(for url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}

private struct Measurement {
    var size: Int64
    var fileCount: Int
    var directoryCount: Int
    var unreadableCount: Int
    var fingerprint: ContentFingerprint?

    mutating func add(_ other: Measurement) {
        size += other.size
        fileCount += other.fileCount
        directoryCount += other.directoryCount
        unreadableCount += other.unreadableCount
        addFingerprint(other.fingerprint)
    }

    mutating func addFingerprint(_ other: ContentFingerprint?) {
        guard var current = fingerprint, let other else {
            fingerprint = nil
            return
        }
        current.combine(other)
        fingerprint = current
    }
}

private struct ChildAccumulator {
    let maxRetained: Int
    private(set) var retained: [DiskNode] = []
    private var discardedSize: Int64 = 0
    private var discardedFileCount = 0
    private var discardedDirectoryCount = 0
    private var discardedUnreadableCount = 0
    private var discardedNodeCount = 0

    private(set) var totalSize: Int64 = 0
    private(set) var totalFileCount = 0
    private(set) var totalDirectoryCount = 0
    private(set) var totalUnreadableCount = 0
    private(set) var totalFingerprint: ContentFingerprint? = .empty

    init(maxVisibleChildren: Int) {
        maxRetained = Int(sr_retained_limit(UInt32(clamping: maxVisibleChildren)))
        retained.reserveCapacity(maxRetained)
    }

    mutating func add(_ node: DiskNode) {
        totalSize += node.size
        totalFileCount += node.fileCount
        totalDirectoryCount += node.directoryCount
        totalUnreadableCount += node.unreadableCount
        if var fingerprint = totalFingerprint, let childFingerprint = node.fingerprint {
            fingerprint.combine(childFingerprint)
            totalFingerprint = fingerprint
        } else {
            totalFingerprint = nil
        }

        let smallestIndex = retained.indices.min(by: { retained[$0].size < retained[$1].size })
        switch sr_keep_child(
            UInt32(clamping: retained.count),
            UInt32(clamping: maxRetained),
            smallestIndex.map { retained[$0].size } ?? 0,
            node.size
        ) {
        case UInt32(SR_RETAIN):
            retained.append(node)
        case UInt32(SR_DISPLACE_SMALLEST):
            if let smallestIndex {
                let displaced = retained[smallestIndex]
                retained[smallestIndex] = node
                aggregate(displaced)
            }
        default:
            aggregate(node)
        }
    }

    mutating func finishedChildren() -> [DiskNode] {
        retained.sort { lhs, rhs in
            switch sr_order(lhs.size, rhs.size) {
            case UInt32(SR_FIRST): true
            case UInt32(SR_SECOND): false
            default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        guard discardedNodeCount > 0 else { return retained }
        let other = DiskNode(
            url: nil,
            name: "Other (\(discardedNodeCount))",
            size: discardedSize,
            fileCount: discardedFileCount,
            directoryCount: discardedDirectoryCount,
            unreadableCount: discardedUnreadableCount,
            isDirectory: true,
            isVirtual: true
        )
        return retained + [other]
    }

    mutating func invalidateFingerprint() {
        totalFingerprint = nil
    }

    private mutating func aggregate(_ node: DiskNode) {
        discardedNodeCount += 1
        discardedSize += node.size
        discardedFileCount += node.fileCount
        discardedDirectoryCount += node.directoryCount
        discardedUnreadableCount += node.unreadableCount
    }
}
