import Foundation
import Darwin

enum FileIdentity {
    static func read(for url: URL) -> String? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return [
            String(info.st_dev),
            String(info.st_ino),
            String(info.st_mode),
            String(info.st_birthtimespec.tv_sec),
            String(info.st_birthtimespec.tv_nsec),
            String(info.st_ctimespec.tv_sec),
            String(info.st_ctimespec.tv_nsec)
        ].joined(separator: ":")
    }

    static func relocationIdentifier(for url: URL) -> String? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return [
            String(info.st_dev),
            String(info.st_ino),
            String(info.st_mode),
            String(info.st_birthtimespec.tv_sec),
            String(info.st_birthtimespec.tv_nsec)
        ].joined(separator: ":")
    }

    static func deviceID(for url: URL) -> UInt64? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0 else { return nil }
        return UInt64(info.st_dev)
    }

    static func hardLinkKeyIfNeeded(for url: URL) -> String? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &info)
        }
        guard result == 0, info.st_nlink > 1 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
}

/// Three words that change whenever anything inside an item changes; rules in Specs/fingerprint.t27.
struct ContentFingerprint: Sendable, Equatable {
    private(set) var xor: UInt64
    private(set) var sum: UInt64
    private(set) var itemCount: UInt64

    static let empty = ContentFingerprint(xor: 0, sum: 0, itemCount: 0)

    static func node(
        name: String,
        identity: String?,
        size: Int64,
        modificationDate: Date?,
        isDirectory: Bool,
        children: ContentFingerprint?
    ) -> ContentFingerprint? {
        guard fp_node_exists(identity != nil, isDirectory, children != nil), let identity else { return nil }
        var result = children ?? .empty
        let timeBits = modificationDate?.timeIntervalSince1970.bitPattern ?? 0
        let hash = stableHash("\(isDirectory ? "d" : "f")|\(name)|\(identity)|\(size)|\(timeBits)")
        result.xor = fp_leaf_xor(result.xor, hash)
        result.sum = fp_leaf_sum(result.sum, hash)
        result.itemCount = fp_leaf_count(result.itemCount)
        return result
    }

    mutating func combine(_ other: ContentFingerprint) {
        xor = fp_combine_xor(xor, other.xor, other.itemCount)
        sum = fp_combine_sum(sum, other.sum)
        itemCount = fp_combine_count(itemCount, other.itemCount)
    }

    /// FNV-1a over the UTF-8 bytes, fed to the spec in chunks of FP_CHUNK.
    private static func stableHash(_ value: String) -> UInt64 {
        var hash = UInt64(FP_OFFSET_BASIS)
        let bytes = Array(value.utf8)
        let chunk = Int(FP_CHUNK)
        var start = 0
        repeat {
            let end = min(bytes.count, start + chunk)
            hash = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: chunk) { buffer in
                let base = buffer.baseAddress!
                base.initialize(repeating: 0, count: chunk)
                bytes[start..<end].withUnsafeBufferPointer { slice in
                    if let source = slice.baseAddress { base.update(from: source, count: end - start) }
                }
                return fp_hash_continue(hash, base, UInt32(end - start))
            }
            start = end
        } while start < bytes.count
        return hash
    }
}

struct DiskNode: Identifiable, Sendable {
    let id: UUID
    let url: URL?
    let resourceIdentifier: String?
    let fingerprint: ContentFingerprint?
    let name: String
    let size: Int64
    let fileCount: Int
    let directoryCount: Int
    let unreadableCount: Int
    let isDirectory: Bool
    let isVirtual: Bool
    let isPackage: Bool
    let children: [DiskNode]

    init(
        id: UUID = UUID(),
        url: URL?,
        resourceIdentifier: String? = nil,
        fingerprint: ContentFingerprint? = nil,
        name: String,
        size: Int64,
        fileCount: Int,
        directoryCount: Int,
        unreadableCount: Int,
        isDirectory: Bool,
        isVirtual: Bool = false,
        isPackage: Bool = false,
        children: [DiskNode] = []
    ) {
        self.id = id
        self.url = url
        self.resourceIdentifier = resourceIdentifier
        self.fingerprint = fingerprint
        self.name = name
        self.size = sr_non_negative(size)
        self.fileCount = Int(sr_non_negative(Int64(fileCount)))
        self.directoryCount = Int(sr_non_negative(Int64(directoryCount)))
        self.unreadableCount = Int(sr_non_negative(Int64(unreadableCount)))
        self.isDirectory = isDirectory
        self.isVirtual = isVirtual
        self.isPackage = isPackage
        self.children = children
    }

    var itemCount: Int { fileCount + directoryCount }
}

struct ScanSnapshot: Sendable {
    let root: DiskNode
    let startedAt: Date
    let finishedAt: Date
    let skippedSymbolicLinks: Int
    let skippedMountPoints: Int

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}

struct ScanProgress: Sendable {
    let itemCount: Int
    let currentPath: String
}

final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var itemCount = 0
    private var currentPath = ""

    func record(_ url: URL) {
        lock.lock()
        itemCount += 1
        if itemCount % 32 == 0 || currentPath.isEmpty {
            currentPath = url.path
        }
        lock.unlock()
    }

    func snapshot() -> ScanProgress {
        lock.lock()
        let value = ScanProgress(itemCount: itemCount, currentPath: currentPath)
        lock.unlock()
        return value
    }
}

struct VolumeStats: Sendable {
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: max(0, bytes))
    }

    static func compact(_ bytes: Int64) -> String {
        let amount = Double(max(0, bytes))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = amount
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        if index == 0 { return "\(Int(value)) \(units[index])" }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.*f %@", digits, value, units[index])
    }
}

enum Plural {
    static func objects(_ count: Int) -> String {
        form(count, one: "item", many: "items")
    }

    static func files(_ count: Int) -> String {
        form(count, one: "file", many: "files")
    }

    private static func form(_ count: Int, one: String, many: String) -> String {
        abs(count) == 1 ? one : many
    }
}
