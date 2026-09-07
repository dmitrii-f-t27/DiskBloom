import AppKit
import Combine
import Darwin
import Foundation

enum OrphanDataRisk: String, Sendable {
    case disposable
    case privateState
    case persistentData

    var title: String {
        switch self {
        case .disposable: "Временное состояние"
        case .privateState: "Личное состояние"
        case .persistentData: "Возможные пользовательские данные"
        }
    }

    var warning: String {
        switch self {
        case .disposable:
            "Обычно создаётся приложением заново, но содержимое всё равно нужно проверить."
        case .privateState:
            "Может содержать сеансы, историю, cookies или другое личное состояние."
        case .persistentData:
            "Может содержать документы, проекты, настройки или данные учётной записи."
        }
    }

    var needsExtraAcknowledgement: Bool { self != .disposable }
}

enum OrphanDataConfidence: String, Sendable {
    case probable
    case possible

    var title: String {
        switch self {
        case .probable: "Вероятные остатки"
        case .possible: "Возможный остаток"
        }
    }

    var explanation: String {
        switch self {
        case .probable:
            "Один точный bundle ID найден в нескольких независимых папках Library, а текущий владелец не найден."
        case .possible:
            "Найден один точный путь bundle ID, но этого недостаточно, чтобы доказать прежнего владельца."
        }
    }
}

enum OrphanDataRule: String, CaseIterable, Sendable {
    case applicationSupport
    case cache
    case savedState
    case httpStorage
    case webKit
    case log
    case container
    case applicationScripts

    var title: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .cache: "Кэш"
        case .savedState: "Сохранённое состояние"
        case .httpStorage: "HTTP-хранилище"
        case .webKit: "WebKit-данные"
        case .log: "Журналы"
        case .container: "Песочница приложения"
        case .applicationScripts: "Application Scripts"
        }
    }

    var relativeRoot: String {
        switch self {
        case .applicationSupport: "Application Support"
        case .cache: "Caches"
        case .savedState: "Saved Application State"
        case .httpStorage: "HTTPStorages"
        case .webKit: "WebKit"
        case .log: "Logs"
        case .container: "Containers"
        case .applicationScripts: "Application Scripts"
        }
    }

    var risk: OrphanDataRisk {
        switch self {
        case .cache, .savedState, .log:
            .disposable
        case .httpStorage, .webKit:
            .privateState
        case .applicationSupport, .container, .applicationScripts:
            .persistentData
        }
    }

    func identifier(from entry: URL) -> String? {
        let name = entry.lastPathComponent
        switch self {
        case .savedState:
            guard name.hasSuffix(".savedState") else { return nil }
            return String(name.dropLast(".savedState".count))
        default:
            return name
        }
    }

    func expectedURL(homeURL: URL, identifier: String) -> URL {
        let root = homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(relativeRoot, isDirectory: true)
        switch self {
        case .savedState:
            return root.appendingPathComponent(identifier + ".savedState", isDirectory: true)
        default:
            return root.appendingPathComponent(identifier, isDirectory: true)
        }
    }
}

enum OrphanBundleIdentifier {
    static func canonical(_ value: String?) -> String? {
        guard let value,
              value.count >= 3,
              value.count <= 255,
              value.contains("."),
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains(".."),
              value.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
                      || (scalar.value >= 97 && scalar.value <= 122)
                      || scalar == "."
                      || scalar == "-"
              }) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.allSatisfy({ part in
                  guard let first = part.unicodeScalars.first else { return false }
                  return (first.value >= 48 && first.value <= 57)
                      || (first.value >= 65 && first.value <= 90)
                      || (first.value >= 97 && first.value <= 122)
              }) else { return nil }
        return value.lowercased()
    }

    static func vendorNamespace(_ canonicalIdentifier: String) -> String? {
        let components = canonicalIdentifier.split(separator: ".")
        guard components.count >= 2 else { return nil }
        return components.prefix(2).joined(separator: ".")
    }
}

struct OrphanDataItem: Identifiable, Sendable {
    let id: String
    let identifier: String
    let canonicalIdentifier: String
    let rule: OrphanDataRule
    let node: DiskNode
    let eligibilityIssue: String?

