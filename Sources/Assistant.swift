import AppKit
import Combine
import Foundation
import Security

// MARK: - JSON

/// A small Sendable JSON value used for tool arguments and the chat-completions wire format.
enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): as_is_whole(value) ? String(Int(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): T27Text.withBytes(value.lowercased()) { as_yes_word($0, $1) }
        case .number(let value): value != 0
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    static func parseObject(_ text: String) -> [String: JSONValue] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else { return [:] }
        return object
    }

    func encodedString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Tools

/// One tool the assistant can call. The same description feeds the Apple on-device model
/// and every OpenAI-compatible API.
struct AssistantToolSpec: Sendable {
    enum ParameterType: Sendable {
        case string
        case integer
        case boolean
        case stringArray
        case choice([String])
    }

    struct Parameter: Sendable {
        let name: String
        let description: String
        let type: ParameterType
        let isOptional: Bool
    }

    let name: String
    let description: String
    let parameters: [Parameter]

    /// JSON Schema for the chat-completions `tools` field.
    var jsonSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters {
            var property: [String: JSONValue] = ["description": .string(parameter.description)]
            switch parameter.type {
            case .string: property["type"] = .string("string")
            case .integer: property["type"] = .string("integer")
            case .boolean: property["type"] = .string("boolean")
            case .stringArray:
                property["type"] = .string("array")
                property["items"] = .object(["type": .string("string")])
            case .choice(let values):
                property["type"] = .string("string")
                property["enum"] = .array(values.map { .string($0) })
            }
            properties[parameter.name] = .object(property)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(parameters.filter { !$0.isOptional }.map { .string($0.name) })
        ])
    }
}

enum AssistantTools {
    static let sectionNames = ["disk_map", "caches", "app_uninstaller", "leftovers", "duplicates"]
    static let cacheFilters = ["all", "safe", "optional", "in_use", "keep", "tool"]

    static let all: [AssistantToolSpec] = [
        AssistantToolSpec(
            name: "disk_overview",
            description: "Free and used disk space, the folder open in Disk Map with its biggest items, and cache totals if measured.",
            parameters: []
        ),
        AssistantToolSpec(
            name: "open_section",
            description: "Open a section of the app so the user sees it.",
            parameters: [
                .init(name: "section", description: "Section to open.", type: .choice(sectionNames), isOptional: false)
            ]
        ),
        AssistantToolSpec(
            name: "largest_items",
            description: "Open a folder in Disk Map and return its biggest items. Without a path uses the folder already open (home by default).",
            parameters: [
                .init(name: "path", description: "Folder path, absolute or starting with ~.", type: .string, isOptional: true),
                .init(name: "limit", description: "How many items, 1 to 15.", type: .integer, isOptional: true)
            ]
        ),
        AssistantToolSpec(
            name: "list_caches",
            description: "Measure caches if needed, open the Caches section and return caches with ref, size, verdict and reason.",
            parameters: [
                .init(name: "filter", description: "Which verdict to show.", type: .choice(cacheFilters), isOptional: true),
                .init(name: "limit", description: "How many caches, 1 to 20.", type: .integer, isOptional: true)
            ]
        ),
        AssistantToolSpec(
            name: "select_caches",
            description: "Select caches for cleanup in the Caches section by ref (from list_caches), or all safe ones. Does not delete; the user reviews and confirms.",
            parameters: [
                .init(name: "refs", description: "Cache refs such as c1, c4.", type: .stringArray, isOptional: true),
                .init(name: "all_safe", description: "Select every cache marked safe.", type: .boolean, isOptional: true)
            ]
        ),
        AssistantToolSpec(
            name: "queue_for_cleanup",
            description: "Add a file or folder shown in Disk Map to the cleanup queue. Does not delete; the user reviews and confirms.",
            parameters: [
                .init(name: "path", description: "Exact path from largest_items.", type: .string, isOptional: false)
            ]
        ),
        AssistantToolSpec(
            name: "find_app",
            description: "Open App Uninstaller filtered by an app name and show the app with its related data.",
            parameters: [
                .init(name: "name", description: "App name or part of it.", type: .string, isOptional: false)
            ]
        ),
        AssistantToolSpec(
            name: "reveal_in_finder",
            description: "Show a file or folder in Finder.",
            parameters: [
                .init(name: "path", description: "Absolute path or starting with ~.", type: .string, isOptional: false)
            ]
        )
    ]

