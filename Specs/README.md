# Decisions written in t27

Every decision DiskBloom makes is written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C. Swift collects the facts (paths, sizes, owners, running apps, what the person clicked), asks a spec, and carries out the answer: it shows a view, calls the system, or runs the next step the spec names.

| Spec | Decides | Main Swift callers |
|---|---|---|
| `cache_verdict.t27` | the name tables of known caches; verdict, reason and category of each cache; the last check before a cache moves; list order | `CacheClassifier`, `CachePolicy` (`CacheExplorer.swift`) |
| `deletion_policy.t27` | whether an item may go to the Trash, and the first reason to refuse | `DeletionPolicy` (`AppModel.swift`) |
| `uninstaller_policy.t27` | rule match, risk and default selection; each plan item's trust, block and selection; whether an application may be removed; whether one item may move; whether an old plan may continue; plan and queue order | `AppRemovalRule`, `AppRemovalDecisions`, `AppRemovalPolicy` (`AppRemoval.swift`) |
| `leftovers_policy.t27` | folder risk and group certainty; which Library entries are candidates; which owner claims an ID; whether anything inside makes a folder unsafe; whether a folder may move; group order | `OrphanDataRule`, `OrphanOwnerIndex`, `OrphanedAppDataAnalyzer`, `OrphanDataPolicy` (`OrphanedAppData.swift`) |
| `text_rules.t27` | bundle identifiers and their canonical form, vendor namespace, display names, how two paths relate, Library areas, hidden/Trash/external paths, extension kinds, string order | `T27Text` (`T27Text.swift`), used everywhere |
| `fingerprint.t27` | the FNV-1a folder fingerprint and how child fingerprints combine | `DiskScanner.swift` |
| `scan_rules.t27` | what the scanner maps and measures, allocated size, which children it keeps, child order, when a folder snapshot still holds, snapshot comparison | `DiskScanner`, `SnapshotValidator` |
| `move_rules.t27` | the order of every check around a Trash move (queue, each item, signature), what counts as confirmed or uncertain, the result, whether to stop after a failure | `MoveSteps` (`MoveSteps.swift`) and the three coordinators |
| `duplicate_rules.t27` | which entries the duplicate finder examines, blocked folders, when metadata matches, size groups, SHA-256 itself, byte comparison | `DuplicateFinder.swift` |
| `format_rules.t27` | compact sizes, singular/plural, disk usage and fraction, progress cadence | `ByteFormat`, `Plural`, `VolumeStats` (`Models.swift`) |
| `sunburst_rules.t27` | ring map layout, palette, radii, sector inset, which ring and angle the pointer is on | `SunburstLayout`, `SunburstGeometry` (`SunburstView.swift`) |
| `model_rules.t27` | navigation, the cleanup queue, volume labels, which buttons each screen allows, uninstall review steps, folder grants, when the assistant is busy, API settings status, tool limits | `AppModel`, `CacheExplorerModel`, `OrphanedAppDataModel`, `AppUninstallerModel`, `DuplicateFinderModel`, `FolderAccess` |
| `assistant_rules.t27` | section/verdict words the model may use, path forms, base URL and local hosts, chat and recommended models, HTTP hints, history cut, stripping `<think>` blocks, the app catalog walk, when to send and when a reply is final, each tool's plan | `Assistant.swift`, `AssistantBackends.swift` |

Expensive checks stay lazy: a spec returns the id of the next step (`mv_step`, `md_review_step`), Swift performs it and asks again.

## What stays in Swift, and why

- Views and their texts (SwiftUI); the codes a spec returns are mapped to messages in Swift.
- System calls: FileManager, NSWorkspace, Security and Keychain, URLSession, FoundationModels, NSFileCoordinator.
- Unicode work the OS owns: lowercasing and trimming, NFC/NFD normalization, localized compare, `ByteCountFormatter`, `String(format:)`; `atan2` and `hypot` from the maths library.
- Concurrency bookkeeping (task generations, cancellation) and JSON shaping; tool specs and prompts for the model.

## Regenerate

```bash
T27C=/path/to/t27c ./Specs/generate.sh
```

The script runs the table generators in `Specs/tables/`, type-checks each spec, generates C with `t27c gen-c`, runs the spec's own tests (`clang -std=c11 -ffp-contract=off -Werror`) and writes:

- `Sources/Generated/<spec>.h` — the full generated C (compiled once by `Sources/Generated/t27_specs.c`);
- `Sources/Generated/<spec>.api.h` — its constants and prototypes, read by Swift through `DiskBloom-Bridging.h`.

Both aggregate files are written by the script. Files are copied only when their content changed. The generated files are committed, so `build.sh`, Xcode and the App Store build never need `t27c`. `T27C_PIN` names the gHashTag/t27 revision they were generated with. `-ffp-contract=off` is required everywhere the C is compiled: fused multiply-add changes ring-map angles in the last bit.

Do not run `generate.sh` while the test suite runs: the suite's precompiled bridging header goes stale and every later test fails to build.

## Tests

`Tests/run-smoke-tests.sh` runs every spec's own tests (64 in all) from the committed C, the behaviour smoke tests, and eleven differential tests. Each differential test compares the t27 rules with the Swift they replaced, kept only as the oracle (`Tests/Smoke/*Legacy.swift`, or inline in `ModelRulesDifferentialSmoke`):

| Test | Compared |
|---|---|
| `CacheVerdictDifferentialSmoke` | every field of the cache verdict over synthetic inputs, and the name tables |
| `DeletionPolicyDifferentialSmoke` | every refusal message over real paths |
| `UninstallerDifferentialSmoke` | rule tables, every plan-item decision, every installed application, item checks on fixtures, plan continuation |
| `LeftoversDifferentialSmoke` | tables, owner claims, every real `~/Library` entry as a candidate, unsafe-content fixtures |
| `TextRulesDifferentialSmoke` | identifiers, names and paths on this Mac and a generated corpus, including string order |
| `ScannerDifferentialSmoke` | whole scanned trees and snapshot validation |
| `MoveDifferentialSmoke` | the outcome of each move scenario on identical fixtures |
| `DuplicatesDifferentialSmoke` | SHA-256 against CryptoKit; duplicate groups |
| `PresentationDifferentialSmoke` | sizes, plurals, disk usage, ring-map angles and colours bit for bit |
| `ModelRulesDifferentialSmoke` | every view-model decision, tool plan and list order, exhaustively |
| `AssistantDifferentialSmoke` | the assistant's text rules, model ids from NVIDIA and OpenRouter, catalog walk |

With `DISKBLOOM_DIFF_REAL=1` the cache and leftovers tests also compare every real cache and every real unclaimed leftover on the Mac.

Each test was checked by mutating single rules in the generated C: every reachable mutation fails a test. The few that survive disable checks the app cannot reach (a rule-matched related path is always inside `~/Library`; cloud entries never pass the leftovers candidate filter; a mount-point file is never examined by the duplicate finder); the specs' own tests still cover them.

### Known differences from the old Swift

- String order follows NFC bytes everywhere. Swift's own `<` is not consistent for a few pairs that mix normalizations; the text test skips and counts them.
- `as_is_whole` answers for doubles beyond `Int64`, where the old Swift trapped.
- Replies over 1 MB are not searched for `<think>` blocks.
- SHA-256 in t27 runs at about 400 MB/s against CryptoKit's 3 GB/s; duplicate checks on large files are slower.
