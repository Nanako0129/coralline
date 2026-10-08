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
  local payload="$1" segs="$2" dest="$3" extra="${4:-}" runner="${5:-$SCRIPT}" conf ghome own=0 shome is_grok
  conf=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-host.XXXXXX") || exit 1
  {
    printf '. %s\n' "$CONF_TMPL"
    printf 'VL_SEGMENTS="%s"\n' "$segs"
    printf 'VL_SEGMENTS2=""\nVL_SEGMENTS3=""\n'
    printf 'VL_CLOCK=off\n'
    printf '%s' "$extra"
  } > "$conf"
  # By basename, not by "= $GROK_SCRIPT": case (6c) deliberately runs a COPY of
  # the adapter from another directory, and an exact comparison sent it down the
  # Claude branch with no GROK_HOME and no fixture conf, which is precisely the
  # vacuous assertion that case exists to rule out.
  case "$runner" in
    */statusline-grok.sh) is_grok=1 ;;
    *)                    is_grok=0 ;;
  esac
  if [ "$is_grok" = 1 ]; then
    # The adapter resolves conf and store from GROK_HOME alone and ignores an
    # inherited CORALLINE_CONFIG, so the fixture has to sit under a Grok root.
    # TEST_GROK_HOME lets a case pin that root (and a separate HOME) itself.
    ghome="${TEST_GROK_HOME:-}"
    if [ -z "$ghome" ]; then
      ghome=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-home.XXXXXX")" && pwd -P) || exit 1
      own=1
    fi
    mkdir -p "$ghome/coralline" || exit 1
    cp "$conf" "$ghome/coralline.conf" || exit 1
    # HOME goes in the sandbox too. statusline.sh falls back to
    # "$HOME/.claude/coralline.conf" (statusline.sh:173), so leaving the real
    # HOME in place makes every case below read the developer's own config --
    # it passes here and renders something else on another machine. The cases
    # that need a populated Claude HOME set both TEST_GROK_HOME and HOME.
    shome="$HOME"
    [ -n "${TEST_GROK_HOME:-}" ] || shome="$ghome"
    HOME="$shome" CORALLINE_NO_SAMPLE=1 GROK_HOME="$ghome" \
      bash "$runner" < "$payload" > "$dest"
    [ "$own" = 1 ] && rm -rf "$ghome"
  else
    CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$conf" bash "$runner" < "$payload" > "$dest"
  fi
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

# (2b) The adapter must point the renderer at the GROK_HOME conf. Without that
# export the renderer falls back to "$HOME/.claude/coralline.conf" and, failing
# that, to its built-in defaults -- which still render a plausible row, so this
# needs an assertion that only holds when the fixture conf was actually read.
render "$GROK" "model" "" "$GROK_SCRIPT"
check "adapter renders the Grok conf's VL_SEGMENTS, not the built-in default" "$(lacks '⬡')"

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

# (5) total_input_tokens wins over context_tokens, through the ADAPTER. Running
# statusline.sh here would assert nothing: it never reads context_tokens.
zeroin=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-zeroin.XXXXXX") || exit 1
jq '{cwd:"/tmp", model:{display_name:"Grok 4.6"},
     context_window:{used_percentage:10, total_input_tokens:0, context_tokens:99999}}' \
  -n > "$zeroin" || exit 1
render "$zeroin" "model ctx" "" "$GROK_SCRIPT"
rm -f "$zeroin"
check "adapter: present total_input_tokens 0 wins over context_tokens" "$(has '↑0')"
check "adapter: present total_input_tokens 0 does not fall through to 99.9k" "$(lacks '99.9k')"

# (5b) With only context_tokens, the adapter still fills the Claude field.
ctxonly=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-ctxonly.XXXXXX") || exit 1
jq '{cwd:"/tmp", model:{display_name:"Grok 4.6"},
     context_window:{used_percentage:10, context_tokens:99999}}' -n > "$ctxonly" || exit 1
render "$ctxonly" "model ctx" "" "$GROK_SCRIPT"
rm -f "$ctxonly"
check "adapter: context_tokens fills ctx when total_input_tokens is absent" "$(has '99.9k')"

