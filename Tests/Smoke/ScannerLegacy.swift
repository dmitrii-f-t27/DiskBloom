import Foundation

/// The scanner, fingerprint and node types as they were written in Swift before Specs/fingerprint.t27 and
/// Specs/scan_rules.t27. Renamed with a Legacy prefix; oracle only.
struct LegacyFingerprint: Sendable, Equatable {
    private(set) var xor: UInt64
    private(set) var sum: UInt64
    private(set) var itemCount: UInt64

    static let empty = LegacyFingerprint(xor: 0, sum: 0, itemCount: 0)

    static func node(
        name: String,
        identity: String?,
        size: Int64,
        modificationDate: Date?,
        isDirectory: Bool,
        children: LegacyFingerprint?
    ) -> LegacyFingerprint? {
        guard let identity else { return nil }
        if isDirectory && children == nil { return nil }
        var result = children ?? .empty
        let timeBits = modificationDate?.timeIntervalSince1970.bitPattern ?? 0
        let hash = stableHash("\(isDirectory ? "d" : "f")|\(name)|\(identity)|\(size)|\(timeBits)")
        result.combine(hash: hash)
        return result
    }

    mutating func combine(_ other: LegacyFingerprint) {
        let shift = Int(other.itemCount % 63) + 1
        xor ^= other.xor.legacyRotatedLeft(by: shift)
        sum &+= other.sum &* 0x9E37_79B1_85EB_CA87
        itemCount &+= other.itemCount
    }

    private mutating func combine(hash: UInt64) {
        xor ^= hash
        sum &+= hash
        itemCount &+= 1
    }

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

private extension UInt64 {
    // legacy copy
    func legacyRotatedLeft(by amount: Int) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return self }
        return (self << shift) | (self >> (64 - shift))
    }
}

struct LegacyDiskNode: Identifiable, Sendable {
    let id: UUID
    let url: URL?
    let resourceIdentifier: String?
    let fingerprint: LegacyFingerprint?
    let name: String
    let size: Int64
    let fileCount: Int
    let directoryCount: Int
    let unreadableCount: Int
    let isDirectory: Bool
    let isVirtual: Bool
    let isPackage: Bool
    let children: [LegacyDiskNode]

    init(
        id: UUID = UUID(),
        url: URL?,
        resourceIdentifier: String? = nil,
        fingerprint: LegacyFingerprint? = nil,
        name: String,
        size: Int64,
        fileCount: Int,
        directoryCount: Int,
        unreadableCount: Int,
        isDirectory: Bool,
        isVirtual: Bool = false,
        isPackage: Bool = false,
        children: [LegacyDiskNode] = []
    ) {
        self.id = id
        self.url = url
        self.resourceIdentifier = resourceIdentifier
        self.fingerprint = fingerprint
        self.name = name
        self.size = max(0, size)
        self.fileCount = max(0, fileCount)
        self.directoryCount = max(0, directoryCount)
        self.unreadableCount = max(0, unreadableCount)
        self.isDirectory = isDirectory
        self.isVirtual = isVirtual
        self.isPackage = isPackage
        self.children = children
    }

    var itemCount: Int { fileCount + directoryCount }
}

struct LegacyScanSnapshot: Sendable {
    let root: LegacyDiskNode
    let startedAt: Date
    let finishedAt: Date
    let skippedSymbolicLinks: Int
    let skippedMountPoints: Int

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}


struct LegacyDiskScanner: Sendable {
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

    mutating func scan(root: URL, counter: ScanCounter) throws -> LegacyScanSnapshot {
        let startedAt = Date()
        let normalizedRoot = root.standardizedFileURL
        if let identity = FileIdentity.read(for: normalizedRoot) {
            seenDirectoryIdentifiers.insert(identity)
        }
        let node = try scanNode(normalizedRoot, depth: 0, counter: counter)
            ?? LegacyDiskNode(
                url: normalizedRoot,
                name: normalizedRoot.lastPathComponent.isEmpty ? normalizedRoot.path : normalizedRoot.lastPathComponent,
                size: 0,
                fileCount: 0,
                directoryCount: 0,
                unreadableCount: 1,
                isDirectory: true
            )
        return LegacyScanSnapshot(
            root: node,
            startedAt: startedAt,
            finishedAt: Date(),
            skippedSymbolicLinks: skippedSymbolicLinks,
            skippedMountPoints: skippedMountPoints
        )
    }

