#!/usr/bin/env bash
# End-to-end test for agy (Antigravity CLI) payloads. agy feeds a custom status
# line a Claude-Code-shaped JSON tagged "product":"antigravity" whose limits sit
# in a quota map (gemini-5h/gemini-weekly, 3p-5h/3p-weekly; remaining_fraction,
# reset_time, reset_in_seconds) instead of rate_limits. Fixtures mirror a payload
# captured from agy 1.5.15. Renders the real statusline.sh under the bash running
# this file, so `/bin/bash test/test-agy.sh` checks bash 3.2.
#
#   bash test/test-agy.sh
#
# Exits non-zero if any case fails. Needs bash and jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)   # the stores refuse a symlinked ancestor (macOS /var)
export CLAUDE_CONFIG_DIR="$TMP/cfg"
unset CORALLINE_BURN_FILE CORALLINE_RL5H_FILE CORALLINE_RL7D_FILE
mkdir -p "$CLAUDE_CONFIG_DIR"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model effort limit5h limit7d"\nVL_LIMIT_SYNC=1\n' > "$TMP/conf"

now=$(date +%s)
iso() {  # $1=epoch → ISO UTC (BSD date, then GNU date)
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
R5=$(iso $(( now + 7200 ))); R7=$(iso $(( now + 3 * 86400 )))
LIVE5="{\"remaining_fraction\":0.6706072,\"reset_time\":\"$R5\",\"reset_in_seconds\":7200}"
LIVE7="{\"remaining_fraction\":0.7472552,\"reset_time\":\"$R7\",\"reset_in_seconds\":259200}"
NONE='{"remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z","reset_in_seconds":0}'

agy() {  # $1=model display name $2=quota JSON → payload
  printf '{"product":"antigravity","session_id":"a68a158b-d5c0-444f-9c11-81a0ffb67c68","model":{"id":"%s","display_name":"%s","effort":"high"},"quota":%s}' "$1" "$1" "$2"
}
render() {  # stdin=payload, $1=1 to let the render write the stores → visible text
  local ns=1; [ "${1:-0}" = 1 ] && ns=0
  CORALLINE_NO_SAMPLE=$ns CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" |
    sed 's/\x1b\[[0-9;]*m//g'
}
pills() {  # the limit pills' "label pct" pairs, space-joined
  grep -o '[57][hd] [^ ]* [0-9]*%' | sed 's/ [^ ]* / /' | tr '\n' ' ' | sed 's/ $//'
}

fail=0
check() {  # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n      want=[%s]\n      got =[%s]\n' "$1" "$2" "$3"; fail=1; fi
}

G="{\"gemini-5h\":$LIVE5,\"gemini-weekly\":$LIVE7,\"3p-5h\":$NONE,\"3p-weekly\":$NONE}"
P="{\"gemini-5h\":$NONE,\"gemini-weekly\":$NONE,\"3p-5h\":$LIVE5,\"3p-weekly\":$LIVE7}"

check "Gemini model reads the gemini buckets as used %" "5h 33% 7d 25%" "$(agy 'Gemini 4 Neon (High)' "$G" | render | pills)"
check "Orchestrator counts as Gemini"                   "5h 33% 7d 25%" "$(agy 'Orchestrator (Neon)' "$G" | render | pills)"
check "Claude model reads the 3p buckets"               "5h 33% 7d 25%" "$(agy 'Claude Opus 5.5 (High)' "$P" | render | pills)"
check "GPT model reads the 3p buckets"                  "5h 33% 7d 25%" "$(agy 'GPT-OSS 120B (Medium)' "$P" | render | pills)"
check "bucket without a live window is hidden"          ""              "$(agy 'Claude Opus 5.5 (High)' "$G" | render | pills)"
check "effort falls back to model.effort" "ψ high" "$(agy 'Gemini 4 Neon (High)' "$G" | render | grep -o 'ψ high')"
rl="{\"product\":\"antigravity\",\"model\":{\"display_name\":\"Gemini 4 Neon (High)\"},\"quota\":$G,\"rate_limits\":{\"five_hour\":{\"used_percentage\":50,\"resets_at\":$(( now + 3600 ))}}}"
check "a payload's own rate_limits wins over quota"     "5h 50%"        "$(printf '%s' "$rl" | render | pills)"

# Store isolation: Claude Code's windows stay out of agy and agy's out of Claude.
cc="{\"model\":{\"display_name\":\"Opus\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":80,\"resets_at\":$(( now + 3600 ))},\"seven_day\":{\"used_percentage\":60,\"resets_at\":$(( now + 86400 ))}}}"
printf '%s' "$cc" | render 1 >/dev/null
check "a Claude session borrows its own store"          "5h 80% 7d 60%" "$(printf '{"model":{"display_name":"Opus"}}' | render | pills)"
check "agy never shows Claude's stored windows"         ""              "$(agy 'Gemini 4 Neon (High)' "{}" | render | pills)"
agy 'Gemini 4 Neon (High)' "$G" | render 1 >/dev/null
check "agy sessions share their own store"              "5h 33% 7d 25%" "$(agy 'Gemini 4 Neon (High)' "{}" | render | pills)"
check "agy's windows never reach Claude's store"        "5h 80% 7d 60%" "$(printf '{"model":{"display_name":"Opus"}}' | render | pills)"
check "agy wrote only under its own namespace" "limit-5h-agy-gemini.d" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d limit-5h*agy*)"
check "agy writes no toks state" "" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d toks-* 2>/dev/null)"

exit "$fail"