    var url: URL { node.url! }
    var isSelectable: Bool { eligibilityIssue == nil }
    var risk: OrphanDataRisk { rule.risk }
}

struct OrphanDataGroup: Identifiable, Sendable {
    let id: String
    let identifier: String
    let items: [OrphanDataItem]
    let confidence: OrphanDataConfidence

    var totalSize: Int64 { items.reduce(0) { $0 + $1.node.size } }
    var selectableCount: Int { items.filter(\.isSelectable).count }
}

struct OrphanDataAnalysis: Sendable {
    let groups: [OrphanDataGroup]
    let scannedAt: Date
    let examinedPathCount: Int
    let protectedGroupCount: Int
    let skippedUnsafePathCount: Int
}

struct OrphanCleanupOutcome: Sendable {
    let movedPaths: [String]
    let uncertainPaths: [String]
    let failure: String?
    let unattemptedPaths: [String]
}

struct OrphanOwnerIndex: Sendable {
    private let claims: [String: String]

    init(claims: [String: String] = [:]) {
        var normalized: [String: String] = [:]
        for (identifier, reason) in claims {
            if let canonical = OrphanBundleIdentifier.canonical(identifier) {
                normalized[canonical] = reason
            }
        }
        self.claims = normalized
    }

    func claimReason(for identifier: String) -> String? {
        guard let canonical = OrphanBundleIdentifier.canonical(identifier) else {
            return "Bundle ID не прошёл безопасную проверку."
        }
        if let reason = claims[canonical] { return reason }
        if let related = claims.keys.sorted().first(where: {
            $0.hasPrefix(canonical + ".") || canonical.hasPrefix($0 + ".")
        }) {
            return "Найден установленный или активный родственный bundle ID \(related)."
        }
        if let namespace = OrphanBundleIdentifier.vendorNamespace(canonical),
           let sibling = claims.keys.sorted().first(where: {
               OrphanBundleIdentifier.vendorNamespace($0) == namespace
           }) {
            return "Найден установленный или активный bundle ID \(sibling) из того же namespace \(namespace)."
        }
        return nil
    }

    static func capture(
        candidateIdentifiers: Set<String>,
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> OrphanOwnerIndex {
        var claims: [String: String] = [:]
        let applications = ApplicationCatalog.discover(homeURL: homeURL)
        for application in applications {
            if let identifier = OrphanBundleIdentifier.canonical(application.bundleIdentifier) {
                claims[identifier] = "Найдено установленное приложение: \(application.url.path)"
            }
            collectNestedBundleClaims(in: application.url, claims: &claims)
        }

        if let selfIdentifier = OrphanBundleIdentifier.canonical(Bundle.main.bundleIdentifier) {
            claims[selfIdentifier] = "Этот bundle ID принадлежит работающему DiskBloom."
        }

        for application in NSWorkspace.shared.runningApplications {
            if let identifier = OrphanBundleIdentifier.canonical(application.bundleIdentifier) {
                let label = application.localizedName ?? application.bundleURL?.lastPathComponent ?? identifier
                claims[identifier] = "Найдено запущенное приложение или helper: \(label)"
            }
        }

        collectLaunchServiceClaims(
            candidateIdentifiers: candidateIdentifiers,
            claims: &claims
        )
        collectLaunchAgentClaims(homeURL: homeURL, claims: &claims)
        collectProcessClaims(candidateIdentifiers: candidateIdentifiers, claims: &claims)
        return OrphanOwnerIndex(claims: claims)
    }

    private static func collectNestedBundleClaims(in applicationURL: URL, claims: inout [String: String]) {
        let relativeRoots = [
            "Contents/PlugIns",
            "Contents/XPCServices",
            "Contents/Helpers",
            "Contents/Frameworks",
            "Contents/Library/LoginItems",
            "Contents/Library/LaunchServices",
            "Contents/Library/SystemExtensions"
        ]
        let bundleExtensions: Set<String> = ["app", "appex", "xpc", "framework", "bundle", "systemextension"]
        for relativeRoot in relativeRoots {
            let root = applicationURL.appendingPathComponent(relativeRoot, isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard bundleExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      let identifier = OrphanBundleIdentifier.canonical(Bundle(url: url)?.bundleIdentifier) else {
                    continue
                }
                claims[identifier] = "Найден встроенный компонент установленного приложения: \(url.path)"
            }
        }
    }

    private static func collectLaunchServiceClaims(
        candidateIdentifiers: Set<String>,
        claims: inout [String: String]
    ) {
        for identifier in candidateIdentifiers {
            let urls = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
            if let existing = urls.first(where: { url in
                let path = url.standardizedFileURL.path
                let components = (path as NSString).pathComponents
                return !components.contains(".Trash")
                    && !components.contains(".Trashes")
                    && FileManager.default.fileExists(atPath: path)
            }), let canonical = OrphanBundleIdentifier.canonical(identifier) {
                claims[canonical] = "LaunchServices зарегистрировал существующее приложение: \(existing.path)"
            }
        }
    }

    private static func collectLaunchAgentClaims(homeURL: URL, claims: inout [String: String]) {
        let roots = [
            homeURL.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/LaunchAgents", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/LaunchDaemons", isDirectory: true)
        ]
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.pathExtension.lowercased() == "plist" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let data = try? Data(contentsOf: url),
                      let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    continue
                }
                let candidates = [
                    dictionary["Label"] as? String,
                    url.deletingPathExtension().lastPathComponent
                ]
                for candidate in candidates {
                    if let identifier = OrphanBundleIdentifier.canonical(candidate) {
                        claims[identifier] = "Найдена конфигурация launchd: \(url.path)"
                    }
                }
            }
        }
    }

    private static func collectProcessClaims(
        candidateIdentifiers: Set<String>,
        claims: inout [String: String]
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let commands = String(data: data, encoding: .utf8)?.lowercased() else { return }
            for identifier in candidateIdentifiers {
                guard let canonical = OrphanBundleIdentifier.canonical(identifier),
                      commands.contains(canonical) else { continue }
                claims[canonical] = "В командной строке работающего процесса найден этот bundle ID."
            }
        } catch {
            return
        }
    }
}

