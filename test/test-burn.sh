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

# missing parent dir → created on demand, sample still written (issue #17 bug)
BURN_FILE="$TMPD/nodir/burn.tsv"
burn_sample 1781794590 6 1781811000
eq "sample creates missing dir" "$(cat "$BURN_FILE" 2>/dev/null)" "$(printf '1781794590\t6\t1781811000')"

eval "$(sed -n '/^burn_eta_5h() {/,/^}/p' "$SCRIPT")"
CORALLINE_BURN_WINDOW=600
BURN_TRIM=1500

# rl_sample / rl_latest: directory-as-set high-water store (cross-session limit sync).
# Entry = <reset:%010d>_<pct:%07.3f> dir; read = max; gc = drop below-max. So pct
# reads back fixed-width (e.g. 034.000), which display (%.0f) and burn (awk +0) parse.
eval "$(sed -n '/^rl_dir() {/,/^}/p'    "$SCRIPT")"
eval "$(sed -n '/^rl_sample() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^rl_latest() {/,/^}/p' "$SCRIPT")"
RLF="$TMPD/limit.tsv"
# mixed windows: current window = latest reset (2000), its max pct = 34. pct 51
# belongs to an OLDER window (reset 1500) and must not win.
rl_sample "$RLF" 10 1000; rl_sample "$RLF" 34 2000; rl_sample "$RLF" 31 2000
rl_sample "$RLF" 9 2000;  rl_sample "$RLF" 51 1500
rl_latest "$RLF"
eq "rl_latest pct" "$_LL_PCT" "034.000"
eq "rl_latest rst" "$_LL_RST" "2000"
# same-window cache-lag: highest pct wins regardless of insertion order
rm -rf "$TMPD/limit.d"
rl_sample "$RLF" 40 2000; rl_sample "$RLF" 44 2000; rl_sample "$RLF" 41 2000
rl_latest "$RLF"; eq "rl_latest same-window max" "$_LL_PCT" "044.000"
# fractional pct preserved (not quantized to an integer)
rm -rf "$TMPD/limit.d"
rl_sample "$RLF" 41.2 2000
rl_latest "$RLF"; eq "rl_latest float pct" "$_LL_PCT" "041.200"
# missing store → empty (caller falls back to the session's own snapshot)
rl_latest "$TMPD/none.tsv"; eq "rl_latest missing" "$_LL_PCT" ""
# a brand-new window (later reset, lower pct) supersedes the old high-water
rm -rf "$TMPD/limit.d"
rl_sample "$RLF" 80 2000; rl_sample "$RLF" 3 9000
rl_latest "$RLF"; eq "rl_latest new window pct" "$_LL_PCT" "003.000"
eq "rl_latest new window rst" "$_LL_RST" "9000"
# leading-zero reset must decode as decimal, not octal (10# guard)
rm -rf "$TMPD/limit.d"
rl_sample "$RLF" 5 8; rl_latest "$RLF"; eq "rl_latest octal-safe rst" "$_LL_RST" "8"
# gc keeps only the current-window high-water entry after a read
rm -rf "$TMPD/limit.d"
rl_sample "$RLF" 50 2000; rl_sample "$RLF" 48 2000; rl_sample "$RLF" 47 2000
rl_latest "$RLF"
eq "rl_latest gc keeps one" "$(ls -1 "$TMPD/limit.d" | wc -l | tr -d ' ')" "1"
rl_latest "$RLF"; eq "rl_latest gc keeps max" "$_LL_PCT" "050.000"
# migration: a legacy flat-file store is removed when the dir-set is first created
rm -rf "$TMPD/limit.d"; printf 'x' > "$TMPD/limit.tsv"
rl_sample "$RLF" 12 2000
eq "rl legacy flat-file removed" "$([ -e "$TMPD/limit.tsv" ] && echo present || echo gone)" "gone"
eq "rl dir-set created"          "$([ -d "$TMPD/limit.d" ]  && echo yes || echo no)" "yes"

