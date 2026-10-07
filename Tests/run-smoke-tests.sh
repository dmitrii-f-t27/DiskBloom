#!/bin/zsh
# Compile and run the DiskBloom smoke/regression tests against the current Sources.
# Every test builds its own fixtures and never touches the real Trash.
#   ./Tests/run-smoke-tests.sh              (Apple Silicon)
#   ARCH=x86_64 ./Tests/run-smoke-tests.sh  (Intel slice, runs under Rosetta on Apple Silicon)
set -euo pipefail
ARCH="${ARCH:-arm64}"

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build/smoke-$ARCH"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
# Fixtures live inside the checkout (and therefore inside the home folder): the cleanup policy
# deliberately refuses to treat anything under /private, /tmp or other system roots as removable.
FIXTURES="$BUILD_DIR/fixtures-$$"
cleanup() {
  [[ -d "$FIXTURES" && "$FIXTURES" == "$BUILD_DIR"/fixtures-* ]] || return 0
  /usr/bin/chflags -R nouchg "$FIXTURES" 2>/dev/null; /bin/chmod -R u+rwx "$FIXTURES" 2>/dev/null
  /bin/rm -r -- "$FIXTURES"
}
trap cleanup EXIT

/bin/mkdir -p "$BUILD_DIR"
/bin/rm -rf -- "$FIXTURES"
APP_SOURCES=("$ROOT_DIR"/Sources/*.swift)
APP_SOURCES=(${APP_SOURCES:#*/DiskBloomApp.swift})

xcrun clang -c -O2 -std=c11 -ffp-contract=off -Wall -Wno-parentheses-equality -Werror \
  -isysroot "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
  "$ROOT_DIR/Sources/Generated/t27_specs.c" -o "$BUILD_DIR/t27_specs.o"

build_test() {
  local name="$1"
  local extra=()
  # Each differential test also compiles the pre-t27 Swift rules it compares against.
  [[ "$name" == CacheVerdictDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/CacheVerdictLegacy.swift" "$ROOT_DIR/Tests/Smoke/CacheTablesLegacy.swift" "$ROOT_DIR/Tests/Smoke/TestSupport.swift")
  [[ "$name" == DeletionPolicyDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/DeletionPolicyLegacy.swift")
  [[ "$name" == UninstallerDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/UninstallerLegacy.swift")
  [[ "$name" == LeftoversDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/LeftoversLegacy.swift")
  [[ "$name" == ScannerDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/ScannerLegacy.swift" "$ROOT_DIR/Tests/Smoke/SnapshotLegacy.swift")
  [[ "$name" == MoveDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/MoveLegacy.swift")
  [[ "$name" == DuplicatesDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/DuplicatesLegacy.swift" "$ROOT_DIR/Tests/Smoke/TestSupport.swift")
  [[ "$name" == PresentationDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/PresentationLegacy.swift" "$ROOT_DIR/Tests/Smoke/TestSupport.swift")
  [[ "$name" == TextRulesDifferentialSmoke ]] && extra=("$ROOT_DIR/Tests/Smoke/LegacyText.swift" "$ROOT_DIR/Tests/Smoke/TestSupport.swift")
  xcrun swiftc \
    -emit-executable \
    -parse-as-library \
    -O \
    -swift-version 6 \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -sdk "$SDK_PATH" \
    -target "$ARCH-apple-macosx14.0" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Foundation \
    -framework Combine \
    -framework Security \
    -Xlinker -weak_framework -Xlinker FoundationModels \
    -import-objc-header "$ROOT_DIR/Sources/Generated/DiskBloom-Bridging.h" \
    -Xcc -Wno-parentheses-equality \
    "$BUILD_DIR/t27_specs.o" \
    "${APP_SOURCES[@]}" \
    "${extra[@]}" \
    "$ROOT_DIR/Tests/Smoke/$name.swift" \
    -o "$BUILD_DIR/$name"
}

for NAME in ScannerRegressionSmoke SafetySmoke AppRemovalSmoke OrphanLeftoversSmoke DuplicateFinderSmoke CacheExplorerSmoke CacheVerdictDifferentialSmoke DeletionPolicyDifferentialSmoke UninstallerDifferentialSmoke LeftoversDifferentialSmoke TextRulesDifferentialSmoke ScannerDifferentialSmoke MoveDifferentialSmoke DuplicatesDifferentialSmoke PresentationDifferentialSmoke; do
  print "== building $NAME"
  build_test "$NAME"
done

/bin/mkdir -p "$FIXTURES/scanner" "$FIXTURES/safety-root" "$FIXTURES/safety-mutation/Candidate" "$FIXTURES/app-removal" "$FIXTURES/orphans" "$FIXTURES/caches" "$FIXTURES/deletion-policy" "$FIXTURES/uninstaller" "$FIXTURES/leftovers" "$FIXTURES/text" "$FIXTURES/scanner-diff" "$FIXTURES/move" "$FIXTURES/duplicates"
print "child fixture" > "$FIXTURES/safety-root/child.txt"
print "candidate state" > "$FIXTURES/safety-mutation/Candidate/state.txt"

print "== t27 specs"
for SPEC_HEADER in "$ROOT_DIR"/Sources/Generated/*.api.h(N); do
  SPEC="${SPEC_HEADER:t:r:r}"
  /bin/cp "$ROOT_DIR/Sources/Generated/$SPEC.h" "$BUILD_DIR/$SPEC-spec-test.c"
  xcrun clang -std=c11 -ffp-contract=off -Wall -Wno-parentheses-equality -Werror -DT27_TEST_MAIN \
    -isysroot "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
    "$BUILD_DIR/$SPEC-spec-test.c" -o "$BUILD_DIR/$SPEC-spec-test"
  print -n "$SPEC: "
  /usr/bin/arch -"$ARCH" "$BUILD_DIR/$SPEC-spec-test"
done

print "== running ($ARCH)"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/ScannerRegressionSmoke" "$FIXTURES/scanner"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/SafetySmoke" "$FIXTURES/safety-root" "$FIXTURES/safety-mutation"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/AppRemovalSmoke" "$FIXTURES/app-removal"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/OrphanLeftoversSmoke" "$FIXTURES/orphans"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/DuplicateFinderSmoke"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/CacheExplorerSmoke" "$FIXTURES/caches"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/CacheVerdictDifferentialSmoke"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/DeletionPolicyDifferentialSmoke" "$FIXTURES/deletion-policy"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/UninstallerDifferentialSmoke" "$FIXTURES/uninstaller"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/LeftoversDifferentialSmoke" "$FIXTURES/leftovers"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/TextRulesDifferentialSmoke" "$FIXTURES/text"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/ScannerDifferentialSmoke" "$FIXTURES/scanner-diff"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/MoveDifferentialSmoke" "$FIXTURES/move"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/DuplicatesDifferentialSmoke" "$FIXTURES/duplicates"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/PresentationDifferentialSmoke"
print "ALL_SMOKE_TESTS_PASSED ($ARCH)"