    static let instructions = """
    You are the assistant inside DiskBloom, a Mac app that shows what uses disk space. \
    Use the tools to get real numbers and to open things in the app; never guess sizes, paths or verdicts. \
    Opening the matching section, folder or cache list right away is good: the user sees it at once. \
    You cannot delete or move anything. You can only select caches or queue items; the user then reviews \
    the exact paths and presses "Move to Trash" themselves. Say so whenever you select something. \
    Prefer caches marked safe, explain optional ones, and never select caches that are in use or marked keep. \
    Keep replies short: a few sentences or a short list with sizes. Reply in the language the user writes in.
    """
}

// MARK: - Chat messages

enum AssistantActionTarget: Sendable, Equatable {
    case section(WorkspaceSection)
    case folder(URL)
    case reveal(URL)
}

struct AssistantMessage: Identifiable, Sendable, Equatable {
    enum Role: Sendable, Equatable {
        case user
        case assistant
        case action
        case error
    }

    let id = UUID()
    let role: Role
    let text: String
    var target: AssistantActionTarget? = nil
}

// MARK: - Settings

enum AssistantProviderKind: String, CaseIterable, Identifiable, Sendable {
    case apple
    case api

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple, on this Mac"
        case .api: "API (OpenAI-compatible)"
        }
    }
}

struct AssistantEndpointPreset: Identifiable, Sendable {
    let id: String
    let title: String
    let baseURL: String
    let suggestedModels: [String]
    let note: String

    static let all: [AssistantEndpointPreset] = [
        AssistantEndpointPreset(
            id: "nvidia",
            title: "NVIDIA NIM",
            baseURL: "https://integrate.api.nvidia.com/v1",
            suggestedModels: ["moonshotai/kimi-k3", "z-ai/glm-5.3", "deepseek-ai/deepseek-v4.1-flash", "nvidia/nemotron-3-super-120b-a12b", "openai/gpt-oss-20b"],
            note: "Key from build.nvidia.com. The full model list loads by itself; ★ marks models that handle the assistant's tools."
        ),
        AssistantEndpointPreset(
            id: "zai",
            title: "Z.ai",
            baseURL: "https://api.z.ai/api/paas/v4",
            suggestedModels: ["glm-5.3", "glm-4.6"],
            note: "Key from z.ai. Save the key, and the list of your models loads by itself."
        ),
        AssistantEndpointPreset(
            id: "zai-coding",
            title: "Z.ai Coding Plan",
            baseURL: "https://api.z.ai/api/coding/paas/v4",
            suggestedModels: ["glm-4.6", "glm-4.5-air"],
            note: "Endpoint for Z.ai Coding Plan keys."
        ),
        AssistantEndpointPreset(
            id: "openrouter",
            title: "OpenRouter",
            baseURL: "https://openrouter.ai/api/v1",
            suggestedModels: [],
            note: "Many providers behind one key. Load the list and pick a model with tool support."
        ),
        AssistantEndpointPreset(
            id: "openai",
            title: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            suggestedModels: [],
            note: "Key from platform.openai.com."
        ),
        AssistantEndpointPreset(
            id: "ollama",
            title: "Ollama (local)",
            baseURL: "http://localhost:11434/v1",
            suggestedModels: ["qwen3:8b", "llama3.1:8b"],
            note: "Runs on this Mac; nothing leaves it. No key needed."
        ),
        AssistantEndpointPreset(
            id: "lmstudio",
            title: "LM Studio (local)",
            baseURL: "http://localhost:1234/v1",
            suggestedModels: [],
            note: "Runs on this Mac; nothing leaves it. No key needed."
        ),
        AssistantEndpointPreset(
            id: "custom",
            title: "Custom",
            baseURL: "",
            suggestedModels: [],
            note: "Any server with an OpenAI-compatible /chat/completions endpoint."
        )
    ]

