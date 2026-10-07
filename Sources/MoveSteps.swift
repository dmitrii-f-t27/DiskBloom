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