# sentinel guard (#32): a far-future reset (e.g. sample-input.json's year-2030
# preview value) must be dropped when NOW is known, so a preview render can never
# win the high-water and prune the real window. NOW is set for these cases only.
RLS="$TMPD/limit-sentinel.tsv"; NOW=1781794590        # cutoff = NOW + 8d
rl_sample "$RLS" 30 1781811000                        # real ~4.5h window: kept
rl_sample "$RLS" 99 1893490200                        # 2030 sentinel: dropped
rl_latest "$RLS"
eq "rl_sample drops sentinel pct" "$_LL_PCT" "030.000"
eq "rl_sample drops sentinel rst" "$_LL_RST" "1781811000"
# burn_sample applies the same bound, keyed off its own now ($1)
BURN_FILE="$TMPD/burn-sentinel.tsv"
burn_sample 1781794590 50 1781811000                  # real window: appended
burn_sample 1781794590 99 1893490200                  # 2030 sentinel: dropped
eq "burn_sample drops sentinel" "$([ -f "$BURN_FILE" ] && wc -l < "$BURN_FILE" | tr -d ' ' || echo 0)" "1"
NOW=""

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

# cross-window isolation: a shared file where an idle session's stale snapshots
# (50,51 / older reset 1500000) are interleaved with the current window
# (6,7,8 / later reset 2000000). The estimate must use ONLY the current window —
# pre-fix the mixed series mis-fit; now it fits the real 6→7→8 slope.
# crossings (current window): (1000120,7),(1000300,8) → rate=1/180 %/s
# now pct=8 → ETA=(100-8)*180=16560s
run5h "1000000\t6\t2000000\n1000060\t50\t1500000\n1000120\t7\t2000000\n1000180\t51\t1500000\n1000300\t8\t2000000\n1000360\t8\t2000000\n" 1000360
eq "5h cross-window state" "$_B5_STATE" "active"
eq "5h cross-window eta"   "$_B5_ETA"   "16560"
eq "5h cross-window ttr"   "$_B5_TTR"   "999640"

# same-window jitter: concurrent sessions' caches disagree by a point or two, so
# pct dips mid-window (13→12) though usage only ever rises. A decrease used to
# reset `start` to the tail and fit the slope over the last 1-2 samples (1s apart)
# → bogus ~1m ETA. Now the fit is anchored at the window start and spans the
# first→last crossing: (1000150,11)→(1000400,16) = 5%/250s, lp=16 → ETA=84/0.02=4200.
run5h "1000050\t10\t2000000\n1000150\t11\t2000000\n1000380\t13\t2000000\n1000398\t12\t2000000\n1000399\t14\t2000000\n1000400\t16\t2000000\n" 1000400
eq "5h jitter state" "$_B5_STATE" "active"
eq "5h jitter eta"   "$_B5_ETA"   "4200"
eq "5h jitter ttr"   "$_B5_TTR"   "999600"

# min-span guard: a tiny late burst (two crossings 2s apart, nothing earlier in
# window) is too short to trust → warming, not a wild fast ETA.
run5h "1000000\t9\t2000000\n1000398\t10\t2000000\n1000400\t11\t2000000\n" 1000400
eq "5h short-span guard" "$_B5_STATE" "warming"

# but a genuine fast burn that spans more than the guard (win/10=60s) must show,
# not be hidden as warming: 1→5→9→10 over 90s. fc=(1000010,5) lc=(1000100,10),
# span=90s ≥ 60s → rate=5/90, lp=10 → ETA=90/(5/90)=1620.
run5h "1000000\t1\t2000000\n1000010\t5\t2000000\n1000070\t9\t2000000\n1000100\t10\t2000000\n" 1000100
eq "5h fast-burn shows state" "$_B5_STATE" "active"
eq "5h fast-burn shows eta"   "$_B5_ETA"   "1620"

