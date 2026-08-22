#!/usr/bin/env bash
# Mutable Bash burn / limit state regressions. Helpers are extracted live from
# statusline.sh so validation, estimators, and trust-boundary checks cannot drift.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
case "$(uname -s)" in Darwin) TEST_TMP=/private/tmp ;; *) TEST_TMP=${TMPDIR:-/tmp} ;; esac
TMPD=$(mktemp -d "$TEST_TMP/coralline-burn.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT HUP INT TERM
fail=0
pass=0
ok() { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$2"; }
true_case() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "condition failed"; fi; }
file_bytes() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else printf '0\n'; fi; }
entry_count() {
  _COUNT=0
  [ -d "$1" ] || return 0
  for _CE in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$_CE" ] || [ -L "$_CE" ] || continue
    _COUNT=$(( _COUNT + 1 ))
  done
}
snapshot_tree() {
  local path="$1" archive="$2" parent base
  parent=${path%/*}; base=${path##*/}; [ -n "$parent" ] || parent=/
  (cd "$parent" && COPYFILE_DISABLE=1 LC_ALL=C tar -cf "$archive" "$base") 2>/dev/null
}
old_mtimes() { find "$1" -exec touch -t 202001010000 {} + 2>/dev/null; }

# Pull production implementations. Every extracted function closes at column 0.
eval "$(sed -n '/^iso_epoch() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^to_epoch() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^fmt_eta() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^state_pct() {/,/^seg_burn() {/p' "$SCRIPT" | sed '$d')"
eval "$(sed -n '/^fg() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^push() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_burn() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^make_bar() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^pct_fg() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^fmt_countdown() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_limit() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_limit_elapsed() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_limit5h() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_limit7d() {/,/^}/p' "$SCRIPT")"

RL_MAX_5H=21600
RL_MAX_7D=691200
CORALLINE_BURN_WINDOW=600
BURN_TRIM=1500
BURN_SLACK=0
VL_LIMIT_SYNC=0
CORALLINE_NO_SAMPLE=0
BASH_BIN=${BASH:-bash}

# Strict payload canonicalization. Oversized input is rejected before regex or arithmetic.
pct_case() {
  if state_pct "$2"; then eq "$1 milli" "$_SP_MILLI" "$3"; eq "$1 canonical" "$_SP_CANON" "$4"
  else bad "$1" "unexpected rejection"; fi
}
pct_reject() { if state_pct "$2"; then bad "$1" "accepted as $_SP_CANON"; else ok "$1"; fi; }
pct_case 'pct zero' '0' 0 '000.000'
pct_case 'pct integer' '41' 41000 '041.000'
pct_case 'pct midpoint even' '1.2345' 1234 '001.234'
pct_case 'pct midpoint odd' '1.2355' 1236 '001.236'
pct_case 'pct carry to 100' '99.9995' 100000 '100.000'
for _BAD_PCT in -0 00 01 +1 ' 1' '1 ' 100.000001 101 1,2 1e2 NaN Infinity 1.1234567 .5 12345678901; do
  pct_reject "pct rejects $_BAD_PCT" "$_BAD_PCT"
