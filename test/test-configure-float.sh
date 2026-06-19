#!/usr/bin/env bash
# Verifies write_candidate_config persists VL_FLOAT / VL_FLOAT_SEGMENTS.
# Extracts the live functions from configure.sh so the test cannot drift.
#   bash test/test-configure-float.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"
fail=0

# Pull the three pure functions out of configure.sh.
eval "$(sed -n '/^shell_quote() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_assign() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_candidate_config() {/,/^}/p' "$CONF")"

# Minimal globals write_candidate_config reads.
theme="claude-coral" ; style="pill" ; layout="auto" ; max_lines=3
segments="ctx cost" ; segments2="" ; segments3=""
clock_mode="12h" ; clock_seconds=1 ; name_max=0 ; ascii_mode=0
lean_sep="" ; extra_config=""
float_enabled=1 ; float_segments="ctx limit5h limit7d cost"
runtime_theme_dir() { printf '/tmp/themes'; }

out=$(mktemp "${TMPDIR:-/tmp}/coralline-cfg-test.XXXXXX") || exit 1
trap 'rm -f "$out"' EXIT
write_candidate_config "$out"

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }
grep -q '^VL_FLOAT=1' "$out"            && check "VL_FLOAT=1 written" 1          || check "VL_FLOAT=1 written" 0
grep -q '^VL_FLOAT_SEGMENTS=' "$out"    && check "VL_FLOAT_SEGMENTS written" 1   || check "VL_FLOAT_SEGMENTS written" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
