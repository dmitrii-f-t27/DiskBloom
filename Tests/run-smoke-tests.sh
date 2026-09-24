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
cleanup() { [[ -d "$FIXTURES" && "$FIXTURES" == "$BUILD_DIR"/fixtures-* ]] && /bin/rm -r -- "$FIXTURES"; }
trap cleanup EXIT

/bin/mkdir -p "$BUILD_DIR"
/bin/rm -rf -- "$FIXTURES"
APP_SOURCES=("$ROOT_DIR"/Sources/*.swift)
APP_SOURCES=(${APP_SOURCES:#*/DiskBloomApp.swift})

build_test() {
  local name="$1"
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
    "${APP_SOURCES[@]}" \
    "$ROOT_DIR/Tests/Smoke/$name.swift" \
    -o "$BUILD_DIR/$name"
}

for NAME in ScannerRegressionSmoke SafetySmoke AppRemovalSmoke OrphanLeftoversSmoke DuplicateFinderSmoke; do
  print "== building $NAME"
  build_test "$NAME"
done

/bin/mkdir -p "$FIXTURES/scanner" "$FIXTURES/safety-root" "$FIXTURES/safety-mutation/Candidate" "$FIXTURES/app-removal" "$FIXTURES/orphans"
print "child fixture" > "$FIXTURES/safety-root/child.txt"
print "candidate state" > "$FIXTURES/safety-mutation/Candidate/state.txt"

print "== running ($ARCH)"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/ScannerRegressionSmoke" "$FIXTURES/scanner"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/SafetySmoke" "$FIXTURES/safety-root" "$FIXTURES/safety-mutation"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/AppRemovalSmoke" "$FIXTURES/app-removal"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/OrphanLeftoversSmoke" "$FIXTURES/orphans"
/usr/bin/arch -"$ARCH" "$BUILD_DIR/DuplicateFinderSmoke"
print "ALL_SMOKE_TESTS_PASSED ($ARCH)"