done
printf -v _LONG_PCT '%5000s' ''; _LONG_PCT=${_LONG_PCT// /9}
pct_reject 'pct rejects oversized printable value' "$_LONG_PCT"

state_epoch 0 12; eq 'epoch zero' "$_SE_PAD" '000000000000'
state_epoch 253402300799 12; eq 'epoch max' "$_SE_VALUE" '253402300799'
state_epoch 9999999999 10; eq 'limit epoch max' "$_SE_PAD" '9999999999'
for _BAD_EP in -0 +1 01 1.0 253402300800 10000000000 9999999999999; do
  if state_epoch "$_BAD_EP" 10; then bad "epoch rejects $_BAD_EP" "accepted $_SE_PAD"; else ok "epoch rejects $_BAD_EP"; fi
done
state_payload_epoch '2026-07-31T12:34:56Z' 10 && ok 'canonical ISO epoch accepted' || bad 'canonical ISO epoch accepted' rejected
for _BAD_ISO in '2026-07-31 12:34:56Z' '2026-07-31T12:34:56+00:00' '2026-07-31T12:34:56.1234567Z'; do
  if state_payload_epoch "$_BAD_ISO" 10; then bad "ISO rejects $_BAD_ISO" accepted; else ok "ISO rejects $_BAD_ISO"; fi
done

state_round_even 5 2; eq 'round-even 2.5 to even' "$_RE" 2
state_round_even 7 2; eq 'round-even 3.5 to even' "$_RE" 4
state_rate10 10000000000 3; eq 'rate non-divisible' "$_RATE10" '0.3333333333'
state_rate10 19999999999 2; eq 'rate rounding carry' "$_RATE10" '1.0000000000'

# Lexical path normalization and strict limit basename parsing stay fork-free.
_PWD_SAVE=$PWD
cd "$TMPD"
state_store_path relative.tsv; eq 'relative store root' "$_SS_ROOT" "$TMPD/relative.d"
state_store_path C:/tmp/state.tsv; eq 'native drive store root' "$_SS_ROOT" '/c/tmp/state.d'
state_store_path 'C:\tmp\state.tsv'; eq 'backslash drive store root' "$_SS_ROOT" '/c/tmp/state.d'
cd "$_PWD_SAVE"
state_limit_name '0001015900_041.200'; eq 'limit name reset' "$_SLN_RST" 1015900; eq 'limit name pct' "$_SLN_PCT" 41200
for _BAD_NAME in '1015900_041.200' '0001015900_41.200' '0001015900_101.000' '0001015900_041.200x' '1+1_041.200' 'x[$(touch${IFS}pwn)]_041.200'; do
  if state_limit_name "$_BAD_NAME" 2>/dev/null; then bad "limit name rejects $_BAD_NAME" accepted; else ok "limit name rejects $_BAD_NAME"; fi
done

true_case 'same-path exact' state_same_path "$TMPD/missing" "$TMPD/missing"
mkdir -p "$TMPD/same-object"
true_case 'same-path filesystem identity' state_same_path "$TMPD/same-object" "$TMPD/same-object/."
_NCM_WAS=0; shopt -q nocasematch && _NCM_WAS=1
shopt -u nocasematch
state_same_path "$TMPD/Missing" "$TMPD/missing" >/dev/null 2>&1 || true
if shopt -q nocasematch; then bad 'same-path restores disabled nocasematch' 'left enabled'; else ok 'same-path restores disabled nocasematch'; fi
shopt -s nocasematch
state_same_path "$TMPD/Missing" "$TMPD/missing" >/dev/null 2>&1 || true
if shopt -q nocasematch; then ok 'same-path preserves enabled nocasematch'; else bad 'same-path preserves enabled nocasematch' 'left disabled'; fi
[ "$_NCM_WAS" = 1 ] || shopt -u nocasematch

unit_gate() {  # $1=root $2=now $3=5h pct $4=5h reset $5=7d pct $6=7d reset $7=read-only
  local root="$1"
  NOW="$2"; fh_pct="$3"; fh_rst="$4"; wd_pct="$5"; wd_rst="$6"; CORALLINE_NO_SAMPLE="$7"
  BURN_FILE="$root/burn.tsv"; RL5H_FILE="$root/limit5.tsv"; RL7D_FILE="$root/limit7.tsv"
  _STATE_BURN_GATE=1; _STATE_RL5_GATE=1; _STATE_RL7_GATE=1
  VL_LIMIT_SYNC=1; CORALLINE_BURN_WINDOW=600; BURN_TRIM=1500; BURN_SLACK=0
  state_gate
}

# Canonical TSV writes remain readable by the native PowerShell legacy parser.
CASE="$TMPD/sample"; mkdir -p "$CASE"
unit_gate "$CASE" 1000000 41.2 1015900 30 1345600 0
burn_sample "$_CUR_BURN_SAMP" "$_CUR_BURN_TSV" "$_CUR_BURN_RST"
IFS= read -r _ROW < "$CASE/burn.tsv"
eq 'burn sample canonical TSV row' "$_ROW" $'1000000\t41.200\t1015900'
eq 'burn sample appended once' "$_BURN_APPENDED" 1

run5h() {  # $1=fixture $2=now $3=mutate
  local root="$TMPD/run5h" trim="$BURN_TRIM" slack="$BURN_SLACK"
  rm -rf "$root"; mkdir -p "$root"
  unit_gate "$root" "$2" '' '' '' '' 1
  BURN_TRIM=$trim; BURN_SLACK=$slack
  printf '%b' "$1" > "$BURN_FILE"
  _CUR_BURN_VALID=0
  burn_eta_5h "$3"
}

# Released 5h estimator behavior: active, warming, idle, reset isolation, fractions, jitter.
run5h '1000000\t6\t1015900\n1000060\t7\t1015900\n1000300\t8\t1015900\n1000360\t8\t1015900\n' 1000360 0
eq '5h active state' "$_B5_STATE" active
eq '5h active eta' "$_B5_ETA" 22080
eq '5h active rate' "$_B5_RATE" '0.0041666667'
eq '5h active ttr' "$_B5_TTR" 15540

run5h '1000000\t6.125\t1015900\n1000060\t7.125\t1015900\n1000300\t8.125\t1015900\n1000360\t8.125\t1015900\n' 1000360 0
eq '5h fractional pct exact eta' "$_B5_ETA" 22050

run5h '1000000\t6\t1015900\n1000060\t6.500\t1015900\n1000060\t7\t1015900\n1000300\t8\t1015900\n1000360\t8\t1015900\n' 1000360 0
eq 'same-second maximum keeps slope' "$_B5_ETA" 22080

run5h '1000000\t6\t1015900\n1000300\t8\t1015900\n1000060\t7\t1015900\n1000360\t8\t1015900\n' 1000360 0
eq 'out-of-order appends sort before slope' "$_B5_ETA" 22080

run5h '1000000\t6\t1015900\n1000060\t50\t1010000\n1000120\t7\t1015900\n1000180\t51\t1010000\n1000300\t8\t1015900\n1000360\t8\t1015900\n' 1000360 0
eq 'latest reset isolates old windows' "$_B5_ETA" 16560

run5h '1000050\t10\t1015900\n1000150\t11\t1015900\n1000380\t13\t1015900\n1000398\t12\t1015900\n1000399\t14\t1015900\n1000400\t16\t1015900\n' 1000400 0
eq 'cache-lag jitter stays bounded' "$_B5_ETA" 4200

run5h '1000000\t6\t1015900\n1000010\t7\t1015900\n1001200\t7\t1015900\n' 1001200 0
eq '5h idle state' "$_B5_STATE" idle
run5h '1000000\t6\t1015900\n1000060\t7\t1015900\n' 1000100 0
eq '5h warming state' "$_B5_STATE" warming
run5h '1000000\t80\t1004000\n1000060\t81\t1004000\n1000120\t1\t1019000\n1000180\t2\t1019000\n' 1000200 0
eq '5h reset rollover warms' "$_B5_STATE" warming

# Sentinel healing and physical-row trim occur only when mutation is allowed.
run5h '1000000\t6\t1015900\n1000060\t7\t1015900\n1000300\t8\t1015900\n9999000\t99\t99999999\n' 1000360 1
eq 'burn sentinel ignored for estimate' "$_B5_ETA" 22080
if grep -q 99999999 "$BURN_FILE"; then bad 'burn sentinel healed on mutable read' present; else ok 'burn sentinel healed on mutable read'; fi

BURN_TRIM=3
run5h '1\t6\t9\n2\t6\t9\n3\t7\t9\n4\t7\t9\n5\t8\t9\n' 6 1
eq '5h trim physical rowcount' "$(wc -l < "$BURN_FILE" | tr -d ' ')" 3
IFS=$'\t' read -r _FIRST _ _ < "$BURN_FILE"; eq '5h trim first kept' "$_FIRST" 3
BURN_TRIM=3
run5h '1\t6\t9\n1\t6.100\t9\n1\t6.200\t9\n2\t7\t9\n2\t7.100\t9\n2\t7.200\t9\n' 3 1
eq 'resize burst collapses same-second rows' "$(wc -l < "$BURN_FILE" | tr -d ' ')" 2

CASE="$TMPD/stale-tmp"; mkdir -p "$CASE"
unit_gate "$CASE" 6 '' '' '' '' 1
printf '1\t6\t9\n2\t7\t9\n3\t8\t9\n4\t9\t9\n' > "$BURN_FILE"
printf 'stale-canary\n' > "$BURN_FILE.$$.tmp"
cp "$BURN_FILE" "$CASE/before"; _CUR_BURN_VALID=0; BURN_TRIM=3; burn_eta_5h 1
if cmp -s "$BURN_FILE" "$CASE/before"; then ok 'pre-existing temp never replaces history'; else bad 'pre-existing temp never replaces history' changed; fi
eq 'pre-existing temp remains untouched' "$(LC_ALL=C tr -d '\n' < "$BURN_FILE.$$.tmp")" stale-canary
BURN_TRIM=1500

# Stateless 7d estimator keeps exact rational semantics.
NOW=1000000
burn_eta_7d 30000 1345600
eq '7d exact eta' "$_B7_ETA" 604800
eq '7d exact rate' "$_B7_RATE" '0.0001157407'
eq '7d ttr' "$_B7_TTR" 345600
burn_eta_7d 0 1345600; eq '7d zero pct is infinite' "$_B7_ETA" inf

# Compact limit directory high-water: reset first, pct second, malformed entries ignored.
CASE="$TMPD/highwater"; mkdir -p "$CASE"
unit_gate "$CASE" 1000000 15 1015900 30 1345600 0
mkdir -p "$_SL5_ROOT/0001015800_090.000" "$_SL5_ROOT/0001015900_010.000" "$_SL5_ROOT/0001015900_020.000"
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0
eq 'limit high-water pct' "$_LL_PCT" '020.000'
eq 'limit high-water reset' "$_LL_RST" 1015900
# Own window, own reading. The store used to win on a higher pct for the same
# reset, which pinned the recorded maximum for the rest of the window whenever the
# percentage legitimately dropped (upstream reset, plan upgrade).
rl_choose 5; eq 'own reading beats a higher stored pct' "$_STATE_RL5_PCT" 15000
eq 'own reading keeps its own reset' "$_STATE_RL5_RST" 1015900
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 1
entry_count "$_SL5_ROOT"; eq 'limit mutable GC keeps winner' "$_COUNT" 1

# A drop inside one window is followed, and the store still wins when it holds a
# newer window than this session has caught up to.
rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/0001015900_090.000"
_CUR5_VALID=1; _CUR5_RST=1015900; _CUR5_PCT=5000
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0; rl_choose 5
eq 'pct drop inside one window is followed' "$_STATE_RL5_PCT" 5000

rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/0001016900_007.000"
_CUR5_VALID=1; _CUR5_RST=1015900; _CUR5_PCT=90000
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0; rl_choose 5
eq 'newer stored window beats an older own reading' "$_STATE_RL5_PCT" 7000
eq 'newer stored window carries its reset' "$_STATE_RL5_RST" 1016900

rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/0001015900_042.000"
_CUR5_VALID=0; _CUR5_RST=0; _CUR5_PCT=0
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0; rl_choose 5
eq 'store is the sole source without an own reading' "$_STATE_RL5_PCT" 42000
_CUR5_VALID=1; _CUR5_RST=1015900; _CUR5_PCT=15000

rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/0001015900_041.200"
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0; eq 'limit fractional pct preserved' "$_LL_PCT" '041.200'

rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/0001015800_090.000"
_CUR5_VALID=1; _CUR5_RST=1015900; _CUR5_PCT=3000
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0; rl_choose 5
eq 'newer reset supersedes old high pct' "$_STATE_RL5_PCT" 3000

rm -rf "$_SL5_ROOT"; mkdir -p "$_SL5_ROOT/9999999999_099.000" "$_SL5_ROOT/0001015900_030.000"
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0
eq 'limit sentinel ignored read-only' "$_LL_PCT" '030.000'
true_case 'limit sentinel preserved read-only' test -d "$_SL5_ROOT/9999999999_099.000"
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 1
true_case 'limit sentinel healed when mutable' test ! -e "$_SL5_ROOT/9999999999_099.000"

# Runtime helpers.
if ! command -v jq >/dev/null 2>&1; then
  bad 'jq prerequisite' missing
  printf 'SUMMARY pass=%s fail=%s\n' "$pass" "$fail"
  exit 1
fi
make_payload() {  # $1=path $2=p5 $3=r5 $4=p7 $5=r7
  jq -n --arg p5 "$2" --arg r5 "$3" --arg p7 "$4" --arg r7 "$5" \
    '{workspace:{current_dir:"/tmp"},rate_limits:{five_hour:{used_percentage:$p5,resets_at:$r5},seven_day:{used_percentage:$p7,resets_at:$r7}}}' > "$1"
}
write_config() {  # $1=path $2=root $3=segments $4=sync $5=trim(optional)
  {
    printf 'VL_SEGMENTS=%q\n' "$3"
    printf '%s\n' 'VL_CLOCK=off' 'VL_STYLE=lean' 'VL_NOCOLOR=1' 'VL_BURN_GLYPH=B'
    printf 'VL_LIMIT_SYNC=%q\n' "$4"
    printf 'BURN_FILE=%q\n' "$2/burn.tsv"
    printf 'RL5H_FILE=%q\n' "$2/limit5.tsv"
    printf 'RL7D_FILE=%q\n' "$2/limit7.tsv"
    [ -z "${5:-}" ] || printf 'BURN_TRIM=%q\n' "$5"
  } > "$1"
}
write_paths_config() {  # $1=path $2=segments $3=sync $4=burn $5=rl5 $6=rl7 $7=trim(optional)
  {
    printf 'VL_SEGMENTS=%q\n' "$2"
    printf '%s\n' 'VL_CLOCK=off' 'VL_STYLE=lean' 'VL_NOCOLOR=1' 'VL_BURN_GLYPH=B'
    printf 'VL_LIMIT_SYNC=%q\n' "$3"
    printf 'BURN_FILE=%q\n' "$4"
    printf 'RL5H_FILE=%q\n' "$5"
    printf 'RL7D_FILE=%q\n' "$6"
    [ -z "${7:-}" ] || printf 'BURN_TRIM=%q\n' "$7"
  } > "$1"
}
run_runtime() {  # $1=shell/runtime $2=config $3=input $4=stdout $5=stderr $6=no-sample
  if [ "$6" = 1 ]; then
    CORALLINE_CONFIG="$2" CORALLINE_NO_SAMPLE=1 "$1" "$SCRIPT" < "$3" > "$4" 2> "$5"
  else
    CORALLINE_CONFIG="$2" CORALLINE_NO_SAMPLE=0 "$1" "$SCRIPT" < "$3" > "$4" 2> "$5"
  fi
}
run_runtime_cwd() {  # $1=cwd, remaining args match run_runtime
  local cwd="$1"; shift
  (cd "$cwd" && run_runtime "$@")
}

# Strict no-sample: oversized/dirty TSV, orphan tmp, immutable burn.d, limit GC
# candidates, and every mtime remain byte-for-byte unchanged. A mutable clone
# computes the same visible result while performing its allowed maintenance.
CASE="$TMPD/no-sample"; STATE="$CASE/state"; MUT="$CASE/mutable"; mkdir -p "$STATE/burn.d" "$STATE/limit5.d" "$STATE/limit7.d"
_now=$(date +%s); _r5=$((_now + 15930)); _r7=$((_now + 345630))
_i=0; while [ "$_i" -lt 1502 ]; do printf '%s\t8\t%s\n' $((_now - 1501 + _i)) "$_r5" >> "$STATE/burn.tsv"; _i=$((_i + 1)); done
printf '%s\t99\t9999999999\n' "$_now" >> "$STATE/burn.tsv"
printf 'orphan-canary' > "$STATE/burn.tsv.123.tmp"
printf 'immutable-canary' > "$STATE/burn.d/b_000000000001_000000000001_001.000_0000"
mkdir -p "$STATE/limit5.d/$(printf '%010d_020.000' "$_r5")" "$STATE/limit5.d/9999999999_099.000" "$STATE/limit5.d/not-state"
mkdir -p "$STATE/limit7.d/$(printf '%010d_030.000' "$_r7")" "$STATE/limit7.d/9999999999_099.000" "$STATE/limit7.d/not-state"
cp -R "$STATE" "$MUT"
old_mtimes "$STATE"
write_config "$CASE/read.conf" "$STATE" 'burn limit5h limit7d' 1
write_config "$CASE/mut.conf" "$MUT" 'burn limit5h limit7d' 1
make_payload "$CASE/input" 8 "$_r5" 30 "$_r7"
snapshot_tree "$STATE" "$CASE/before.tar"
run_runtime "$BASH_BIN" "$CASE/read.conf" "$CASE/input" "$CASE/read.out" "$CASE/read.err" 1; _RC=$?
snapshot_tree "$STATE" "$CASE/after.tar"
run_runtime "$BASH_BIN" "$CASE/mut.conf" "$CASE/input" "$CASE/mut.out" "$CASE/mut.err" 0; _MRC=$?
eq 'no-sample runtime exits zero' "$_RC" 0
eq 'mutable reference exits zero' "$_MRC" 0
if cmp -s "$CASE/before.tar" "$CASE/after.tar"; then ok 'no-sample full tree contents and mtimes unchanged'; else bad 'no-sample full tree contents and mtimes unchanged' changed; fi
if cmp -s "$CASE/read.out" "$CASE/mut.out"; then ok 'no-sample output matches mutable reference'; else bad 'no-sample output matches mutable reference' differs; fi
eq 'no-sample stderr empty' "$(file_bytes "$CASE/read.err")" 0

CASE="$TMPD/no-sample-missing"; mkdir -p "$CASE/parent"
write_config "$CASE/conf" "$CASE/parent/state" 'burn limit5h limit7d' 1
make_payload "$CASE/input" 8 "$_r5" 30 "$_r7"
old_mtimes "$CASE/parent"; snapshot_tree "$CASE/parent" "$CASE/before.tar"
run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 1
snapshot_tree "$CASE/parent" "$CASE/after.tar"
if cmp -s "$CASE/before.tar" "$CASE/after.tar"; then ok 'no-sample absent roots and parent mtime unchanged'; else bad 'no-sample absent roots and parent mtime unchanged' changed; fi

# Malformed, over-width, scientific, negative, >100, and oversized payload values
# never create state. The next valid render recovers immediately.
_invalid_pct=(-1 1e2 101 100.000001 0001 .5 12345678901 "$_LONG_PCT")
_idx=0
for _VALUE in "${_invalid_pct[@]}"; do
  CASE="$TMPD/invalid-pct-$_idx"; mkdir -p "$CASE"
  write_config "$CASE/conf" "$CASE/state" 'burn limit5h' 1
  _now=$(date +%s); _r5=$((_now + 15930)); make_payload "$CASE/bad.json" "$_VALUE" "$_r5" '' ''
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/bad.json" "$CASE/bad.out" "$CASE/bad.err" 0
  true_case "invalid pct $_idx creates no state" test ! -e "$CASE/state"
  eq "invalid pct $_idx stderr empty" "$(file_bytes "$CASE/bad.err")" 0
  make_payload "$CASE/good.json" 41.2 "$_r5" '' ''
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/good.json" "$CASE/good.out" "$CASE/good.err" 0
  true_case "invalid pct $_idx recovers next render" test -s "$CASE/state/burn.tsv"
  _idx=$((_idx + 1))
done
_invalid_rst=(-1 1e2 01 10000000000 9999999999999 '2026-07-31T12:34:56+00:00')
_idx=0
for _VALUE in "${_invalid_rst[@]}"; do
  CASE="$TMPD/invalid-rst-$_idx"; mkdir -p "$CASE"
  write_config "$CASE/conf" "$CASE/state" 'burn limit5h' 1
  make_payload "$CASE/bad.json" 41.2 "$_VALUE" '' ''
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/bad.json" "$CASE/bad.out" "$CASE/bad.err" 0
  true_case "invalid reset $_idx creates no state" test ! -e "$CASE/state"
  _now=$(date +%s); _r5=$((_now + 15930)); make_payload "$CASE/good.json" 41.2 "$_r5" '' ''
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/good.json" "$CASE/good.out" "$CASE/good.err" 0
  true_case "invalid reset $_idx recovers next render" test -s "$CASE/state/burn.tsv"
  _idx=$((_idx + 1))
done

# Path collision, relative alias, conservative case alias, symlink base/ancestor,
# and symlink limit-root canaries all fail soft without mutation.
_now=$(date +%s); _r5=$((_now + 15930)); _r7=$((_now + 345630))
CASE="$TMPD/path-exact"; mkdir -p "$CASE"; printf 'exact-canary' > "$CASE/shared.tsv"
write_paths_config "$CASE/conf" 'burn limit5h' 1 "$CASE/shared.tsv" "$CASE/shared.tsv" "$CASE/limit7.tsv"
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
cp "$CASE/shared.tsv" "$CASE/before"; run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
if cmp -s "$CASE/shared.tsv" "$CASE/before"; then ok 'exact path collision preserves canary'; else bad 'exact path collision preserves canary' changed; fi

CASE="$TMPD/path-relative"; mkdir -p "$CASE/a"; printf 'relative-canary' > "$CASE/shared.tsv"
write_paths_config "$CASE/conf" 'burn limit5h' 1 "$CASE/a/../shared.tsv" "$CASE/shared.tsv" "$CASE/limit7.tsv"
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
cp "$CASE/shared.tsv" "$CASE/before"; run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
if cmp -s "$CASE/shared.tsv" "$CASE/before"; then ok 'relative alias collision preserves canary'; else bad 'relative alias collision preserves canary' changed; fi

CASE="$TMPD/path-case"; mkdir -p "$CASE/State"; printf 'case-canary' > "$CASE/State/burn.tsv"
write_paths_config "$CASE/conf" 'burn limit5h' 1 "$CASE/State/burn.tsv" "$CASE/state/burn.tsv" "$CASE/limit7.tsv"
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
cp "$CASE/State/burn.tsv" "$CASE/before"; run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
case "${OSTYPE:-}" in
  (darwin*|mingw*|msys*)
    if cmp -s "$CASE/State/burn.tsv" "$CASE/before"; then ok 'case alias collision preserves canary'; else bad 'case alias collision preserves canary' changed; fi
    ;;
  (*)
    if cmp -s "$CASE/State/burn.tsv" "$CASE/before"; then bad 'case-sensitive distinct paths remain usable' unchanged; else ok 'case-sensitive distinct paths remain usable'; fi
    ;;
esac

CASE="$TMPD/path-link"; mkdir -p "$CASE/target"; printf 'ancestor-canary' > "$CASE/target/canary"
if ln -s "$CASE/target" "$CASE/link" 2>/dev/null; then
  write_paths_config "$CASE/conf" 'burn limit5h' 1 "$CASE/link/burn.tsv" "$CASE/limit5.tsv" "$CASE/limit7.tsv"
  make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
  eq 'symlink ancestor canary unchanged' "$(LC_ALL=C tr -d '\n' < "$CASE/target/canary")" ancestor-canary
  true_case 'symlink ancestor receives no state' test ! -e "$CASE/target/burn.tsv"
else ok 'symlink ancestor fixture unavailable'; fi

CASE="$TMPD/path-file-link"; mkdir -p "$CASE"; printf 'file-canary' > "$CASE/target.tsv"
if ln -s "$CASE/target.tsv" "$CASE/burn.tsv" 2>/dev/null; then
  write_paths_config "$CASE/conf" burn 0 "$CASE/burn.tsv" "$CASE/limit5.tsv" "$CASE/limit7.tsv"
  make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
  eq 'symlink file target unchanged' "$(LC_ALL=C tr -d '\n' < "$CASE/target.tsv")" file-canary
else ok 'symlink file fixture unavailable'; fi

CASE="$TMPD/path-limit-link"; mkdir -p "$CASE/target"; printf 'limit-canary' > "$CASE/target/canary"
if ln -s "$CASE/target" "$CASE/limit5.d" 2>/dev/null; then
  write_config "$CASE/conf" "$CASE" 'limit5h' 1
  make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
  run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
  eq 'symlink limit target unchanged' "$(LC_ALL=C tr -d '\n' < "$CASE/target/canary")" limit-canary
else ok 'symlink limit fixture unavailable'; fi

# Existing immutable burn.d and unrelated temp canaries are never touched.
CASE="$TMPD/coexist"; mkdir -p "$CASE/state/burn.d"; printf 'immutable' > "$CASE/state/burn.d/canary"
write_config "$CASE/conf" "$CASE/state" burn 0 3
# Slack would let the file sit above trim between rewrites; pin it off so the
# repeated-render bound below stays exact.
printf 'BURN_SLACK=0\n' >> "$CASE/conf"
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
snapshot_tree "$CASE/state/burn.d" "$CASE/before.tar"
run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0
snapshot_tree "$CASE/state/burn.d" "$CASE/after.tar"
if cmp -s "$CASE/before.tar" "$CASE/after.tar"; then ok 'immutable burn.d stays untouched'; else bad 'immutable burn.d stays untouched' changed; fi
printf 'tmp-canary' > "$CASE/state/burn.tsv.keep.tmp"
_i=0; while [ "$_i" -lt 8 ]; do run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out.$_i" "$CASE/err.$_i" 0; _i=$((_i + 1)); done
eq 'unrelated temp canary preserved' "$(LC_ALL=C tr -d '\n' < "$CASE/state/burn.tsv.keep.tmp")" tmp-canary
[ "$(wc -l < "$CASE/state/burn.tsv" | tr -d ' ')" -le 3 ] && ok 'repeated render TSV remains trimmed' || bad 'repeated render TSV remains trimmed' "rows=$(wc -l < "$CASE/state/burn.tsv")"

# Malformed arithmetic/metacharacter basenames and nonempty canonical-looking
# directories never displace the valid winner, emit stderr, or trigger side effects.
CASE="$TMPD/arithmetic"; mkdir -p "$CASE/state/limit5.d"
_now=$(date +%s); _winner=$((_now + 200)); _later=$((_now + 300))
printf -v _WINNER '%010d_020.000' "$_winner"; printf -v _NONEMPTY '%010d_099.000' "$_later"
mkdir -p "$CASE/state/limit5.d/$_WINNER" "$CASE/state/limit5.d/$_NONEMPTY"
printf 'child' > "$CASE/state/limit5.d/$_NONEMPTY/canary"
_META1='x[$(touch${IFS}ARITH_PWN)]_099.000'
_META2='1+1_099.000'
_META3='0000000001_099.000]||touch${IFS}ARITH_PWN||x['
mkdir -p "$CASE/state/limit5.d/$_META1" "$CASE/state/limit5.d/$_META2" "$CASE/state/limit5.d/$_META3"
write_config "$CASE/conf" "$CASE/state" limit5h 1
make_payload "$CASE/input" 15 "$_winner" '' ''
run_runtime_cwd "$CASE" "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0; _RC=$?
eq 'malformed basename runtime exits zero' "$_RC" 0
eq 'malformed basename stderr empty' "$(file_bytes "$CASE/err")" 0
true_case 'arithmetic basename creates no side effect' test ! -e "$CASE/ARITH_PWN"
true_case 'metachar basename one preserved' test -d "$CASE/state/limit5.d/$_META1"
true_case 'metachar basename two preserved' test -d "$CASE/state/limit5.d/$_META2"
true_case 'metachar basename three preserved' test -d "$CASE/state/limit5.d/$_META3"
true_case 'nonempty canonical-looking entry preserved' test -f "$CASE/state/limit5.d/$_NONEMPTY/canary"
if LC_ALL=C grep -q '15%' "$CASE/out"; then ok 'own reading wins its own window'; else bad 'own reading wins its own window' "output=$(LC_ALL=C tr '\n' ' ' < "$CASE/out")"; fi
if LC_ALL=C grep -q '99%' "$CASE/out"; then bad 'malformed names never reach the bar' "output=$(LC_ALL=C tr '\n' ' ' < "$CASE/out")"; else ok 'malformed names never reach the bar'; fi
# Without a reading of its own the session falls back to the store, which is the
# only source that knows the account's open window. rl_latest admits an entry only
# while its reset is still ahead, so the borrowed value cannot be a fossil, and the
# malformed neighbours must still never reach the bar.
make_payload "$CASE/blank" '' '' '' ''
run_runtime_cwd "$CASE" "$BASH_BIN" "$CASE/conf" "$CASE/blank" "$CASE/blank.out" "$CASE/blank.err" 0
if LC_ALL=C grep -q '20%' "$CASE/blank.out"; then ok 'no own reading falls back to the store'; else bad 'no own reading falls back to the store' "output=$(LC_ALL=C tr '\n' ' ' < "$CASE/blank.out")"; fi
if LC_ALL=C grep -q '99%' "$CASE/blank.out"; then bad 'store fallback never shows a malformed entry' "output=$(LC_ALL=C tr '\n' ' ' < "$CASE/blank.out")"; else ok 'store fallback never shows a malformed entry'; fi
eq 'no own reading keeps stderr empty' "$(file_bytes "$CASE/blank.err")" 0
unit_gate "$CASE/state" "$_now" 15 "$_winner" 30 "$_later" 1
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 0
eq 'malformed names do not displace canonical winner' "$_LL_PCT" '020.000'
eq 'malformed names do not displace canonical reset' "$_LL_RST" "$_winner"

# No immutable-controller tools remain on the state path. Wrappers would fail the
# render if find or od were invoked.
CASE="$TMPD/trace"; mkdir -p "$CASE/bin" "$CASE/state"; : > "$CASE/trace.log"
for _TOOL in find od; do
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s\n" "$0" >> "$CORALLINE_TRACE"'
    printf '%s\n' 'exit 97'
  } > "$CASE/bin/$_TOOL"
  chmod +x "$CASE/bin/$_TOOL"
