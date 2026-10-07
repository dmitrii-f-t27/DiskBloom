import Darwin
import Foundation

enum DuplicateScanStage: Sendable {
    case enumerating
    case hashing
    case verifying

    var title: String {
        switch self {
        case .enumerating: "Finding files"
        case .hashing: "Full hashing"
        case .verifying: "Byte-by-byte verification"
        }
    }
}

struct DuplicateScanProgress: Sendable {
    let stage: DuplicateScanStage
    let examinedFileCount: Int
    let candidateFileCount: Int
    let processedCandidateCount: Int
    let bytesRead: Int64
    let currentPath: String
}

final class DuplicateScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: DuplicateScanStage = .enumerating
    private var examinedFileCount = 0
    private var candidateFileCount = 0
    private var processedCandidateCount = 0
    private var bytesRead: Int64 = 0
    private var currentPath = ""

    func recordExamined(_ url: URL) {
        lock.lock()
        examinedFileCount += 1
        if fm_duplicate_progress_shows(Int64(examinedFileCount)) {
            currentPath = url.path
        }
        lock.unlock()
    }

    func beginHashing(candidateCount: Int) {
        lock.lock()
        stage = .hashing
        candidateFileCount = candidateCount
        processedCandidateCount = 0
        lock.unlock()
    }

    func recordCandidateProcessed(_ url: URL) {
        lock.lock()
        processedCandidateCount += 1
        currentPath = url.path
        lock.unlock()
    }

    func recordRead(byteCount: Int) {
        guard byteCount > 0 else { return }
        lock.lock()
        bytesRead &+= Int64(byteCount)
        lock.unlock()
    }

    func beginVerification() {
        lock.lock()
        stage = .verifying
        processedCandidateCount = 0
        lock.unlock()
    }

    func snapshot() -> DuplicateScanProgress {
        lock.lock()
        let value = DuplicateScanProgress(
            stage: stage,
            examinedFileCount: examinedFileCount,
            candidateFileCount: candidateFileCount,
            processedCandidateCount: processedCandidateCount,
            bytesRead: bytesRead,
            currentPath: currentPath
        )
        lock.unlock()
        return value
    }
}

struct DuplicateFileSnapshot: Identifiable, Sendable {
    let id: String
    let url: URL
    let logicalSize: Int64
    let allocatedSize: Int64
    let modificationDate: Date
    let resourceIdentity: String
    let digest: String
}

struct DuplicateFileGroup: Identifiable, Sendable {
    let id: String
    let digest: String
    let logicalSize: Int64
    let files: [DuplicateFileSnapshot]

    var duplicateCount: Int { Int(du_extra_copies(UInt32(clamping: files.count))) }

    var logicalDuplicateBytes: Int64 {
        du_duplicate_bytes(logicalSize, UInt32(clamping: files.count))
    }
}

struct DuplicateScanResult: Sendable {
    let rootURL: URL
    let groups: [DuplicateFileGroup]
    let examinedFileCount: Int
    let candidateFileCount: Int
    let hashedFileCount: Int
    let skippedSymbolicLinkCount: Int
    let skippedPackageCount: Int
    let skippedMountCount: Int
    let skippedCloudPlaceholderCount: Int
    let skippedHardLinkCount: Int
    let unreadableOrChangedCount: Int
    let startedAt: Date
    let finishedAt: Date

    var duplicateFileCount: Int { groups.reduce(0) { $0 + $1.duplicateCount } }

    var logicalDuplicateBytes: Int64 {
        groups.reduce(0) { du_saturating_add($0, $1.logicalDuplicateBytes) }
    }

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

enum DuplicateFinderError: LocalizedError {
    case invalidRoot(String)
    case fileChanged(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let path):
            "The selected location is unavailable or unsafe to analyze: \(path)"
        case .fileChanged(let path):
            "File changed during analysis: \(path)"
        case .unreadable(let path):
            "Could not read file: \(path)"
        }
    }
}

