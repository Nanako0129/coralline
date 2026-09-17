#!/usr/bin/env bash
# Grok Build host: Claude sample stays byte-identical; Grok payloads fill
# overlapping fields and hide Claude-only segments instead of fabricating zeros.
#
#   bash test/test-grok-host.sh
#
# Needs jq and the bundled sample payloads.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/statusline.sh"
GROK_SCRIPT="$REPO/statusline-grok.sh"
CONF_TMPL="$REPO/themes/claude-coral.conf"
SAMPLE="$HERE/sample-input.json"
GROK="$HERE/sample-input-grok.json"
GOLDEN="$HERE/golden-claude-host.out"

fail=0
ok()    { printf 'ok    %s\n' "$1"; }
bad()   { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }
has()   { case "$out" in (*"$1"*) printf 1 ;; (*) printf 0 ;; esac; }
lacks() { case "$out" in (*"$1"*) printf 0 ;; (*) printf 1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }
[ -f "$GOLDEN" ] || { echo "FAIL  missing $GOLDEN"; exit 1; }

# Render the REAL statusline.sh. CORALLINE_NO_SAMPLE keeps cross-session stores
# untouched. Output lands in a file so cmp keeps the trailing newline.
render_file() { # $1 payload $2 segments $3 dest [extra conf] [runner]
  local payload="$1" segs="$2" dest="$3" extra="${4:-}" runner="${5:-$SCRIPT}" conf
  conf=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-host.XXXXXX") || exit 1
  {
    printf '. %s\n' "$CONF_TMPL"
    printf 'VL_SEGMENTS="%s"\n' "$segs"
    printf 'VL_SEGMENTS2=""\nVL_SEGMENTS3=""\n'
    printf 'VL_CLOCK=off\n'
    printf '%s' "$extra"
  } > "$conf"
  CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$conf" bash "$runner" < "$payload" > "$dest"
  rm -f "$conf"
}

render() { # $1 payload $2 segments [extra conf] [runner] -> $out
  local dest
  dest=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-out.XXXXXX") || exit 1
  render_file "$1" "$2" "$dest" "${3:-}" "${4:-$SCRIPT}"
  out=$(cat "$dest")
  rm -f "$dest"
}

# (1) Claude golden: time-invariant payload-derived segments stay byte-identical.
got=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-got.XXXXXX") || exit 1
trap 'rm -f "$got"' EXIT
render_file "$SAMPLE" "model ctx lines cost style duration effort" "$got"
cmp -s "$GOLDEN" "$got" && check "Claude golden bytes match pre-change capture" 1 \
  || check "Claude golden bytes match pre-change capture" 0

# (2) Claude presence: cache / 5h / 7d labels still render. Do not pin digits.
render "$SAMPLE" "model ctx cache limit5h limit7d lines cost style duration effort"
check "Claude payload still shows cache glyph ⛁" "$(has '⛁')"
check "Claude payload still shows 5h label"      "$(has '5h')"
check "Claude payload still shows 7d label"      "$(has '7d')"

# (3) Grok fixture: overlapping fields honest, Claude-only segments hidden.
render "$GROK" "model ctx cache limit5h limit7d lines cost style duration effort" "" "$GROK_SCRIPT"
check "Grok payload shows model Grok 4.6"        "$(has 'Grok 4.6')"
check "Grok payload shows ctx percent 25%"       "$(has '25%')"
check "Grok payload shows ↑12.3k from context_tokens" "$(has '↑12.3k')"
check "Grok payload shows cost"                  "$(has '$1.23')"
check "Grok payload does not fabricate ↓0"       "$(lacks '↓0')"
check "Grok payload does not fabricate cr:0"     "$(lacks 'cr:0')"
check "Grok payload does not fabricate cw:0"     "$(lacks 'cw:0')"
check "Grok payload hides 5h pill"               "$(lacks '5h')"
check "Grok payload hides 7d pill"               "$(lacks '7d')"
check "Grok payload hides cache glyph"           "$(lacks '⛁')"
check "Grok payload hides style glyph"           "$(lacks '✎')"
check "Grok payload hides lines + pill"          "$(lacks '+')"
check "Grok payload hides lines - pill"          "$(lacks '-')"

# (4) Grok-like payload missing total_cost_usd does not render $0.00.
nocost=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-nocost.XXXXXX") || exit 1
jq 'del(.cost.total_cost_usd)' "$GROK" > "$nocost" || exit 1
render "$nocost" "model ctx cache limit5h limit7d lines cost style duration effort" "" "$GROK_SCRIPT"
rm -f "$nocost"
check "Grok payload without cost does not show \$0.00" "$(lacks '$0.00')"

# (5) Claude total_input_tokens: 0 wins over context_tokens (present 0 is not a miss).
zeroin=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-zeroin.XXXXXX") || exit 1
jq '.context_window.total_input_tokens = 0 | .context_window.context_tokens = 99999' \
  "$SAMPLE" > "$zeroin" || exit 1
render "$zeroin" "model ctx"
rm -f "$zeroin"
check "present total_input_tokens 0 wins over context_tokens" "$(has '↑0')"
check "present total_input_tokens 0 does not fall through to 99.9k" "$(lacks '99.9k')"

# (6) A Grok payload must not paint 5h/7d/burn from a Claude VL_LIMIT_SYNC store.
store=$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-store.XXXXXX") || exit 1
rst=$(( $(date +%s) + 3600 ))
printf -v entry '%010d_%03d.%03d' "$rst" 41 200
mkdir -p "$store/limit-5h.d/$entry" "$store/limit-7d.d" || exit 1
sync_extra='VL_LIMIT_SYNC=1
'
CORALLINE_DIR="$store" render "$GROK" "model ctx limit5h limit7d burn cost" "$sync_extra" "$GROK_SCRIPT"
rm -rf "$store"
check "Grok payload does not sync 5h from a Claude store" "$(lacks '5h')"
check "Grok payload does not sync 7d from a Claude store" "$(lacks '7d')"
check "Grok payload does not sync burn from a Claude store" "$(lacks '↗')"

# (7) Grok conversation total comes from usage.json, not attach-scoped payload cost.
sess=$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-usage.XXXXXX") || exit 1
printf '%s\n' '{"session":{"costUsdTicks":41943147200}}' > "$sess/usage.json"
: > "$sess/updates.jsonl"
ledger=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-ledger.XXXXXX") || exit 1
jq --arg t "$sess/updates.jsonl" '.transcript_path=$t' "$GROK" > "$ledger" || exit 1
render "$ledger" "model cost" "" "$GROK_SCRIPT"
rm -f "$ledger"
rm -rf "$sess"
check "Grok usage.json session total overrides attach-scoped payload cost" "$(has '$4.19')"
check "Grok usage.json does not keep the attach-scoped \$1.23" "$(lacks '$1.23')"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