done
write_config "$CASE/conf" "$CASE/state" 'burn limit5h limit7d' 1
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
CORALLINE_TRACE="$CASE/trace.log" PATH="$CASE/bin:$PATH" run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 0; _RC=$?
eq 'state trace exits zero without find or od' "$_RC" 0
eq 'state trace has no find or od calls' "$(file_bytes "$CASE/trace.log")" 0
eq 'state trace stderr empty' "$(file_bytes "$CASE/err")" 0
if grep -Eq 'state_scan|state_prepare|find -P|od -An' "$SCRIPT"; then bad 'immutable controller symbols removed' present; else ok 'immutable controller symbols removed'; fi

# State-disabled and subagent paths perform no state work.
CASE="$TMPD/gates"; mkdir -p "$CASE"
write_config "$CASE/disabled.conf" "$CASE/disabled-state" dir 1
make_payload "$CASE/input" 41.2 "$_r5" 30 "$_r7"
run_runtime "$BASH_BIN" "$CASE/disabled.conf" "$CASE/input" "$CASE/disabled.out" "$CASE/disabled.err" 0
true_case 'state-disabled runtime creates no state' test ! -e "$CASE/disabled-state"
printf '%s\n' '{"columns":80,"tasks":[]}' > "$CASE/subagent.json"
CORALLINE_CONFIG="$CASE/disabled.conf" "$BASH_BIN" "$SCRIPT" --subagent < "$CASE/subagent.json" > "$CASE/subagent.out" 2> "$CASE/subagent.err"
true_case 'subagent runtime creates no state' test ! -e "$CASE/disabled-state"

