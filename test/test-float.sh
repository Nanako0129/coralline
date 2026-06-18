#!/usr/bin/env bash
# Verifies VL_FLOAT=1 makes statusline.sh emit a plain-text float.txt
# containing the expected segments and NO ANSI escape bytes.
#   bash test/test-float.sh
# Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
SAMPLE="$HERE/sample-input.json"
ESC=$'\033'
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-float-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
conf="$tmpdir/c.conf"
floatf="$tmpdir/float.txt"

cat > "$conf" <<EOF
VL_FLOAT=1
VL_FLOAT_FILE="$floatf"
VL_FLOAT_SEGMENTS="ctx limit5h limit7d cost"
EOF

CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$SAMPLE" >/dev/null

check() {  # $1=description ; $2=1 if pass
  if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi
}

[ -f "$floatf" ]; check "float.txt created" "$([ -f "$floatf" ] && echo 1 || echo 0)"

# No ESC bytes anywhere in the file.
if LC_ALL=C grep -q "$ESC" "$floatf"; then check "no ANSI escapes" 0; else check "no ANSI escapes" 1; fi

# Expected rendered tokens (ctx 62%, 5h 41%, 7d 79%, cost $1.23).
grep -q '62%' "$floatf"        && check "ctx 62%"  1 || check "ctx 62%"  0
grep -q '41%' "$floatf"        && check "5h 41%"   1 || check "5h 41%"   0
grep -q '79%' "$floatf"        && check "7d 79%"   1 || check "7d 79%"   0
grep -qF '$1.23' "$floatf"     && check "cost"     1 || check "cost"     0

# Exactly one line.
lines=$(wc -l < "$floatf" | tr -d ' ')
[ "$lines" = "1" ]; check "single line (got $lines)" "$([ "$lines" = "1" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
