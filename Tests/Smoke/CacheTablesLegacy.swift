import Foundation

/// The cache name tables as they were written in Swift before Specs/cache_verdict.t27 held them. Oracle only.
enum LegacyCacheTables {
    /// Sign-in, sync and system state that lives in Caches but must not be cleared casually.
    static let keepNames: Set<String> = [
        "cloudkit",
        "familycircle",
        "passkit",
        "com.apple.bird",
        "com.apple.cloudd",
        "com.apple.akd",
        "com.apple.accountsd",
        "com.apple.appleaccountd",
        "com.apple.amsaccountsd",
        "com.apple.containermanagerd",
        "com.apple.nsurlsessiond",
        "com.apple.cache_delete",
        "com.apple.homekit",
        "com.apple.passd",
        "com.apple.trustd",
        "com.apple.screentimeagent",
        "com.apple.icloud.fmfd",
        "com.apple.findmy.fmipcore"
    ]

    static let keepPrefixes = [
        "com.apple.fileprovider",
        "com.apple.security",
        "com.apple.keychain",
        "com.apple.icloud",
        "com.apple.cloudphotos"
    ]

    /// Package managers and model downloaders: safe to clear, but the next install downloads again.
    static let packageManagers: [String: (title: String, hint: String?)] = [
        "homebrew": ("Homebrew downloads", "brew cleanup --prune=all"),
        "pip": ("pip downloads", "pip cache purge"),
        "pypoetry": ("Poetry cache", "poetry cache clear --all ."),
        "yarn": ("Yarn cache", "yarn cache clean"),
        "go-build": ("Go build cache", "go clean -cache"),
        "cocoapods": ("CocoaPods cache", "pod cache clean --all"),
        "ms-playwright": ("Playwright browsers", "npx playwright install (to download again)"),
        "bun": ("Bun cache", "bun pm cache rm"),
        "uv": ("uv cache", "uv cache clean"),
        "pnpm": ("pnpm cache", "pnpm store prune"),
        "deno": ("Deno cache", nil),
        "node-gyp": ("node-gyp headers", nil),
        "electron": ("Electron downloads", nil),
        "electron-builder": ("electron-builder downloads", nil),
        "zig": ("Zig cache", nil),
        "huggingface": ("Hugging Face models", "huggingface-cli delete-cache"),
        "torch": ("PyTorch downloads", nil),
        "prisma": ("Prisma engines", nil),
        "typescript": ("TypeScript type cache", nil),
        "puppeteer": ("Puppeteer browsers", nil),
        "jna": ("JNA native libraries", nil),
        "gradle": ("Gradle cache", nil),
        "composer": ("Composer cache", "composer clear-cache"),
        "codex-runtimes": ("Codex runtimes", nil),
        "gh": ("GitHub CLI cache", nil),
        "opencode": ("opencode cache", nil),
        "scapy": ("Scapy cache", nil)
    ]

    /// Cache folder names that belong to a browser, mapped to the browser's bundle ID.
    static let browsers: [String: (title: String, identifier: String)] = [
        "google": ("Google Chrome", "com.google.chrome"),
        "com.google.chrome": ("Google Chrome", "com.google.chrome"),
        "mozilla": ("Firefox", "org.mozilla.firefox"),
        "firefox": ("Firefox", "org.mozilla.firefox"),
        "com.apple.safari": ("Safari", "com.apple.safari"),
        "com.brave.browser": ("Brave", "com.brave.browser"),
        "com.microsoft.edgemac": ("Microsoft Edge", "com.microsoft.edgemac"),
        "company.thebrowser.browser": ("Arc", "company.thebrowser.browser"),
        "com.operasoftware.opera": ("Opera", "com.operasoftware.opera"),
        "com.vivaldi.vivaldi": ("Vivaldi", "com.vivaldi.vivaldi")
    ]

    static func friendlyTitle(for name: String, location: CacheLocationKind) -> String {
        if location == .derivedData {
            switch name {
            case "ModuleCache.noindex": return "Module cache"
            case "CompilationCache.noindex": return "Compilation cache"
            case "SymbolCache.noindex": return "Symbol cache"
            default: break
            }
            // Xcode names project folders "<Project>-<28 lowercase letters>".
            if let dash = name.lastIndex(of: "-") {
                let suffix = name[name.index(after: dash)...]
                if suffix.count == 28, suffix.allSatisfy({ $0.isLowercase && $0.isLetter }) {
                    return String(name[..<dash])
                }
            }
            return name
        }
        return name
    }
}

struct LegacyCacheToolHint: Sendable {
    let relativePath: String
    let title: String
    let hint: String
    let category: CacheCategory

    static let all: [LegacyCacheToolHint] = [
        LegacyCacheToolHint(relativePath: ".npm/_cacache", title: "npm cache", hint: "npm cache clean --force", category: .packageManager),
        LegacyCacheToolHint(relativePath: ".cargo/registry/cache", title: "Cargo downloads", hint: "cargo install cargo-cache && cargo cache --autoclean", category: .packageManager),
        LegacyCacheToolHint(relativePath: ".gradle/caches", title: "Gradle cache", hint: "gradle --stop, then remove ~/.gradle/caches", category: .packageManager),
        LegacyCacheToolHint(relativePath: "Library/Developer/CoreSimulator/Caches", title: "Simulator caches", hint: "xcrun simctl delete unavailable", category: .developer),
        LegacyCacheToolHint(relativePath: "Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device support", hint: "Remove versions you no longer debug in Finder (Xcode downloads them again)", category: .developer)
    ]
}

