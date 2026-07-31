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

RL_MAX_5H=21600
RL_MAX_7D=691200
CORALLINE_BURN_WINDOW=600
BURN_TRIM=1500
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
  VL_LIMIT_SYNC=1; CORALLINE_BURN_WINDOW=600; BURN_TRIM=1500
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
  local root="$TMPD/run5h" trim="$BURN_TRIM"
  rm -rf "$root"; mkdir -p "$root"
  unit_gate "$root" "$2" '' '' '' '' 1
  BURN_TRIM=$trim
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
rl_choose 5; eq 'current lower pct cannot regress high-water' "$_STATE_RL5_PCT" 20000
rl_latest "$_SL5_BASE" "$RL_MAX_5H" 1
entry_count "$_SL5_ROOT"; eq 'limit mutable GC keeps winner' "$_COUNT" 1

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
if LC_ALL=C grep -q '20%' "$CASE/out"; then ok 'malformed names do not displace canonical winner'; else bad 'malformed names do not displace canonical winner' "output=$(LC_ALL=C tr '\n' ' ' < "$CASE/out")"; fi

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
  if [ -f "$root/state/burn.tsv" ]; then _CC_ROWS=$(wc -l < "$root/state/burn.tsv" | tr -d ' '); else _CC_ROWS=0; fi
  _CC_IMMUTABLE=0
  [ "$(LC_ALL=C tr -d '\n' < "$root/state/burn.d/canary")" = immutable-concurrency-canary ] && _CC_IMMUTABLE=1
  [ "$_CC_RCFILES" -eq "$_CC_EXPECTED" ] && [ "$_CC_SUCCESS" -eq "$_CC_EXPECTED" ] \
    && [ "$_CC_NONEMPTY" -eq "$_CC_EXPECTED" ] && [ "$_CC_MATCH" -eq "$_CC_EXPECTED" ] \
    && [ "$_CC_STDERR_EMPTY" -eq "$_CC_EXPECTED" ] && [ "$_CC_ROWS" -eq "$_CC_EXPECTED" ] \
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
    eq "concurrency n=$_N TSV rows" "$_CC_ROWS" $((_N * 2))
    eq "concurrency n=$_N immutable store untouched" "$_CC_IMMUTABLE" 1
  else
    bad "concurrency n=$_N" "expected=$_CC_EXPECTED rcfiles=$_CC_RCFILES success=$_CC_SUCCESS nonempty=$_CC_NONEMPTY match=$_CC_MATCH stderr=$_CC_STDERR_EMPTY rows=$_CC_ROWS immutable=$_CC_IMMUTABLE"
  fi
done

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
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _BURN_STATE=active; _BURN_LABEL=5h; _BURN_ETA=1000; _BURN_RATE=0; _BURN_TTR=900
seg_burn
case "${SEG_TXT[0]}" in (*'↗ 5h ⇢ 16m'*) ok 'burn renderer uses precomputed estimate' ;; (*) bad 'burn renderer uses precomputed estimate' "${SEG_TXT[0]}" ;; esac
case "${SEG_TXT[0]}" in (*$'\033[38;5;179m'*) ok 'burn renderer warning color' ;; (*) bad 'burn renderer warning color' 'missing warning fg' ;; esac
SEG_BGS=(); SEG_TXT=(); SEG_LEN=(); _BURN_STATE=warming; _BURN_LABEL=''; _BURN_ETA=inf; _BURN_RATE=0; _BURN_TTR=0
seg_burn
case "${SEG_TXT[0]}" in (*'↗ …'*) ok 'burn renderer warming marker' ;; (*) bad 'burn renderer warming marker' "${SEG_TXT[0]}" ;; esac

printf 'SUMMARY pass=%s fail=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ALL PASS\n'
