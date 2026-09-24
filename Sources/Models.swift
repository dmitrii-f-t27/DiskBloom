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
        guard let identity else { return nil }
        if isDirectory && children == nil { return nil }
        var result = children ?? .empty
        let timeBits = modificationDate?.timeIntervalSince1970.bitPattern ?? 0
        let hash = stableHash("\(isDirectory ? "d" : "f")|\(name)|\(identity)|\(size)|\(timeBits)")
        result.combine(hash: hash)
        return result
    }

    mutating func combine(_ other: ContentFingerprint) {
        let shift = Int(other.itemCount % 63) + 1
        xor ^= other.xor.rotatedLeft(by: shift)
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
    func rotatedLeft(by amount: Int) -> UInt64 {
        let shift = amount & 63
        guard shift != 0 else { return self }
        return (self << shift) | (self >> (64 - shift))
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
