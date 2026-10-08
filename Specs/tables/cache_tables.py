#!/usr/bin/env python3
"""Writes the name tables of Specs/cache_verdict.t27 from the readable lists below.

The spec stores every string as bytes in one packed array; each table row records where its fields
start and how long they are. Run: python3 Specs/tables/cache_tables.py (Specs/generate.sh does it).
"""
import pathlib, re

# Table codes (must match CV_TABLE_* in the spec).
KEEP, KEEP_PREFIX, PACKAGE, BROWSER, DERIVED, TOOL = range(6)
# Row codes: CV_KIND_* for packages, CV_CAT_* for tool hints, 0 otherwise.
KIND_PACKAGE, KIND_MODELS = 2, 3
CAT_DEVELOPER, CAT_PACKAGE = 2, 3

# Sign-in, sync and system state that lives in Caches but must not be cleared casually.
keep = ["cloudkit", "familycircle", "passkit", "com.apple.bird", "com.apple.cloudd", "com.apple.akd",
        "com.apple.accountsd", "com.apple.appleaccountd", "com.apple.amsaccountsd", "com.apple.containermanagerd",
        "com.apple.nsurlsessiond", "com.apple.cache_delete", "com.apple.homekit", "com.apple.passd",
        "com.apple.trustd", "com.apple.screentimeagent", "com.apple.icloud.fmfd", "com.apple.findmy.fmipcore"]
keep_prefixes = ["com.apple.fileprovider", "com.apple.security", "com.apple.keychain", "com.apple.icloud",
                 "com.apple.cloudphotos"]
# Package managers and model downloaders: name, title, cleanup command ("" = none).
packages = [
    ("homebrew", "Homebrew downloads", "brew cleanup --prune=all"),
    ("pip", "pip downloads", "pip cache purge"),
    ("pypoetry", "Poetry cache", "poetry cache clear --all ."),
    ("yarn", "Yarn cache", "yarn cache clean"),
    ("go-build", "Go build cache", "go clean -cache"),
    ("cocoapods", "CocoaPods cache", "pod cache clean --all"),
    ("ms-playwright", "Playwright browsers", "npx playwright install (to download again)"),
    ("bun", "Bun cache", "bun pm cache rm"),
    ("uv", "uv cache", "uv cache clean"),
    ("pnpm", "pnpm cache", "pnpm store prune"),
    ("deno", "Deno cache", ""),
    ("node-gyp", "node-gyp headers", ""),
    ("electron", "Electron downloads", ""),
    ("electron-builder", "electron-builder downloads", ""),
    ("zig", "Zig cache", ""),
    ("huggingface", "Hugging Face models", "huggingface-cli delete-cache"),
    ("torch", "PyTorch downloads", ""),
    ("prisma", "Prisma engines", ""),
    ("typescript", "TypeScript type cache", ""),
    ("puppeteer", "Puppeteer browsers", ""),
    ("jna", "JNA native libraries", ""),
    ("gradle", "Gradle cache", ""),
    ("composer", "Composer cache", "composer clear-cache"),
    ("codex-runtimes", "Codex runtimes", ""),
    ("gh", "GitHub CLI cache", ""),
    ("opencode", "opencode cache", ""),
    ("scapy", "Scapy cache", ""),
]
models = {"huggingface"}
# Cache folder names that belong to a browser: name, title, bundle ID.
browsers = [
    ("google", "Google Chrome", "com.google.chrome"),
    ("com.google.chrome", "Google Chrome", "com.google.chrome"),
    ("mozilla", "Firefox", "org.mozilla.firefox"),
    ("firefox", "Firefox", "org.mozilla.firefox"),
    ("com.apple.safari", "Safari", "com.apple.safari"),
    ("com.brave.browser", "Brave", "com.brave.browser"),
    ("com.microsoft.edgemac", "Microsoft Edge", "com.microsoft.edgemac"),
    ("company.thebrowser.browser", "Arc", "company.thebrowser.browser"),
    ("com.operasoftware.opera", "Opera", "com.operasoftware.opera"),
    ("com.vivaldi.vivaldi", "Vivaldi", "com.vivaldi.vivaldi"),
]
# Xcode DerivedData folders with a fixed meaning: exact name, title.
derived = [("ModuleCache.noindex", "Module cache"), ("CompilationCache.noindex", "Compilation cache"),
           ("SymbolCache.noindex", "Symbol cache")]
# Locations DiskBloom never moves: path relative to home, title, command, category.
tools = [
    (".npm/_cacache", "npm cache", "npm cache clean --force", CAT_PACKAGE),
    (".cargo/registry/cache", "Cargo downloads", "cargo install cargo-cache && cargo cache --autoclean", CAT_PACKAGE),
    (".gradle/caches", "Gradle cache", "gradle --stop, then remove ~/.gradle/caches", CAT_PACKAGE),
    ("Library/Developer/CoreSimulator/Caches", "Simulator caches", "xcrun simctl delete unavailable", CAT_DEVELOPER),
    ("Library/Developer/Xcode/iOS DeviceSupport", "iOS device support",
     "Remove versions you no longer debug in Finder (Xcode downloads them again)", CAT_DEVELOPER),
]

rows = []  # (table, fields..., code)
rows += [(KEEP, (n,), 0) for n in keep]
rows += [(KEEP_PREFIX, (n,), 0) for n in keep_prefixes]
rows += [(PACKAGE, (n, t, h), KIND_MODELS if n in models else KIND_PACKAGE) for n, t, h in packages]
rows += [(BROWSER, (n, t, i), 0) for n, t, i in browsers]
rows += [(DERIVED, (n, t), 0) for n, t in derived]
rows += [(TOOL, (p, t, h), c) for p, t, h, c in tools]

text = bytearray()
offsets = [[], [], []]
lengths = [[], [], []]
for _, fields, _ in rows:
    for f in range(3):
        value = fields[f].encode() if f < len(fields) else b""
        assert all(b < 128 for b in value), value
        offsets[f].append(len(text))
        lengths[f].append(len(value))
        text += value

def arr(name, typ, values):
    return f"pub const {name} : [{len(values)}]{typ} = [{', '.join(map(str, values))}];"

lines = ["; >>> generated by Specs/tables/cache_tables.py -- edit the lists there, not here",
         f"pub const CV_ROWS : u32 = {len(rows)};",
         arr("CV_ROW_TABLE", "u32", [r[0] for r in rows]),
         arr("CV_ROW_CODE", "u32", [r[2] for r in rows])]
for f in range(3):
    lines.append(arr(f"CV_ROW_F{f}_OFFSET", "u32", offsets[f]))
    lines.append(arr(f"CV_ROW_F{f}_LENGTH", "u32", lengths[f]))
lines.append(arr("CV_TEXT", "u8", list(text)))
lines.append("; <<< generated")
spec = pathlib.Path(__file__).resolve().parents[1] / "cache_verdict.t27"
source = spec.read_text()
block = "\n".join(lines)
source, n = re.subn(r"; >>> generated by Specs/tables/cache_tables\.py.*?; <<< generated", lambda m: block, source, flags=re.S)
assert n == 1, "marker block not found"
spec.write_text(source)
print(f"cache tables: {len(rows)} rows, {len(text)} bytes")
