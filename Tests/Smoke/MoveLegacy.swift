import AppKit
import Foundation

/// The four Trash coordinators as they were written in Swift before Specs/move_rules.t27. Oracle only.
enum LegacyCacheCleanupCoordinator {
    typealias TrashMover = @Sendable (URL) throws -> URL?
    typealias RunningResolver = @Sendable () -> Set<String>

    static let systemTrashMover: TrashMover = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    /// Items are independent caches, so one failure does not stop the rest.
    static func moveToTrash(
        items: [CacheItem],
        runningResolver: RunningResolver,
        mover: TrashMover = systemTrashMover
    ) -> CacheCleanupOutcome {
        var moved: [String] = []
        var failures: [String] = []
        for item in items.sorted(by: { $0.url.path < $1.url.path }) {
            let url = item.url
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var localFailure: String?
            var didMove = false
            coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                if let reason = CachePolicy.validate(
                    item,
                    runningIdentifiers: runningResolver(),
                    candidateURL: coordinatedURL
                ) {
                    localFailure = reason
                    return
                }
                guard let expectedIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                    localFailure = "Could not capture the identity before moving: \(url.path)"
                    return
                }
                do {
                    let movedURL = try mover(coordinatedURL)
                    guard let movedURL,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedIdentity else {
                        let result = movedURL?.path ?? "no Trash path was returned"
                        localFailure = "Could not confirm the item after moving: \(url.path). Result: \(result). Check the Trash."
                        return
                    }
                    didMove = true
                } catch {
                    localFailure = "\(url.path): \(error.localizedDescription)"
                }
            }
            if let coordinationError {
                failures.append("\(url.path): \(coordinationError.localizedDescription)")
            } else if let localFailure {
                failures.append(localFailure)
            } else if didMove {
                moved.append(url.path)
            }
        }
        return CacheCleanupOutcome(movedPaths: moved, failures: failures)
    }
}

enum LegacyOrphanCleanupCoordinator {
    typealias TrashMover = @Sendable (URL) throws -> URL?
    typealias OwnerResolver = @Sendable (Set<String>) -> OrphanOwnerIndex

    static let systemTrashMover: TrashMover = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    static func moveToTrash(
        items: [OrphanDataItem],
        homeURL: URL = UserHome.url,
        ownerResolver: OwnerResolver,
        mover: TrashMover = systemTrashMover
    ) -> OrphanCleanupOutcome {
        let ordered = items.sorted { $0.url.path < $1.url.path }
        guard !ordered.isEmpty else {
            return OrphanCleanupOutcome(movedPaths: [], uncertainPaths: [], failure: "Nothing selected.", unattemptedPaths: [])
        }
        if let overlap = OrphanDataPolicy.overlappingSelectionReason(ordered) {
            return OrphanCleanupOutcome(
                movedPaths: [], uncertainPaths: [], failure: overlap,
                unattemptedPaths: ordered.map { $0.url.path }
            )
        }
        let identifiers = Set(ordered.map(\.canonicalIdentifier))
        let initialOwners = ownerResolver(identifiers)
        for item in ordered {
            if let reason = initialOwners.claimReason(for: item.canonicalIdentifier) {
                return OrphanCleanupOutcome(
                    movedPaths: [],
                    uncertainPaths: [],
                    failure: "Cleanup blocked: \(reason)",
                    unattemptedPaths: ordered.map { $0.url.path }
                )
            }
            if let reason = OrphanDataPolicy.validate(item, homeURL: homeURL) {
                return OrphanCleanupOutcome(
                    movedPaths: [], uncertainPaths: [], failure: reason,
                    unattemptedPaths: ordered.map { $0.url.path }
                )
            }
        }

        var moved: [String] = []
        for (index, item) in ordered.enumerated() {
            let url = item.url
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var localFailure: String?
            var didMove = false
            var uncertain = false
            coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                let freshOwners = ownerResolver(Set([item.canonicalIdentifier]))
                if let reason = freshOwners.claimReason(for: item.canonicalIdentifier) {
                    localFailure = "Cleanup blocked: \(reason)"
                    return
                }
                if let reason = OrphanDataPolicy.validate(
                    item,
                    homeURL: homeURL,
                    candidateURL: coordinatedURL
                ) {
                    localFailure = reason
                    return
                }
                let ownersImmediatelyBeforeMove = ownerResolver(Set([item.canonicalIdentifier]))
                if let reason = ownersImmediatelyBeforeMove.claimReason(for: item.canonicalIdentifier) {
                    localFailure = "Cleanup blocked immediately before moving: \(reason)"
                    return
                }
                if let reason = OrphanDataPolicy.validate(
                    item,
                    homeURL: homeURL,
                    candidateURL: coordinatedURL
                ) {
                    localFailure = reason
                    return
                }
                guard let expectedIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                    localFailure = "Could not capture the identity immediately before moving: \(url.path)"
                    return
                }
                do {
                    let movedURL = try mover(coordinatedURL)
                    guard let movedURL,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedIdentity,
                          (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        let result = movedURL?.path ?? "no Trash path was returned"
                        localFailure = "Could not confirm the item after moving: \(url.path). Result: \(result)."
                        uncertain = !FileManager.default.fileExists(atPath: coordinatedURL.path)
                        return
                    }
                    didMove = true
                } catch {
                    let sourceExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    uncertain = !sourceExists
                    let suffix = sourceExists
                        ? ""
                        : " The original path disappeared; automatic retry is blocked."
                    localFailure = "\(url.path): \(error.localizedDescription)\(suffix)"
                }
            }
            if coordinationError != nil, !FileManager.default.fileExists(atPath: url.path) {
                uncertain = true
            }
            let failure = coordinationError.map { "\(url.path): \($0.localizedDescription)" } ?? localFailure
            if let failure {
                return OrphanCleanupOutcome(
                    movedPaths: moved,
                    uncertainPaths: uncertain ? [url.path] : [],
                    failure: failure,
                    unattemptedPaths: ordered.dropFirst(index + 1).map { $0.url.path }
                )
            }
            if didMove { moved.append(url.path) }
        }
        return OrphanCleanupOutcome(movedPaths: moved, uncertainPaths: [], failure: nil, unattemptedPaths: [])
    }
}