private struct OrphanCandidateSpec: Sendable {
    let identifier: String
    let canonicalIdentifier: String
    let rule: OrphanDataRule
    let url: URL
}

enum OrphanedAppDataAnalyzer {
    static func analyze(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        progress: ScanCounter,
        ownerIndexOverride: OrphanOwnerIndex? = nil
    ) throws -> OrphanDataAnalysis {
        let normalizedHome = homeURL.standardizedFileURL
        var examined = 0
        var skippedUnsafe = 0
        var specs: [OrphanCandidateSpec] = []

        for rule in OrphanDataRule.allCases {
            try checkCancellation()
            let root = normalizedHome
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent(rule.relativeRoot, isDirectory: true)
            guard !AppRemovalPathSafety.pathHasSymlinkedComponent(root),
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: root,
                      includingPropertiesForKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey,
                          .volumeIsLocalKey,
                          .volumeIsReadOnlyKey,
                          .isUbiquitousItemKey
                      ],
                      options: [.skipsHiddenFiles]
                  ) else { continue }
            for entry in entries {
                try checkCancellation()
                progress.record(entry)
                examined += 1
                guard let rawIdentifier = rule.identifier(from: entry),
                      let canonical = OrphanBundleIdentifier.canonical(rawIdentifier),
                      !canonical.hasPrefix("com.apple."),
                      !canonical.hasPrefix("group."),
                      rule.expectedURL(homeURL: normalizedHome, identifier: rawIdentifier)
                        .standardizedFileURL.path == entry.standardizedFileURL.path,
                      let values = try? entry.resourceValues(forKeys: [
                          .isDirectoryKey,
                          .isSymbolicLinkKey,
                          .volumeIsLocalKey,
                          .volumeIsReadOnlyKey,
                          .isUbiquitousItemKey
                      ]),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      values.volumeIsLocal == true,
                      values.volumeIsReadOnly != true,
                      values.isUbiquitousItem != true,
                      !AppRemovalPathSafety.pathHasSymlinkedComponent(entry) else {
                    skippedUnsafe += 1
                    continue
                }
                specs.append(
                    OrphanCandidateSpec(
                        identifier: rawIdentifier,
                        canonicalIdentifier: canonical,
                        rule: rule,
                        url: entry.standardizedFileURL
                    )
                )
            }
        }

        let candidateIdentifiers = Set(specs.map(\.canonicalIdentifier))
        let ownerIndex = ownerIndexOverride ?? OrphanOwnerIndex.capture(
            candidateIdentifiers: candidateIdentifiers,
            homeURL: normalizedHome
        )
        var protectedIdentifiers: Set<String> = []
        var items: [OrphanDataItem] = []

        for spec in specs.sorted(by: { $0.url.path < $1.url.path }) {
            try checkCancellation()
            if ownerIndex.claimReason(for: spec.canonicalIdentifier) != nil {
                protectedIdentifiers.insert(spec.canonicalIdentifier)
                continue
            }
            var scanner = DiskScanner(maxDepth: 8, maxChildrenPerFolder: 96)
            let snapshot = try scanner.scan(root: spec.url, counter: progress)
            let issue = OrphanDataPolicy.treeEligibilityIssue(
                for: snapshot.root,
                homeURL: normalizedHome
            )
            items.append(
                OrphanDataItem(
                    id: spec.url.path,
                    identifier: spec.identifier,
                    canonicalIdentifier: spec.canonicalIdentifier,
                    rule: spec.rule,
                    node: snapshot.root,
                    eligibilityIssue: issue
                )
            )
        }

        let grouped = Dictionary(grouping: items, by: \.canonicalIdentifier)
        let groups = grouped.map { identifier, values in
            let sorted = values.sorted { $0.url.path < $1.url.path }
            return OrphanDataGroup(
                id: identifier,
                identifier: sorted.first?.identifier ?? identifier,
                items: sorted,
                confidence: Set(sorted.map(\.rule)).count >= 2 ? .probable : .possible
            )
        }.sorted {
            if $0.confidence != $1.confidence { return $0.confidence == .probable }
            if $0.totalSize != $1.totalSize { return $0.totalSize > $1.totalSize }
            return $0.identifier.localizedCaseInsensitiveCompare($1.identifier) == .orderedAscending
        }

        return OrphanDataAnalysis(
            groups: groups,
            scannedAt: Date(),
            examinedPathCount: examined,
            protectedGroupCount: protectedIdentifiers.count,
            skippedUnsafePathCount: skippedUnsafe
        )
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw CancellationError() }
    }
}