    static func preset(id: String) -> AssistantEndpointPreset {
        all.first { $0.id == id } ?? all[all.count - 1]
    }
}

/// API keys live in the login Keychain, one per endpoint, never in preferences.
enum AssistantKeychain {
    private static let service = "DiskBloom Assistant API key"

    static func account(for baseURL: String) -> String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        return host + url.path
    }

    static func read(baseURL: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: baseURL),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ key: String, baseURL: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: baseURL)
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

@MainActor
final class AssistantSettings: ObservableObject {
    @Published var provider: AssistantProviderKind {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider) }
    }
    @Published var presetID: String {
        didSet { UserDefaults.standard.set(presetID, forKey: Keys.preset) }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Keys.baseURL) }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }
    /// Bumped whenever a key is saved, so the chat rebuilds its connection.
    @Published private(set) var keyRevision = 0

    private enum Keys {
        static let provider = "DiskBloom.assistant.provider"
        static let preset = "DiskBloom.assistant.preset"
        static let baseURL = "DiskBloom.assistant.baseURL"
        static let model = "DiskBloom.assistant.model"
    }

    init() {
        let defaults = UserDefaults.standard
        provider = AssistantProviderKind(rawValue: defaults.string(forKey: Keys.provider) ?? "") ?? .apple
        presetID = defaults.string(forKey: Keys.preset) ?? "zai"
        baseURL = defaults.string(forKey: Keys.baseURL) ?? AssistantEndpointPreset.preset(id: "zai").baseURL
        model = defaults.string(forKey: Keys.model) ?? ""
    }

    var preset: AssistantEndpointPreset { AssistantEndpointPreset.preset(id: presetID) }

    var normalizedBaseURL: String { Self.normalize(baseURL) }

    /// The address without trailing slashes or an endpoint path (Specs/assistant_rules.t27).
    nonisolated static func normalize(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = T27Text.withBytes(value) { as_base_url_length($0, $1) }
        return String(decoding: Array(value.utf8).prefix(Int(length)), as: UTF8.self)
    }

    nonisolated static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return T27Text.withBytes(host) { as_local_host($0, $1) }
    }

    var apiKey: String? { AssistantKeychain.read(baseURL: normalizedBaseURL) }

    var hasAPIKey: Bool { !(apiKey ?? "").isEmpty }

    var isLocalEndpoint: Bool {
        Self.isLocal(normalizedBaseURL)
    }

    func apply(_ preset: AssistantEndpointPreset) {
        presetID = preset.id
        if as_preset_sets_address(preset.baseURL.isEmpty) { baseURL = preset.baseURL }
        if let first = preset.suggestedModels.first,
           as_replace_model(true, model.isEmpty, preset.suggestedModels.contains(model)) {
            model = first
        }
    }

    func saveAPIKey(_ key: String) -> Bool {
        let saved = AssistantKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: normalizedBaseURL)
        keyRevision += 1
        return saved
    }

    /// Changes whenever the chat must reconnect (and start a fresh conversation).
    var connectionSignature: String {
        switch provider {
        case .apple: "apple"
        case .api: "api|\(normalizedBaseURL)|\(model)|\(keyRevision)"
        }
    }
}

// MARK: - Tool execution

/// Runs assistant tools against the live app models on the main actor.
@MainActor
final class AssistantToolbox {
    private weak var app: AppModel?
    private weak var caches: CacheExplorerModel?
    private weak var uninstaller: AppUninstallerModel?
    private weak var orphans: OrphanedAppDataModel?
    private var cacheRefs: [String: String] = [:]