# trim: 5 rows, trim=3 → file keeps last 3
BURN_TRIM=3
run5h "1\t6\t9\n2\t6\t9\n3\t7\t9\n4\t7\t9\n5\t8\t9\n" 6
eq "5h trim rowcount" "$(wc -l < "$TMPD/b5.tsv" | tr -d ' ')" "3"
eq "5h trim first-kept" "$(head -1 "$TMPD/b5.tsv" | cut -f1)" "3"
# trim on PHYSICAL rows: 6 same-second rows (only 2 distinct seconds) with trim=3
# must still trim — a distinct-second cap would never fire and the file would grow.
BURN_TRIM=3
run5h "1\t6\t9\n1\t6\t9\n1\t6\t9\n2\t7\t9\n2\t7\t9\n2\t7\t9\n" 3
eq "5h trim same-second rows" "$(wc -l < "$TMPD/b5.tsv" | tr -d ' ')" "2"
BURN_TRIM=1500

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
VL_BURN_GLYPH="↗"; VL_BG_BURN=""; VL_BG_5H=237; VL_LAYOUT="fixed"
VL_FG_OK=114; VL_FG_WARN=179; VL_FG_HOT=167; VL_FG_DIM=245
VL_NOCOLOR=0   # fg()/push() reference it (statusline default); set under `set -u`
VL_LIMIT_SYNC=0   # burn_estimate branches on it (statusline default); set under `set -u`
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

# render: all-good ✓ is window-absolute — 7d binding with eta 24d15h > the 7d window
# (you couldn't empty even a full window at this pace) → bright-green ✓, no number.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=inf M5R=0 M5T=0  M7E=2127600 M7R=0 M7T=3600
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *"↗ ✓"*) ok "render all-good 7d check" ;; *) bad "render all-good 7d check" "got=${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *"⇢"*) bad "all-good drops countdown" "got=${SEG_TXT[0]}" ;; *) ok "all-good drops countdown" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;114m'*) ok "all-good OK colour" ;; *) bad "all-good OK colour" "no OK fg in ${SEG_TXT[0]}" ;; esac

# the window is per-label: 5h binding with eta 20000s (> the 5h/18000s window) → ✓ too
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=20000 M5R=0 M5T=600  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *"↗ ✓"*) ok "render all-good 5h check" ;; *) bad "render all-good 5h check" "got=${SEG_TXT[0]}" ;; esac

# regression: eta 4h50m is *under* the 5h window, so it must NOT collapse to ✓ — it
# shows the number, coloured green here (comfortable vs reset: eta 17400 > 1.25·ttr 7200).
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=17400 M5R=0 M5T=7200  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *"↗ 5h ⇢ 4h50m"*) ok "render green number" ;; *) bad "render green number" "got=${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *"✓"*) bad "under-window keeps number" "got=${SEG_TXT[0]}" ;; *) ok "under-window keeps number" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;114m'*) ok "green number OK colour" ;; *) bad "green number OK colour" "no OK fg in ${SEG_TXT[0]}" ;; esac

# render: active 5h binding, eta 5m ≤ ttr 10m → you empty before reset → HOT colour,
# and the actionable countdown number is kept.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=300 M5R=0 M5T=600  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *$'\033[38;5;167m'*) ok "render HOT colour" ;; *) bad "render HOT colour" "no HOT fg in ${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *"⇢ "*) ok "HOT keeps countdown" ;; *) bad "HOT keeps countdown" "got=${SEG_TXT[0]}" ;; esac

# render: idle → dim all-good ✓ (not burning), no dash placeholder
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=idle M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *"↗ ✓"*) ok "render idle check" ;; *) bad "render idle check" "got=${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;245m'*) ok "render idle dim" ;; *) bad "render idle dim" "no DIM fg in ${SEG_TXT[0]}" ;; esac

