#!/usr/bin/env bash
# Unit tests for the burn-rate segment helpers. Each function is pulled live
# from statusline.sh so the tests can never drift from the implementation.
#   bash test/test-burn.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
fail=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s — %s\n' "$1" "$2"; fail=1; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$2"; }

# Pull the helpers under test out of the real script.
eval "$(sed -n '/^to_epoch() {/,/^}/p'     "$SCRIPT")"
eval "$(sed -n '/^fmt_eta() {/,/^}/p'       "$SCRIPT")"
eval "$(sed -n '/^burn_sample() {/,/^}/p'   "$SCRIPT")"

# fmt_eta
fmt_eta 0;       eq "fmt_eta 0m"     "$_ETA" "0m"
fmt_eta 2820;    eq "fmt_eta 47m"    "$_ETA" "47m"
fmt_eta 7080;    eq "fmt_eta 1h58m"  "$_ETA" "1h58m"
fmt_eta 127800;  eq "fmt_eta 1d11h"  "$_ETA" "1d11h"

# burn_sample appends one row with the reset converted to epoch
BURN_FILE="$TMPD/burn.tsv"
burn_sample 1781794590 6 1781811000
eq "sample row" "$(cat "$BURN_FILE")" "$(printf '1781794590\t6\t1781811000')"

# empty pct → no-op (file unchanged)
burn_sample 1781794600 "" 1781811000
eq "sample empty-pct no-op" "$(wc -l < "$BURN_FILE" | tr -d ' ')" "1"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