    var report: (AssistantMessage) -> Void = { _ in }

    func attach(
        app: AppModel,
        caches: CacheExplorerModel,
        uninstaller: AppUninstallerModel,
        orphans: OrphanedAppDataModel
    ) {
        self.app = app
        self.caches = caches
        self.uninstaller = uninstaller
        self.orphans = orphans
    }

    private var isBusy: Bool {
        guard let app, let caches, let uninstaller, let orphans else { return true }
        return md_assistant_busy(
            app.isMovingToTrash,
            app.showingTrashReview,
            uninstaller.isMovingToTrash,
            uninstaller.isReviewing,
            uninstaller.showingReview,
            uninstaller.showingOutcomeReport,
            orphans.isNavigationLocked,
            caches.isNavigationLocked
        )
    }

    private static let busyMessage = "DiskBloom is in the middle of a review or a move to the Trash. Ask the user to finish it first."

    func run(_ name: String, arguments: [String: JSONValue]) async -> String {
        guard app != nil else { return "The app is not ready yet." }
        switch name {
        case "disk_overview": return diskOverview()
        case "open_section": return openSection(arguments["section"]?.stringValue ?? "")
        case "largest_items":
            return await largestItems(path: arguments["path"]?.stringValue, limit: arguments["limit"]?.intValue)
        case "list_caches":
            return await listCaches(filter: arguments["filter"]?.stringValue, limit: arguments["limit"]?.intValue)
        case "select_caches":
            let refs = arguments["refs"]?.arrayValue?.compactMap(\.stringValue)
                ?? arguments["refs"]?.stringValue?.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
                ?? []
            return selectCaches(refs: refs, allSafe: arguments["all_safe"]?.boolValue == true)
        case "queue_for_cleanup": return queueForCleanup(arguments["path"]?.stringValue ?? "")
        case "find_app": return await findApp(arguments["name"]?.stringValue ?? "")
        case "reveal_in_finder": return reveal(arguments["path"]?.stringValue ?? "")
        default: return "Unknown tool \(name)."
        }
    }

    // MARK: Tools

    private func diskOverview() -> String {
        guard let app, let caches else { return "Not ready." }
        let stats = app.volumeStats
        var lines = [
            "Disk: \(ByteFormat.string(stats.available)) free of \(ByteFormat.string(stats.total)) (\(Int(stats.usedFraction * 100))% used)."
        ]
        switch Int32(as_overview_map(app.isScanning, app.focusNode != nil)) {
        case AS_MAP_SCANNING:
            lines.append("Disk Map is scanning \(app.currentURL.path) (\(app.progress.itemCount) items so far).")
        case AS_MAP_SHOWS:
            let focus = app.focusNode!
            lines.append("Disk Map shows \(focus.url?.path ?? focus.name): \(ByteFormat.string(focus.size)). Biggest items:")
            lines += focus.children.prefix(6).map(Self.describe)
        default:
            lines.append("Disk Map has not scanned anything yet.")
        }
        if let analysis = caches.analysis {
            lines.append("Caches: \(ByteFormat.string(analysis.totalSize)) total; safe \(ByteFormat.string(analysis.size(of: .safe))), optional \(ByteFormat.string(analysis.size(of: .optional))).")
        } else {
            lines.append("Caches not measured yet (list_caches measures them).")
        }
        return lines.joined(separator: "\n")
    }

    private func openSection(_ name: String) -> String {
        guard let app else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        guard let section = Self.section(named: name) else {
            return "Unknown section \(name). Use one of: \(AssistantTools.sectionNames.joined(separator: ", "))."
        }
        app.selectWorkspaceSection(section)
        report(AssistantMessage(role: .action, text: "Opened \(Self.title(of: section))", target: .section(section)))
        return "Opened \(Self.title(of: section))."
    }