# render: active 5h binding, eta 1000s, ttr 900s → ratio 0.9 ∈ [0.8,1) → WARN colour,
# and the countdown number is kept (only the green band collapses to ✓).
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=active M5E=1000 M5R=0 M5T=900  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *$'\033[38;5;179m'*) ok "render WARN colour" ;; *) bad "render WARN colour" "no WARN fg in ${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *"⇢ "*) ok "WARN keeps countdown" ;; *) bad "WARN keeps countdown" "got=${SEG_TXT[0]}" ;; esac

# render: warming (cold start, no data) → dim ↗ … — a distinct "no data yet" mark,
# NOT the ✓ that idle/all-good use, so a fresh install doesn't look healthy-green.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=warming M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
burn_estimate
seg_burn
case "${SEG_TXT[0]}" in *"↗ …"*) ok "render warming check" ;; *) bad "render warming check" "got=${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in *"✓"*) bad "warming is not ✓" "got=${SEG_TXT[0]}" ;; *) ok "warming is not ✓" ;; esac
case "${SEG_TXT[0]}" in *$'\033[38;5;245m'*) ok "render warming dim" ;; *) bad "render warming dim" "no DIM fg in ${SEG_TXT[0]}" ;; esac

# contract: seg_burn renders a PRECOMPUTED estimate and must NOT recompute. The
# stubs say warming, but the precomputed _BURN_* says active/5h — seg_burn has to
# honour the globals (burn_estimate is hoisted to run once per render, upstream of
# seg_burn, so float and visible passes share one computation).
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
M5S=warming M5E=inf M5R=0 M5T=0  M7E=inf M7R=0 M7T=0
_BURN_STATE=active _BURN_LABEL=5h _BURN_ETA=1000 _BURN_RATE=0 _BURN_TTR=900
seg_burn
case "${SEG_TXT[0]}" in *"↗ 5h ⇢ "*) ok "seg_burn renders precomputed estimate" ;; *) bad "seg_burn renders precomputed estimate" "got=${SEG_TXT[0]}" ;; esac

# tie-break: equal ETAs (5000s) → 5h wins via -le comparison
M5S=active M5E=5000 M5R=0 M5T=9000  M7E=5000 M7R=0 M7T=9000
burn_estimate
eq "tie→5h"            "$_BURN_LABEL" "5h"

# guard: neither limit reported → segment renders nothing
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct="" wd_pct=""
seg_burn
eq "neither-reported renders nothing" "${#SEG_TXT[@]}" "0"

# ── integration: the sampler runs iff `burn` is in the segment list (issue #17) ─
# Drives the whole statusline.sh so the top-level gate is exercised end to end.
if command -v jq >/dev/null 2>&1; then
  gate_run() {  # $1=VL_SEGMENTS → "written" if a sample landed, else "absent"
    local conf="$TMPD/conf.sh" bf="$TMPD/gate/burn.tsv" in="$TMPD/gate-input.json" soon
    rm -rf "$TMPD/gate"
    printf 'VL_SEGMENTS=%q\n' "$1" > "$conf"
    # Give the fixture a plausible near-future reset (raw epoch; to_epoch accepts
    # it) so the sentinel guard (#32) doesn't correctly drop the sample and mask
    # the gate under test. The bundled sample-input.json keeps its 2030 sentinel.
    soon=$(( $(date +%s) + 10800 ))
    jq --arg r "$soon" \
       '.rate_limits.five_hour.resets_at=$r | .rate_limits.seven_day.resets_at=$r' \
       "$HERE/sample-input.json" > "$in"
    CORALLINE_CONFIG="$conf" CORALLINE_BURN_FILE="$bf" \
      bash "$SCRIPT" < "$in" >/dev/null 2>&1
    [ -f "$bf" ] && echo written || echo absent
  }
  eq "gate: burn listed → samples"    "$(gate_run 'dir burn clock')" "written"
  eq "gate: burn absent → no samples" "$(gate_run 'dir clock')"      "absent"
else
  ok "gate integration (skipped: no jq)"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
