import AppKit
import Combine
import Foundation
import Security
import UniformTypeIdentifiers

struct InstalledApplication: Identifiable, Sendable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let sourceLabel: String

    var id: String { url.standardizedFileURL.path }
}

enum AppRemovalMatch: String, Sendable {
    case application
    case exactIdentifier
    case exactName
    case declaredGroup

    var title: String {
        switch self {
        case .application: "Application"
        case .exactIdentifier: "Exact bundle ID match"
        case .exactName: "Possible name match"
        case .declaredGroup: "Shared App Group"
        }
    }

    var tintName: String {
        switch self {
        case .application: "blue"
        case .exactIdentifier: "mint"
        case .exactName: "orange"
        case .declaredGroup: "purple"
        }
    }
}

enum AppRemovalRisk: String, Sendable {
    case application
    case disposableState
    case persistentData
    case sharedData

    var warning: String? {
        switch self {
        case .application, .disposableState:
            nil
        case .persistentData:
            "May contain local documents, projects or user data."
        case .sharedData:
            "May be used by another application or account."
        }
    }

    var needsExtraAcknowledgement: Bool {
        self == .persistentData || self == .sharedData
    }
}

enum AppRemovalRule: String, Sendable {
    case application
    case identifierApplicationSupport
    case identifierCache
    case identifierPreference
    case identifierSavedState
    case identifierHTTPStorage
    case identifierWebKit
    case identifierLog
    case identifierCookie
    case identifierContainer
    case identifierApplicationScripts
    case identifierLaunchAgent
    case nameApplicationSupport
    case nameCache
    case namePreference
    case nameSavedState
    case nameLog
    case groupContainer
    case groupApplicationScripts

    var title: String {
        switch self {
        case .application: "Application bundle"
        case .identifierApplicationSupport, .nameApplicationSupport: "Application Support"
        case .identifierCache, .nameCache: "Cache"
        case .identifierPreference, .namePreference: "Preferences"
        case .identifierSavedState, .nameSavedState: "Saved state"
        case .identifierHTTPStorage: "HTTP storage"
        case .identifierWebKit: "WebKit data"
        case .identifierLog, .nameLog: "Logs"
        case .identifierCookie: "Cookies"
        case .identifierContainer: "Sandbox container"
        case .identifierApplicationScripts, .groupApplicationScripts: "Application Scripts"
        case .identifierLaunchAgent: "LaunchAgent"
        case .groupContainer: "Group Container"
        }
    }

    var match: AppRemovalMatch {
        switch self {
        case .application: .application
        case .nameApplicationSupport, .nameCache, .namePreference, .nameSavedState, .nameLog: .exactName
        case .groupContainer, .groupApplicationScripts: .declaredGroup
        default: .exactIdentifier
        }
    }