    private func largestItems(path: String?, limit: Int?) async -> String {
        guard let app else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        let count = Int(md_tool_limit(Int64(limit ?? 0), limit != nil, 8, 15))
        app.selectWorkspaceSection(.diskMap)

        let hasPath = path.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        let url = hasPath ? Self.resolve(path!) : nil
        // Focusing is itself the check whether the map holds the folder, so it runs only once the path exists.
        let focused = url.map { app.focus(onPath: $0.path) } ?? false
        var isDirectory: ObjCBool = false
        let isFolder = url.map { FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue } ?? false
        switch Int32(as_largest_plan(hasPath, url != nil, focused, isFolder, app.focusNode != nil, app.isScanning)) {
        case AS_LARGEST_NO_SUCH_PATH: return "No such file or folder: \(path ?? "")"
        case AS_LARGEST_NOT_A_FOLDER: return "\(url!.path) is a file, not a folder."
        case AS_LARGEST_SCAN_FOLDER: app.open(source: url!)
        case AS_LARGEST_START_CURRENT: app.open(source: app.currentURL)
        default: break
        }
        if let url {
            report(AssistantMessage(role: .action, text: "Showing \(Self.displayPath(url)) in Disk Map", target: .folder(url)))
        }

        if let pending = await waitForDiskMap() { return pending }
        guard let focus = app.focusNode else {
            return "Disk Map could not open that folder. The user may need to grant access to it."
        }
        var lines = ["\(focus.url?.path ?? focus.name): \(ByteFormat.string(focus.size)), \(focus.itemCount.formatted()) items. Biggest:"]
        lines += focus.children.prefix(count).map(Self.describe)
        return lines.joined(separator: "\n")
    }

    private func listCaches(filter: String?, limit: Int?) async -> String {
        guard let app, let caches else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        app.selectWorkspaceSection(.cacheExplorer)
        let verdict = Self.verdict(named: filter)
        caches.verdictFilter = verdict
        if as_should_start_measuring(caches.analysis != nil, caches.isScanning) {
            caches.startAnalysis()
        }
        report(AssistantMessage(role: .action, text: "Opened Caches" + (verdict.map { " · \($0.title.lowercased())" } ?? ""), target: .section(.cacheExplorer)))
        await caches.waitForAnalysis()
        switch Int32(as_after_wait(caches.isScanning, caches.analysis != nil)) {
        case AS_WAIT_STILL_RUNNING:
            return "Still measuring caches (\(caches.progress.itemCount) items so far). Ask the user to wait a moment, then try again."
        case AS_WAIT_NOTHING:
            return "Caches were not measured. The user may need to grant access to the home folder."
        default: break
        }
        guard let analysis = caches.analysis else { return "Not ready." }
        cacheRefs = [:]
        for (index, item) in analysis.items.enumerated() { cacheRefs["c\(index + 1)"] = item.id }
        let refByID = Dictionary(uniqueKeysWithValues: cacheRefs.map { ($0.value, $0.key) })
        let shown = analysis.items.filter { verdict == nil || $0.verdict == verdict }.prefix(Int(md_tool_limit(Int64(limit ?? 0), limit != nil, 10, 20)))
        var lines = [
            "Caches: \(ByteFormat.string(analysis.totalSize)) in \(analysis.items.count). Safe \(ByteFormat.string(analysis.size(of: .safe))) (\(analysis.count(of: .safe))), optional \(ByteFormat.string(analysis.size(of: .optional))) (\(analysis.count(of: .optional))), in use \(analysis.count(of: .quitFirst)), keep \(analysis.count(of: .keep)), tool-only \(analysis.count(of: .useTool))."
        ]
        lines += shown.map { item in
            let owner = item.ownerName.map { " (\($0))" } ?? ""
            let hint = item.cleanupHint.map { " Command: \($0)" } ?? ""
            return "\(refByID[item.id] ?? "?") | \(item.title)\(owner) | \(ByteFormat.compact(item.size)) | \(item.verdict.shortTitle) | \(item.reason)\(hint)"
        }
        return lines.joined(separator: "\n")
    }

