import CoreServices
import Foundation

/// Runs the checks around a move to the Trash in the order Specs/move_rules.t27 gives, and reads
/// its verdict on the result. Each coordinator supplies what one step does.
enum MoveSteps {
    typealias Mover = @Sendable (URL) throws -> URL?

    static let systemTrashMover: Mover = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    /// Runs the steps of one phase and returns the first failure. `perform` gets the step and how many
    /// times that step already ran in this phase.
    static func run(
        _ kind: Int32,
        _ phase: Int32,
        required: Bool = false,
        appMoved: Bool = false,
        hasSignature: Bool = false,
        _ perform: (_ step: Int32, _ occurrence: Int) -> String?
    ) -> String? {
        var index: UInt32 = 0
        var seen: [Int32: Int] = [:]
        while true {
            let step = Int32(mv_step(UInt32(kind), UInt32(phase), index, required, appMoved, hasSignature))
            if step == MV_STEP_END { return nil }
            let occurrence = seen[step, default: 0]
            seen[step] = occurrence + 1
            if let failure = perform(step, occurrence) { return failure }
            index += 1
        }
    }

    static func confirmed(_ kind: Int32, movedURL: URL?, expectedIdentity: String, expectedDirectory: Bool) -> Bool {
        let identityMatches = movedURL.flatMap { FileIdentity.relocationIdentifier(for: $0) }.map { T27Text.same($0, expectedIdentity) } ?? false
        let isDirectory = movedURL.flatMap { try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory }
        return mv_confirmed(UInt32(kind), movedURL != nil, identityMatches, isDirectory != nil, isDirectory == true, expectedDirectory)
    }

    static func uncertain(_ kind: Int32, _ how: Int32, sourcePath: String) -> Bool {
        mv_uncertain(UInt32(kind), UInt32(how), FileManager.default.fileExists(atPath: sourcePath))
    }

    static func result(coordinationError: Bool, failure: Bool, moved: Bool) -> Int32 {
        Int32(mv_result(coordinationError, failure, moved))
    }

    static func stopsAfterFailure(_ kind: Int32) -> Bool {
        mv_stop_after_failure(UInt32(kind))
    }
}

/// An open handle on the reviewed item that follows it when it is renamed or moved, so the place it ends
/// up in can be read afterwards. It never follows a symlink and does not keep the volume busy.
/// Not Sendable: use it on one thread only.
final class HeldItem {
    private let fd: Int32

    init?(url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        fd = descriptor
    }

    deinit {
        close(fd)
    }

    var identity: String? { FileIdentity.relocationIdentifier(descriptor: fd) }

    var isDirectory: Bool? { FileIdentity.isDirectory(descriptor: fd) }

    /// Where the item is now (F_GETPATH), as the spike verified.
    var currentPath: String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

/// What DiskBloom asks of Finder when macOS refuses to move a reviewed application: the Automation
/// permission check and one `core/delo` Apple Event. Both return a status (0 = OK) and block, so call
/// them from a background queue only. Tests pass stand-ins; they never reference `live`.
struct FinderTrashRequest: Sendable {
    let permission: @Sendable () -> Int64
    let send: @Sendable (URL) -> Int64

    static let sendTimeout: TimeInterval = 600

    /// The form the spike used: work/admin-removal-2026-10-29/spike-probe.log lines 14-32.
    static let live = FinderTrashRequest(
        permission: {
            dispatchPrecondition(condition: .notOnQueue(.main))
            let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            return Int64(AEDeterminePermissionToAutomateTarget(finder.aeDesc, AEEventClass(0x636F7265) /* 'core' */, AEEventID(0x64656C6F) /* 'delo' */, true))
        },
        send: { url in
            dispatchPrecondition(condition: .notOnQueue(.main))
            let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            let event = NSAppleEventDescriptor(
                eventClass: 0x636F7265,
                eventID: 0x64656C6F,
                targetDescriptor: finder,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(NSAppleEventDescriptor(fileURL: url), forKeyword: AEKeyword(0x2D2D2D2D) /* '----' */)
            do {
                let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: FinderTrashRequest.sendTimeout)
                if let errn = reply.paramDescriptor(forKeyword: AEKeyword(0x6572726E) /* 'errn' */)?.int32Value, errn != 0 {
                    return Int64(errn)
                }
                return 0
            } catch {
                let code = (error as NSError).code
                return code == 0 ? -1 : Int64(code)
            }
        }
    )
}

struct DiskMapMoveOutcome: Sendable {
    let successfulPaths: [String]
    let failures: [String]
}

/// Moves the reviewed Disk Map queue to the Trash.
enum DiskMapCleanupCoordinator {
    static func moveToTrash(
        candidates: [DiskNode],
        rescanURL: URL,
        protectedRootURL: URL,
        mover: MoveSteps.Mover = MoveSteps.systemTrashMover
    ) -> DiskMapMoveOutcome {
        var successful: [String] = []
        var failures: [String] = []
        for node in candidates {
            guard let url = node.url else { continue }
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var localFailure: String?
            var didMove = false
            coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                var expectedIdentity: String?
                localFailure = MoveSteps.run(MV_DISK_MAP, MV_PHASE_ITEM) { step, _ in
                    switch step {
                    case MV_STEP_VALIDATE:
                        return DeletionPolicy.validateImmediatelyBeforeTrash(
                            node,
                            scanRootURL: protectedRootURL,
                            activeScanURL: rescanURL,
                            candidateURL: coordinatedURL
                        )
                    case MV_STEP_CAPTURE_IDENTITY:
                        expectedIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL)
                        return expectedIdentity == nil ? "Could not capture the identity before moving: \(url.path)" : nil
                    default:
                        return nil
                    }
                }
                guard localFailure == nil, let expectedIdentity else { return }
                do {
                    let movedURL = try mover(coordinatedURL)
                    guard MoveSteps.confirmed(MV_DISK_MAP, movedURL: movedURL, expectedIdentity: expectedIdentity, expectedDirectory: node.isDirectory) else {
                        let resultPath = movedURL?.path ?? "no Trash path was returned"
                        localFailure = "Could not confirm the item’s identity after moving: \(url.path). Result: \(resultPath). No automatic restore of an unknown item was attempted."
                        return
                    }
                    didMove = true
                } catch {
                    localFailure = "\(url.path): \(error.localizedDescription)"
                }
            }
            switch MoveSteps.result(coordinationError: coordinationError != nil, failure: localFailure != nil, moved: didMove) {
            case MV_FAILED:
                failures.append(coordinationError.map { "\(url.path): \($0.localizedDescription)" } ?? localFailure ?? "")
                if MoveSteps.stopsAfterFailure(MV_DISK_MAP) { return DiskMapMoveOutcome(successfulPaths: successful, failures: failures) }
            case MV_MOVED:
                successful.append(url.path)
            default:
                break
            }
        }
        return DiskMapMoveOutcome(successfulPaths: successful, failures: failures)
    }
}
