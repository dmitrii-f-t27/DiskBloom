import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

typealias AssistantToolExecutor = @Sendable (_ name: String, _ argumentsJSON: String) async -> String

// MARK: - OpenAI-compatible API

/// One entry of a provider's model list.
struct AssistantModelInfo: Identifiable, Sendable, Hashable {
    let id: String
    /// `true`/`false` when the provider says whether the model takes tools; `nil` when it does not say.
    let declaresTools: Bool?

    /// Embedding, reranking, safety, vision-parsing and speech models cannot hold a chat (Specs/assistant_rules.t27).
    var isChatModel: Bool {
        T27Text.withBytes(id.lowercased()) { as_chat_model($0, $1) }
    }

    /// Models that handle the assistant's tool calling well enough.
    var isRecommended: Bool {
        T27Text.withBytes(id.lowercased()) { as_recommended_model($0, $1, declaresTools != nil, declaresTools == true) }
    }
}

/// Talks to any server that implements `/chat/completions` with function calling
/// (NVIDIA NIM, Z.ai, OpenRouter, OpenAI, Ollama, LM Studio, …).
@MainActor
final class OpenAICompatibleBackend: AssistantBackend {
    private let baseURL: String
    private let model: String
    private let apiKey: String?
    private let executor: AssistantToolExecutor
    private var history: [JSONValue]

    private static let maxToolRounds = 8
    private static let maxHistory = 60