private struct DuplicateFileMetadata: Equatable, Sendable {
    /// Unchanged only when every recorded field is the same (Specs/duplicate_rules.t27).
    static func == (a: DuplicateFileMetadata, b: DuplicateFileMetadata) -> Bool {
        du_metadata_same(
            a.device, b.device, a.inode, b.inode, UInt32(a.mode), UInt32(b.mode),
            UInt32(a.hardLinkCount), UInt32(b.hardLinkCount), a.size, b.size, a.allocatedSize, b.allocatedSize,
            a.modificationSeconds, b.modificationSeconds, a.modificationNanoseconds, b.modificationNanoseconds,
            a.changeSeconds, b.changeSeconds, a.changeNanoseconds, b.changeNanoseconds
        )
    }

    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let hardLinkCount: UInt16
    let size: Int64
    let allocatedSize: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    var isRegularFile: Bool { du_mode_is(UInt32(mode), UInt32(DU_TYPE_REGULAR)) }
    var isDirectory: Bool { du_mode_is(UInt32(mode), UInt32(DU_TYPE_DIRECTORY)) }
    var isSymbolicLink: Bool { du_mode_is(UInt32(mode), UInt32(DU_TYPE_LINK)) }
    var identity: String {
        [
            String(device), String(inode), String(mode),
            String(modificationSeconds), String(modificationNanoseconds),
            String(changeSeconds), String(changeNanoseconds)
        ].joined(separator: ":")
    }
    var modificationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(modificationSeconds) + TimeInterval(modificationNanoseconds) / 1_000_000_000)
    }
}

private struct DuplicateCandidate: Sendable {
    let url: URL
    let metadata: DuplicateFileMetadata
}

private struct DigestedCandidate: Sendable {
    let candidate: DuplicateCandidate
    let digest: String
}

private final class DuplicateScanTally: @unchecked Sendable {
    struct Snapshot: Sendable {
        let examinedFiles: Int
        let skippedSymbolicLinks: Int
        let skippedPackages: Int
        let skippedMounts: Int
        let skippedCloudPlaceholders: Int
        let skippedHardLinks: Int
        let unreadableOrChanged: Int
    }

    private let lock = NSLock()
    private var examinedFiles = 0
    private var skippedSymbolicLinks = 0
    private var skippedPackages = 0
    private var skippedMounts = 0
    private var skippedCloudPlaceholders = 0
    private var skippedHardLinks = 0
    private var unreadableOrChanged = 0

    func examined() { update { examinedFiles += 1 } }
    func symbolicLink() { update { skippedSymbolicLinks += 1 } }
    func package() { update { skippedPackages += 1 } }
    func mount() { update { skippedMounts += 1 } }
    func cloudPlaceholder() { update { skippedCloudPlaceholders += 1 } }
    func hardLink() { update { skippedHardLinks += 1 } }
    func unreadableOrChangedFile() { update { unreadableOrChanged += 1 } }

    func snapshot() -> Snapshot {
        lock.lock()
        let value = Snapshot(
            examinedFiles: examinedFiles,
            skippedSymbolicLinks: skippedSymbolicLinks,
            skippedPackages: skippedPackages,
            skippedMounts: skippedMounts,
            skippedCloudPlaceholders: skippedCloudPlaceholders,
            skippedHardLinks: skippedHardLinks,
            unreadableOrChanged: unreadableOrChanged
        )
        lock.unlock()
        return value
    }

    private func update(_ mutation: () -> Void) {
        lock.lock()
        mutation()
        lock.unlock()
    }
}

struct DuplicateFinderScanner: Sendable {
    typealias DigestOverride = @Sendable (URL) throws -> String

    private let chunkSize: Int
    private let digestOverride: DigestOverride?

    init(chunkSize: Int = 1_048_576, digestOverride: DigestOverride? = nil) {
        self.chunkSize = Int(du_chunk_size(Int64(chunkSize)))
        self.digestOverride = digestOverride
    }

