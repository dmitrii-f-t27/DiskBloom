import AppKit
import Foundation

/// The App Uninstaller rules as they were written in Swift before Specs/uninstaller_policy.t27.
/// Kept only as the oracle of the differential test.
enum LegacyUninstallerPolicy {
    static func match(_ rule: AppRemovalRule) -> AppRemovalMatch {
        switch rule {
        case .application: .application
        case .nameApplicationSupport, .nameCache, .namePreference, .nameSavedState, .nameLog: .exactName
        case .groupContainer, .groupApplicationScripts: .declaredGroup
        default: .exactIdentifier
        }
    }

    static func risk(_ rule: AppRemovalRule) -> AppRemovalRisk {
        switch rule {
        case .application:
            .application
        case .identifierApplicationSupport, .identifierContainer, .identifierApplicationScripts,
             .nameApplicationSupport:
            .persistentData
        case .groupContainer, .groupApplicationScripts,
             .nameCache, .namePreference, .nameSavedState, .nameLog:
            .sharedData
        default:
            .disposableState
        }
    }

    static func normallySelected(_ rule: AppRemovalRule) -> Bool {
        switch rule {
        case .application, .identifierCache, .identifierPreference, .identifierSavedState,
             .identifierHTTPStorage, .identifierWebKit, .identifierLog, .identifierCookie:
            true
        default:
            false
        }
    }


    static func needsExtraAcknowledgement(_ risk: AppRemovalRisk) -> Bool {
        risk == .persistentData || risk == .sharedData
    }

    /// The per-item decisions of the old buildPlan and makeItem, transcribed as one function.
    static func itemDecision(
        rule: AppRemovalRule,
        key: String,
        required: Bool,
        duplicate: Bool,
        signatureBacked: Bool,
        complete: Bool,
        unreadableCount: Int,
        foreignMounts: Int,
        applicationIssue: String?
    ) -> AppRemovalItemDecision {
        let explanation: String
        let defaultSelected: Bool
        var additionalIssue: String? = nil
        var keepSelectableWithIssue = false
        var riskOverride: AppRemovalRisk? = nil
        if required {
            explanation = "The .app bundle itself. It is always part of the plan."
            defaultSelected = true
            additionalIssue = applicationIssue
        } else {
            switch match(rule) {
            case .exactIdentifier:
                let sharedNote = duplicate
                    ? " This bundle ID was also found in another installed application, so the item is treated as potentially shared."
                    : (signatureBacked
                        ? ""
                        : " The bundle ID is not backed by a signature with an Apple trust anchor and Team ID, so default selection is off.")
                explanation = "Path built from the exact bundle ID “\(key)”." + sharedNote
                defaultSelected = duplicate || !signatureBacked ? false : normallySelected(rule)
            case .exactName:
                explanation = "Only the exact name “\(key)” matched; check the path manually."
                defaultSelected = false
            default:
                explanation = "App Group “\(key)” is declared in a signature with an Apple trust anchor and Team ID, but may be shared."
                defaultSelected = false
            }
            let identifierTrustIssue: String?
            if match(rule) == .exactIdentifier, duplicate {
                identifierTrustIssue = "This bundle ID is used by another installed application. Default selection is off."
            } else if match(rule) == .exactIdentifier, !signatureBacked {
                identifierTrustIssue = "The bundle ID is not backed by a signature with an Apple trust anchor and Team ID. Check the path manually."
            } else {
                identifierTrustIssue = nil
            }
            additionalIssue = identifierTrustIssue
            keepSelectableWithIssue = identifierTrustIssue != nil
            riskOverride = identifierTrustIssue == nil ? nil : .sharedData
        }
        let snapshotIssue: String?
        if !complete {
            snapshotIssue = "Could not capture a complete snapshot of the item."
        } else if unreadableCount > 0 {
            snapshotIssue = "It contains inaccessible items: \(unreadableCount)."
        } else if foreignMounts > 0 {
            snapshotIssue = "Another volume was found inside; a complete snapshot is impossible."
        } else {
            snapshotIssue = nil
        }
        let eligibilityIssue = snapshotIssue ?? (keepSelectableWithIssue ? nil : additionalIssue)
        return AppRemovalItemDecision(
            explanation: explanation + (keepSelectableWithIssue ? " " + (additionalIssue ?? "") : ""),
            isDefaultSelected: defaultSelected && eligibilityIssue == nil,
            eligibilityIssue: eligibilityIssue,
            riskOverride: riskOverride
        )
    }

