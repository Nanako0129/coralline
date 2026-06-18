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

eval "$(sed -n '/^fg() {/,/^}/p'            "$SCRIPT")"
eval "$(sed -n '/^push() {/,/^}/p'          "$SCRIPT")"
eval "$(sed -n '/^burn_estimate() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_burn() {/,/^}/p'      "$SCRIPT")"
VL_BURN_GLYPH="↗"; VL_BURN_SHOWRATE=0; VL_BG_BURN=""; VL_BG_5H=237; VL_LAYOUT="fixed"
VL_FG_OK=114; VL_FG_WARN=179; VL_FG_HOT=167; VL_FG_DIM=245
fh_pct=8 wd_pct=0

# stub the two estimators so binding logic is tested in isolation
mk5h() { _B5_STATE="$1"; _B5_ETA="$2"; _B5_RATE="$3"; _B5_TTR="$4"; }
mk7d() {                 _B7_ETA="$1"; _B7_RATE="$2"; _B7_TTR="$3"; }
burn_eta_5h() { mk5h "$M5S" "$M5E" "$M5R" "$M5T"; }
burn_eta_7d() { mk7d "$M7E" "$M7R" "$M7T"; }

# 5h roomy (eta 6h), 7d binding (eta 2h) → label 7d
M5S=active M5E=21600 M5R=0 M5T=15000  M7E=7200 M7R=0 M7T=86400
burn_estimate
eq "binding label 7d"  "$_BURN_LABEL" "7d"
eq "binding eta 7d"    "$_BURN_ETA"   "7200"

# 5h binding (eta 1h) vs 7d (eta 10h) → label 5h
M5S=active M5E=3600 M5R=0 M5T=9000  M7E=36000 M7R=0 M7T=200000
burn_estimate
eq "binding label 5h"  "$_BURN_LABEL" "5h"

# 5h idle + 7d unused → idle, no label
M5S=idle M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
burn_estimate
eq "binding idle"      "$_BURN_STATE" "idle"
eq "binding idle nolabel" "$_BURN_LABEL" ""

# render: active 7d binding, eta 2h, ttr 1h → ratio ttr/eta=0.5 (<0.8) → OK colour;
# 5h roomy (eta 6h) so 7d wins. Contains ↗7d and ⇢2h00m.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=21600 M5R=0 M5T=15000  M7E=7200 M7R=0 M7T=3600
seg_burn
case "${SEG_TXT[0]}" in *"↗7d"*"⇢2h00m"*) ok "render active 7d" ;; *) bad "render active 7d" "got=${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;114m'*) ok "render OK colour" ;; *) bad "render OK colour" "no OK fg in ${SEG_TXT[0]}" ;; esac

# render: active 5h binding, eta 5m ≤ ttr 10m → you empty before reset → HOT colour
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=300 M5R=0 M5T=600  M7E=inf M7R=0 M7T=0
seg_burn
case "${SEG_TXT[0]}" in *$'\033[38;5;167m'*) ok "render HOT colour" ;; *) bad "render HOT colour" "no HOT fg in ${SEG_TXT[0]}" ;; esac

# render: idle → dim, contains ⇢—
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=idle M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
seg_burn
case "${SEG_TXT[0]}" in *"⇢—"*$'\033'*|*$'\033'*"⇢—"*) ok "render idle dash" ;; *) bad "render idle dash" "got=${SEG_TXT[0]}" ;; esac

# render: active 5h binding, eta 1000s, ttr 900s → ratio 0.9 ∈ [0.8,1) → WARN colour
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=1000 M5R=0 M5T=900  M7E=inf M7R=0 M7T=0
seg_burn
case "${SEG_TXT[0]}" in *$'\033[38;5;179m'*) ok "render WARN colour" ;; *) bad "render WARN colour" "no WARN fg in ${SEG_TXT[0]}" ;; esac

# render: warming state → dim, contains ⇢…
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=warming M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
seg_burn
case "${SEG_TXT[0]}" in *"⇢…"*$'\033'*|*$'\033'*"⇢…"*) ok "render warming" ;; *) bad "render warming" "got=${SEG_TXT[0]}" ;; esac

# tie-break: equal ETAs (5000s) → 5h wins via -le comparison
M5S=active M5E=5000 M5R=0 M5T=9000  M7E=5000 M7R=0 M7T=9000
burn_estimate
eq "tie→5h"            "$_BURN_LABEL" "5h"

# VL_BURN_SHOWRATE=1: 5h-binding active case; rate 0.008 %/s × 600 = 4.8%/10m
VL_BURN_SHOWRATE=1
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=21600 M5R=0.008 M5T=99999  M7E=inf M7R=0 M7T=0
fh_pct=8 wd_pct=0
seg_burn
case "${SEG_TXT[0]}" in *"%/10m"*) ok "showrate %/10m label" ;; *) bad "showrate %/10m label" "got=${SEG_TXT[0]}" ;; esac
VL_BURN_SHOWRATE=0

# guard: neither limit reported → segment renders nothing
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct="" wd_pct=""
seg_burn
eq "neither-reported renders nothing" "${#SEG_TXT[@]}" "0"

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
