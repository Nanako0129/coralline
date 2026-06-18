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

eval "$(sed -n '/^burn_eta_5h() {/,/^}/p' "$SCRIPT")"
CORALLINE_BURN_WINDOW=600
VL_BURN_TRIM=1500

# helper: write a fixture and run the estimator at a given "now"
run5h() { BURN_FILE="$TMPD/b5.tsv"; printf '%b' "$1" > "$BURN_FILE"; NOW="$2"; burn_eta_5h; }

# active: 6→7 at +60s, 7→8 at +300s; now=+360s; reset 4h25m out.
# crossings in window: (60,7),(300,8) → rate=(8-7)/(300-60)=1/240 %/s
# now pct=8 → ETA=(100-8)/(1/240)=22080s=6h08m
RST=$(( 1000000 + 18000 ))     # window opened at t=1000000-? use reset far ahead
run5h "1000000\t6\t1015900\n1000060\t7\t1015900\n1000300\t8\t1015900\n1000360\t8\t1015900\n" 1000360
eq "5h active state" "$_B5_STATE" "active"
eq "5h active eta"   "$_B5_ETA"   "22080"
eq "5h ttr"          "$_B5_TTR"   "15540"

# idle: only crossing is older than the 600s window (at +0s); now=+1200s
run5h "1000000\t6\t1015900\n1000010\t7\t1015900\n1001200\t7\t1015900\n" 1001200
eq "5h idle state" "$_B5_STATE" "idle"
eq "5h idle eta"   "$_B5_ETA"   "inf"

# warming: a single crossing, in window
run5h "1000000\t6\t1015900\n1000060\t7\t1015900\n" 1000100
eq "5h warming state" "$_B5_STATE" "warming"
eq "5h warming eta"   "$_B5_ETA"   "inf"

# reset: pct drops mid-file → pre-drop discarded, then only one crossing → warming
run5h "1000000\t80\t1004000\n1000060\t81\t1004000\n1000120\t1\t1019000\n1000180\t2\t1019000\n" 1000200
eq "5h reset→warming" "$_B5_STATE" "warming"

# empty file → warming/inf
run5h "" 1000000
eq "5h empty state" "$_B5_STATE" "warming"
eq "5h empty eta"   "$_B5_ETA"   "inf"

# trim: 5 rows, trim=3 → file keeps last 3
VL_BURN_TRIM=3
run5h "1\t6\t9\n2\t6\t9\n3\t7\t9\n4\t7\t9\n5\t8\t9\n" 6
eq "5h trim rowcount" "$(wc -l < "$TMPD/b5.tsv" | tr -d ' ')" "3"
eq "5h trim first-kept" "$(head -1 "$TMPD/b5.tsv" | cut -f1)" "3"
VL_BURN_TRIM=1500

eval "$(sed -n '/^burn_eta_7d() {/,/^}/p' "$SCRIPT")"

# 7d: used 30%, window opened 3 days ago (elapsed=259200s), reset 4 days out.
# rate=30/259200 %/s; ETA=(100-30)/rate=70*259200/30=604800s=7d00h
WS=$(( 1000000 - 259200 )); R7=$(( WS + 604800 ))
wd_pct=30; wd_rst=$R7; NOW=1000000; burn_eta_7d
eq "7d eta"  "$_B7_ETA" "604800"
eq "7d ttr"  "$_B7_TTR" "345600"

# 7d unused → inf
wd_pct=0; wd_rst=$R7; NOW=1000000; burn_eta_7d
eq "7d unused eta" "$_B7_ETA" "inf"

# 7d not reported → inf
wd_pct=""; wd_rst=""; NOW=1000000; burn_eta_7d
eq "7d empty eta" "$_B7_ETA" "inf"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
