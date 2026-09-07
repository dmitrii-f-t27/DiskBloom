import CryptoKit
import Darwin
import Foundation

enum DuplicateScanStage: Sendable {
    case enumerating
    case hashing
    case verifying

    var title: String {
        switch self {
        case .enumerating: "Поиск файлов"
        case .hashing: "Полное хеширование"
        case .verifying: "Побайтовая проверка"
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
        if examinedFileCount == 1 || examinedFileCount.isMultiple(of: 32) {
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

    var duplicateCount: Int { max(0, files.count - 1) }

    var logicalDuplicateBytes: Int64 {
        let (value, overflow) = logicalSize.multipliedReportingOverflow(by: Int64(duplicateCount))
        return overflow ? Int64.max : max(0, value)
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
        groups.reduce(0) { partial, group in
            let (value, overflow) = partial.addingReportingOverflow(group.logicalDuplicateBytes)
            return overflow ? Int64.max : value
        }
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
            "Выбранная область недоступна или небезопасна для анализа: \(path)"
        case .fileChanged(let path):
            "Файл изменился во время анализа: \(path)"
        case .unreadable(let path):
            "Не удалось прочитать файл: \(path)"
        }
    }
}

private struct DuplicateFileMetadata: Equatable, Sendable {
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

    var isRegularFile: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFREG) }
    var isDirectory: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFDIR) }
    var isSymbolicLink: Bool { (mode & UInt16(S_IFMT)) == UInt16(S_IFLNK) }
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
        self.chunkSize = max(4_096, chunkSize)
        self.digestOverride = digestOverride
    }

    func scan(root rootURL: URL, counter: DuplicateScanCounter = DuplicateScanCounter()) throws -> DuplicateScanResult {
        let startedAt = Date()
        let root = rootURL.standardizedFileURL
        guard root.resolvingSymlinksInPath().path == root.path,
              let rootMetadata = Self.metadata(at: root),
              rootMetadata.isDirectory,
              (try? root.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
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
        let blockedDirectoryNames: Set<String> = [".Trash", ".Trashes", "Backups.backupdb", ".MobileBackups"]

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
            guard Self.isStrictDescendant(url, of: root),
                  url.resolvingSymlinksInPath().path == url.path else {
                tally.symbolicLink()
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: keys)
            } catch {
                tally.unreadableOrChangedFile()
                continue
            }

            if values.isSymbolicLink == true {
                tally.symbolicLink()
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true {
                if values.isPackage == true || blockedDirectoryNames.contains(url.lastPathComponent) {
                    tally.package()
                    enumerator.skipDescendants()
                    continue
                }
                guard let metadata = Self.metadata(at: url) else {
                    tally.unreadableOrChangedFile()
                    enumerator.skipDescendants()
                    continue
                }
                if metadata.device != rootMetadata.device {
                    tally.mount()
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  let metadata = Self.metadata(at: url),
                  metadata.isRegularFile else {
                continue
            }
            tally.examined()
            counter.recordExamined(url)

            guard metadata.device == rootMetadata.device else {
                tally.mount()
                continue
            }
            guard metadata.size > 0 else { continue }
            if values.isUbiquitousItem == true,
               values.ubiquitousItemDownloadingStatus != .current {
                tally.cloudPlaceholder()
                continue
            }
            guard metadata.hardLinkCount <= 1 else {
                tally.hardLink()
                continue
            }

            candidatesBySize[metadata.size, default: []].append(
                DuplicateCandidate(url: url, metadata: metadata)
            )
        }

        let candidateBuckets = candidatesBySize
            .filter { $0.value.count > 1 }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key > rhs.key }
                return lhs.value.first?.url.path ?? "" < rhs.value.first?.url.path ?? ""
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
        for digested in digestBuckets.values where digested.count > 1 {
            try Self.checkCancellation()
            var partitions: [[DigestedCandidate]] = []
            for candidate in digested.sorted(by: { $0.candidate.url.path < $1.candidate.url.path }) {
                try Self.checkCancellation()
                var matchedPartition = false
                for index in partitions.indices {
                    guard let representative = partitions[index].first else { continue }
                    do {
                        if try filesAreByteIdentical(
                            representative.candidate,
                            candidate.candidate,
                            counter: counter
                        ) {
                            partitions[index].append(candidate)
                            matchedPartition = true
                            break
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        tally.unreadableOrChangedFile()
                        matchedPartition = true
                        break
                    }
                }
                if !matchedPartition { partitions.append([candidate]) }
                counter.recordCandidateProcessed(candidate.candidate.url)
            }

            for partition in partitions where partition.count > 1 {
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
            if lhs.logicalDuplicateBytes != rhs.logicalDuplicateBytes {
                return lhs.logicalDuplicateBytes > rhs.logicalDuplicateBytes
            }
            return lhs.id < rhs.id
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
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Self.checkCancellation()
            let count = try Self.readChunk(descriptor: descriptor, buffer: &buffer, path: candidate.url.path)
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
            counter.recordRead(byteCount: count)
        }
        guard Self.metadata(descriptor: descriptor) == candidate.metadata,
              Self.metadata(at: candidate.url) == candidate.metadata else {
            throw DuplicateFinderError.fileChanged(candidate.url.path)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
            if lhsBuffer[0..<lhsCount] != rhsBuffer[0..<rhsCount] { return false }
        }
        guard Self.metadata(descriptor: lhsDescriptor) == lhs.metadata,
              Self.metadata(descriptor: rhsDescriptor) == rhs.metadata,
              Self.metadata(at: lhs.url) == lhs.metadata,
              Self.metadata(at: rhs.url) == rhs.metadata else {
            throw DuplicateFinderError.fileChanged("\(lhs.url.path) или \(rhs.url.path)")
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
        let blocks = Int64(info.st_blocks)
        let (allocated, overflow) = blocks.multipliedReportingOverflow(by: 512)
        return DuplicateFileMetadata(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            mode: UInt16(info.st_mode),
            hardLinkCount: UInt16(info.st_nlink),
            size: max(0, Int64(info.st_size)),
            allocatedSize: overflow ? Int64.max : max(0, allocated),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec),
            changeSeconds: Int64(info.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(info.st_ctimespec.tv_nsec)
        )
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        if rootPath == "/" { return candidatePath != "/" && candidatePath.hasPrefix("/") }
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func checkCancellation() throws {
        let cancelled = withUnsafeCurrentTask { task in task?.isCancelled ?? false }
        if cancelled { throw CancellationError() }
    }
}