# (5c) Neither token field: the gauge stays, the count does not get invented.
# statusline.sh renders a missing count as 0, so this is the same fabrication
# the ↓0 cr:0 cw:0 strip exists to prevent.
notok=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-notok.XXXXXX") || exit 1
jq '{cwd:"/tmp", model:{display_name:"Grok 4.6"},
     context_window:{used_percentage:25}}' -n > "$notok" || exit 1
render "$notok" "model ctx" "" "$GROK_SCRIPT"
rm -f "$notok"
check "adapter: ctx gauge still renders without a token field" "$(has '25%')"
check "adapter: does not fabricate ↑0 when no token field exists" "$(lacks '↑0')"

# (6) Grok must not read Claude Code's VL_LIMIT_SYNC store. statusline.sh builds
# its store as "$CLAUDE_CONFIG_DIR/coralline" and ignores an inherited
# CORALLINE_DIR, so the adapter's CLAUDE_CONFIG_DIR export is the whole
# mechanism.
#
# The store is written by the renderer, not by hand: a hand-made limit-5h.d
# entry is not read back (the name encoding and the emptiness checks in
# rl_latest reject it), which would make every assertion below vacuously true.
# So (6a) has Claude Code's own payload populate the store, and proves the
# fixture is LIVE by reading 5h/7d back out of it. Only then does (6b) ask
# whether a Grok render can see it.
# pwd -P: statusline.sh refuses a store whose path contains a symlink
# (state_no_symlink_path), and on macOS $TMPDIR lives under /var -> /private/var.
# Without this the store is never written and every assertion below passes for
# the wrong reason.
claude_home=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-claude.XXXXXX")" && pwd -P) || exit 1
grok_store=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-store.XXXXXX")" && pwd -P) || exit 1
mkdir -p "$claude_home/.claude" "$grok_store/coralline" || exit 1
sync_extra='VL_LIMIT_SYNC=1
'
seed_conf=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-seed.XXXXXX") || exit 1
{
  printf '. %s\n' "$CONF_TMPL"
  printf 'VL_SEGMENTS="model limit5h limit7d"\n'
  printf 'VL_SEGMENTS2=""\nVL_SEGMENTS3=""\nVL_CLOCK=off\nVL_LIMIT_SYNC=1\n'
} > "$seed_conf"
# The bundled sample resets in 2030, which rl_latest rejects as further ahead
# than the window can be, so the seed payload needs reset times inside the real
# 5h / 7d windows. jq's todate keeps this portable (no date -d vs date -r).
seed_pay=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-seedpay.XXXXXX") || exit 1
jq --argjson a "$(( $(date +%s) + 3000 ))" --argjson b "$(( $(date +%s) + 200000 ))" \
  '.rate_limits.five_hour.resets_at = ($a|todate)
   | .rate_limits.seven_day.resets_at = ($b|todate)' "$SAMPLE" > "$seed_pay" || exit 1
# Write the store (NO_SAMPLE=0 permits mutation; every path is inside the sandbox).
HOME="$claude_home" CLAUDE_CONFIG_DIR="$claude_home/.claude" \
  CORALLINE_CONFIG="$seed_conf" CORALLINE_NO_SAMPLE=0 \
  bash "$SCRIPT" < "$seed_pay" > /dev/null
# Read it back with a payload that carries no rate_limits of its own.
nolimits=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-nolimits.XXXXXX") || exit 1
jq 'del(.rate_limits)' "$SAMPLE" > "$nolimits" || exit 1
out=$(HOME="$claude_home" CLAUDE_CONFIG_DIR="$claude_home/.claude" \
  CORALLINE_CONFIG="$seed_conf" CORALLINE_NO_SAMPLE=1 \
  bash "$SCRIPT" < "$nolimits")
check "(6a) fixture is live: the seeded Claude store renders 5h" "$(has '5h')"
check "(6a) fixture is live: the seeded Claude store renders 7d" "$(has '7d')"
rm -f "$seed_conf" "$nolimits" "$seed_pay"

# (6b) Same HOME, same store, rendered through the Grok adapter.
HOME="$claude_home" TEST_GROK_HOME="$grok_store" \
  render "$GROK" "model ctx limit5h limit7d burn cost" "$sync_extra" "$GROK_SCRIPT"