enum OrphanDataPolicy {
    static func validate(
        _ item: OrphanDataItem,
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        candidateURL: URL? = nil
    ) -> String? {
        if let issue = item.eligibilityIssue { return "\(item.url.path): \(issue)" }
        guard OrphanBundleIdentifier.canonical(item.identifier) == item.canonicalIdentifier else {
            return "Bundle ID больше не проходит безопасную проверку: \(item.identifier)"
        }
        let original = item.url.standardizedFileURL
        let candidate = (candidateURL ?? original).standardizedFileURL
        guard candidate.path == original.path else {
            return "Координированный путь изменился: \(original.path)"
        }
        let expected = item.rule.expectedURL(homeURL: homeURL, identifier: item.identifier)
            .standardizedFileURL
        guard expected.path == original.path else {
            return "Путь не соответствует точному разрешённому правилу: \(original.path)"
        }
        if AppRemovalPathSafety.pathHasSymlinkedComponent(candidate) {
            return "Путь содержит символическую ссылку: \(candidate.path)"
        }
        guard let values = try? candidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .isUbiquitousItemKey
        ]), values.isDirectory == true, values.isSymbolicLink != true else {
            return "Объект больше не является обычной папкой: \(candidate.path)"
        }
        if values.volumeIsLocal != true { return "Сетевой или неопределённый том защищён: \(candidate.path)" }
        if values.volumeIsReadOnly == true { return "Том доступен только для чтения: \(candidate.path)" }
        if values.isUbiquitousItem == true { return "Облачный объект защищён: \(candidate.path)" }
        if let issue = treeEligibilityIssue(for: item.node, homeURL: homeURL) { return "\(candidate.path): \(issue)" }
        return SnapshotValidator.validate(item.node, candidateURL: candidate)
    }

    static func treeEligibilityIssue(for node: DiskNode, homeURL: URL) -> String? {
        guard let url = node.url else { return "Не удалось получить точный путь." }
        guard node.resourceIdentifier != nil, node.fingerprint != nil else {
            return "Снимок папки неполон; удаление отключено."
        }
        guard node.unreadableCount == 0 else {
            return "Внутри есть недоступные объекты; удаление отключено."
        }
        let library = homeURL.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(library + "/") else {
            return "Путь находится вне пользовательской Library."
        }
        return inspectTree(at: url)
    }

    static func overlappingSelectionReason(_ items: [OrphanDataItem]) -> String? {
        let paths = items.map { $0.url.standardizedFileURL.path }.sorted()
        for (index, path) in paths.enumerated() {
            for other in paths.dropFirst(index + 1) where other.hasPrefix(path + "/") {
                return "Выбранные пути пересекаются: \(path) и \(other)"
            }
        }
        return nil
    }

    private static func inspectTree(at root: URL) -> String? {
        let rootDevice = FileIdentity.deviceID(for: root)
        var urls: [URL] = [root]
        var enumerationIssue: String?
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                enumerationIssue = "Не удалось прочитать \(url.path): \(error.localizedDescription)"
                return false
            }
        ) {
            for case let url as URL in enumerator { urls.append(url) }
        } else {
            return "Не удалось перечислить содержимое папки."
        }
        if let enumerationIssue { return enumerationIssue }

        let executableBundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]
        for url in urls {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return lstat(path, &info)
            }
            guard result == 0 else { return "Не удалось проверить права: \(url.path)" }
            if info.st_uid != geteuid() {
                return "Внутри есть объект другого владельца: \(url.path)"
            }
            let immutableFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
            if info.st_flags & immutableFlags != 0 {
                return "Внутри есть защищённый флагами объект: \(url.path)"
            }
            if FileIdentity.deviceID(for: url) != rootDevice {
                return "Внутри обнаружена граница другого тома: \(url.path)"
            }
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFLNK {
                return "Внутри обнаружена символическая ссылка: \(url.path)"
            }
            if executableBundleExtensions.contains(url.pathExtension.lowercased()) {
                return "Внутри найден исполняемый bundle: \(url.path)"
            }
            let executableBits = mode_t(S_IXUSR | S_IXGRP | S_IXOTH)
            if fileType == S_IFREG, info.st_mode & executableBits != 0 {
                return "Внутри найден исполняемый файл: \(url.path)"
            }
        }
        return nil
    }
}