    private func selectCaches(refs: [String], allSafe: Bool) -> String {
        guard let app, let caches else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        guard Int32(as_select_plan(caches.analysis != nil, 1, 0)) != AS_SELECT_NOT_MEASURED else {
            return "Caches are not measured yet. Call list_caches first."
        }
        app.selectWorkspaceSection(.cacheExplorer)
        var chosen: [CacheItem] = []
        if allSafe {
            caches.selectAll(verdict: .safe)
            chosen = caches.items.filter { $0.verdict == .safe }
        }
        let ids = refs.compactMap { cacheRefs[$0.lowercased().trimmingCharacters(in: .whitespaces)] }
        let refused = caches.items.filter { ids.contains($0.id) && !$0.isSelectable }
        chosen += caches.select(ids: ids)
        caches.verdictFilter = nil
        caches.highlightedIDs = Set(chosen.map(\.id))
        let plan = Int32(as_select_plan(true, Int64(chosen.count), Int64(refused.count)))
        switch plan {
        case AS_SELECT_UNKNOWN_REFS:
            return "Nothing was selected; the refs are unknown. Call list_caches again."
        case AS_SELECT_ONLY_REFUSED:
            return "Not selectable: " + refused.map { "\($0.title): \($0.verdict.title.lowercased())" }.joined(separator: "; ") + "."
        default: break
        }
        let total = chosen.reduce(Int64(0)) { $0 + $1.size }
        report(AssistantMessage(role: .action, text: "Selected \(chosen.count) \(Plural.objects(chosen.count)) · \(ByteFormat.compact(total))", target: .section(.cacheExplorer)))
        var result = "Selected \(chosen.count) caches, \(ByteFormat.string(total)). Nothing is deleted yet: the user presses \"Review & Move to Trash\" at the bottom of Caches to see exact paths and confirm."
        if plan == AS_SELECT_DONE_WITH_SKIPPED {
            result += " Skipped because they are in use or kept: " + refused.map(\.title).joined(separator: ", ") + "."
        }
        return result
    }

    private func queueForCleanup(_ path: String) -> String {
        guard let app else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        let url = Self.resolve(path)
        let node = url.flatMap { app.node(atPath: $0.path) }
        let reason = node.flatMap { app.rejectionReason(for: $0) }
        let already = node.map { app.isCollected($0) } ?? false
        switch Int32(as_queue_plan(url != nil, node != nil, already, reason != nil)) {
        case AS_QUEUE_NO_SUCH_PATH: return "No such file or folder: \(path)"
        case AS_QUEUE_NOT_IN_MAP: return "\(url!.path) is not in the current Disk Map. Call largest_items for its parent folder first."
        default: break
        }
        guard let url, let node else { return "Not ready." }
        app.selectWorkspaceSection(.diskMap)
        _ = app.focus(onPath: url.path)
        if already { return "\(node.name) is already in the cleanup queue." }
        if let reason { return "Cannot queue \(node.name): \(reason)" }
        app.toggleCollection(node)
        guard app.isCollected(node) else { return "\(node.name) could not be queued." }
        report(AssistantMessage(role: .action, text: "Queued \(node.name) · \(ByteFormat.compact(node.size))", target: .folder(url.deletingLastPathComponent())))
        return "Queued \(node.name) (\(ByteFormat.string(node.size))). Nothing is deleted yet: the user reviews the queue at the bottom of Disk Map and confirms the move to the Trash."
    }