    init(baseURL: String, model: String, apiKey: String?, executor: @escaping AssistantToolExecutor) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.executor = executor
        history = [.object(["role": .string("system"), "content": .string(AssistantTools.instructions)])]
    }

    func send(_ text: String) async throws -> String {
        history.append(.object(["role": .string("user"), "content": .string(text)]))
        trimHistory()
        for _ in 0..<Self.maxToolRounds {
            try Task.checkCancellation()
            let message = try await complete()
            history.append(Self.storable(message))
            let calls = message["tool_calls"]?.arrayValue ?? []
            guard !calls.isEmpty else {
                return Self.visibleText(message["content"]?.stringValue ?? "")
            }
            for call in calls {
                try Task.checkCancellation()
                let id = call["id"]?.stringValue ?? UUID().uuidString
                let name = call["function"]?["name"]?.stringValue ?? ""
                let arguments = call["function"]?["arguments"]?.stringValue ?? "{}"
                let result = await executor(name, arguments)
                history.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(id),
                    "content": .string(result)
                ]))
            }
        }
        return "I stopped after several steps without a final answer. Try asking more specifically."
    }

    private func complete() async throws -> JSONValue {
        let tools: [JSONValue] = AssistantTools.all.map { spec in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "parameters": spec.jsonSchema
                ])
            ])
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array(history),
            "tools": .array(tools),
            "tool_choice": .string("auto"),
            "temperature": .number(0.2)
        ])
        let response = try await Self.request(
            baseURL: baseURL,
            path: "/chat/completions",
            apiKey: apiKey,
            body: body,
            timeout: 120
        )
        guard let message = response["choices"]?.arrayValue?.first?["message"] else {
            throw AssistantFailure(message: "The API answered without a message. Check that the model name is right.")
        }
        return message
    }

    /// Keeps only the fields the next request needs; some servers reject unknown ones.
    private static func storable(_ message: JSONValue) -> JSONValue {
        var stored: [String: JSONValue] = ["role": .string("assistant")]
        stored["content"] = message["content"].flatMap { $0 == .null ? nil : $0 } ?? .string("")
        if let calls = message["tool_calls"], calls.arrayValue?.isEmpty == false {
            stored["tool_calls"] = calls
        }
        return .object(stored)
    }

    /// Drops old turns, cutting only at a user message so tool calls keep their results.
    private func trimHistory() {
        guard let cut = Self.historyCut(roles: history.map { $0["role"]?.stringValue ?? "" }, keep: Self.maxHistory) else { return }
        history = [history[0]] + history[cut...]
    }

    /// The first turn to keep when the conversation is too long (Specs/assistant_rules.t27), or nil.
    nonisolated static func historyCut(roles: [String], keep: Int) -> Int? {
        var flags = roles.map { $0 == "user" ? UInt8(1) : UInt8(0) }
        let count = flags.count
        if flags.count < T27Text.capacity { flags += repeatElement(0, count: T27Text.capacity - flags.count) }
        let cut = flags.withUnsafeMutableBufferPointer { as_history_cut($0.baseAddress!, UInt32(count), UInt32(keep)) }
        return cut > 0 ? Int(cut) : nil
    }

    /// Removes the reasoning some models put inline in <think> tags.
    nonisolated static func visibleText(_ text: String) -> String {
        let capacity = Int(AS_REPLY_MAX)
        var bytes = Array(text.utf8)
        let length = bytes.count
        if bytes.count < capacity { bytes += repeatElement(0, count: capacity - bytes.count) }
        var out = [UInt8](repeating: 0, count: max(capacity, length))
        let kept = bytes.withUnsafeMutableBufferPointer { input in
            out.withUnsafeMutableBufferPointer { as_strip_thinking(input.baseAddress!, UInt32(length), $0.baseAddress!) }
        }
        let result = length > capacity ? text : String(decoding: out.prefix(Int(kept)), as: UTF8.self)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Shared HTTP

    nonisolated static func request(
        baseURL: String,
        path: String,
        apiKey: String?,
        body: JSONValue?,
        timeout: TimeInterval
    ) async throws -> JSONValue {
        guard let url = URL(string: baseURL + path), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw AssistantFailure(message: "The API address is not a valid URL: \(baseURL)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw AssistantFailure(message: "Could not reach \(url.host ?? baseURL): \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard as_http_ok(Int64(status)) else {
            let detail = decoded?["error"]?["message"]?.stringValue
                ?? decoded?["error"]?.stringValue
                ?? decoded?["message"]?.stringValue
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            let hintRow = as_http_hint_row(UInt32(clamping: status))
            let hint = T27Text.output { as_row_text(hintRow, 1, $0) } ?? ""
            throw AssistantFailure(message: "API error \(status): \(detail)\(hint)")
        }
        guard let decoded else {
            throw AssistantFailure(message: "The API returned something that is not JSON.")
        }
        return decoded
    }

    /// Every model the provider lists at `/models`, sorted by name.
    nonisolated static func availableModels(baseURL: String, apiKey: String?) async throws -> [AssistantModelInfo] {
        let response = try await request(baseURL: baseURL, path: "/models", apiKey: apiKey, body: nil, timeout: 30)
        let list = response["data"]?.arrayValue ?? response["models"]?.arrayValue ?? []
        var seen: Set<String> = []
        var models: [AssistantModelInfo] = []
        for entry in list {
            guard let id = entry["id"]?.stringValue ?? entry["name"]?.stringValue, seen.insert(id).inserted else { continue }
            // OpenRouter and some others declare tool support; most providers do not.
            let parameters = entry["supported_parameters"]?.arrayValue?.compactMap(\.stringValue)
            models.append(AssistantModelInfo(id: id, declaresTools: parameters.map { $0.contains("tools") }))
        }
        return models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// One tiny request that proves the address, key and model work, including tool calling.
    nonisolated static func testConnection(baseURL: String, model: String, apiKey: String?) async throws -> String {
        let body: JSONValue = .object([
            "model": .string(model),
            "messages": .array([.object(["role": .string("user"), "content": .string("Reply with the single word OK.")])]),
            "max_tokens": .number(20),
            "temperature": .number(0)
        ])
        let response = try await request(baseURL: baseURL, path: "/chat/completions", apiKey: apiKey, body: body, timeout: 60)
        let content = response["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue ?? ""
        let visible = visibleText(content)
        return visible.isEmpty ? "connected" : visible
    }
}

// MARK: - Apple on-device model

enum AppleAssistantSupport {
    /// Whether the on-device model can answer right now, in words for the status line.
    @MainActor
    static func status() -> (ready: Bool, text: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return (true, "Apple model on this Mac")
            case .unavailable(.appleIntelligenceNotEnabled):
                return (false, "Turn on Apple Intelligence in System Settings, or connect an API in Settings")
            case .unavailable(.deviceNotEligible):
                return (false, "This Mac cannot run the Apple model. Connect an API in Settings")
            case .unavailable(.modelNotReady):
                return (false, "The Apple model is still downloading. Try again later or connect an API")
            case .unavailable:
                return (false, "The Apple model is unavailable. Connect an API in Settings")
            }
        }
        #endif
        return (false, "The Apple model needs macOS 26. Connect an API in Settings")
    }

    /// Languages the on-device model understands, for the settings note.
    @MainActor
    static func supportedLanguagesDescription() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let names = SystemLanguageModel.default.supportedLanguages.compactMap { language -> String? in
                guard let code = language.languageCode?.identifier else { return nil }
                return Locale.current.localizedString(forLanguageCode: code)
            }
            let unique = Array(Set(names)).sorted()
            return unique.isEmpty ? nil : unique.joined(separator: ", ")
        }
        #endif
        return nil
    }

    @MainActor
    static func makeBackend(executor: @escaping AssistantToolExecutor) throws -> any AssistantBackend {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return try AppleOnDeviceBackend(executor: executor)
        }
        #endif
        throw AssistantFailure(message: "The Apple model needs macOS 26. Connect an API in Settings.")
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
private struct AppleAssistantTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let executor: AssistantToolExecutor

    func call(arguments: GeneratedContent) async throws -> String {
        await executor(name, arguments.jsonString)
    }
}