# Full-runtime concurrent correctness checker. Each worker performs two renders;
# every exit/stdout/stderr is accounted for against one fixed no-clock oracle.
run_concurrency() {  # $1=runtime $2=workers $3=tag
  local runtime="$1" workers="$2" tag="$3" root i j rc path
  local pids=()
  root="$TMPD/concurrency-$tag-$workers"
  rm -rf "$root"; mkdir -p "$root/state/burn.d" "$root/results"
  printf 'immutable-concurrency-canary' > "$root/state/burn.d/canary"
  write_config "$root/conf" "$root/state" burn 0
  local now reset
  now=$(date +%s); reset=$((now + 15930)); make_payload "$root/input" 10 "$reset" 0 "$((now + 345630))"
  printf '\033[0m B … \033[0m\n' > "$root/oracle"
  for ((i=0; i<workers; i++)); do
    (
      for j in 1 2; do
        path="$root/results/$i.$j"
        CORALLINE_CONFIG="$root/conf" CORALLINE_NO_SAMPLE=0 "$runtime" "$SCRIPT" < "$root/input" > "$path.out" 2> "$path.err"
        rc=$?
        printf '%s\n' "$rc" > "$path.rc"
      done
    ) &
    pids[${#pids[@]}]=$!
  done
  for i in "${pids[@]}"; do wait "$i" 2>/dev/null || true; done

  _CC_EXPECTED=$(( workers * 2 )); _CC_RCFILES=0; _CC_SUCCESS=0; _CC_NONZERO=0
  _CC_NONEMPTY=0; _CC_MATCH=0; _CC_STDERR_EMPTY=0
  for ((i=0; i<workers; i++)); do
    for j in 1 2; do
      path="$root/results/$i.$j"
      if [ -f "$path.rc" ]; then
        _CC_RCFILES=$(( _CC_RCFILES + 1 )); IFS= read -r rc < "$path.rc"
        if [ "$rc" = 0 ]; then _CC_SUCCESS=$(( _CC_SUCCESS + 1 )); else _CC_NONZERO=$(( _CC_NONZERO + 1 )); fi
      fi
      [ -s "$path.out" ] && _CC_NONEMPTY=$(( _CC_NONEMPTY + 1 ))
      cmp -s "$path.out" "$root/oracle" && _CC_MATCH=$(( _CC_MATCH + 1 ))
      [ ! -s "$path.err" ] && _CC_STDERR_EMPTY=$(( _CC_STDERR_EMPTY + 1 ))
    done
  done
  # Single-writer contract: the per-(second, window) election means N renders
  # in the same second persist ONE row, so the row count equals the number of
  # distinct (sample, reset) pairs -- never the render count -- and duplicates
  # are the failure signature of a broken election.
  _CC_ROWS=0; _CC_DUPES=0
  if [ -f "$root/state/burn.tsv" ]; then
    _CC_ROWS=$(wc -l < "$root/state/burn.tsv" | tr -d ' ')
    _CC_DUPES=$(LC_ALL=C awk -F '\t' '{k=$1 FS $3} seen[k]++ {d++} END{print d+0}' "$root/state/burn.tsv")
  fi
  _CC_IMMUTABLE=0
  [ "$(LC_ALL=C tr -d '\n' < "$root/state/burn.d/canary")" = immutable-concurrency-canary ] && _CC_IMMUTABLE=1
  # Winner-published estimate: present, regular, six validly-shaped fields;
  # and no orphaned publish temporaries once every render has exited.
  _CC_EST=0
  if [ -f "$root/state/burn.tsv.est" ] && [ ! -L "$root/state/burn.tsv.est" ]; then
    _E1=""; _E2=""; _E3=""; _E4=""; _E5=""; _E6=""; _E7=""; _E8=""
    read -r _E1 _E2 _E3 _E4 _E5 _E6 _E7 _E8 < "$root/state/burn.tsv.est" 2>/dev/null || :
    case "$_E1$_E2$_E4$_E5$_E6$_E7$_E8" in (''|*[!0-9]*) ;; (*)
      case "$_E3" in (active|idle|warming) _CC_EST=1 ;; esac ;; esac
  fi
  _CC_TMPS=$(ls "$root/state" 2>/dev/null | grep -c '\.tmp$')
  [ "$_CC_RCFILES" -eq "$_CC_EXPECTED" ] && [ "$_CC_SUCCESS" -eq "$_CC_EXPECTED" ] \
    && [ "$_CC_NONEMPTY" -eq "$_CC_EXPECTED" ] && [ "$_CC_MATCH" -eq "$_CC_EXPECTED" ] \
    && [ "$_CC_STDERR_EMPTY" -eq "$_CC_EXPECTED" ] \
    && [ "$_CC_ROWS" -ge 1 ] && [ "$_CC_ROWS" -le "$_CC_EXPECTED" ] && [ "$_CC_DUPES" -eq 0 ] \
    && [ "$_CC_EST" -eq 1 ] && [ "$_CC_TMPS" -eq 0 ] \
    && [ "$_CC_IMMUTABLE" -eq 1 ]
}

CASE="$TMPD/fake-runtime"; mkdir -p "$CASE"
printf '%s\n' '#!/usr/bin/env bash' 'exit 7' > "$CASE/fail.sh"; chmod +x "$CASE/fail.sh"
if run_concurrency "$CASE/fail.sh" 2 fake; then
  bad 'concurrency checker rejects nonzero runtime' 'false pass'
else
  eq 'fake runtime nonzero exits counted' "$_CC_NONZERO" 4
  ok 'concurrency checker rejects nonzero runtime'
fi

for _N in 5 12 16; do
  if run_concurrency "$BASH_BIN" "$_N" "bash-${BASH_VERSINFO[0]}"; then
    eq "concurrency n=$_N successes" "$_CC_SUCCESS" $((_N * 2))
    eq "concurrency n=$_N exact outputs" "$_CC_MATCH" $((_N * 2))
    eq "concurrency n=$_N stderr empty" "$_CC_STDERR_EMPTY" $((_N * 2))
    eq "concurrency n=$_N single writer per (second, window)" "$_CC_DUPES" 0
    ok "concurrency n=$_N TSV rows within [1, renders] ($_CC_ROWS)"
    eq "concurrency n=$_N estimate published and well-shaped" "$_CC_EST" 1
    eq "concurrency n=$_N no orphaned publish temporaries" "$_CC_TMPS" 0
    eq "concurrency n=$_N immutable store untouched" "$_CC_IMMUTABLE" 1
  else
    bad "concurrency n=$_N" "expected=$_CC_EXPECTED rcfiles=$_CC_RCFILES success=$_CC_SUCCESS nonempty=$_CC_NONEMPTY match=$_CC_MATCH stderr=$_CC_STDERR_EMPTY rows=$_CC_ROWS dupes=$_CC_DUPES est=$_CC_EST tmps=$_CC_TMPS immutable=$_CC_IMMUTABLE"
  fi
done

# A killed render leaves its trim temporary behind and nothing used to retire it.
# The sweep must take only what is unambiguously ours and unambiguously dead: an
# exactly <base>.<digits>.tmp name, a regular file, and older than the store it was
# derived from, since a temporary a live render is still writing is newer than the
# base it is about to replace.
CASE="$TMPD/tmpsweep"; mkdir -p "$CASE"
_SB_BASE="$CASE/burn.tsv"
printf 'x\n' > "$_SB_BASE.111.tmp"; printf 'x\n' > "$_SB_BASE.222.tmp"
printf 'x\n' > "$_SB_BASE.abc.tmp"; printf 'x\n' > "$_SB_BASE.333.bak"
ln -s /dev/null "$_SB_BASE.444.tmp"
sleep 1; printf 'row\n' > "$_SB_BASE"; sleep 1; printf 'live\n' > "$_SB_BASE.555.tmp"
burn_tmp_sweep
true_case 'sweep removes an orphaned temporary' test ! -e "$_SB_BASE.111.tmp"
true_case 'sweep removes every orphaned temporary' test ! -e "$_SB_BASE.222.tmp"
true_case 'sweep keeps a non-numeric name' test -f "$_SB_BASE.abc.tmp"
true_case 'sweep keeps a non-temporary suffix' test -f "$_SB_BASE.333.bak"
true_case 'sweep keeps a symlink' test -L "$_SB_BASE.444.tmp"
true_case 'sweep keeps a temporary newer than the store' test -f "$_SB_BASE.555.tmp"
true_case 'sweep leaves the store intact' test -s "$_SB_BASE"

# Trim hysteresis: at the cap, appends accumulate for BURN_SLACK rows before one
# render pays the rewrite; healing is never deferred by slack.
CASE="$TMPD/slack"; mkdir -p "$CASE"
unit_gate "$CASE" 6 '' '' '' '' 1
BURN_TRIM=3; BURN_SLACK=2
run5h '1\t6\t9\n2\t6\t9\n3\t7\t9\n4\t7\t9\n' 6 1
eq 'slack holds the rewrite below trim+slack' "$(wc -l < "$BURN_FILE" | tr -d ' ')" 4
run5h '1\t6\t9\n2\t6\t9\n3\t7\t9\n4\t7\t9\n5\t8\t9\n6\t8\t9\n' 7 1
eq 'past trim+slack rewrites down to trim' "$(wc -l < "$BURN_FILE" | tr -d ' ')" 3
run5h '1\t6\t9\n2\t7\t9\n9999000\t99\t99999999\n' 6 1
if grep -q 99999999 "$BURN_FILE"; then bad 'heal is not deferred by slack' present; else ok 'heal is not deferred by slack'; fi
BURN_TRIM=1500; BURN_SLACK=0

# Per-(second, window, pct) burn-write election. Tokens carry the store's own
# file name as prefix (provenance: a shared directory never gets foreign files
# deleted) and every touch around the claim re-runs the store's TOCTOU guards.
CASE="$TMPD/lead"; mkdir -p "$CASE"
unit_gate "$CASE" 1000000 41.2 1015900 '' '' 0
TOK="$CASE/burn.tsv.1000000.1015900.41200.tick"
_BURN_LEAD=
true_case 'lead: first claim wins' state_burn_lead
true_case 'lead: winning claim leaves a token' test -f "$TOK"
_BURN_LEAD=
if state_burn_lead; then bad 'lead: same-pct token loses' won; else ok 'lead: same-pct token loses'; fi
rm -f "$TOK"
: > "$CASE/burn.tsv.1000000.1015900.50000.tick"
_BURN_LEAD=
if state_burn_lead; then bad 'lead: higher-pct claim wins over ours' won; else ok 'lead: higher-pct claim wins over ours'; fi
rm -f "$CASE/burn.tsv.1000000.1015900.50000.tick"
: > "$CASE/burn.tsv.1000000.1015900.30000.tick"
_BURN_LEAD=
true_case 'lead: our higher reading beats a lower claim' state_burn_lead
true_case 'lead: divergent readings both leave tokens' test -f "$TOK"
rm -f "$CASE"/burn.tsv.*.tick
# Only a regular non-symlink file counts as a claim: a planted symlink or
# directory carrying a higher percentage must not make us lose (and must not
# mark the loss adoption-safe), because no live parse stands behind it.
ln -s /dev/null "$CASE/burn.tsv.1000000.1015900.70000.tick"
mkdir "$CASE/burn.tsv.1000000.1015900.80000.tick"
_BURN_LEAD=; _BURN_LOST=0
true_case 'lead: planted symlink claim does not win' state_burn_lead
eq 'lead: planted objects never mark an adoptable loss' "${_BURN_LOST:-0}" 0
rm -f "$CASE/burn.tsv.1000000.1015900.70000.tick"; rmdir "$CASE/burn.tsv.1000000.1015900.80000.tick"
rm -f "$CASE"/burn.tsv.*.tick
: > "$CASE/burn.tsv.1000000.1016000.41200.tick"
_BURN_LEAD=
true_case 'lead: same-second other-window token does not block' state_burn_lead
true_case 'lead: other-window token kept by the sweep' test -f "$CASE/burn.tsv.1000000.1016000.41200.tick"
rm -f "$CASE"/burn.tsv.*.tick
: > "$CASE/burn.tsv.999990.1015900.41200.tick"
: > "$CASE/burn.tsv.999999.1015900.41200.tick"
: > "$CASE/burn.tsv.1000002.1015900.41200.tick"
: > "$CASE/burn.tsv.abc.1015900.41200.tick"
: > "$CASE/burn.tsv.999990.1015900.tick"
: > "$CASE/tick.999990.1015900.41200.tick"
ln -s /dev/null "$CASE/burn.tsv.999980.1015900.41200.tick"
_BURN_LEAD=
state_burn_lead || bad 'lead: sweep round claim' lost
true_case 'lead sweep: stale token removed' test ! -e "$CASE/burn.tsv.999990.1015900.41200.tick"
true_case 'lead sweep: recent-past token kept for stragglers' test -f "$CASE/burn.tsv.999999.1015900.41200.tick"
true_case 'lead sweep: future token removed' test ! -e "$CASE/burn.tsv.1000002.1015900.41200.tick"
true_case 'lead sweep: non-numeric epoch kept' test -f "$CASE/burn.tsv.abc.1015900.41200.tick"
true_case 'lead sweep: two-field name kept' test -f "$CASE/burn.tsv.999990.1015900.tick"
true_case 'lead sweep: foreign unprefixed file untouched' test -f "$CASE/tick.999990.1015900.41200.tick"
true_case 'lead sweep: symlink kept' test -L "$CASE/burn.tsv.999980.1015900.41200.tick"
rm -f "$CASE"/burn.tsv.*.tick 2>/dev/null
: > "$CASE/burn.tsv.1000000.1015900.999999999999999999999999.tick"
: > "$CASE/burn.tsv.999990.1015900.999999999999999999999999.tick"
_BURN_LEAD=
state_burn_lead 2> "$CASE/overflow.err" || bad 'lead: oversized field never blocks a claim' lost
eq 'lead: oversized digit field leaks no stderr' "$(wc -c < "$CASE/overflow.err" | tr -d ' ')" 0
true_case 'lead sweep: stale oversized name kept, not compared' test -f "$CASE/burn.tsv.999990.1015900.999999999999999999999999.tick"
rm -f "$CASE"/burn.tsv.*.tick "$CASE"/tick.* 2>/dev/null
ln -s "$CASE/linktarget" "$TOK"
_BURN_LEAD=
if state_burn_lead; then bad 'lead: symlink at the token name loses' won; else ok 'lead: symlink at the token name loses'; fi
true_case 'lead: symlink token never followed' test ! -e "$CASE/linktarget"
true_case 'lead: symlink token never deleted' test -L "$TOK"
rm -f "$TOK"
_STATE_PATHS_OK=0
_BURN_LEAD=
true_case 'lead: revalidation failure fails open' state_burn_lead
true_case 'lead: fail-open touches nothing' test ! -e "$TOK"
_STATE_PATHS_OK=1
CASE="$TMPD/lead-fresh"
unit_gate "$CASE/absent" 1000000 41.2 1015900 '' '' 0
_BURN_LEAD=
true_case 'lead: missing store parent fails open' state_burn_lead
true_case 'lead: fail-open creates no token' test ! -e "$CASE/absent/burn.tsv.1000000.1015900.41200.tick"
_BURN_LEAD=

# Published-estimate fast path: the election winner publishes its validated
# awk result; a follower that lost to a covering claim adopts it only after
# every field survives the same validation the awk output gets, and every
# anomaly falls back to the full parse.
CASE="$TMPD/est"; mkdir -p "$CASE"
unit_gate "$CASE" 1000000 41.2 1015900 '' '' 0
EST="$CASE/burn.tsv.est"
# An estimate summarizes the TSV, so the source has to exist for any of the
# adoption cases below to describe a real situation.
printf '1\t6\t9\n' > "$BURN_FILE"

# Publish: winner shape, maintenance/no-raw refusal.
_CUR_BURN_VALID=1; _B5_RAW='warming 0 0 41200 9000'; _B5_TTR=9000
burn_est_snap; burn_est_publish
eq 'est publish: winner writes the claim-stamped line' "$(cat "$EST" 2>/dev/null)" '1000000 1009000 warming 0 0 41200 1015900 41200'
rm -f "$EST"
_CUR_BURN_VALID=0
burn_est_snap; burn_est_publish
true_case 'est publish: maintenance winner never publishes' test ! -e "$EST"
_CUR_BURN_VALID=1; _B5_RAW=''
burn_est_snap; burn_est_publish
true_case 'est publish: no raw line, no publish' test ! -e "$EST"
mkdir "$EST"
_B5_RAW='warming 0 0 41200 9000'
burn_est_snap; burn_est_publish
true_case 'est publish: directory at est name aborts' test -d "$EST"
true_case 'est publish: aborted publish leaves no tmp' test ! -e "$CASE/burn.tsv.$$.tmp"
rmdir "$EST"
# A covering higher claim in the same (second, window) suppresses our publish;
# a lower one does not.
: > "$CASE/burn.tsv.1000000.1015900.60000.tick"
burn_est_snap; burn_est_publish
true_case 'est publish: higher same-second claim suppresses ours' test ! -e "$EST"
true_case 'est publish: suppressed publish leaves no tmp' test ! -e "$CASE/burn.tsv.$$.tmp"
rm -f "$CASE/burn.tsv.1000000.1015900.60000.tick"
: > "$CASE/burn.tsv.1000000.1015900.30000.tick"
burn_est_snap; burn_est_publish
true_case 'est publish: lower claim does not suppress' test -f "$EST"
rm -f "$EST" "$CASE/burn.tsv.1000000.1015900.30000.tick"
: > "$CASE/burn.tsv.1000000.1016100.20000.tick"
burn_est_snap; burn_est_publish
true_case 'est publish: newer-window claim suppresses ours' test ! -e "$EST"
true_case 'est publish: cross-window suppression leaves no tmp' test ! -e "$CASE/burn.tsv.$$.tmp"
rm -f "$CASE/burn.tsv.1000000.1016100.20000.tick"
: > "$CASE/burn.tsv.1000000.1009000.90000.tick"
burn_est_snap; burn_est_publish
true_case 'est publish: older-window claim does not suppress' test -f "$EST"
rm -f "$EST" "$CASE/burn.tsv.1000000.1009000.90000.tick"
# The estimate is versioned against the TSV as the parse read it, so a row
# landing between parse and publish abandons the publication, and an
# unversioned publish is refused outright.
rm -f "$EST"
burn_est_snap
true_case 'est snap: marker created before the parse' test -f "$_BURN_SNAP"
_SNAPPED=$_BURN_SNAP
sleep 1; printf '2\t7\t9\n' >> "$BURN_FILE"
burn_est_publish
true_case 'est publish: TSV touched during the parse abandons publication' test ! -e "$EST"
true_case 'est publish: abandoned publication releases the marker' test ! -e "$_SNAPPED"
_BURN_SNAP=""
burn_est_publish
true_case 'est publish: unversioned publish refused' test ! -e "$EST"
# The redirection creates the temporary before the write runs; a write that
# fails afterwards must not leave it behind.
printf() { return 1; }
burn_est_snap; burn_est_publish
unset -f printf
true_case 'est publish: failed write leaves no temporary' test ! -e "$CASE/burn.tsv.$$.tmp"
true_case 'est publish: failed write publishes nothing' test ! -e "$EST"
burn_est_snap; burn_est_publish
true_case 'est publish: untouched TSV publishes normally' test -f "$EST"
true_case 'est publish: successful publication releases the marker' test ! -e "$_SNAPPED"
rm -f "$EST"

# Discarding a temporary is a mutation: it must re-prove the path identity, so
# an unlink can never traverse an ancestor swapped for a symlink mid-render.
: > "$CASE/burn.tsv.4242.tmp"
_STATE_PATHS_OK=0
burn_est_discard "$CASE/burn.tsv.4242.tmp"
true_case 'est discard: revalidation failure keeps the temporary' test -f "$CASE/burn.tsv.4242.tmp"
_STATE_PATHS_OK=1
burn_est_discard "$CASE/burn.tsv.4242.tmp"
true_case 'est discard: revalidated temporary removed' test ! -e "$CASE/burn.tsv.4242.tmp"
ln -s "$CASE/discardtarget" "$CASE/burn.tsv.4243.tmp"
burn_est_discard "$CASE/burn.tsv.4243.tmp"
true_case 'est discard: symlink temporary never unlinked' test -L "$CASE/burn.tsv.4243.tmp"
true_case 'est discard: symlink target never touched' test ! -e "$CASE/discardtarget"
rm -f "$CASE/burn.tsv.4243.tmp"

# Adopt: fresh valid estimate is used without the awk (values differ from
# anything the empty TSV could produce, so adoption is observable).
# _BURN_LOST_PCT simulates the covering claim this session lost to.
printf '1000000 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
_CUR_BURN_VALID=1; _BURN_LOST_PCT=41200
true_case 'est adopt: fresh valid estimate adopted' burn_est_adopt
eq 'est adopt: state comes from the estimate' "$_B5_STATE" active
eq 'est adopt: ttr derives from window and local NOW' "$_B5_TTR" 15900
printf '999996 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: stale estimate rejected' adopted; else ok 'est adopt: stale estimate rejected'; fi
printf '1000002 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: future-dated estimate rejected' adopted; else ok 'est adopt: future-dated estimate rejected'; fi
printf '1000000 1015900 active 90000 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: span beyond window cap rejected' adopted; else ok 'est adopt: span beyond window cap rejected'; fi
printf '1000000 1015900 active 300 200000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: delta beyond pct cap rejected' adopted; else ok 'est adopt: delta beyond pct cap rejected'; fi
printf '1000000 1015900 active 300 5000 100001 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: latest beyond pct cap rejected' adopted; else ok 'est adopt: latest beyond pct cap rejected'; fi
printf '1000000 1015900 hacked 300 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: unknown state token rejected' adopted; else ok 'est adopt: unknown state token rejected'; fi
printf '1000000 1015900 active 008 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt 2> "$CASE/octal.err"; then bad 'est adopt: leading-zero span rejected' adopted; else ok 'est adopt: leading-zero span rejected'; fi
eq 'est adopt: leading-zero rejection leaks no stderr' "$(wc -c < "$CASE/octal.err" | tr -d ' ')" 0
printf '1000000 1009000 active 300 5000 50000 1009000 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: older-window estimate rejected' adopted; else ok 'est adopt: older-window estimate rejected'; fi
printf '1000000 1020000 active 300 5000 50000 1020000 41200\n' > "$EST"
true_case 'est adopt: newer-window estimate accepted' burn_est_adopt
eq 'est adopt: newer-window ttr from published maxrst' "$_B5_TTR" 20000
printf '1000000 1021601 active 300 5000 50000 1021601 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: reset beyond 5h horizon rejected' adopted; else ok 'est adopt: reset beyond 5h horizon rejected'; fi
printf '1000000 1021600 active 300 5000 50000 1021600 41200\n' > "$EST"
true_case 'est adopt: reset at the 5h horizon accepted' burn_est_adopt
printf '1000000 1015900 active 300 5000 50000\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: legacy six-field line rejected' adopted; else ok 'est adopt: legacy six-field line rejected'; fi
printf '1000000 1015900 active 300 5000 50000 1015900 30000\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: claim below the covering pct rejected' adopted; else ok 'est adopt: claim below the covering pct rejected'; fi
printf '1000000 1015900 active 300 5000 50000 1015900 50000\n' > "$EST"
true_case 'est adopt: claim above the covering pct accepted' burn_est_adopt
printf '1000000 1020000 active 300 5000 50000 1020000 5000\n' > "$EST"
true_case 'est adopt: newer-window claim supersedes any pct' burn_est_adopt
# Prior-tick same-window adoption substitutes this session's own reading for
# the published latest (our observation is the newest distinct sample, and
# percentages legitimately drop within a window). A same-tick estimate keeps
# the published value: the winner's row shares our sample key, where the
# reader keeps the maximum, so it already covers our injection.
printf '999999 1015900 active 300 5000 50000 1015900 50000\n' > "$EST"
true_case 'est adopt: prior-tick latest override adoption succeeds' burn_est_adopt
_ADOPT_ETA=$_B5_ETA
burn_b5_line 'active 300 5000 41200 15900' || bad 'est adopt: reference line parses' failed
eq 'est adopt: prior-tick latest is our own reading' "$_ADOPT_ETA" "$_B5_ETA"
printf '1000000 1015900 active 300 5000 50000 1015900 50000\n' > "$EST"
true_case 'est adopt: same-tick adoption succeeds' burn_est_adopt
_ADOPT_ETA=$_B5_ETA
burn_b5_line 'active 300 5000 50000 15900' || bad 'est adopt: same-tick reference parses' failed
eq 'est adopt: same-tick keeps the published latest' "$_ADOPT_ETA" "$_B5_ETA"
# A writer claiming our window whose parse selected a NEWER window published
# numbers our reading has no part in: the substitution follows the described
# window, not the claimed one.
printf '999999 1020000 active 300 5000 50000 1015900 41200\n' > "$EST"
true_case 'est adopt: claim-ours described-newer adoption succeeds' burn_est_adopt
_ADOPT_ETA=$_B5_ETA
burn_b5_line 'active 300 5000 50000 20000' || bad 'est adopt: described-window reference parses' failed
eq 'est adopt: described-newer keeps the published latest' "$_ADOPT_ETA" "$_B5_ETA"

# A TSV strictly newer than the estimate means rows landed after the publish
# (an older-tick straggler inside the sweep grace window): the snapshot is
# incomplete and must not be adopted.
printf '1000000 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
touch -t 202001010000 "$EST"
printf '1\t6\t9\n' >> "$BURN_FILE"
if burn_est_adopt; then bad 'est adopt: TSV newer than estimate rejected' adopted; else ok 'est adopt: TSV newer than estimate rejected'; fi
# A summary must not outlive the file it summarizes: with the TSV deleted the
# mtime test is vacuous, so absence is checked on its own.
cp "$BURN_FILE" "$CASE/tsv.keep"; rm -f "$BURN_FILE"
printf '1000000 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
if burn_est_adopt; then bad 'est adopt: missing source TSV rejected' adopted; else ok 'est adopt: missing source TSV rejected'; fi
ln -s "$CASE/tsv.keep" "$BURN_FILE"
if burn_est_adopt; then bad 'est adopt: symlinked source TSV rejected' adopted; else ok 'est adopt: symlinked source TSV rejected'; fi
rm -f "$BURN_FILE"; cp "$CASE/tsv.keep" "$BURN_FILE"
printf '1000000 1015900 active a[$(touch %s/pwn)] 5000 50000 1015900 41200\n' "$CASE" > "$EST"
if burn_est_adopt; then bad 'est adopt: arithmetic injection rejected' adopted; else ok 'est adopt: arithmetic injection rejected'; fi
true_case 'est adopt: injection produced no side effect' test ! -e "$CASE/pwn"
{ printf '1000000 1015900 active 300 5000 50000 1015900 '; head -c 400 /dev/zero | tr '\0' '9'; printf '\n'; } > "$EST"
if burn_est_adopt; then bad 'est adopt: oversized line rejected' adopted; else ok 'est adopt: oversized line rejected'; fi
rm -f "$EST"; ln -s "$CASE/esttarget" "$EST"
if burn_est_adopt; then bad 'est adopt: symlink est rejected' adopted; else ok 'est adopt: symlink est rejected'; fi
true_case 'est adopt: symlink est not followed' test ! -e "$CASE/esttarget"
true_case 'est adopt: symlink est not deleted' test -L "$EST"
rm -f "$EST"
printf '999998 1015900 active 300 5000 50000 1015900 41200\n' > "$EST"
true_case 'est adopt: two-second-old estimate still adopts' burn_est_adopt
eq 'est adopt: aged estimate ttr still local' "$_B5_TTR" 15900
_CUR_BURN_VALID=0
rm -f "$EST"

# Read-only wiring: a CORALLINE_NO_SAMPLE render never consumes a published
# estimate (test/preview determinism, rule #32) and never writes one. The
# planted est claims an active state no empty TSV could produce, so any
# adoption would be visible in the output.
CASE="$TMPD/est-ro"; mkdir -p "$CASE/state"
write_config "$CASE/conf" "$CASE/state" burn 0
_now=$(date +%s)
make_payload "$CASE/input" 41.2 "$((_now + 9000))" '' ''
printf '%s %s active 300 5000 50000 %s 41200\n' "$_now" "$((_now + 9000))" "$((_now + 9000))" > "$CASE/state/burn.tsv.est"
cp "$CASE/state/burn.tsv.est" "$CASE/est.before"
run_runtime "$BASH_BIN" "$CASE/conf" "$CASE/input" "$CASE/out" "$CASE/err" 1
printf '\033[0m B … \033[0m\n' > "$CASE/oracle"
if cmp -s "$CASE/out" "$CASE/oracle"; then ok 'est read-only: no-sample render ignores a fresh estimate'; else bad 'est read-only: no-sample render ignores a fresh estimate' "$(cat "$CASE/out")"; fi
if cmp -s "$CASE/state/burn.tsv.est" "$CASE/est.before"; then ok 'est read-only: estimate file untouched'; else bad 'est read-only: estimate file untouched' changed; fi
eq 'est read-only: no tokens created' "$(ls "$CASE/state" | grep -c '\.tick$')" 0
eq 'est read-only: stderr empty' "$(wc -c < "$CASE/err" | tr -d ' ')" 0

# Maintenance claim: a render with no valid 5h reading may still win the
# mutate path (trim/heal/sweep never starve), under the reserved 0.0 name; it
# loses to any same-second claimant, and a real claimant ignores it.
CASE="$TMPD/lead-maint"; mkdir -p "$CASE"
unit_gate "$CASE" 1000000 '' '' '' '' 0
_BURN_LEAD=
true_case 'maint: reading-less render claims maintenance' state_burn_lead
true_case 'maint: reserved token created' test -f "$CASE/burn.tsv.1000000.0.0.tick"
rm -f "$CASE"/burn.tsv.*.tick
: > "$CASE/burn.tsv.1000000.1015900.41200.tick"
_BURN_LEAD=
if state_burn_lead; then bad 'maint: loses to a same-second claimant' won; else ok 'maint: loses to a same-second claimant'; fi
rm -f "$CASE"/burn.tsv.*.tick
: > "$CASE/burn.tsv.1000000.0.0.tick"
unit_gate "$CASE" 1000000 41.2 1015900 '' '' 0
_BURN_LEAD=
true_case 'maint: real claimant ignores the maintenance token' state_burn_lead
true_case 'maint: real claim landed beside it' test -f "$CASE/burn.tsv.1000000.1015900.41200.tick"
rm -f "$CASE"/burn.tsv.*.tick
_BURN_LEAD=

# Two-window coverage under election: a session holding a different (newer) 5h
# window than the tick winner must still persist its rows and reach the limit
# store, and the newer window's history must be enough for an active estimate.
# The store starts absent, so the first render also proves the fail-open path
# creates a working store from nothing.
CASE="$TMPD/twowin"; mkdir -p "$CASE"
_now=$(date +%s); _rA=$((_now + 9000)); _rB=$((_now + 12000))
write_config "$CASE/conf" "$CASE/state" 'burn limit5h' 1
_i=0
while [ "$_i" -lt 3 ]; do
  make_payload "$CASE/inA" "3$_i.5" "$_rA" '' ''
  make_payload "$CASE/inB" "4$_i.5" "$_rB" '' ''
  CORALLINE_CONFIG="$CASE/conf" CORALLINE_NO_SAMPLE=0 "$BASH_BIN" "$SCRIPT" < "$CASE/inA" > /dev/null 2> "$CASE/errA.$_i" &
  _pidA=$!
  CORALLINE_CONFIG="$CASE/conf" CORALLINE_NO_SAMPLE=0 "$BASH_BIN" "$SCRIPT" < "$CASE/inB" > /dev/null 2> "$CASE/errB.$_i" &
  _pidB=$!
  wait "$_pidA" "$_pidB" 2>/dev/null
  _i=$((_i + 1))
  sleep 1
done
_rowsA=$(awk -F '\t' -v r="$_rA" '$3 == r' "$CASE/state/burn.tsv" 2>/dev/null | wc -l | tr -d ' ')
_rowsB=$(awk -F '\t' -v r="$_rB" '$3 == r' "$CASE/state/burn.tsv" 2>/dev/null | wc -l | tr -d ' ')
true_case 'two-window: older-window rows persisted' test "$_rowsA" -ge 2
true_case 'two-window: newer-window rows persisted' test "$_rowsB" -ge 2
# Once the newer reset lands, rl_choose makes every session render (and thus
# republish) that window, so the store legitimately converges on B's entries;
# the non-suppression proof is that entries exist at all and include B's reset.
entry_count "$CASE/state/limit5.d"; _ENTRIES=$_COUNT
true_case 'two-window: limit store received entries' test "$_ENTRIES" -ge 1
_LIM_B=0; for _e in "$CASE/state/limit5.d/${_rB}"_*; do [ -e "$_e" ] && _LIM_B=1; done
eq 'two-window: newer reset reached the limit store' "$_LIM_B" 1
# The newer window's persisted rows must feed an active estimate rather than
# stranding that session on permanent warming. The estimator needs crossings
# spanning >= win/10 seconds, which a 3s render loop cannot produce, so the
# read fixture adds two backdated in-window rows for the same reset; the LAST
# crossing still comes from a row the elected renders persisted above.
CASE2="$TMPD/twowin-read"; mkdir -p "$CASE2"
{ printf '%s\t38.000\t%s\n' "$((_now - 300))" "$_rB"; printf '%s\t39.000\t%s\n' "$((_now - 240))" "$_rB"; cat "$CASE/state/burn.tsv"; } > "$CASE2/burn.tsv"
unit_gate "$CASE2" $((_now + 5)) 49.5 "$_rB" '' '' 1
burn_eta_5h 0
eq 'two-window: newer window estimates active' "$_B5_STATE" active

# Binding and renderer regressions after state/storage tests. Stubs isolate the
# already-tested estimators from the presentation logic.
VL_BURN_GLYPH='↗'; VL_BG_BURN=''; VL_BG_5H=237; VL_LAYOUT=fixed
VL_FG_OK=114; VL_FG_WARN=179; VL_FG_HOT=167; VL_FG_DIM=245; VL_NOCOLOR=0
fh_pct=8; wd_pct=0; _STATE_READY=0
mk5h() { _B5_STATE="$1"; _B5_ETA="$2"; _B5_RATE="$3"; _B5_TTR="$4"; }
mk7d() { _B7_ETA="$1"; _B7_RATE="$2"; _B7_TTR="$3"; }
burn_eta_5h() { mk5h "$M5S" "$M5E" "$M5R" "$M5T"; }
burn_eta_7d() { mk7d "$M7E" "$M7R" "$M7T"; }
_STATE_MUTATE=0; _CUR7_VALID=0; _STATE_RL7_VALID=0
M5S=active M5E=21600 M5R=0 M5T=15000 M7E=7200 M7R=0 M7T=86400
burn_estimate; eq 'binding label 7d' "$_BURN_LABEL" 7d
M5S=active M5E=5000 M5R=0 M5T=9000 M7E=5000 M7R=0 M7T=9000
burn_estimate; eq 'binding ETA tie chooses 5h' "$_BURN_LABEL" 5h

# The projection binds to whatever source the gauge is willing to show, or the bar
# and the 7d pill would describe different windows in one render. That means the
# store feeds burn_eta_7d whenever it is valid, with or without a reading of our own.
burn_eta_7d() { _B7_ARGS="$1|$2"; mk7d "$M7E" "$M7R" "$M7T"; }
_VLS_SAVE=$VL_LIMIT_SYNC; VL_LIMIT_SYNC=1
_STATE_RL7_VALID=1; _STATE_RL7_PCT=99000; _STATE_RL7_RST=1345600
_CUR7_VALID=0; _CUR7_PCT=0; _CUR7_RST=0
_B7_ARGS=unset; burn_estimate
eq 'no own 7d reading still projects from the store' "$_B7_ARGS" '99000|1345600'
_CUR7_VALID=1; _CUR7_PCT=30000; _CUR7_RST=1345600
_B7_ARGS=unset; burn_estimate
eq 'own 7d reading admits the synced projection' "$_B7_ARGS" '99000|1345600'
_STATE_RL7_VALID=0
_B7_ARGS=unset; burn_estimate
eq 'no store leaves the projection on the payload' "$_B7_ARGS" '30000|1345600'
VL_LIMIT_SYNC=$_VLS_SAVE; _STATE_RL7_VALID=0; _CUR7_VALID=0
burn_eta_7d() { mk7d "$M7E" "$M7R" "$M7T"; }

# The 5h projection must describe the same window as the gauge. When only the store
# supplies that window, a burn history still sitting on the one that just closed
# would put an active ETA for the old window beside a gauge for the new one; the
# estimator reports its window as NOW + _B5_TTR.
NOW=1000000; _VLS_SAVE2=$VL_LIMIT_SYNC; VL_LIMIT_SYNC=1
_CUR5_VALID=0; _STATE_RL5_VALID=1; _STATE_RL5_RST=$(( NOW + 9000 ))
_CUR7_VALID=0; _STATE_RL7_VALID=0
M5S=active M5E=4000 M5R=0 M5T=9000 M7E=inf M7R=0 M7T=0
burn_estimate
eq 'store-only 5h projection on the stored window survives' "$_BURN_STATE" active
M5T=0
burn_estimate
eq 'store-only 5h projection on a closed window is dropped' "$_B5_STATE" warming
eq 'dropped 5h projection leaves burn warming' "$_BURN_STATE" warming
# A valid reading of our own does not exempt the projection. rl_choose lets a
# strictly newer stored window beat it, and the session that published that window
# need not run burn at all, so the shared history can hold only the older one.
_CUR5_VALID=1; _CUR5_RST=$(( NOW + 1000 )); _STATE_RL5_RST=$(( NOW + 1000 ))
M5T=1000
burn_estimate
eq 'own 5h window matching the store keeps its projection' "$_BURN_STATE" active
M5T=1000; _STATE_RL5_RST=$(( NOW + 9000 ))
burn_estimate
eq 'newer stored window drops a projection still on the older one' "$_B5_STATE" warming
M5T=9000
burn_estimate
eq 'projection rebound to the newer stored window survives' "$_BURN_STATE" active
_STATE_RL5_VALID=0
M5T=1000
burn_estimate
eq 'no synced state leaves the projection alone' "$_BURN_STATE" active
VL_LIMIT_SYNC=$_VLS_SAVE2; _STATE_RL5_VALID=0; _CUR5_VALID=0
M5S=active M5E=21600 M5R=0 M5T=15000 M7E=7200 M7R=0 M7T=86400
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _BURN_STATE=active; _BURN_LABEL=5h; _BURN_ETA=1000; _BURN_RATE=0; _BURN_TTR=900
seg_burn
case "${SEG_TXT[0]}" in (*'↗ 5h ⇢ 16m'*) ok 'burn renderer uses precomputed estimate' ;; (*) bad 'burn renderer uses precomputed estimate' "${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in (*$'\033[38;5;179m'*) ok 'burn renderer warning color' ;; (*) bad 'burn renderer warning color' 'missing warning fg' ;; esac
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _BURN_STATE=warming; _BURN_LABEL=''; _BURN_ETA=inf; _BURN_RATE=0; _BURN_TTR=0
seg_burn
case "${SEG_TXT[0]}" in (*'↗ …'*) ok 'burn renderer warming marker' ;; (*) bad 'burn renderer warming marker' "${SEG_TXT[0]}" ;; esac

# The projection accepts the same sources as the gauges. Leaving burn gated on the
# payload alone would show 5h and 7d from the store with a hole between them.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_READY=1
_CUR5_VALID=0; _CUR7_VALID=0; _STATE_RL5_VALID=0; _STATE_RL7_VALID=0
seg_burn
eq 'no reading and no store draws no projection' "${#SEG_TXT[@]}" 0
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL7_VALID=1
seg_burn
eq 'store window alone draws the projection' "${#SEG_TXT[@]}" 1
_STATE_READY=0; _STATE_RL7_VALID=0

# Synced limit segments override the payload but never gate on it. Once a window's
# reset passes, the payload snapshot and every store entry go invalid in the same
# render, so gating here blanked the segment for the whole idle stretch until the
# next keystroke delivered a fresh snapshot. The fallback reads the canonical
# _CUR*_PCT, never the raw payload, so an unvalidated pct still renders nothing.
NOW=1000000; VL_BG_7D=236; VL_LIMIT_SYNC=1
VL_BAR_WIDTH=5; VL_BAR_FILL='▰'; VL_BAR_EMPTY='▱'; VL_WARN_PCT=50; VL_HOT_PCT=75
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct=41.2; fh_rst=1015900; _CUR5_CANON='041.200'; _CUR5_PCT=41200; _CUR5_RST=1015900
_CUR5_VALID=1; _CUR7_VALID=1
_STATE_RL5_VALID=1; _STATE_RL5_PCT=62000; _STATE_RL5_RST=1015900
seg_limit5h
case "${SEG_TXT[0]}" in (*'5h '*' 62% '*) ok 'synced high-water overrides the payload' ;; (*) bad 'synced high-water overrides the payload' "${SEG_TXT[0]}" ;; esac

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL5_VALID=0; _CUR5_RST=999000
seg_limit5h
eq 'expired 5h window still renders' "${#SEG_TXT[@]}" 1
case "${SEG_TXT[0]}" in (*'5h '*' 41% '*) ok 'expired 5h window keeps the canonical reading' ;; (*) bad 'expired 5h window keeps the canonical reading' "${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in (*'↺now'*) ok 'expired 5h window countdown reads now' ;; (*) bad 'expired 5h window countdown reads now' "${SEG_TXT[0]}" ;; esac

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL7_VALID=0
wd_pct=30; wd_rst=999000; _CUR7_CANON='030.000'; _CUR7_PCT=30000; _CUR7_RST=999000
seg_limit7d
eq 'expired 7d window still renders' "${#SEG_TXT[@]}" 1
case "${SEG_TXT[0]}" in (*'7d '*' 30% '*) ok 'expired 7d window keeps the canonical reading' ;; (*) bad 'expired 7d window keeps the canonical reading' "${SEG_TXT[0]}" ;; esac

# An oversized/malformed payload pct leaves _CUR5_CANON empty, so the fallback
# must draw nothing rather than push the raw value through make_bar/pct_fg.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL5_VALID=0; _CUR5_CANON=''; _CUR5_PCT=0
fh_pct=$_LONG_PCT; fh_rst=999000
seg_limit5h
eq 'unvalidated payload pct renders nothing' "${#SEG_TXT[@]}" 0

# A canonical pct is not on its own evidence of an elapsed window. A missing or
# malformed reset leaves _CUR5_RST at 0 and a sentinel reset lands beyond the
# window ceiling; drawing either would invent a countdown that was never observed.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _CUR5_CANON='041.200'; _CUR5_PCT=41200; _CUR5_RST=0
seg_limit5h
eq 'unparsed reset renders nothing' "${#SEG_TXT[@]}" 0

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _CUR5_RST=$(( NOW + 999999 ))
seg_limit5h
eq 'far-future sentinel reset renders nothing' "${#SEG_TXT[@]}" 0

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _CUR5_RST=$NOW
seg_limit5h
eq 'reset exactly at now counts as elapsed' "${#SEG_TXT[@]}" 1

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL7_VALID=0; _CUR7_RST=0
seg_limit7d
eq '7d unparsed reset renders nothing' "${#SEG_TXT[@]}" 0

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _CUR5_CANON=''; fh_pct=''; fh_rst=''
seg_limit5h
eq 'no payload and no synced state renders nothing' "${#SEG_TXT[@]}" 0

# With no reading of its own the session shows the store's open window, in both
# windows alike. This is the case that blanked both gauges for a freshly started,
# resumed, or idle session, whose payload carries no rate_limits at all.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct=''; fh_rst=''; _CUR5_VALID=0; _CUR5_CANON=''; _CUR5_RST=0
_STATE_RL5_VALID=1; _STATE_RL5_PCT=99000; _STATE_RL5_RST=1015900
seg_limit5h
eq 'no own 5h reading shows the stored window' "${#SEG_TXT[@]}" 1
case "${SEG_TXT[0]}" in (*'5h '*' 99% '*) ok 'stored 5h value reaches the bar' ;; (*) bad 'stored 5h value reaches the bar' "${SEG_TXT[0]}" ;; esac

SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
wd_pct=''; wd_rst=''; _CUR7_VALID=0; _CUR7_CANON=''; _CUR7_RST=0
_STATE_RL7_VALID=1; _STATE_RL7_PCT=99000; _STATE_RL7_RST=1345600
seg_limit7d
eq 'no own 7d reading shows the stored window' "${#SEG_TXT[@]}" 1
case "${SEG_TXT[0]}" in (*'7d '*' 99% '*) ok 'stored 7d value reaches the bar' ;; (*) bad 'stored 7d value reaches the bar' "${SEG_TXT[0]}" ;; esac

# Nothing of our own and nothing in the store still renders nothing.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _STATE_RL5_VALID=0
seg_limit5h
eq 'no own 5h reading and no store renders nothing' "${#SEG_TXT[@]}" 0

# An elapsed window is a fallback for one that JUST closed. Claude Code replays the
# last snapshot an idle session received forever, so past the window ceiling that
# reading stops standing in for the current window: it falls through to the store,
# and renders nothing when the store has nothing either.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct=41.2; fh_rst=1; _CUR5_CANON='041.200'; _CUR5_PCT=41200
_CUR5_RST=$(( NOW - RL_MAX_5H )); _CUR5_VALID=0; _STATE_RL5_VALID=0
seg_limit5h
eq 'elapsed exactly at the ceiling still renders' "${#SEG_TXT[@]}" 1

SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _CUR5_RST=$(( NOW - RL_MAX_5H - 1 ))
seg_limit5h
eq 'elapsed past the ceiling renders nothing' "${#SEG_TXT[@]}" 0

SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
_STATE_RL5_VALID=1; _STATE_RL5_PCT=33000; _STATE_RL5_RST=1015900
seg_limit5h
eq 'elapsed past the ceiling falls through to the store' "${#SEG_TXT[@]}" 1
case "${SEG_TXT[0]}" in (*' 33% '*) ok 'stale reading never outranks the open window' ;; (*) bad 'stale reading never outranks the open window' "${SEG_TXT[0]}" ;; esac

SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
wd_pct=30; wd_rst=1; _CUR7_CANON='030.000'; _CUR7_PCT=30000
_CUR7_RST=$(( NOW - RL_MAX_7D - 1 )); _CUR7_VALID=0; _STATE_RL7_VALID=0
seg_limit7d
eq '7d elapsed past the ceiling renders nothing' "${#SEG_TXT[@]}" 0

# The roll-over catch-up survives: this session holds a valid but older window and
# the store holds a strictly newer one, which is the case rl_choose lets win.
SEG_BGS=(); SEG_TXT=(); SEG_LEN=()
fh_pct=41.2; fh_rst=1015900; _CUR5_VALID=1; _CUR5_CANON='041.200'; _CUR5_PCT=41200; _CUR5_RST=1015900
_STATE_RL5_VALID=1; _STATE_RL5_PCT=7000; _STATE_RL5_RST=1016900
seg_limit5h
case "${SEG_TXT[0]}" in (*'5h '*' 7% '*) ok 'roll-over catch-up still renders the newer window' ;; (*) bad 'roll-over catch-up still renders the newer window' "${SEG_TXT[0]}" ;; esac

# Default store base follows CLAUDE_CONFIG_DIR (two Claude config dirs must not
# share one 5h/7d store). Asserted on where a real render puts the files, with no
# CORALLINE_*_FILE override in play, so a relocated default cannot pass by text.
default_store_case() {  # $1=case dir $2=CLAUDE_CONFIG_DIR value ("" = unset)
  local case_dir="$1" cfg_dir="$2" now
  rm -rf "$case_dir"; mkdir -p "$case_dir/home"
  printf '%s\n' 'VL_SEGMENTS="limit5h limit7d"' VL_CLOCK=off VL_STYLE=lean \
    VL_NOCOLOR=1 VL_LIMIT_SYNC=1 > "$case_dir/conf"
  now=$(date +%s)
  make_payload "$case_dir/input" 41.2 "$((now + 15930))" 30 "$((now + 345630))"
  if [ -n "$cfg_dir" ]; then
    HOME="$case_dir/home" CLAUDE_CONFIG_DIR="$cfg_dir" CORALLINE_CONFIG="$case_dir/conf" \
      CORALLINE_NO_SAMPLE=0 "$BASH_BIN" "$SCRIPT" < "$case_dir/input" > "$case_dir/out" 2> "$case_dir/err"
  else
    # Unset, not merely unassigned: a developer who exports CLAUDE_CONFIG_DIR
    # (the very configuration this fix targets) would otherwise leak it in.
    ( unset CLAUDE_CONFIG_DIR
      HOME="$case_dir/home" CORALLINE_CONFIG="$case_dir/conf" \
        CORALLINE_NO_SAMPLE=0 "$BASH_BIN" "$SCRIPT" < "$case_dir/input" > "$case_dir/out" 2> "$case_dir/err" )
  fi
}

CASE="$TMPD/store-base"
default_store_case "$CASE/redirected" "$CASE/redirected/alt"
true_case 'CLAUDE_CONFIG_DIR redirects the default store' test -e "$CASE/redirected/alt/coralline/limit-5h.d"
true_case 'redirected store leaves the HOME store untouched' test ! -e "$CASE/redirected/home/.claude/coralline"
eq 'redirected render stderr empty' "$(file_bytes "$CASE/redirected/err")" 0

default_store_case "$CASE/plain" ""
true_case 'unset CLAUDE_CONFIG_DIR keeps the historical HOME store' test -e "$CASE/plain/home/.claude/coralline/limit-5h.d"
eq 'plain render stderr empty' "$(file_bytes "$CASE/plain/err")" 0

printf 'SUMMARY pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ALL PASS\n'