check "Grok payload does not sync 5h from a Claude store" "$(lacks '5h')"
check "Grok payload does not sync 7d from a Claude store" "$(lacks '7d')"
check "Grok payload does not sync burn from a Claude store" "$(lacks '↗')"

# (6c) The same adapter copy installed under ~/.claude/coralline must still read
# the Grok root. Resolving conf/store from the script's own directory cannot
# tell the two apart and silently hands Grok Claude Code's store.
claude_copy="$claude_home/.claude/coralline"
mkdir -p "$claude_copy" || exit 1
cp "$REPO/statusline.sh" "$claude_copy/statusline.sh" || exit 1
cp "$GROK_SCRIPT" "$claude_copy/statusline-grok.sh" || exit 1
# A Claude conf with limit sync ON sits next to that copy. Without it, an
# adapter that resolved paths from its own directory would read a conf that
# does not exist, fall back to defaults with VL_LIMIT_SYNC=0, and hide the
# Claude store it just leaked into -- the assertions below would pass for the
# wrong reason. This is the shape that originally put 5h/7d on a Grok row.
{
  printf '. %s\n' "$CONF_TMPL"
  printf 'VL_SEGMENTS="model ctx limit5h limit7d burn cost"\n'
  printf 'VL_SEGMENTS2=""\nVL_SEGMENTS3=""\nVL_CLOCK=off\nVL_LIMIT_SYNC=1\n'
} > "$claude_home/.claude/coralline.conf" || exit 1
HOME="$claude_home" TEST_GROK_HOME="$grok_store" \
  render "$GROK" "model ctx limit5h limit7d burn cost" "$sync_extra" "$claude_copy/statusline-grok.sh"
check "adapter under ~/.claude/coralline still hides the Claude 5h store" "$(lacks '5h')"
check "adapter under ~/.claude/coralline still hides the Claude 7d store" "$(lacks '7d')"
rm -rf "$claude_home" "$grok_store"

# (7) Grok conversation total comes from usage.json, not attach-scoped payload cost.
sess=$(mktemp -d "${TMPDIR:-/tmp}/coralline-grok-usage.XXXXXX") || exit 1
: > "$sess/updates.jsonl"
ledger=$(mktemp "${TMPDIR:-/tmp}/coralline-grok-ledger.XXXXXX") || exit 1
jq --arg t "$sess/updates.jsonl" '.transcript_path=$t' "$GROK" > "$ledger" || exit 1
set_ledger() { rm -f "$sess/usage.json"; printf '%s\n' "$1" > "$sess/usage.json"; }

set_ledger '{"session":{"costUsdTicks":41943147200}}'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "Grok usage.json session total overrides attach-scoped payload cost" "$(has '$4.19')"
check "Grok usage.json does not keep the attach-scoped \$1.23" "$(lacks '$1.23')"

# (7b) A real usage.json repeats costUsdTicks under session.modelUsage and under
# every turns[] entry. Reading the first one out of the serialized text is a
# hostage to the writer's key order.
set_ledger '{"models":[{"costUsdTicks":10000000000}],"session":{"costUsdTicks":41943147200}}'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "ledger total is session.costUsdTicks, not the first one in the file" "$(has '$4.19')"

# (7c) Whitespace around the colon is valid JSON.
set_ledger '{"session":{"costUsdTicks" : 41943147200}}'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "ledger tolerates whitespace before the colon" "$(has '$4.19')"

# (7d) Sub-$0.10 remainders: the fraction is 10 decimal places, not 9.
set_ledger '{"session":{"costUsdTicks":401234567}}'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "ledger 401234567 ticks renders \$0.04, not \$0.40" "$(has '$0.04')"

# (7e) A corrupt ledger must fall back to the payload, never blank the row.
set_ledger 'not json at all'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "corrupt ledger falls back to the payload cost" "$(has '$1.23')"
check "corrupt ledger still renders a row" "$([ -n "$out" ] && echo 1 || echo 0)"

# (7f) A ledger without the key falls back too.
set_ledger '{"sessionId":"x","session":{"inputTokens":5}}'
render "$ledger" "model cost" "" "$GROK_SCRIPT"
check "ledger without costUsdTicks falls back to the payload cost" "$(has '$1.23')"
rm -f "$ledger"
rm -rf "$sess"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