enum OrphanCleanupCoordinator {
    typealias TrashMover = @Sendable (URL) throws -> URL?
    typealias OwnerResolver = @Sendable (Set<String>) -> OrphanOwnerIndex

    static let systemTrashMover: TrashMover = { url in
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        return resultingURL as URL?
    }

    static func moveToTrash(
        items: [OrphanDataItem],
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        ownerResolver: OwnerResolver,
        mover: TrashMover = systemTrashMover
    ) -> OrphanCleanupOutcome {
        let ordered = items.sorted { $0.url.path < $1.url.path }
        guard !ordered.isEmpty else {
            return OrphanCleanupOutcome(movedPaths: [], uncertainPaths: [], failure: "Ничего не выбрано.", unattemptedPaths: [])
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
                    failure: "Очистка заблокирована: \(reason)",
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
                    localFailure = "Очистка заблокирована: \(reason)"
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
                    localFailure = "Очистка заблокирована непосредственно перед перемещением: \(reason)"
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
                    localFailure = "Не удалось зафиксировать идентичность непосредственно перед перемещением: \(url.path)"
                    return
                }
                do {
                    let movedURL = try mover(coordinatedURL)
                    guard let movedURL,
                          FileIdentity.relocationIdentifier(for: movedURL) == expectedIdentity,
                          (try? movedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                        let result = movedURL?.path ?? "путь в Корзине не возвращён"
                        localFailure = "Не удалось подтвердить объект после перемещения: \(url.path). Результат: \(result)."
                        uncertain = !FileManager.default.fileExists(atPath: coordinatedURL.path)
                        return
                    }
                    didMove = true
                } catch {
                    let sourceExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    uncertain = !sourceExists
                    let suffix = sourceExists
                        ? ""
                        : " Исходный путь исчез; автоматический повтор заблокирован."
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

@MainActor
final class OrphanedAppDataModel: ObservableObject {
    @Published private(set) var analysis: OrphanDataAnalysis?
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var confirmedMovedItemIDs: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var isReviewing = false
    @Published private(set) var isMovingToTrash = false
    @Published private(set) var progress = ScanProgress(itemCount: 0, currentPath: "")
    @Published private(set) var lastOutcome: OrphanCleanupOutcome?
    @Published private(set) var manuallyAcknowledgedUncertainPaths: Set<String> = []
    @Published var showingReview = false
    @Published var showingOutcomeReport = false
    @Published var notice: AppNotice?

    private var analysisTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var analysisGeneration = UUID()
    private var reviewGeneration = UUID()
    private let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    var groups: [OrphanDataGroup] { analysis?.groups ?? [] }

    var selectedItems: [OrphanDataItem] {
        groups.flatMap(\.items).filter {
            selectedItemIDs.contains($0.id) && !confirmedMovedItemIDs.contains($0.id)
        }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.node.size } }
    var needsExtraAcknowledgement: Bool { selectedItems.contains { $0.risk.needsExtraAcknowledgement } }
    var hasUncertainOutcome: Bool {
        guard let uncertainPaths = lastOutcome?.uncertainPaths else { return false }
        return !Set(uncertainPaths).isSubset(of: manuallyAcknowledgedUncertainPaths)
    }
    var isNavigationLocked: Bool {
        isReviewing || isMovingToTrash || showingReview || showingOutcomeReport
    }

    func startAnalysis() {
        guard !isReviewing, !isMovingToTrash, !hasUncertainOutcome else {
            notice = AppNotice(
                title: "Повторный анализ заблокирован",
                message: "Сначала проверьте спорный результат предыдущего перемещения."
            )
            return
        }
        analysisTask?.cancel()
        reviewTask?.cancel()
        showingReview = false
        showingOutcomeReport = false
        lastOutcome = nil
        manuallyAcknowledgedUncertainPaths = []
        confirmedMovedItemIDs = []
        selectedItemIDs = []
        let generation = UUID()
        analysisGeneration = generation
        isScanning = true
        progress = ScanProgress(itemCount: 0, currentPath: homeURL.appendingPathComponent("Library").path)
        let counter = ScanCounter()
        let localHome = homeURL
        let worker = Task.detached(priority: .userInitiated) {
            try OrphanedAppDataAnalyzer.analyze(homeURL: localHome, progress: counter)
        }
        analysisTask = Task { [weak self] in
            guard let self else {
                worker.cancel()
                return
            }
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(180))
                    guard !Task.isCancelled, let self, self.analysisGeneration == generation else { break }
                    self.progress = counter.snapshot()
                }
            }
            defer { poller.cancel() }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard analysisGeneration == generation, !Task.isCancelled else { return }
                analysis = result
                progress = counter.snapshot()
                isScanning = false
            } catch is CancellationError {
                guard analysisGeneration == generation else { return }
                isScanning = false
            } catch {
                guard analysisGeneration == generation else { return }
                isScanning = false
                notice = AppNotice(title: "Анализ не завершён", message: error.localizedDescription)
            }
        }
    }

    func cancelAnalysis() {
        analysisGeneration = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        isScanning = false
    }

    func toggle(_ item: OrphanDataItem) {
        guard item.isSelectable,
              !confirmedMovedItemIDs.contains(item.id),
              !isReviewing,
              !isMovingToTrash,
              !hasUncertainOutcome else { return }
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func reveal(_ item: OrphanDataItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func requestReview() {
        let items = selectedItems
        guard !items.isEmpty, !isScanning, !isMovingToTrash, !hasUncertainOutcome else { return }
        let generation = UUID()
        reviewGeneration = generation
        reviewTask?.cancel()
        isReviewing = true
        let localHome = homeURL
        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                let identifiers = Set(items.map(\.canonicalIdentifier))
                let owners = OrphanOwnerIndex.capture(candidateIdentifiers: identifiers, homeURL: localHome)
                var failures: [String] = []
                for item in items {
                    if let reason = owners.claimReason(for: item.canonicalIdentifier) {
                        failures.append("\(item.identifier): \(reason)")
                    } else if let reason = OrphanDataPolicy.validate(item, homeURL: localHome) {
                        failures.append(reason)
                    }
                }
                return failures
            }.value
            guard reviewGeneration == generation, !Task.isCancelled else { return }
            isReviewing = false
            if failures.isEmpty {
                showingReview = true
            } else {
                notice = AppNotice(
                    title: "Нужен новый анализ",
                    message: failures.joined(separator: "\n\n")
                )
            }
        }
    }

    func moveReviewedItemsToTrash() {
        let items = selectedItems
        guard showingReview, !items.isEmpty, !isMovingToTrash, !hasUncertainOutcome else { return }
        showingReview = false
        isMovingToTrash = true
        let localHome = homeURL
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                OrphanCleanupCoordinator.moveToTrash(
                    items: items,
                    homeURL: localHome,
                    ownerResolver: { identifiers in
                        OrphanOwnerIndex.capture(candidateIdentifiers: identifiers, homeURL: localHome)
                    }
                )
            }.value
            isMovingToTrash = false
            lastOutcome = outcome
            manuallyAcknowledgedUncertainPaths = []
            let movedIDs = Set(items.filter { outcome.movedPaths.contains($0.url.path) }.map(\.id))
            confirmedMovedItemIDs.formUnion(movedIDs)
            selectedItemIDs.subtract(movedIDs)
            showingOutcomeReport = true
        }
    }

    func recheckUncertainOutcome() {
        guard let outcome = lastOutcome,
              !outcome.uncertainPaths.isEmpty,
              !isReviewing,
              !isMovingToTrash else { return }
        let uncertain = groups.flatMap(\.items).filter { outcome.uncertainPaths.contains($0.url.path) }
        guard uncertain.count == outcome.uncertainPaths.count else {
            notice = AppNotice(
                title: "Автоматическая проверка невозможна",
                message: "Для одного из спорных путей нет исходного снимка. Проверьте Корзину вручную."
            )
            return
        }
        let generation = UUID()
        reviewGeneration = generation
        isReviewing = true
        let localHome = homeURL
        reviewTask = Task {
            let failures = await Task.detached(priority: .userInitiated) {
                uncertain.compactMap { OrphanDataPolicy.validate($0, homeURL: localHome) }
            }.value
            guard reviewGeneration == generation, !Task.isCancelled else { return }
            isReviewing = false
            if failures.isEmpty {
                lastOutcome = nil
                showingOutcomeReport = false
                notice = AppNotice(
                    title: "Исходная папка подтверждена",
                    message: "Спорная папка всё ещё находится на исходном месте и совпадает со снимком. Можно выполнить новый анализ."
                )
            } else {
                lastOutcome = OrphanCleanupOutcome(
                    movedPaths: outcome.movedPaths,
                    uncertainPaths: outcome.uncertainPaths,
                    failure: failures.joined(separator: "\n")
                        + "\n\nАвтоматический повтор остаётся заблокирован. Проверьте Корзину вручную.",
                    unattemptedPaths: outcome.unattemptedPaths
                )
                showingOutcomeReport = true
            }
        }
    }

    func acknowledgeUncertainOutcomeAfterManualCheck() {
        guard let outcome = lastOutcome,
              !outcome.uncertainPaths.isEmpty,
              !isReviewing,
              !isMovingToTrash else { return }
        manuallyAcknowledgedUncertainPaths.formUnion(outcome.uncertainPaths)
        showingOutcomeReport = false
        notice = AppNotice(
            title: "Автоматический повтор отключён",
            message: "Спорный результат отмечен как проверяемый вручную. DiskBloom не подтвердил перемещение, не пометил путь как успешно перемещённый и не будет повторять действие автоматически."
        )
    }

    func clearLastOutcome() {
        guard !isMovingToTrash, !hasUncertainOutcome else { return }
        lastOutcome = nil
        manuallyAcknowledgedUncertainPaths = []
        showingOutcomeReport = false
    }
}
