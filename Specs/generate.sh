#!/bin/zsh
# Regenerate the C that the app compiles from the t27 specs, and run every spec's own tests.
#   T27C=/path/to/t27c ./Specs/generate.sh
# The generated headers are committed, so building the app (build.sh, Xcode, App Store) never needs t27c.
# <spec>.h is the full output of t27c gen-c; <spec>.api.h is its constants and prototypes, for Swift.
# Specs/T27C_PIN names the gHashTag/t27 revision the committed headers were generated with.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
T27C="${T27C:-$HOME/Documents/t27-diskbloom/target/release/t27c}"
OUT="$ROOT_DIR/Sources/Generated"
WORK="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf -- "$WORK"' EXIT
[[ -x "$T27C" ]] || { print -u2 "t27c not found: set T27C"; exit 2; }
/bin/mkdir -p "$OUT"
# Byte tables are written into their specs from readable lists first.
for TABLES in "$ROOT_DIR"/Specs/tables/*.py; do /usr/bin/python3 "$TABLES" >/dev/null; done

for SPEC in "$ROOT_DIR"/Specs/*.t27; do
  NAME="${SPEC:t:r}"
  "$T27C" check "$SPEC" >/dev/null
  "$T27C" gen-c "$SPEC" > "$WORK/$NAME.h"
  /bin/cp "$WORK/$NAME.h" "$WORK/$NAME-test.c"
  xcrun clang -std=c11 -ffp-contract=off -Wall -Wno-parentheses-equality -Werror -DT27_TEST_MAIN \
    "$WORK/$NAME-test.c" -o "$WORK/$NAME-test"
  print -n "$NAME: "
  "$WORK/$NAME-test"
  /usr/bin/cmp -s "$WORK/$NAME.h" "$OUT/$NAME.h" || /bin/cp "$WORK/$NAME.h" "$OUT/$NAME.h"
  # Swift compiles any function body it sees in a header, so Swift gets only the constants and
  # the prototypes; the bodies are compiled once from Sources/Generated/t27_specs.c.
  /usr/bin/awk '
    /^   Function implementations/ { print "/* Function bodies: see the full header. */"; print "#endif"; exit }
    { if (held != "") print held; held = $0 }
  ' "$WORK/$NAME.h" > "$WORK/$NAME.api.h"
  /usr/bin/cmp -s "$WORK/$NAME.api.h" "$OUT/$NAME.api.h" || /bin/cp "$WORK/$NAME.api.h" "$OUT/$NAME.api.h"
done
# The Swift bridging header and the single C file that compiles the bodies list every spec.
{
  print "// Decisions written in t27 (Specs/*.t27), compiled to C by t27c. Regenerate with Specs/generate.sh."
  for SPEC in "$ROOT_DIR"/Specs/*.t27; do print "#include \"${SPEC:t:r}.api.h\""; done
} > "$WORK/DiskBloom-Bridging.h"
{
  print "// Emits the function bodies of the generated t27 headers once, for Swift to link against."
  for SPEC in "$ROOT_DIR"/Specs/*.t27; do print "#include \"${SPEC:t:r}.h\""; done
} > "$WORK/t27_specs.c"
for FILE in DiskBloom-Bridging.h t27_specs.c; do
  /usr/bin/cmp -s "$WORK/$FILE" "$OUT/$FILE" || /bin/cp "$WORK/$FILE" "$OUT/$FILE"
done
print "generated into $OUT"
