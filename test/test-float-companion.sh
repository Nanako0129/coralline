#!/usr/bin/env bash
# Verifies coralline-float emits the correct SetUserVar OSC for a fresh float.txt
# and clears the bar when float.txt is stale.
#   bash test/test-float-companion.sh
# Needs bash + base64.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
COMPANION="$HERE/../coralline-float"
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-companion-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
floatf="$tmpdir/float.txt"
out="$tmpdir/tty.out"

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fi; [ "$2" = "1" ] || fail=1; }

# --- Fresh file → emits OSC with base64 of its content ---
printf 'ctx 62%%\n' > "$floatf"   # %% → literal %
b64=$(printf '%s' 'ctx 62%' | base64 | tr -d '\n')
printf '\033]1337;SetUserVar=coralline=%s\007' "$b64" > "$tmpdir/expect.fresh"

CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" \
  CORALLINE_FLOAT_STALE=5 bash "$COMPANION" --once

if cmp -s "$out" "$tmpdir/expect.fresh"; then check "fresh emits correct OSC" 1; else check "fresh emits correct OSC" 0; fi

# --- Stale file → clears the bar (empty value) ---
touch -t 200001010000 "$floatf"   # mtime in the year 2000 → stale
printf '\033]1337;SetUserVar=coralline=%s\007' "" > "$tmpdir/expect.clear"

CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" \
  CORALLINE_FLOAT_STALE=5 bash "$COMPANION" --once

if cmp -s "$out" "$tmpdir/expect.clear"; then check "stale clears the bar" 1; else check "stale clears the bar" 0; fi

# --- Missing file → clears the bar ---
rm -f "$floatf"
CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" bash "$COMPANION" --once
if cmp -s "$out" "$tmpdir/expect.clear"; then check "missing clears the bar" 1; else check "missing clears the bar" 0; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
