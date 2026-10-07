import Foundation

/// The assistant's text rules as written in Swift before Specs/assistant_rules.t27. Oracle only.
enum LegacyAssistantRules {
    static func section(named name: String) -> WorkspaceSection? {
        switch name.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "disk_map", "diskmap", "map": .diskMap
        case "caches", "cache": .cacheExplorer
        case "app_uninstaller", "uninstaller", "apps": .appUninstaller
        case "leftovers", "possible_leftovers": .orphanedAppData
        case "duplicates", "duplicate_files": .duplicateFinder
        default: nil
        }
    }

    static func verdict(named name: String?) -> CacheVerdict? {
        switch name?.lowercased() {
        case "safe": .safe
        case "optional": .optional
        case "in_use", "quitfirst", "quit_first": .quitFirst
        case "keep": .keep
        case "tool", "use_tool": .useTool
        default: nil
        }
    }

    static func resolve(_ raw: String, home: String) -> String? {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
        guard !path.isEmpty else { return nil }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        } else if !path.hasPrefix("/") {
            path = home + "/" + path
        }
        return path
    }

    static func displayPath(_ path: String, home: String) -> String {
        if path == home { return "Home" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func normalizedBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        for suffix in ["/chat/completions", "/models"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }

    static func isLocal(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let nonChat = [
            "embed", "rerank", "reward", "guard", "safety", "content-safety", "topic-control", "nemoretriever",
            "retriever", "parse", "clip", "vila", "neva", "deplot", "kosmos", "fuyu", "riva", "detector",
            "calibration", "whisper", "tts", "diffusion", "cosmos", "paligemma", "starcoder", "codegemma"
        ]
        return !nonChat.contains { lower.contains($0) }
    }

    static func isRecommended(_ id: String, declaresTools: Bool?) -> Bool {
        if let declaresTools { return declaresTools && isChatModel(id) }
        let lower = id.lowercased()
        let families = [
            "kimi-k", "glm-4.5", "glm-4.6", "glm-5", "deepseek-v3", "deepseek-v4", "gpt-oss", "gpt-4", "gpt-5",
            "nemotron-3-super", "nemotron-3-ultra", "nemotron-ultra", "mistral-large", "qwen3", "qwen2.5",
            "llama-3.1-70b", "llama-3.3", "llama-4", "gemma-4", "claude", "gemini"
        ]
        return isChatModel(id) && families.contains { lower.contains($0) }
    }

    static func visibleText(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>") {
            if let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func historyCut(_ roles: [String], keep: Int) -> Int? {
        guard roles.count > keep else { return nil }
        var index = roles.count - keep
        while index < roles.count, roles[index] != "user" { index += 1 }
        guard index < roles.count else { return nil }
        return index
    }

    static func httpHint(_ status: Int) -> String {
        switch status {
        case 401, 403: " Check the API key."
        case 404: " The address is wrong or this provider has no model with that name — pick one from the model list."
        case 429: " The provider's rate limit or balance ran out."
        default: ""
        }
    }

    static func yes(_ value: String) -> Bool { ["true", "yes", "1"].contains(value.lowercased()) }

    static func replacesModel(model: String, suggestions: [String]) -> Bool {
        guard suggestions.first != nil else { return false }
        return model.isEmpty || !suggestions.contains(model)
    }

    static func catalogAction(readable: Bool, directory: Bool, symlink: Bool, appExtension: Bool, depthLeft: Int, package: Bool) -> Int32 {
        guard readable, directory, !symlink else { return AS_CATALOG_SKIP }
        if appExtension { return AS_CATALOG_ADD }
        if depthLeft > 0, !package { return AS_CATALOG_DESCEND }
        return AS_CATALOG_SKIP
    }
}
