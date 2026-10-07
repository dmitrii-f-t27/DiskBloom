# Decisions written in t27

DiskBloom's safety decisions are written in [t27](https://github.com/gHashTag/t27), the spec language of the Trinity stack, and compiled to C. Swift collects the facts (paths, owners, running apps); the specs decide.

| Spec | Decides | Swift caller |
|---|---|---|
| `cache_verdict.t27` | verdict, reason and category of each cache; the last check before a cache moves | `CacheClassifier.classify`, `CachePolicy.validate` (`Sources/CacheExplorer.swift`) |
| `deletion_policy.t27` | whether an item may go to the Trash, and the first reason to refuse | `DeletionPolicy.rejectionReason` (`Sources/AppModel.swift`) |

## Regenerate

```bash
T27C=/path/to/t27c ./Specs/generate.sh
```

The script type-checks each spec, generates C with `t27c gen-c`, runs the spec's own tests and writes:

- `Sources/Generated/<spec>.h` — the full generated C (compiled once by `Sources/Generated/t27_specs.c`);
- `Sources/Generated/<spec>.api.h` — its constants and prototypes, read by Swift through `DiskBloom-Bridging.h`.

The generated files are committed, so `build.sh`, Xcode and the App Store build never need `t27c`. `T27C_PIN` names the gHashTag/t27 revision they were generated with.

## Tests

`Tests/run-smoke-tests.sh` runs every spec's own tests from the committed C, and two differential tests that compare the t27 rules with the Swift rules they replaced (`Tests/Smoke/*Legacy.swift`, kept only as the oracle): every field of the cache verdict over 10,560 synthetic inputs, and every refusal message of the deletion policy over 23,328 real paths. With `DISKBLOOM_DIFF_REAL=1` the cache test also compares every real cache name on the Mac.