    private func findApp(_ name: String) async -> String {
        guard let app, let uninstaller else { return "Not ready." }
        guard !isBusy else { return Self.busyMessage }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int32(as_find_plan(query.isEmpty, 0)) != AS_FIND_ASK_NAME else { return "Give an app name." }
        app.selectWorkspaceSection(.appUninstaller)
        uninstaller.loadApplicationsIfNeeded()
        let deadline = ContinuousClock.now + .seconds(30)
        while uninstaller.isLoadingApplications, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        uninstaller.searchText = query
        let matches = uninstaller.filteredApplications
        report(AssistantMessage(role: .action, text: "App Uninstaller · “\(query)”", target: .section(.appUninstaller)))
        let plan = Int32(as_find_plan(false, Int64(matches.count)))
        if plan == AS_FIND_NONE { return "No installed app matches “\(query)”." }
        if plan == AS_FIND_OPEN_ONE, let match = matches.first {
            uninstaller.inspect(match)
            return "Opened \(match.name) (\(match.url.path)) in App Uninstaller. It lists the app and its related data; the user chooses what to remove and confirms."
        }
        return "Matches: " + matches.prefix(8).map { "\($0.name) — \($0.url.path)" }.joined(separator: "; ") + ". The list is filtered in App Uninstaller."
    }

    private func reveal(_ path: String) -> String {
        guard let url = Self.resolve(path) else { return "No such file or folder: \(path)" }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        report(AssistantMessage(role: .action, text: "Revealed \(url.lastPathComponent) in Finder", target: .reveal(url)))
        return "Shown in Finder: \(url.path)"
    }