    func scan(root rootURL: URL, counter: DuplicateScanCounter = DuplicateScanCounter()) throws -> DuplicateScanResult {
        let startedAt = Date()
        let root = rootURL.standardizedFileURL
        let rootMetadataRead = Self.metadata(at: root)
        guard du_root_ok(
            T27Text.same(root.resolvingSymlinksInPath().path, root.path),
            rootMetadataRead != nil,
            rootMetadataRead?.isDirectory == true,
            (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true
        ), let rootMetadata = rootMetadataRead else {
            throw DuplicateFinderError.invalidRoot(root.path)
        }

        let tally = DuplicateScanTally()
        var candidatesBySize: [Int64: [DuplicateCandidate]] = [:]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isPackageKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in
                tally.unreadableOrChangedFile()
                return true
            }
        ) else {
            throw DuplicateFinderError.invalidRoot(root.path)
        }

        while let item = enumerator.nextObject() as? URL {
            try Self.checkCancellation()
            let url = item.standardizedFileURL
            let insideRoot = Self.isStrictDescendant(url, of: root)
                && T27Text.same(url.resolvingSymlinksInPath().path, url.path)
            let values = insideRoot ? try? url.resourceValues(forKeys: keys) : nil
            let isDirectory = insideRoot
                ? values?.isDirectory == true
                : (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let metadata = insideRoot && values != nil && values?.isSymbolicLink != true ? Self.metadata(at: url) : nil
            let blockedName = T27Text.withBytes(url.lastPathComponent) { du_blocked_directory($0, $1) }
            let action = Int32(du_entry_action(
                insideRoot,
                isDirectory,
                values != nil,
                values?.isSymbolicLink == true,
                isDirectory,
                values?.isPackage == true,
                blockedName,
                metadata != nil,
                metadata?.device == rootMetadata.device,
                values?.isRegularFile == true,
                metadata?.isRegularFile == true,
                metadata?.size ?? 0,
                values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current,
                UInt32(metadata?.hardLinkCount ?? 0)
            ))
            if du_examined(UInt32(action)) {
                tally.examined()
                counter.recordExamined(url)
            }
            switch action {
            case DU_SKIP_LINK:
                tally.symbolicLink()
            case DU_SKIP_LINK_FOLDER:
                tally.symbolicLink()
                enumerator.skipDescendants()
            case DU_UNREADABLE:
                tally.unreadableOrChangedFile()
            case DU_SKIP_PACKAGE:
                tally.package()
                enumerator.skipDescendants()
            case DU_UNREADABLE_FOLDER:
                tally.unreadableOrChangedFile()
                enumerator.skipDescendants()
            case DU_SKIP_MOUNT_FOLDER:
                tally.mount()
                enumerator.skipDescendants()
            case DU_SKIP_MOUNT_FILE:
                tally.mount()
            case DU_SKIP_CLOUD:
                tally.cloudPlaceholder()
            case DU_SKIP_HARD_LINK:
                tally.hardLink()
            case DU_CANDIDATE:
                if let metadata {
                    candidatesBySize[metadata.size, default: []].append(DuplicateCandidate(url: url, metadata: metadata))
                }
            default:
                break
            }
        }

        let candidateBuckets = candidatesBySize
            .filter { du_worth_hashing(UInt32(clamping: $0.value.count)) }
            .sorted { lhs, rhs in
                switch Int32(du_larger_first(lhs.key, rhs.key)) {
                case DU_FIRST: return true
                case DU_SECOND: return false
                default: return lhs.value.first?.url.path ?? "" < rhs.value.first?.url.path ?? ""
                }
            }
        let candidateCount = candidateBuckets.reduce(0) { $0 + $1.value.count }
        counter.beginHashing(candidateCount: candidateCount)

        var hashedFileCount = 0
        var digestBuckets: [String: [DigestedCandidate]] = [:]
        for (_, candidates) in candidateBuckets {
            for candidate in candidates.sorted(by: { $0.url.path < $1.url.path }) {
                try Self.checkCancellation()
                do {
                    let digest = try digest(candidate, counter: counter)
                    let key = "\(candidate.metadata.size):\(digest)"
                    digestBuckets[key, default: []].append(
                        DigestedCandidate(candidate: candidate, digest: digest)
                    )
                    hashedFileCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    tally.unreadableOrChangedFile()
                }
                counter.recordCandidateProcessed(candidate.url)
            }
        }

        counter.beginVerification()
        var groups: [DuplicateFileGroup] = []
        for digested in digestBuckets.values where du_is_group(UInt32(clamping: digested.count)) {
            try Self.checkCancellation()
            var partitions: [[DigestedCandidate]] = []
            for candidate in digested.sorted(by: { $0.candidate.url.path < $1.candidate.url.path }) {
                try Self.checkCancellation()
                var matchedPartition = false
                for index in partitions.indices {
                    guard let representative = partitions[index].first else { continue }
                    var identical = false
                    var compared = true
                    do {
                        identical = try filesAreByteIdentical(representative.candidate, candidate.candidate, counter: counter)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        compared = false
                    }
                    let next = Int32(du_after_compare(compared, identical))
                    if next == DU_JOIN {
                        partitions[index].append(candidate)
                        matchedPartition = true
                        break
                    }
                    if next == DU_DROP {
                        tally.unreadableOrChangedFile()
                        matchedPartition = true
                        break
                    }
                }
                if !matchedPartition { partitions.append([candidate]) }
                counter.recordCandidateProcessed(candidate.candidate.url)
            }

            for partition in partitions where du_is_group(UInt32(clamping: partition.count)) {
                let sorted = partition.sorted { $0.candidate.url.path < $1.candidate.url.path }
                guard let first = sorted.first else { continue }
                let files = sorted.map { item in
                    DuplicateFileSnapshot(
                        id: item.candidate.url.path,
                        url: item.candidate.url,
                        logicalSize: item.candidate.metadata.size,
                        allocatedSize: item.candidate.metadata.allocatedSize,
                        modificationDate: item.candidate.metadata.modificationDate,
                        resourceIdentity: item.candidate.metadata.identity,
                        digest: item.digest
                    )
                }
                groups.append(
                    DuplicateFileGroup(
                        id: "\(first.digest):\(first.candidate.metadata.size):\(first.candidate.url.path)",
                        digest: first.digest,
                        logicalSize: first.candidate.metadata.size,
                        files: files
                    )
                )
            }
        }

        groups.sort { lhs, rhs in
            switch Int32(du_larger_first(lhs.logicalDuplicateBytes, rhs.logicalDuplicateBytes)) {
            case DU_FIRST: return true
            case DU_SECOND: return false
            default: return lhs.id < rhs.id
            }
        }
        let counts = tally.snapshot()
        return DuplicateScanResult(
            rootURL: root,
            groups: groups,
            examinedFileCount: counts.examinedFiles,
            candidateFileCount: candidateCount,
            hashedFileCount: hashedFileCount,
            skippedSymbolicLinkCount: counts.skippedSymbolicLinks,
            skippedPackageCount: counts.skippedPackages,
            skippedMountCount: counts.skippedMounts,
            skippedCloudPlaceholderCount: counts.skippedCloudPlaceholders,
            skippedHardLinkCount: counts.skippedHardLinks,
            unreadableOrChangedCount: counts.unreadableOrChanged,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    private func digest(_ candidate: DuplicateCandidate, counter: DuplicateScanCounter) throws -> String {
        guard Self.metadata(at: candidate.url) == candidate.metadata else {
            throw DuplicateFinderError.fileChanged(candidate.url.path)
        }
        if let digestOverride {
            let value = try digestOverride(candidate.url)
            guard Self.metadata(at: candidate.url) == candidate.metadata else {
                throw DuplicateFinderError.fileChanged(candidate.url.path)
            }
            counter.recordRead(byteCount: Int(clamping: candidate.metadata.size))
            return value
        }

        let descriptor = try Self.openReadOnlyNoFollow(candidate.url, expected: candidate.metadata)
        defer { Darwin.close(descriptor) }
        var hasher = DuplicateSHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Self.checkCancellation()
            let count = try Self.readChunk(descriptor: descriptor, buffer: &buffer, path: candidate.url.path)
            if count == 0 { break }
            hasher.update(buffer[0..<count])
            counter.recordRead(byteCount: count)
        }
        guard Self.metadata(descriptor: descriptor) == candidate.metadata,
              Self.metadata(at: candidate.url) == candidate.metadata else {
            throw DuplicateFinderError.fileChanged(candidate.url.path)
        }
        return hasher.finalizeHex()
    }

    private func filesAreByteIdentical(
        _ lhs: DuplicateCandidate,
        _ rhs: DuplicateCandidate,
        counter: DuplicateScanCounter
    ) throws -> Bool {
        guard lhs.metadata.size == rhs.metadata.size else { return false }
        let lhsDescriptor = try Self.openReadOnlyNoFollow(lhs.url, expected: lhs.metadata)
        defer { Darwin.close(lhsDescriptor) }
        let rhsDescriptor = try Self.openReadOnlyNoFollow(rhs.url, expected: rhs.metadata)
        defer { Darwin.close(rhsDescriptor) }

        var lhsBuffer = [UInt8](repeating: 0, count: chunkSize)
        var rhsBuffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Self.checkCancellation()
            let lhsCount = try Self.readChunk(descriptor: lhsDescriptor, buffer: &lhsBuffer, path: lhs.url.path)
            let rhsCount = try Self.readChunk(descriptor: rhsDescriptor, buffer: &rhsBuffer, path: rhs.url.path)
            guard lhsCount == rhsCount else { return false }
            if lhsCount == 0 { break }
            counter.recordRead(byteCount: lhsCount + rhsCount)
            if !DuplicateSHA256.sameBytes(lhsBuffer, rhsBuffer, count: lhsCount) { return false }
        }
        guard Self.metadata(descriptor: lhsDescriptor) == lhs.metadata,
              Self.metadata(descriptor: rhsDescriptor) == rhs.metadata,
              Self.metadata(at: lhs.url) == lhs.metadata,
              Self.metadata(at: rhs.url) == rhs.metadata else {
            throw DuplicateFinderError.fileChanged("\(lhs.url.path) or \(rhs.url.path)")
        }
        return true
    }