    static func applicationEligibilityReason(for application: InstalledApplication) -> String? {
        let url = application.url.standardizedFileURL
        let path = url.path
        guard url.pathExtension.lowercased() == "app" else {
            return "The selected item is not an .app bundle."
        }
        if AppRemovalPathSafety.pathHasSymlinkedComponent(url) {
            return "The application path contains a symbolic link. Such an item is view-only."
        }
        let protectedRoots = ["/System", "/usr", "/bin", "/sbin", "/private", "/Library"]
        if protectedRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "System and system-wide applications are protected. Use the vendor’s official uninstall method."
        }
        if application.bundleIdentifier?.hasPrefix("com.apple.") == true {
            return "Apple applications with a com.apple.* bundle ID are protected in this mode."
        }
        let selfPath = Bundle.main.bundleURL.standardizedFileURL.path
        if path == selfPath || selfPath.hasPrefix(path + "/") {
            return "DiskBloom cannot move itself or its containing bundle to the Trash."
        }
        let home = UserHome.path
        let blockedUserRoots = [
            home + "/Library",
            home + "/.Trash",
            home + "/My Drive",
            home + "/Dropbox",
            home + "/OneDrive",
            home + "/Google Drive",
            home + "/iCloud Drive"
        ]
        if blockedUserRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            return "Applications inside Library, the Trash or a cloud folder are protected."
        }
        if (path as NSString).pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) {
            return "The item is already in the Trash."
        }
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isUbiquitousItemKey
        ]),
              values.isDirectory == true,
              values.isPackage == true,
              values.isSymbolicLink != true else {
            return "Could not confirm the application bundle type."
        }
        if values.volumeIsLocal != true { return "Network and unknown volumes are not supported." }
        if values.volumeIsReadOnly == true { return "The volume is read-only." }
        if values.isUbiquitousItem == true { return "Cloud applications are view-only." }
        return nil
    }

    static func continuationEligibilityReason(for plan: AppRemovalPlan) -> String? {
        let originalPath = plan.application.url.standardizedFileURL.path
        let installedApplications = ApplicationCatalog.discover()
        if let identifier = plan.application.bundleIdentifier, !identifier.isEmpty {
            let registeredApplications = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
            if installedApplications.contains(where: { $0.bundleIdentifier == identifier }) {
                return "A new or different copy with bundle ID \(identifier) is installed. A new analysis is needed."
            }
            if registeredApplications.contains(where: { url in
                let path = url.standardizedFileURL.path
                let components = (path as NSString).pathComponents
                let isInTrash = components.contains(".Trash") || components.contains(".Trashes")
                return !isInTrash && FileManager.default.fileExists(atPath: path)
            }) {
                return "LaunchServices registered another existing copy with bundle ID \(identifier). A new analysis is needed."
            }
        } else if installedApplications.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(plan.application.name) == .orderedSame
        }) {
            return "An application with the same name “\(plan.application.name)” is installed. A new analysis is needed."
        }
        if FileManager.default.fileExists(atPath: originalPath) {
            return "An application exists again at the original path: \(originalPath). A new analysis is needed."
        }
        if AppRunningDetector.reason(for: plan.application) != nil {
            return "A running process with the previous bundle ID was found. Cleanup of the old plan is blocked."
        }
        return nil
    }

    static func validate(
        _ item: AppRemovalItem,
        application: InstalledApplication,
        homeURL: URL = UserHome.url,
        candidateURL: URL? = nil,
        requireApplicationPresence: Bool = true
    ) -> String? {
        if requireApplicationPresence,
           let reason = LegacyUninstallerPolicy.applicationEligibilityReason(for: application) { return reason }
        if let issue = item.eligibilityIssue { return "\(item.url.path): \(issue)" }
        let original = item.url.standardizedFileURL
        let candidate = (candidateURL ?? original).standardizedFileURL
        switch LegacyUninstallerPolicy.match(item.rule) {
        case .exactIdentifier, .declaredGroup:
            guard AppRemovalPathSafety.safeIdentifier(item.key) == item.key else {
                return "Unsafe path identifier: \(original.path)"
            }
        case .exactName:
            guard AppRemovalPathSafety.safeDisplayName(item.key) == item.key else {
                return "Unsafe name for a path: \(original.path)"
            }
        case .application:
            break
        }
        guard candidate.path == original.path else {
            return "The coordinated path changed: \(original.path)"
        }
        guard let expected = item.rule.expectedURL(
            applicationURL: application.url,
            homeURL: homeURL,
            key: item.key
        )?.standardizedFileURL,
              expected.path == original.path else {
            return "The path does not match an allowed rule: \(original.path)"
        }
        if AppRemovalPathSafety.pathHasSymlinkedComponent(original) {
            return "The path contains a symbolic link: \(original.path)"
        }
        guard let values = try? original.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isUbiquitousItemKey
        ]) else {
            return "Could not check the volume: \(original.path)"
        }
        if values.volumeIsLocal != true { return "The item is not on a local volume: \(original.path)" }
        if values.volumeIsReadOnly == true { return "The item is on a read-only volume: \(original.path)" }
        if values.isUbiquitousItem == true { return "Cloud item is protected: \(original.path)" }

        if item.rule == .application {
            let currentProfile = ApplicationCatalog.profile(for: original)
            if currentProfile.bundleIdentifier != application.bundleIdentifier {
                return "The application’s bundle ID changed after analysis: \(original.path)"
            }
        } else {
            let library = homeURL.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
            guard original.path.hasPrefix(library + "/") else {
                return "The related item is outside the user Library: \(original.path)"
            }
        }
        return SnapshotValidator.validate(item.node, candidateURL: candidate)
    }

}