enum LegacyAppRemovalCoordinator {
    static func moveToTrash(
        items: [AppRemovalItem],
        plan: AppRemovalPlan,
        applicationAlreadyMoved: Bool,
        mover: @Sendable (URL) throws -> URL?
    ) -> AppRemovalOutcome {
        let ordered = items.sorted {
            if $0.isRequired != $1.isRequired { return $0.isRequired }
            return $0.url.path < $1.url.path
        }
        if let overlap = AppRemovalPolicy.overlappingSelectionReason(ordered) {
            return AppRemovalOutcome(
                movedPaths: [],
                uncertainPaths: [],
                failure: overlap,
                unattemptedPaths: ordered.map { $0.url.path }
            )
        }
        if !applicationAlreadyMoved,
           let running = AppRunningDetector.reason(for: plan.application) {
            return AppRemovalOutcome(
                movedPaths: [],
                uncertainPaths: [],
                failure: running,
                unattemptedPaths: ordered.map { $0.url.path }
            )
        }
        if !applicationAlreadyMoved,
           let signatureFailure = LegacyAppRemovalCoordinator.validateTrustedSignature(for: plan) {
            return AppRemovalOutcome(
                movedPaths: [],
                uncertainPaths: [],
                failure: signatureFailure,
                unattemptedPaths: ordered.map { $0.url.path }
            )
        }
        if applicationAlreadyMoved,
           let continuationFailure = AppRemovalPolicy.continuationEligibilityReason(for: plan) {
            return AppRemovalOutcome(
                movedPaths: [],
                uncertainPaths: [],
                failure: continuationFailure,
                unattemptedPaths: ordered.map { $0.url.path }
            )
        }
        for item in ordered {
            if let reason = AppRemovalPolicy.validate(
                item,
                application: plan.application,
                requireApplicationPresence: !applicationAlreadyMoved
            ) {
                return AppRemovalOutcome(
                    movedPaths: [],
                    uncertainPaths: [],
                    failure: reason,
                    unattemptedPaths: ordered.map { $0.url.path }
                )
            }
        }

        var moved: [String] = []
        var appHasMoved = applicationAlreadyMoved
        for (index, item) in ordered.enumerated() {
            let url = item.url
            let coordinator = NSFileCoordinator(filePresenter: nil)
            var coordinationError: NSError?
            var localFailure: String?
            var didMove = false
            var moveResultIsUncertain = false
            coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                if item.isRequired,
                   let running = AppRunningDetector.reason(for: plan.application) {
                    localFailure = running
                    return
                }
                if item.isRequired,
                   let signatureFailure = LegacyAppRemovalCoordinator.validateTrustedSignature(
                       for: plan,
                       candidateURL: coordinatedURL
                   ) {
                    localFailure = signatureFailure
                    return
                }
                if let reason = AppRemovalPolicy.validate(
                    item,
                    application: plan.application,
                    candidateURL: coordinatedURL,
                    requireApplicationPresence: !appHasMoved
                ) {
                    localFailure = reason
                    return
                }
                guard let expectedRelocationIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                    localFailure = "Could not capture the identity before moving: \(url.path)"
                    return
                }
                if item.isRequired,
                   let running = AppRunningDetector.reason(for: plan.application) {
                    localFailure = running
                    return
                }
                if !item.isRequired,
                   appHasMoved,
                   let continuationFailure = AppRemovalPolicy.continuationEligibilityReason(for: plan) {
                    localFailure = continuationFailure
                    return
                }
                do {
                    let resultingURL = try mover(coordinatedURL)
                    guard let movedURL = resultingURL,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedRelocationIdentity,
                          (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == item.node.isDirectory else {
                        let resultPath = resultingURL?.path ?? "no Trash path was returned"
                        localFailure = "Could not confirm the item after moving: \(url.path). Result: \(resultPath). No automatic restore of an unknown item was attempted."
                        moveResultIsUncertain = true
                        return
                    }
                    didMove = true
                } catch {
                    let sourceStillExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    moveResultIsUncertain = !sourceStillExists
                    let uncertainty = sourceStillExists
                        ? ""
                        : " The original path disappeared, so the move result is unconfirmed and automatic retry is blocked."
                    localFailure = "\(url.path): \(error.localizedDescription)\(uncertainty)"
                }
            }
            if coordinationError != nil, !FileManager.default.fileExists(atPath: url.path) {
                moveResultIsUncertain = true
            }
            let failure = coordinationError.map { "\(url.path): \($0.localizedDescription)" } ?? localFailure
            if let failure {
                return AppRemovalOutcome(
                    movedPaths: moved,
                    uncertainPaths: moveResultIsUncertain ? [url.path] : [],
                    failure: failure,
                    unattemptedPaths: ordered.dropFirst(index + 1).map { $0.url.path }
                )
            }
            if didMove {
                moved.append(url.path)
                if item.isRequired { appHasMoved = true }
            }
        }
        return AppRemovalOutcome(movedPaths: moved, uncertainPaths: [], failure: nil, unattemptedPaths: [])
    }
    static func validateTrustedSignature(
        for plan: AppRemovalPlan,
        candidateURL: URL? = nil
    ) -> String? {
        guard let expectedSignature = plan.validatedSignature else { return nil }
        let expectedURL = plan.application.url.standardizedFileURL
        let currentURL = (candidateURL ?? expectedURL).standardizedFileURL
        guard currentURL.path == expectedURL.path else {
            return "The coordinated application path changed: \(expectedURL.path)"
        }
        guard let applicationItem = plan.items.first(where: \.isRequired) else {
            return "The plan is missing the required application snapshot."
        }
        if let reason = SnapshotValidator.validate(applicationItem.node, candidateURL: currentURL) {
            return "The application bundle changed after analysis: \(reason)"
        }
        guard CodeSignatureReader.validatedMetadata(at: currentURL) == expectedSignature else {
            return "The application’s signature, Team ID or signing identifier changed after analysis: \(currentURL.path)"
        }
        if let reason = SnapshotValidator.validate(applicationItem.node, candidateURL: currentURL) {
            return "The application bundle changed during signature verification: \(reason)"
        }
        return nil
    }

}
enum LegacyDiskMapMove {
    /// The move loop of AppModel.moveReviewedItemsToTrash, as it was before Specs/move_rules.t27.
    static func moveToTrash(
        candidates: [DiskNode],
        rescanURL: URL,
        protectedRootURL: URL,
        mover: @Sendable (URL) throws -> URL?
    ) -> (successful: [String], failures: [String]) {
                var successful: [String] = []
                var failures: [String] = []
                for node in candidates {
                    guard let url = node.url else { continue }
                    let coordinator = NSFileCoordinator(filePresenter: nil)
                    var coordinationError: NSError?
                    var localFailure: String?
                    var didMove = false
                    coordinator.coordinate(writingItemAt: url, options: .forMoving, error: &coordinationError) { coordinatedURL in
                        if let reason = DeletionPolicy.validateImmediatelyBeforeTrash(
                            node,
                            scanRootURL: protectedRootURL,
                            activeScanURL: rescanURL,
                            candidateURL: coordinatedURL
                        ) {
                            localFailure = reason
                            return
                        }
                        guard let expectedRelocationIdentity = FileIdentity.relocationIdentifier(for: coordinatedURL) else {
                            localFailure = "Could not capture the identity before moving: \(url.path)"
                            return
                        }
                        do {
                            let resultingURL = try mover(coordinatedURL)
                            guard let movedURL = resultingURL,
                                  FileIdentity.relocationIdentifier(for: movedURL) == expectedRelocationIdentity,
                                  (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == node.isDirectory else {
                                let resultPath = resultingURL?.path ?? "no Trash path was returned"
                                localFailure = "Could not confirm the item’s identity after moving: \(url.path). Result: \(resultPath). No automatic restore of an unknown item was attempted."
                                return
                            }
                            didMove = true
                        } catch {
                            localFailure = "\(url.path): \(error.localizedDescription)"
                        }
                    }
                    if let coordinationError {
                        failures.append("\(url.path): \(coordinationError.localizedDescription)")
                    } else if let localFailure {
                        failures.append(localFailure)
                    } else if didMove {
                        successful.append(url.path)
                    }
                }
                return (successful, failures)
    }
}