    private static func openReadOnlyNoFollow(_ url: URL, expected: DuplicateFileMetadata) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw DuplicateFinderError.unreadable(url.path) }
        guard metadata(descriptor: descriptor) == expected else {
            Darwin.close(descriptor)
            throw DuplicateFinderError.fileChanged(url.path)
        }
        return descriptor
    }

    private static func readChunk(descriptor: Int32, buffer: inout [UInt8], path: String) throws -> Int {
        while true {
            let result = Darwin.read(descriptor, &buffer, buffer.count)
            if result >= 0 { return result }
            if errno == EINTR { continue }
            throw DuplicateFinderError.unreadable(path)
        }
    }

    private static func metadata(at url: URL) -> DuplicateFileMetadata? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return metadata(from: info)
    }

    private static func metadata(descriptor: Int32) -> DuplicateFileMetadata? {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        return metadata(from: info)
    }

    private static func metadata(from info: stat) -> DuplicateFileMetadata {
        return DuplicateFileMetadata(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            mode: UInt16(info.st_mode),
            hardLinkCount: UInt16(info.st_nlink),
            size: du_logical_size(Int64(info.st_size)),
            allocatedSize: du_allocated_size(Int64(info.st_blocks)),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return T27Text.strictDescendant(candidatePath, of: rootPath)
    }

    private static func checkCancellation() throws {
        let cancelled = withUnsafeCurrentTask { task in task?.isCancelled ?? false }
        if cancelled { throw CancellationError() }
    }
}