    /// Opens the target of an action chip again.
    func perform(_ target: AssistantActionTarget) {
        guard let app, !isBusy else { return }
        switch target {
        case .section(let section):
            app.selectWorkspaceSection(section)
        case .folder(let url):
            app.selectWorkspaceSection(.diskMap)
            if !app.focus(onPath: url.path) { app.open(source: url) }
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: Helpers

    private func waitForDiskMap() async -> String? {
        guard let app else { return "Not ready." }
        let deadline = ContinuousClock.now + .seconds(90)
        while app.isScanning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        if app.isScanning {
            return "Still scanning \(app.currentURL.path) (\(app.progress.itemCount) items so far). The map is open; ask the user to wait and ask again."
        }
        return nil
    }

    private static func describe(_ node: DiskNode) -> String {
        let kind = node.isVirtual ? "group" : (node.isDirectory ? "folder" : "file")
        return "- \(node.name) | \(ByteFormat.compact(node.size)) | \(kind) | \(node.url?.path ?? "(several small items)")"
    }

    static func resolve(_ raw: String) -> URL? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        switch Int32(T27Text.withBytes(path) { as_path_form($0, $1) }) {
        case AS_PATH_EMPTY: return nil
        case AS_PATH_HOME: path = UserHome.path
        case AS_PATH_UNDER_HOME: path = UserHome.path + String(path.dropFirst(1))
        case AS_PATH_RELATIVE: path = UserHome.path + "/" + path
        default: break
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func displayPath(_ url: URL) -> String {
        let path = url.path
        switch Int32(as_display_form(T27Text.same(path, UserHome.path), T27Text.inside(path, UserHome.path))) {
        case AS_SHOW_HOME: return "Home"
        case AS_SHOW_TILDE: return "~" + path.dropFirst(UserHome.path.count)
        default: return path
        }
    }

    /// Which section a tool argument names, read by Specs/assistant_rules.t27.
    static func section(named name: String) -> WorkspaceSection? {
        let code = T27Text.withBytes(name.lowercased()) { as_section($0, $1) }
        let sections: [WorkspaceSection] = [.diskMap, .appUninstaller, .orphanedAppData, .duplicateFinder, .cacheExplorer]
        return code == UInt32(AS_NONE) ? nil : sections[Int(code)]
    }

    static func verdict(named name: String?) -> CacheVerdict? {
        guard let name else { return nil }
        let code = T27Text.withBytes(name.lowercased()) { as_verdict($0, $1) }
        return code == UInt32(AS_NONE) ? nil : CacheVerdict(t27: code)
    }

    static func title(of section: WorkspaceSection) -> String {
        switch section {
        case .diskMap: "Disk Map"
        case .appUninstaller: "App Uninstaller"
        case .orphanedAppData: "Possible Leftovers"
        case .duplicateFinder: "Duplicate Files"
        case .cacheExplorer: "Caches"
        }
    }
}

// MARK: - Chat model

@MainActor
protocol AssistantBackend: AnyObject {
    func send(_ text: String) async throws -> String
}

struct AssistantFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AssistantModel: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var messages: [AssistantMessage] = []
    @Published var draft = ""
    @Published private(set) var isThinking = false
    @Published var showingSettings = false

    let settings = AssistantSettings()
    let toolbox = AssistantToolbox()

    private var backend: (any AssistantBackend)?
    private var backendSignature = ""
    private var sendTask: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?

    init() {
        toolbox.report = { [weak self] message in self?.messages.append(message) }
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func connect(
        app: AppModel,
        caches: CacheExplorerModel,
        uninstaller: AppUninstallerModel,
        orphans: OrphanedAppDataModel
    ) {
        toolbox.attach(app: app, caches: caches, uninstaller: uninstaller, orphans: orphans)
    }

    var providerStatus: (ready: Bool, text: String) {
        switch settings.provider {
        case .apple:
            return AppleAssistantSupport.status()
        case .api:
            switch Int32(md_api_status(
                URL(string: settings.normalizedBaseURL)?.host != nil,
                !settings.model.trimmingCharacters(in: .whitespaces).isEmpty,
                settings.isLocalEndpoint,
                settings.hasAPIKey
            )) {
            case MD_API_NO_ADDRESS: return (false, "Set the API address in Settings")
            case MD_API_NO_MODEL: return (false, "Choose a model in Settings")
            case MD_API_NO_KEY: return (false, "Add the API key in Settings")
            default: return (true, settings.model)
            }
        }
    }

    func send(_ preset: String? = nil) {
        let text = (preset ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard as_can_send(text.isEmpty, isThinking) else { return }
        draft = ""
        messages.append(AssistantMessage(role: .user, text: text))
        let status = providerStatus
        guard status.ready else {
            messages.append(AssistantMessage(role: .error, text: status.text + "."))
            return
        }
        isThinking = true
        sendTask = Task {
            do {
                let backend = try currentBackend()
                let reply = try await backend.send(text)
                guard !Task.isCancelled else { return }
                let cleaned = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                messages.append(AssistantMessage(role: .assistant, text: cleaned.isEmpty ? "Done." : cleaned))
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    messages.append(AssistantMessage(role: .error, text: error.localizedDescription))
                }
            }
            isThinking = false
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
        isThinking = false
        // The interrupted exchange may have left a dangling tool call, so start over.
        backend = nil
    }

    func newChat() {
        stop()
        messages = []
    }

    func perform(_ target: AssistantActionTarget) {
        toolbox.perform(target)
    }

    private func currentBackend() throws -> any AssistantBackend {
        let signature = settings.connectionSignature
        if let backend, signature == backendSignature { return backend }
        let executor: @Sendable (String, String) async -> String = { [weak self] name, arguments in
            await self?.runTool(name, arguments: arguments) ?? "The app closed."
        }
        let made: any AssistantBackend
        switch settings.provider {
        case .apple:
            made = try AppleAssistantSupport.makeBackend(executor: executor)
        case .api:
            made = OpenAICompatibleBackend(
                baseURL: settings.normalizedBaseURL,
                model: settings.model.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: settings.apiKey,
                executor: executor
            )
        }
        backend = made
        backendSignature = signature
        return made
    }

    private func runTool(_ name: String, arguments: String) async -> String {
        await toolbox.run(name, arguments: JSONValue.parseObject(arguments))
    }
}
