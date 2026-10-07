# Decisions written in t27

DiskBloom's safety decisions are written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C. Swift collects the facts (paths, owners, running apps); the specs decide.

| Spec | Decides | Swift caller |
|---|---|---|
| `cache_verdict.t27` | verdict, reason and category of each cache; the last check before a cache moves | `CacheClassifier.classify`, `CachePolicy.validate` (`Sources/CacheExplorer.swift`) |
| `deletion_policy.t27` | whether an item may go to the Trash, and the first reason to refuse | `DeletionPolicy.rejectionReason` (`Sources/AppModel.swift`) |
| `uninstaller_policy.t27` | rule match, risk and default selection; each plan item's trust, block and selection; whether an application may be removed; whether one item may move; whether an old plan may continue | `AppRemovalRule`, `AppRemovalDecisions.item`, `AppRemovalPolicy` (`Sources/AppRemoval.swift`) |
| `leftovers_policy.t27` | folder risk and group certainty; which Library entries are candidates; which owner claims an ID; whether any file inside makes a folder unsafe; whether a folder may move | `OrphanDataRule`, `OrphanOwnerIndex.claimReason`, `OrphanedAppDataAnalyzer.candidate`, `OrphanDataPolicy` (`Sources/OrphanedAppData.swift`) |

Two parts of the uninstaller stay in Swift on purpose: re-verifying the signature right before the bundle moves (two full snapshot comparisons around a signature read) and the move loop itself. Their order of disk work is what they are for.

## Regenerate

```bash
T27C=/path/to/t27c ./Specs/generate.sh
```

The script type-checks each spec, generates C with `t27c gen-c`, runs the spec's own tests and writes:

- `Sources/Generated/<spec>.h` — the full generated C (compiled once by `Sources/Generated/t27_specs.c`);
- `Sources/Generated/<spec>.api.h` — its constants and prototypes, read by Swift through `DiskBloom-Bridging.h`.

The generated files are committed, so `build.sh`, Xcode and the App Store build never need `t27c`. `T27C_PIN` names the gHashTag/t27 revision they were generated with.

## Tests

`Tests/run-smoke-tests.sh` runs every spec's own tests from the committed C, and four differential tests that compare the t27 rules with the Swift rules they replaced (`Tests/Smoke/*Legacy.swift`, kept only as the oracle):

| Test | Compared |
|---|---|
| `CacheVerdictDifferentialSmoke` | every field of the cache verdict, 10,560 synthetic inputs |
| `DeletionPolicyDifferentialSmoke` | every refusal message, 23,328 real paths |
| `UninstallerDifferentialSmoke` | rule tables, all 1,216 plan-item decisions, every installed application and edge paths, item checks on fixtures, plan continuation against this Mac |
| `LeftoversDifferentialSmoke` | tables, owner claims, every real `~/Library` entry as a candidate, unsafe-content fixtures (executable, link, nested app, immutable flag, unreadable folder) |

With `DISKBLOOM_DIFF_REAL=1` the cache and leftovers tests also compare every real cache and every real unclaimed leftover on the Mac. Each test was checked by mutating single rules in the generated C: every reachable mutation fails its test. Two mutations survive because the checks they disable cannot be reached from the app (a rule-matched related path is always inside `~/Library`; cloud entries never pass the candidate filter); the specs' own tests still cover them.