/// SHA-256 written in Specs/duplicate_rules.t27, fed in blocks of up to DU_BLOCK bytes.
struct DuplicateSHA256 {
    private var state = [UInt32](repeating: 0, count: 8)
    private var pending: [UInt8] = []
    private var total: UInt64 = 0

    init() {
        state.withUnsafeMutableBufferPointer { _ = du_sha256_init($0.baseAddress!) }
    }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        total &+= UInt64(bytes.count)
        var rest = bytes[...]
        if !pending.isEmpty {
            let take = min(64 - pending.count, rest.count)
            pending.append(contentsOf: rest.prefix(take))
            rest = rest.dropFirst(take)
            guard pending.count == 64 else { return }
            compress(pending[...])
            pending.removeAll(keepingCapacity: true)
        }
        let block = Int(DU_BLOCK)
        rest.withUnsafeBufferPointer { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            // Whole DU_BLOCK runs are handed to the spec in place; the spec reads exactly DU_BLOCK bytes.
            while remaining >= block {
                state.withUnsafeMutableBufferPointer { _ = du_sha256_blocks($0.baseAddress!, UnsafeMutablePointer(mutating: cursor), UInt32(block / 64)) }
                cursor += block
                remaining -= block
            }
            let whole = remaining / 64 * 64
            if whole > 0 {
                compress(UnsafeBufferPointer(start: cursor, count: whole)[...])
                cursor += whole
                remaining -= whole
            }
            pending.append(contentsOf: UnsafeBufferPointer(start: cursor, count: remaining))
        }
    }

    mutating func finalizeHex() -> String {
        let block = Int(DU_BLOCK)
        var tail = [UInt8](repeating: 0, count: block)
        tail.replaceSubrange(0..<pending.count, with: pending)
        var padded = [UInt8](repeating: 0, count: block)
        let length = tail.withUnsafeMutableBufferPointer { tailPointer in
            padded.withUnsafeMutableBufferPointer { paddedPointer in
                du_sha256_padding(tailPointer.baseAddress!, UInt32(pending.count), total, paddedPointer.baseAddress!)
            }
        }
        compress(padded[0..<Int(length)])
        var hex = [UInt8](repeating: 0, count: block)
        let written = state.withUnsafeMutableBufferPointer { statePointer in
            hex.withUnsafeMutableBufferPointer { du_sha256_hex(statePointer.baseAddress!, $0.baseAddress!) }
        }
        return String(decoding: hex.prefix(Int(written)), as: UTF8.self)
    }

    private mutating func compress<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var block = [UInt8](repeating: 0, count: Int(DU_BLOCK))
        block.replaceSubrange(0..<bytes.count, with: bytes)
        let blocks = UInt32(bytes.count / 64)
        state.withUnsafeMutableBufferPointer { statePointer in
            block.withUnsafeMutableBufferPointer { _ = du_sha256_blocks(statePointer.baseAddress!, $0.baseAddress!, blocks) }
        }
    }

    static func hex(of data: [UInt8]) -> String {
        var hasher = DuplicateSHA256()
        hasher.update(data[...])
        return hasher.finalizeHex()
    }

    /// The first `count` bytes of both buffers are equal, compared DU_BLOCK bytes at a time.
    static func sameBytes(_ a: [UInt8], _ b: [UInt8], count: Int) -> Bool {
        let block = Int(DU_BLOCK)
        var left = [UInt8](repeating: 0, count: block)
        var right = [UInt8](repeating: 0, count: block)
        var start = 0
        while start < count {
            let length = min(block, count - start)
            left.replaceSubrange(0..<length, with: a[start..<(start + length)])
            right.replaceSubrange(0..<length, with: b[start..<(start + length)])
            let equal = left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in du_bytes_equal(l.baseAddress!, r.baseAddress!, UInt32(length)) }
            }
            if !equal { return false }
            start += length
        }
        return true
    }
}
