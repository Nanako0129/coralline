#!/usr/bin/env bash
# Verifies VL_STATE=1 makes statusline.sh emit a valid state.json with raw fields.
#   bash test/test-state.sh
# Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
SAMPLE="$HERE/sample-input.json"
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-state-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
conf="$tmpdir/c.conf"
statef="$tmpdir/state.json"

cat > "$conf" <<EOF
VL_STATE=1
VL_STATE_FILE="$statef"
EOF

CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$SAMPLE" >/dev/null

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

[ -f "$statef" ]; check "state.json created" "$([ -f "$statef" ] && echo 1 || echo 0)"
jq -e . "$statef" >/dev/null 2>&1; check "valid JSON" "$([ $? -eq 0 ] && echo 1 || echo 0)"
[ "$(jq -r '.ctx_pct' "$statef" 2>/dev/null)" = "62.4" ]; check "ctx_pct=62.4" "$([ "$(jq -r '.ctx_pct' "$statef" 2>/dev/null)" = "62.4" ] && echo 1 || echo 0)"
[ "$(jq -r '.fh_pct' "$statef" 2>/dev/null)" = "41.2" ]; check "fh_pct=41.2" "$([ "$(jq -r '.fh_pct' "$statef" 2>/dev/null)" = "41.2" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
