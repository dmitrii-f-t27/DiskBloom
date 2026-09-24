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
        self.maxDepth = max(2, maxDepth)
        self.maxChildrenPerFolder = max(12, maxChildrenPerFolder)
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

    private mutating func scanNode(_ url: URL, depth: Int, counter: ScanCounter) throws -> DiskNode? {
        try checkCancellation()
        counter.record(url)

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            return DiskNode(
                url: url,
                name: displayName(for: url),
                size: 0,
                fileCount: 0,
                directoryCount: 0,
                unreadableCount: 1,
                isDirectory: false
            )
        }

        if values.isSymbolicLink == true {
            skippedSymbolicLinks += 1
            let identity = FileIdentity.read(for: url)
            return DiskNode(
                url: url,
                resourceIdentifier: identity,
                fingerprint: ContentFingerprint.node(
                    name: displayName(for: url),
                    identity: identity,
                    size: 0,
                    modificationDate: values.contentModificationDate,
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
        }

        if depth > 0, values.isVolume == true {
            skippedMountPoints += 1
            incompleteManifestEvents += 1
            return nil
        }

        let capturedIdentity = FileIdentity.read(for: url)
        let isDirectory = values.isDirectory == true
        let isPackage = values.isPackage == true
        if !isDirectory {
            if let identifier = FileIdentity.hardLinkKeyIfNeeded(for: url) {
                if seenFileIdentifiers.contains(identifier) {
                    let size = allocatedSize(from: values)
                    return DiskNode(
                        url: url,
                        resourceIdentifier: capturedIdentity,
                        fingerprint: ContentFingerprint.node(
                            name: displayName(for: url),
                            identity: capturedIdentity,
                            size: size,
                            modificationDate: values.contentModificationDate,
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
                }
                seenFileIdentifiers.insert(identifier)
            }
            let size = allocatedSize(from: values)
            return DiskNode(
                url: url,
                resourceIdentifier: capturedIdentity,
                fingerprint: ContentFingerprint.node(
                    name: displayName(for: url),
                    identity: capturedIdentity,
                    size: size,
                    modificationDate: values.contentModificationDate,
                    isDirectory: false,
                    children: nil
                ),
                name: displayName(for: url),
                size: size,
                fileCount: 1,
                directoryCount: 0,
                unreadableCount: 0,
                isDirectory: false
            )
        }


        if depth > 0, let capturedIdentity {
            if seenDirectoryIdentifiers.contains(capturedIdentity) {
                incompleteManifestEvents += 1
                return nil
            }
            seenDirectoryIdentifiers.insert(capturedIdentity)
        }

        if depth >= maxDepth || (isPackage && depth > 0) {
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

        let identityStayedStable = FileIdentity.read(for: url) == capturedIdentity
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
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: resourceKeys)
            } catch {
                result.unreadableCount += 1
                continue
            }
            if values.isSymbolicLink == true {
                skippedSymbolicLinks += 1
                result.addFingerprint(
                    ContentFingerprint.node(
                        name: displayName(for: entry),
                        identity: FileIdentity.read(for: entry),
                        size: 0,
                        modificationDate: values.contentModificationDate,
                        isDirectory: false,
                        children: nil
                    )
                )
                continue
            }
            if values.isVolume == true {
                skippedMountPoints += 1
                incompleteManifestEvents += 1
                result.addFingerprint(nil)
                continue
            }
            if values.isDirectory == true {
                let nestedIdentity = FileIdentity.read(for: entry)
                if let nestedIdentity {
                    if seenDirectoryIdentifiers.contains(nestedIdentity) {
                        incompleteManifestEvents += 1
                        result.addFingerprint(nil)
                        continue
                    }
                    seenDirectoryIdentifiers.insert(nestedIdentity)
                }
                let nested = try measureDirectory(
                    entry,
                    capturedIdentity: nestedIdentity,
                    capturedValues: values,
                    counter: counter
                )
                result.add(nested)
            } else {
                if let identifier = FileIdentity.hardLinkKeyIfNeeded(for: entry) {
                    if seenFileIdentifiers.contains(identifier) {
                        result.addFingerprint(
                            ContentFingerprint.node(
                                name: displayName(for: entry),
                                identity: FileIdentity.read(for: entry),
                                size: allocatedSize(from: values),
                                modificationDate: values.contentModificationDate,
                                isDirectory: false,
                                children: nil
                            )
                        )
                        continue
                    }
                    seenFileIdentifiers.insert(identifier)
                }
                result.size += allocatedSize(from: values)
                result.fileCount += 1
                let leafFingerprint = ContentFingerprint.node(
                    name: displayName(for: entry),
                    identity: FileIdentity.read(for: entry),
                    size: allocatedSize(from: values),
                    modificationDate: values.contentModificationDate,
                    isDirectory: false,
                    children: nil
                )
                result.addFingerprint(leafFingerprint)
            }
        }
        if FileIdentity.read(for: url) == capturedIdentity {
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
        Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.totalFileSize
                ?? values.fileSize
                ?? 0
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
        maxRetained = max(1, maxVisibleChildren - 1)
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

        guard retained.count >= maxRetained else {
            retained.append(node)
            return
        }
        guard let smallestIndex = retained.indices.min(by: { retained[$0].size < retained[$1].size }) else {
            aggregate(node)
            return
        }
        if node.size > retained[smallestIndex].size {
            let displaced = retained[smallestIndex]
            retained[smallestIndex] = node
            aggregate(displaced)
        } else {
            aggregate(node)
        }
    }

    mutating func finishedChildren() -> [DiskNode] {
        retained.sort { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.size > rhs.size
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