    private mutating func scanNode(_ url: URL, depth: Int, counter: ScanCounter) throws -> LegacyDiskNode? {
        try checkCancellation()
        counter.record(url)

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: resourceKeys)
        } catch {
            return LegacyDiskNode(
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
            return LegacyDiskNode(
                url: url,
                resourceIdentifier: identity,
                fingerprint: LegacyFingerprint.node(
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
                    return LegacyDiskNode(
                        url: url,
                        resourceIdentifier: capturedIdentity,
                        fingerprint: LegacyFingerprint.node(
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
            return LegacyDiskNode(
                url: url,
                resourceIdentifier: capturedIdentity,
                fingerprint: LegacyFingerprint.node(
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
            return LegacyDiskNode(
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
            return LegacyDiskNode(
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

        var accumulator = LegacyChildAccumulator(maxVisibleChildren: maxChildrenPerFolder)
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
        return LegacyDiskNode(
            url: url,
            resourceIdentifier: capturedIdentity,
            fingerprint: identityStayedStable ? LegacyFingerprint.node(
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
    ) throws -> LegacyMeasurement {
        try checkCancellation()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch {
            return LegacyMeasurement(size: 0, fileCount: 0, directoryCount: 1, unreadableCount: 1, fingerprint: nil)
        }

        var result = LegacyMeasurement(
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
                    LegacyFingerprint.node(
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
                            LegacyFingerprint.node(
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
                let leafFingerprint = LegacyFingerprint.node(
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
            result.fingerprint = LegacyFingerprint.node(
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

private struct LegacyMeasurement {
    var size: Int64
    var fileCount: Int
    var directoryCount: Int
    var unreadableCount: Int
    var fingerprint: LegacyFingerprint?

    mutating func add(_ other: LegacyMeasurement) {
        size += other.size
        fileCount += other.fileCount
        directoryCount += other.directoryCount
        unreadableCount += other.unreadableCount
        addFingerprint(other.fingerprint)
    }

    mutating func addFingerprint(_ other: LegacyFingerprint?) {
        guard var current = fingerprint, let other else {
            fingerprint = nil
            return
        }
        current.combine(other)
        fingerprint = current
    }
}

private struct LegacyChildAccumulator {
    let maxRetained: Int
    private(set) var retained: [LegacyDiskNode] = []
    private var discardedSize: Int64 = 0
    private var discardedFileCount = 0
    private var discardedDirectoryCount = 0
    private var discardedUnreadableCount = 0
    private var discardedNodeCount = 0

    private(set) var totalSize: Int64 = 0
    private(set) var totalFileCount = 0
    private(set) var totalDirectoryCount = 0
    private(set) var totalUnreadableCount = 0
    private(set) var totalFingerprint: LegacyFingerprint? = .empty

    init(maxVisibleChildren: Int) {
        maxRetained = max(1, maxVisibleChildren - 1)
        retained.reserveCapacity(maxRetained)
    }

    mutating func add(_ node: LegacyDiskNode) {
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

    mutating func finishedChildren() -> [LegacyDiskNode] {
        retained.sort { lhs, rhs in
            if lhs.size == rhs.size {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.size > rhs.size
        }
        guard discardedNodeCount > 0 else { return retained }
        let other = LegacyDiskNode(
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

    private mutating func aggregate(_ node: LegacyDiskNode) {
        discardedNodeCount += 1
        discardedSize += node.size
        discardedFileCount += node.fileCount
        discardedDirectoryCount += node.directoryCount
        discardedUnreadableCount += node.unreadableCount
    }
}