    var risk: AppRemovalRisk {
        switch self {
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

    var normallySelected: Bool {
        switch self {
        case .application, .identifierCache, .identifierPreference, .identifierSavedState,
             .identifierHTTPStorage, .identifierWebKit, .identifierLog, .identifierCookie:
            true
        default:
            false
        }
    }

    func expectedURL(applicationURL: URL, homeURL: URL, key: String) -> URL? {
        let library = homeURL.appendingPathComponent("Library", isDirectory: true)
        switch self {
        case .application:
            return applicationURL.standardizedFileURL
        case .identifierApplicationSupport:
            return library.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierCache:
            return library.appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierPreference:
            return library.appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent(key + ".plist", isDirectory: false)
        case .identifierSavedState:
            return library.appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent(key + ".savedState", isDirectory: true)
        case .identifierHTTPStorage:
            return library.appendingPathComponent("HTTPStorages", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierWebKit:
            return library.appendingPathComponent("WebKit", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierLog:
            return library.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierCookie:
            return library.appendingPathComponent("Cookies", isDirectory: true)
                .appendingPathComponent(key + ".binarycookies", isDirectory: false)
        case .identifierContainer:
            return library.appendingPathComponent("Containers", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierApplicationScripts:
            return library.appendingPathComponent("Application Scripts", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .identifierLaunchAgent:
            return library.appendingPathComponent("LaunchAgents", isDirectory: true)
                .appendingPathComponent(key + ".plist", isDirectory: false)
        case .nameApplicationSupport:
            return library.appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .nameCache:
            return library.appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .namePreference:
            return library.appendingPathComponent("Preferences", isDirectory: true)
                .appendingPathComponent(key + ".plist", isDirectory: false)
        case .nameSavedState:
            return library.appendingPathComponent("Saved Application State", isDirectory: true)
                .appendingPathComponent(key + ".savedState", isDirectory: true)
        case .nameLog:
            return library.appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .groupContainer:
            return library.appendingPathComponent("Group Containers", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        case .groupApplicationScripts:
            return library.appendingPathComponent("Application Scripts", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
        }
    }
}

struct AppRemovalItem: Identifiable, Sendable {
    let id: String
    let node: DiskNode
    let rule: AppRemovalRule
    let key: String
    let explanation: String
    let isRequired: Bool
    let isDefaultSelected: Bool
    let eligibilityIssue: String?
    let riskOverride: AppRemovalRisk?

    var url: URL { node.url! }
    var match: AppRemovalMatch { rule.match }
    var risk: AppRemovalRisk { riskOverride ?? rule.risk }
    var isSelectable: Bool { eligibilityIssue == nil }
}

struct AppRemovalPlan: Sendable {
    let application: InstalledApplication
    let items: [AppRemovalItem]
    let hasDuplicateBundleIdentifier: Bool
    let bundleIdentifierIsSignatureBacked: Bool
    let validatedSignature: ValidatedCodeSignature?
    let hasPrivilegedComponents: Bool
    let applicationEligibilityIssue: String?
}

struct ValidatedCodeSignature: Sendable, Equatable {
    let identifier: String
    let teamIdentifier: String
    let applicationGroups: [String]
}

struct AppRemovalOutcome: Sendable {
    let movedPaths: [String]
    let uncertainPaths: [String]
    let failure: String?
    let unattemptedPaths: [String]
}

private struct AppCandidateSpec: Sendable {
    let rule: AppRemovalRule
    let key: String
    let explanation: String
    let defaultSelected: Bool
}

enum ApplicationCatalog {
    static func discover(homeURL: URL = UserHome.url) -> [InstalledApplication] {
        let roots: [(URL, String, Int)] = [
            (URL(fileURLWithPath: "/Applications", isDirectory: true), "Applications", 1),
            (homeURL.appendingPathComponent("Applications", isDirectory: true), "User Applications", 1),
            (URL(fileURLWithPath: "/System/Applications", isDirectory: true), "System Applications", 1)
        ]
        var found: [InstalledApplication] = []
        var seen: Set<String> = []
        for (root, label, depth) in roots {
            collectApplications(at: root, sourceLabel: label, remainingDepth: depth, found: &found, seen: &seen)
        }
        return found.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    static func profile(for url: URL, sourceLabel: String = "Selected application") -> InstalledApplication {
        let normalized = url.standardizedFileURL
        let bundle = Bundle(url: normalized)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? normalized.deletingPathExtension().lastPathComponent
        let version = (bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        return InstalledApplication(
            url: normalized,
            name: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            version: version,
            sourceLabel: sourceLabel
        )
    }

    private static func collectApplications(
        at root: URL,
        sourceLabel: String,
        remainingDepth: Int,
        found: inout [InstalledApplication],
        seen: inout Set<String>
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            if entry.pathExtension.lowercased() == "app" {
                let profile = profile(for: entry, sourceLabel: sourceLabel)
                if seen.insert(profile.id).inserted { found.append(profile) }
            } else if remainingDepth > 0, values.isPackage != true {
                collectApplications(
                    at: entry,
                    sourceLabel: sourceLabel,
                    remainingDepth: remainingDepth - 1,
                    found: &found,
                    seen: &seen
                )
            }
        }
    }
}

enum AppRunningDetector {
    static func reason(for application: InstalledApplication) -> String? {
        let targetURL = application.url.standardizedFileURL.resolvingSymlinksInPath()
        let matchingProcess = NSWorkspace.shared.runningApplications.first { running in
            if let targetIdentifier = application.bundleIdentifier,
               !targetIdentifier.isEmpty,
               running.bundleIdentifier == targetIdentifier {
                return true
            }
            if let bundleURL = running.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() {
                return bundleURL.path == targetURL.path || bundleURL.path.hasPrefix(targetURL.path + "/")
            }
            return false
        }
        guard matchingProcess != nil else { return nil }
        return "The application, its embedded helper or another copy with the same bundle ID is running. Quit them and check again."
    }
}

enum CodeSignatureReader {
    static func validatedMetadata(at appURL: URL) -> ValidatedCodeSignature? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else { return nil }
        var appleRequirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            "anchor apple generic" as CFString,
            SecCSFlags(rawValue: 0),
            &appleRequirement
        )
        guard requirementStatus == errSecSuccess, let appleRequirement else { return nil }
        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            appleRequirement
        )
        guard validationStatus == errSecSuccess else { return nil }
        var signingInformation: CFDictionary?
        let copyStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard copyStatus == errSecSuccess,
              let dictionary = signingInformation as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamIdentifier.isEmpty else {
            return nil
        }
        let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        let groups = Array(Set(entitlements?["com.apple.security.application-groups"] as? [String] ?? [])).sorted()
        return ValidatedCodeSignature(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            applicationGroups: groups
        )
    }
}

enum AppRemovalPathSafety {
    static func safeIdentifier(_ value: String?) -> String? {
        guard let value,
              value.count >= 3,
              value.count <= 255,
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains(".."),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_"
              }) else { return nil }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return value
    }

    static func safeDisplayName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 200,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":"),
              !trimmed.contains("\0") else { return nil }
        return trimmed
    }

    static func pathHasSymlinkedComponent(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path != url.standardizedFileURL.path
    }
}

enum ApplicationRemovalAnalyzer {
    static func buildPlan(
        for application: InstalledApplication,
        knownApplications: [InstalledApplication],
        homeURL: URL = UserHome.url,
        progress: ScanCounter
    ) throws -> AppRemovalPlan {
        let applicationIssue = AppRemovalPolicy.applicationEligibilityReason(for: application)
        let safeIdentifier = AppRemovalPathSafety.safeIdentifier(application.bundleIdentifier)
        let appSnapshot = try scan(application.url, progress: progress)
        let signatureCandidate = CodeSignatureReader.validatedMetadata(at: application.url)
        let snapshotStayedStable = SnapshotValidator.validate(
            appSnapshot.root,
            candidateURL: application.url
        ) == nil
        let validatedSignature = snapshotStayedStable
            && safeIdentifier != nil
            && signatureCandidate?.identifier == safeIdentifier
            ? signatureCandidate
            : nil
        let signatureBackedIdentifier = validatedSignature != nil
        let safeName = AppRemovalPathSafety.safeDisplayName(application.url.deletingPathExtension().lastPathComponent)
            ?? AppRemovalPathSafety.safeDisplayName(application.name)
        let duplicateIdentifier: Bool
        if let safeIdentifier {
            duplicateIdentifier = knownApplications.contains {
                $0.id != application.id && $0.bundleIdentifier == safeIdentifier
            }
        } else {
            duplicateIdentifier = false
        }

        var items: [AppRemovalItem] = [
            makeItem(
                snapshot: appSnapshot,
                rule: .application,
                key: safeIdentifier ?? application.name,
                explanation: "The .app bundle itself. It is always part of the plan.",
                required: true,
                defaultSelected: true,
                additionalIssue: applicationIssue
            )
        ]

        var specs: [AppCandidateSpec] = []
        if let safeIdentifier {
            let identifierRules: [AppRemovalRule] = [
                .identifierApplicationSupport,
                .identifierCache,
                .identifierPreference,
                .identifierSavedState,
                .identifierHTTPStorage,
                .identifierWebKit,
                .identifierLog,
                .identifierCookie,
                .identifierContainer,
                .identifierApplicationScripts,
                .identifierLaunchAgent
            ]
            for rule in identifierRules {
                let sharedNote = duplicateIdentifier
                    ? " This bundle ID was also found in another installed application, so the item is treated as potentially shared."
                    : (signatureBackedIdentifier
                        ? ""
                        : " The bundle ID is not backed by a signature with an Apple trust anchor and Team ID, so default selection is off.")
                specs.append(
                    AppCandidateSpec(
                        rule: rule,
                        key: safeIdentifier,
                        explanation: "Path built from the exact bundle ID “\(safeIdentifier)”." + sharedNote,
                        defaultSelected: duplicateIdentifier || !signatureBackedIdentifier ? false : rule.normallySelected
                    )
                )
            }
        }

        if let safeName {
            for rule in [
                AppRemovalRule.nameApplicationSupport,
                .nameCache,
                .namePreference,
                .nameSavedState,
                .nameLog
            ] {
                specs.append(
                    AppCandidateSpec(
                        rule: rule,
                        key: safeName,
                        explanation: "Only the exact name “\(safeName)” matched; check the path manually.",
                        defaultSelected: false
                    )
                )
            }
        }

        let groups = (validatedSignature?.applicationGroups ?? [])
            .compactMap(AppRemovalPathSafety.safeIdentifier)
        for group in Set(groups).sorted() {
            for rule in [AppRemovalRule.groupContainer, .groupApplicationScripts] {
                specs.append(
                    AppCandidateSpec(
                        rule: rule,
                        key: group,
                        explanation: "App Group “\(group)” is declared in a signature with an Apple trust anchor and Team ID, but may be shared.",
                        defaultSelected: false
                    )
                )
            }
        }

        var seenPaths: Set<String> = [application.id]
        for spec in specs {
            guard let candidateURL = spec.rule.expectedURL(
                applicationURL: application.url,
                homeURL: homeURL,
                key: spec.key
            )?.standardizedFileURL else { continue }
            let path = candidateURL.path
            guard seenPaths.insert(path).inserted,
                  FileManager.default.fileExists(atPath: path) else { continue }
            let snapshot = try scan(candidateURL, progress: progress)
            let identifierTrustIssue: String?
            if spec.rule.match == .exactIdentifier, duplicateIdentifier {
                identifierTrustIssue = "This bundle ID is used by another installed application. Default selection is off."
            } else if spec.rule.match == .exactIdentifier, !signatureBackedIdentifier {
                identifierTrustIssue = "The bundle ID is not backed by a signature with an Apple trust anchor and Team ID. Check the path manually."
            } else {
                identifierTrustIssue = nil
            }
            items.append(
                makeItem(
                    snapshot: snapshot,
                    rule: spec.rule,
                    key: spec.key,
                    explanation: spec.explanation,
                    required: false,
                    defaultSelected: spec.defaultSelected,
                    additionalIssue: identifierTrustIssue,
                    keepSelectableWithIssue: identifierTrustIssue != nil,
                    riskOverride: identifierTrustIssue == nil ? nil : .sharedData
                )
            )
        }

        items.sort {
            if $0.isRequired != $1.isRequired { return $0.isRequired }
            if $0.isDefaultSelected != $1.isDefaultSelected { return $0.isDefaultSelected }
            return $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending
        }

        let privilegedPaths = [
            "Contents/Library/SystemExtensions",
            "Contents/Library/LaunchServices",
            "Contents/Library/LoginItems"
        ]
        let hasPrivilegedComponents = privilegedPaths.contains {
            FileManager.default.fileExists(atPath: application.url.appendingPathComponent($0).path)
        }

        return AppRemovalPlan(
            application: application,
            items: items,
            hasDuplicateBundleIdentifier: duplicateIdentifier,
            bundleIdentifierIsSignatureBacked: signatureBackedIdentifier,
            validatedSignature: validatedSignature,
            hasPrivilegedComponents: hasPrivilegedComponents,
            applicationEligibilityIssue: applicationIssue
        )
    }

    private static func scan(_ url: URL, progress: ScanCounter) throws -> ScanSnapshot {
        var scanner = DiskScanner()
        return try scanner.scan(root: url, counter: progress)
    }

    private static func makeItem(
        snapshot: ScanSnapshot,
        rule: AppRemovalRule,
        key: String,
        explanation: String,
        required: Bool,
        defaultSelected: Bool,
        additionalIssue: String?,
        keepSelectableWithIssue: Bool = false,
        riskOverride: AppRemovalRisk? = nil
    ) -> AppRemovalItem {
        let node = snapshot.root
        let snapshotIssue: String?
        if node.resourceIdentifier == nil || node.fingerprint == nil {
            snapshotIssue = "Could not capture a complete snapshot of the item."
        } else if node.unreadableCount > 0 {
            snapshotIssue = "It contains inaccessible items: \(node.unreadableCount)."
        } else if snapshot.skippedMountPoints > 0 {
            snapshotIssue = "Another volume was found inside; a complete snapshot is impossible."
        } else {
            snapshotIssue = nil
        }
        let eligibilityIssue = snapshotIssue ?? (keepSelectableWithIssue ? nil : additionalIssue)
        return AppRemovalItem(
            id: node.url?.standardizedFileURL.path ?? UUID().uuidString,
            node: node,
            rule: rule,
            key: key,
            explanation: explanation + (keepSelectableWithIssue ? " " + (additionalIssue ?? "") : ""),
            isRequired: required,
            isDefaultSelected: defaultSelected && eligibilityIssue == nil,
            eligibilityIssue: eligibilityIssue,
            riskOverride: riskOverride
        )
    }
}

enum AppRemovalPolicy {
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
           let reason = applicationEligibilityReason(for: application) { return reason }
        if let issue = item.eligibilityIssue { return "\(item.url.path): \(issue)" }
        let original = item.url.standardizedFileURL
        let candidate = (candidateURL ?? original).standardizedFileURL
        switch item.match {
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

    static func overlappingSelectionReason(_ items: [AppRemovalItem]) -> String? {
        let paths = items.map { $0.url.standardizedFileURL.path }.sorted()
        for (index, path) in paths.enumerated() {
            for other in paths.dropFirst(index + 1) where other.hasPrefix(path + "/") {
                return "Selected paths overlap: \(path) and \(other)"
            }
        }
        return nil
    }
}

enum AppRemovalCoordinator {
    static func moveToTrash(
        items: [AppRemovalItem],
        plan: AppRemovalPlan,
        applicationAlreadyMoved: Bool
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
           let signatureFailure = AppRemovalPolicy.validateTrustedSignature(for: plan) {
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
                   let signatureFailure = AppRemovalPolicy.validateTrustedSignature(
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
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: coordinatedURL, resultingItemURL: &resultingURL)
                    guard let movedURL = resultingURL as URL?,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedRelocationIdentity,
                          (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == item.node.isDirectory else {
                        let resultPath = (resultingURL as URL?)?.path ?? "no Trash path was returned"
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
}

@MainActor
final class AppUninstallerModel: ObservableObject {
    @Published private(set) var applications: [InstalledApplication] = []
    @Published var searchText = ""
    @Published private(set) var selectedApplication: InstalledApplication?
    @Published private(set) var plan: AppRemovalPlan?
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var confirmedMovedItemIDs: Set<String> = []
    @Published private(set) var isLoadingApplications = false
    @Published private(set) var isInspecting = false
    @Published private(set) var isReviewing = false
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var applicationWasMoved = false
    @Published private(set) var lastOutcome: AppRemovalOutcome?
    @Published private(set) var lastApplicationName: String?
    @Published private(set) var progress = ScanProgress(itemCount: 0, currentPath: "")
    @Published var showingReview = false
    @Published var showingOutcomeReport = false
    @Published var notice: AppNotice?

    private var catalogTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var inspectionGeneration = UUID()
    private var reviewGeneration = UUID()

    var filteredApplications: [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return applications }
        return applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true)
                || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedItems: [AppRemovalItem] {
        plan?.items.filter {
            $0.isRequired
                ? !applicationWasMoved
                : selectedItemIDs.contains($0.id) && !confirmedMovedItemIDs.contains($0.id)
        } ?? []
    }

    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.node.size }
    }

    var needsExtraAcknowledgement: Bool {
        selectedItems.contains { $0.risk.needsExtraAcknowledgement }
    }

    var hasUncertainOutcome: Bool {
        !(lastOutcome?.uncertainPaths.isEmpty ?? true)
    }

    func loadApplicationsIfNeeded() {
        guard applications.isEmpty, !isLoadingApplications else { return }
        refreshApplications()
    }

    /// The sandboxed build sees ~/Library only after the person grants the home folder.
    var needsHomeAccess: Bool { !FolderAccess.shared.hasHomeAccess }

    func grantHomeAccess() {
        guard FolderAccess.shared.ensureHomeAccess(
            message: "DiskBloom checks each app's caches, preferences and other data in your Library. Select your home folder and click Grant Access."
        ) else {
            notice = AppNotice(
                title: "Home folder access needed",
                message: "Related data can be found only with access to your home folder. Choose your home folder itself in the panel."
            )
            return
        }
        refreshApplications()
    }

    func refreshApplications() {
        guard !isMovingToTrash else { return }
        catalogTask?.cancel()
        isLoadingApplications = true
        catalogTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                ApplicationCatalog.discover()
            }.value
            guard !Task.isCancelled else { return }
            applications = result
            isLoadingApplications = false
            if let selectedApplication,
               let refreshed = result.first(where: { $0.id == selectedApplication.id }) {
                self.selectedApplication = refreshed
            }
        }
    }

    func chooseApplication() {
        guard !isMovingToTrash else { return }
        guard !needsHomeAccess else {
            grantHomeAccess()
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose an application to uninstall"
        panel.prompt = "Review"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile = ApplicationCatalog.profile(for: url)
        if !applications.contains(where: { $0.id == profile.id }) {
            applications.append(profile)
            applications.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        inspect(profile, force: true)
    }

    func inspect(_ application: InstalledApplication, force: Bool = false) {
        guard !isMovingToTrash else { return }
        guard !needsHomeAccess else {
            // Without the Library the plan would silently miss related data.
            grantHomeAccess()
            return
        }
        if !force, selectedApplication?.id == application.id, plan != nil { return }
        inspectionTask?.cancel()
        invalidateReview()
        let generation = UUID()
        inspectionGeneration = generation
        selectedApplication = application
        plan = nil
        selectedItemIDs = []
        confirmedMovedItemIDs = []
        applicationWasMoved = false
        lastOutcome = nil
        lastApplicationName = nil
        showingOutcomeReport = false
        isInspecting = true
        progress = ScanProgress(itemCount: 0, currentPath: application.url.path)
        let knownApplications = applications
        let counter = ScanCounter()
        let worker = Task.detached(priority: .userInitiated) {
            try ApplicationRemovalAnalyzer.buildPlan(
                for: application,
                knownApplications: knownApplications,
                progress: counter
            )
        }
        inspectionTask = Task {
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, inspectionGeneration == generation else { break }
                    progress = counter.snapshot()
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard inspectionGeneration == generation, !Task.isCancelled else { return }
                plan = result
                selectedItemIDs = Set(result.items.filter { $0.isDefaultSelected && $0.isSelectable }.map(\.id))
                progress = counter.snapshot()
                isInspecting = false
            } catch is CancellationError {
                if inspectionGeneration == generation { isInspecting = false }
            } catch {
                if inspectionGeneration == generation {
                    isInspecting = false
                    notice = AppNotice(title: "Could not check the application", message: error.localizedDescription)
                }
            }
        }
    }

    func reanalyzeSelectedApplication() {
        guard let selectedApplication,
              !isMovingToTrash,
              !applicationWasMoved,
              confirmedMovedItemIDs.isEmpty,
              !hasUncertainOutcome else { return }
        inspect(selectedApplication, force: true)
    }

    func toggle(_ item: AppRemovalItem) {
        guard !isMovingToTrash,
              !item.isRequired,
              item.isSelectable,
              !confirmedMovedItemIDs.contains(item.id) else { return }
        invalidateReview()
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func reveal(_ item: AppRemovalItem) {
        guard !isMovingToTrash, !confirmedMovedItemIDs.contains(item.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func runningReason() -> String? {
        if applicationWasMoved { return nil }
        guard let application = plan?.application ?? selectedApplication else { return nil }
        return AppRunningDetector.reason(for: application)
    }

    func requestRemovalReview() {
        guard let plan, !isReviewing, !isMovingToTrash else { return }
        invalidateReview()
        if let uncertainPaths = lastOutcome?.uncertainPaths, !uncertainPaths.isEmpty {
            notice = AppNotice(
                title: "Retry blocked",
                message: "Could not confirm the result of the previous move:\n\(uncertainPaths.joined(separator: "\n"))\n\nRe-check the original paths first. If the item is already in the Trash, restore it or choose the application again after a manual check."
            )
            return
        }
        if !applicationWasMoved,
           let reason = plan.applicationEligibilityIssue ?? runningReason() {
            notice = AppNotice(title: "Uninstall blocked", message: reason)
            return
        }
        if !applicationWasMoved, FolderAccess.shared.isRestricted {
            let container = plan.application.url.deletingLastPathComponent().standardizedFileURL
            guard FolderAccess.shared.ensureAccess(
                to: container,
                title: "Allow DiskBloom to move \(plan.application.name)",
                message: "To move \(plan.application.name) to the Trash, DiskBloom needs permission to change the folder that contains it. Keep “\(container.lastPathComponent)” selected and click Grant Access."
            ) else {
                notice = AppNotice(
                    title: "Uninstall blocked",
                    message: "DiskBloom has no permission to change \(container.path). Grant access to this folder to move the application to the Trash."
                )
                return
            }
        }
        let candidates = selectedItems
        guard !candidates.isEmpty else {
            notice = AppNotice(title: "Nothing to move", message: "Select at least one remaining related item.")
            return
        }
        if !applicationWasMoved,
           !(candidates.first(where: \.isRequired)?.isSelectable == true) {
            notice = AppNotice(title: "Uninstall blocked", message: "The application bundle did not pass the full check.")
            return
        }
        if let overlap = AppRemovalPolicy.overlappingSelectionReason(candidates) {
            notice = AppNotice(title: "Paths overlap", message: overlap)
            return
        }
        let generation = UUID()
        let appAlreadyMoved = applicationWasMoved
        reviewGeneration = generation
        isReviewing = true
        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                var failures: [String] = []
                if !appAlreadyMoved,
                   let signatureFailure = AppRemovalPolicy.validateTrustedSignature(for: plan) {
                    failures.append(signatureFailure)
                }
                if appAlreadyMoved,
                   let continuationFailure = AppRemovalPolicy.continuationEligibilityReason(for: plan) {
                    failures.append(continuationFailure)
                }
                failures.append(contentsOf: candidates.compactMap {
                    AppRemovalPolicy.validate(
                        $0,
                        application: plan.application,
                        requireApplicationPresence: !appAlreadyMoved
                    )
                })
                return failures
            }.value
            guard reviewGeneration == generation, !Task.isCancelled else { return }
            isReviewing = false
            if !appAlreadyMoved, let running = runningReason() {
                notice = AppNotice(title: "Application is running", message: running)
            } else if failures.isEmpty {
                showingReview = true
            } else {
                notice = AppNotice(title: "Rescan needed", message: failures.joined(separator: "\n"))
            }
        }
    }

    func moveReviewedItemsToTrash() {
        guard let plan, !isMovingToTrash, !hasUncertainOutcome else { return }
        showingReview = false
        if !applicationWasMoved, let running = runningReason() {
            notice = AppNotice(title: "Application is running", message: running)
            return
        }
        let candidates = selectedItems
        guard !candidates.isEmpty else { return }
        let appAlreadyMoved = applicationWasMoved
        isMovingToTrash = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                AppRemovalCoordinator.moveToTrash(
                    items: candidates,
                    plan: plan,
                    applicationAlreadyMoved: appAlreadyMoved
                )
            }.value
            isMovingToTrash = false
            lastOutcome = outcome
            lastApplicationName = plan.application.name
            let movedSet = Set(outcome.movedPaths)
            let movedIDs = plan.items.filter { movedSet.contains($0.url.path) }.map(\.id)
            selectedItemIDs.subtract(movedIDs)
            confirmedMovedItemIDs.formUnion(movedIDs)
            if appAlreadyMoved || outcome.movedPaths.contains(plan.application.url.path) {
                applicationWasMoved = true
            }
            if outcome.failure == nil {
                let moved = outcome.movedPaths.joined(separator: "\n")
                notice = AppNotice(
                    title: "Selected items moved to Trash",
                    message: "Moved: \(outcome.movedPaths.count). Space is freed only after the Trash is emptied.\n\n\(moved)"
                )
                selectedApplication = nil
                self.plan = nil
                selectedItemIDs = []
                confirmedMovedItemIDs = []
                applicationWasMoved = false
            } else {
                notice = nil
                showingOutcomeReport = true
            }
            refreshApplications()
        }
    }

    func recheckUncertainPaths() {
        guard !isMovingToTrash,
              !isReviewing,
              let plan,
              let outcome = lastOutcome,
              !outcome.uncertainPaths.isEmpty else { return }
        let uncertainSet = Set(outcome.uncertainPaths)
        let uncertainItems = plan.items.filter { uncertainSet.contains($0.url.path) }
        guard uncertainItems.count == uncertainSet.count else {
            notice = AppNotice(
                title: "Result still unconfirmed",
                message: "The plan no longer contains all disputed paths. Choose the application again or check the Trash manually."
            )
            return
        }
        let appAlreadyMoved = applicationWasMoved
        let generation = UUID()
        reviewTask?.cancel()
        reviewGeneration = generation
        isReviewing = true
        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                uncertainItems.compactMap {
                    AppRemovalPolicy.validate(
                        $0,
                        application: plan.application,
                        requireApplicationPresence: !appAlreadyMoved
                    )
                }
            }.value
            guard reviewGeneration == generation, !Task.isCancelled else { return }
            isReviewing = false
            if failures.isEmpty {
                lastOutcome = nil
                lastApplicationName = nil
                showingOutcomeReport = false
                notice = AppNotice(
                    title: "Original item confirmed",
                    message: "The disputed item is still at its original path and matches the snapshot. Automatic retry is available again."
                )
            } else {
                lastOutcome = AppRemovalOutcome(
                    movedPaths: outcome.movedPaths,
                    uncertainPaths: outcome.uncertainPaths,
                    failure: failures.joined(separator: "\n")
                        + "\n\nAutomatic retry remains blocked. Check the Trash or restore the item manually.",
                    unattemptedPaths: outcome.unattemptedPaths
                )
                showingOutcomeReport = true
                notice = nil
            }
        }
    }

    func clearLastOutcome() {
        guard !isMovingToTrash, !hasUncertainOutcome else { return }
        lastOutcome = nil
        lastApplicationName = nil
        showingOutcomeReport = false
    }

    private func invalidateReview(keepSheetState: Bool = false) {
        reviewGeneration = UUID()
        reviewTask?.cancel()
        reviewTask = nil
        isReviewing = false
        if !keepSheetState { showingReview = false }
    }
}
