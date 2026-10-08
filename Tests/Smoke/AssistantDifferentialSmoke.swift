import Foundation

/// Compares the assistant's text rules written in Swift before Specs/assistant_rules.t27
/// (Tests/Smoke/AssistantLegacy.swift) with the ones that ask the spec.
@main
@MainActor
struct AssistantDifferentialSmoke {
    static func main() throws {
        var checks = 0
        func check<T: Equatable>(_ label: String, _ a: T, _ b: T) throws {
            guard a == b else { throw NSError(domain: "Assistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "MISMATCH \(label): Swift=\(a) t27=\(b)"]) }
            checks += 1
        }
        var generator = SplitMix(seed: 0xA5517)
        func random(_ alphabet: [String], _ maxLength: Int) -> String {
            let length = Int(generator.next() % UInt64(maxLength + 1))
            return (0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] }.joined()
        }

        var words = ["disk_map", "diskmap", "map", "caches", "cache", "app_uninstaller", "uninstaller", "apps", "leftovers",
                     "possible_leftovers", "duplicates", "duplicate_files", "Disk Map", "DISK MAP", "possible leftovers", "Caches",
                     "safe", "optional", "in_use", "quitfirst", "quit_first", "keep", "tool", "use_tool", "SAFE", "In_Use", "all",
                     "yes", "YES", "true", "1", "no", "0", "", " ", "map ", "Map", "ma", "cachesx", "kéep", "ﬁle"]
        for _ in 0..<5_000 { words.append(random(["a", "p", "m", "_", " ", "s", "e", "c", "h", "D", "é", "1", "y", "t"], 12)) }
        for word in words {
            try check("section \(word)", LegacyAssistantRules.section(named: word), AssistantToolbox.section(named: word))
            try check("verdict \(word)", LegacyAssistantRules.verdict(named: word), AssistantToolbox.verdict(named: word))
            try check("yes \(word)", LegacyAssistantRules.yes(word), JSONValue.string(word).boolValue ?? false)
        }

        let home = UserHome.path
        var rawPaths = ["", "~", "~/", "~/Downloads", "Downloads", "/tmp", "'~/Library'", "\"Desktop\"", "  ~/Documents ", "`/Applications`",
                        "~x", "~~/a", "/", "Library/Caches", "nonexistent-folder-xyz", "~/nonexistent"]
        for _ in 0..<3_000 { rawPaths.append(random(["~", "/", "a", "Library", "Documents", " ", "'", "\"", "`", "."], 6)) }
        for raw in rawPaths {
            let legacy = LegacyAssistantRules.resolve(raw, home: home).flatMap { path -> URL? in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            try check("resolve \(raw)", legacy, AssistantToolbox.resolve(raw))
        }
        for path in [home, home + "/Downloads", home + "x", "/Applications", "/", home + "/a/b"] {
            try check("display \(path)", LegacyAssistantRules.displayPath(path, home: home), AssistantToolbox.displayPath(URL(fileURLWithPath: path)))
        }

        var addresses = ["https://api.z.ai/api/paas/v4", "https://a.io/v1/", "https://a.io/v1///", "https://a.io/v1/chat/completions",
                         "https://a.io/v1/models", "https://a.io/v1/models/chat/completions", "https://a.io/v1/chat/completions/models",
                         " http://localhost:11434/v1/ ", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1", "http://box.local/v1",
                         "http://LOCALHOST/v1", "https://example.com/local", "", "/", "garbage", "http://x.localx/v1"]
        for _ in 0..<2_000 { addresses.append(random(["https://", "a.io", "/v1", "/", "/models", "/chat/completions", " ", "localhost", ".local"], 6)) }
        for address in addresses {
            let normalized = LegacyAssistantRules.normalizedBaseURL(address)
            try check("normalize \(address)", normalized, AssistantSettings.normalize(address))
            try check("local \(address)", LegacyAssistantRules.isLocal(normalized), AssistantSettings.isLocal(normalized))
        }

        var models: [(String, Bool?)] = CapturedModelIDs.nvidia.map { ($0, nil) } + CapturedModelIDs.openRouter
        for _ in 0..<3_000 { models.append((random(["kimi-k", "glm-5", "embed", "gpt-4", "x", "/", "Claude", "TTS", "qwen3", "-"], 4), [nil, true, false][Int(generator.next() % 3)])) }
        for (id, tools) in models {
            let info = AssistantModelInfo(id: id, declaresTools: tools)
            try check("chat \(id)", LegacyAssistantRules.isChatModel(id), info.isChatModel)
            try check("recommended \(id) \(String(describing: tools))", LegacyAssistantRules.isRecommended(id, declaresTools: tools), info.isRecommended)
        }

        var replies = ["plain", "<think>x</think>answer", "a<think>b</think>c<think>d</think>e", "<think>never closed", "a<thi<think>x</think>nk>zz",
                       "  <think> </think>  spaced  ", "</think>stray", "<think><think>nested</think></think>", "", "\n<think>\n</think>\n"]
        for _ in 0..<5_000 { replies.append(random(["<think>", "</think>", "a", " ", "\n", "é", "<thi", "nk>", "<", "/"], 10)) }
        replies.append(String(repeating: "x<think>y</think>", count: 20_000))
        for reply in replies {
            try check("visible \(reply.prefix(80))", LegacyAssistantRules.visibleText(reply), OpenAICompatibleBackend.visibleText(reply))
        }

        for _ in 0..<3_000 {
            let roles = (0..<Int(generator.next() % 90)).map { _ in ["system", "user", "assistant", "tool"][Int(generator.next() % 4)] }
            let keep = Int(generator.next() % 70)
            try check("history \(roles.count) \(keep)", LegacyAssistantRules.historyCut(roles, keep: keep), OpenAICompatibleBackend.historyCut(roles: roles, keep: keep))
        }
        for status in 0...700 {
            let row = as_http_hint_row(UInt32(status))
            try check("hint \(status)", LegacyAssistantRules.httpHint(status), T27Text.output { as_row_text(row, 1, $0) } ?? "")
            try check("ok \(status)", (200..<300).contains(status), as_http_ok(Int64(status)))
        }
        for model in ["", "glm-4.6", "other"] {
            for suggestions in [[], ["glm-4.6"], ["glm-5", "glm-4.6"], ["x"]] {
                let legacy = LegacyAssistantRules.replacesModel(model: model, suggestions: suggestions)
                let new = suggestions.first != nil && as_replace_model(true, model.isEmpty, suggestions.contains(model))
                try check("replace \(model) \(suggestions)", legacy, new)
            }
        }
        for bits in 0..<32 {
            let f = (0..<5).map { bits & (1 << $0) != 0 }
            for depth in -1...2 {
                try check("catalog \(f) \(depth)", LegacyAssistantRules.catalogAction(readable: f[0], directory: f[1], symlink: f[2], appExtension: f[3], depthLeft: depth, package: f[4]),
                          Int32(as_catalog_entry(f[0], f[1], f[2], f[3], Int64(depth), f[4])))
            }
        }
        for _ in 0..<2_000 {
            let needle = random(["com.", "vendor", ".app", "x", "é"], 4)
            var hay = random(["com.", "vendor", ".app", "x", " ", "é", "/"], 40)
            if generator.next() % 3 == 0 { hay = String(repeating: "z", count: Int(generator.next() % 9000)) + needle + hay }
            try check("contains \(needle) in \(hay.count)", hay.contains(needle) || needle.isEmpty, T27Text.contains(hay, needle))
        }
        print("ASSISTANT_DIFFERENTIAL_OK checks=\(checks)")
    }
}