@available(macOS 26.0, *)
extension AssistantToolSpec {
    func generationSchema() throws -> GenerationSchema {
        let properties = parameters.map { parameter -> DynamicGenerationSchema.Property in
            let schema: DynamicGenerationSchema
            switch parameter.type {
            case .string: schema = DynamicGenerationSchema(type: String.self)
            case .integer: schema = DynamicGenerationSchema(type: Int.self)
            case .boolean: schema = DynamicGenerationSchema(type: Bool.self)
            case .stringArray: schema = DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
            case .choice(let values): schema = DynamicGenerationSchema(name: "\(name)_\(parameter.name)", anyOf: values)
            }
            return DynamicGenerationSchema.Property(
                name: parameter.name,
                description: parameter.description,
                schema: schema,
                isOptional: parameter.isOptional
            )
        }
        let root = DynamicGenerationSchema(name: "\(name)_arguments", description: description, properties: properties)
        return try GenerationSchema(root: root, dependencies: [])
    }
}

@available(macOS 26.0, *)
@MainActor
private final class AppleOnDeviceBackend: AssistantBackend {
    private let tools: [any Tool]
    private var session: LanguageModelSession

    init(executor: @escaping AssistantToolExecutor) throws {
        let tools: [any Tool] = try AssistantTools.all.map { spec in
            AppleAssistantTool(
                name: spec.name,
                description: spec.description,
                parameters: try spec.generationSchema(),
                executor: executor
            )
        }
        self.tools = tools
        session = LanguageModelSession(tools: tools, instructions: AssistantTools.instructions)
    }

    func send(_ text: String) async throws -> String {
        do {
            return try await session.respond(to: text).content
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize:
                session = LanguageModelSession(tools: tools, instructions: AssistantTools.instructions)
                throw AssistantFailure(message: "The conversation got too long for the on-device model, so it started fresh. Ask again.")
            case .unsupportedLanguageOrLocale:
                throw AssistantFailure(message: "The Apple model does not understand this language yet. Write in English (or another supported language), or connect an API in Settings.")
            default:
                throw AssistantFailure(message: "The Apple model could not answer: \(error.localizedDescription)")
            }
        }
    }
}
#endif
