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
W="{\"gemini-5h\":$NONE,\"gemini-weekly\":{\"remaining_fraction\":0.5,\"reset_time\":\"$R7\",\"reset_in_seconds\":259200}}"
check "agy with an unopened 5h borrows a stored one"    "5h 33% 7d 50%" "$(agy 'Gemini 4 Neon (High)' "$W" | render | pills)"
check "control: Claude with a live 7d and no 5h does not" "7d 60%"      "$(printf '{"model":{"display_name":"Opus"},"rate_limits":{"seven_day":{"used_percentage":60,"resets_at":%s}}}' $(( now + 86400 )) | render | pills)"
check "agy wrote only under its own namespace" "limit-5h-agy-gemini.d" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d limit-5h*agy*)"
check "agy writes no toks state" "" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d toks-* 2>/dev/null)"
agy 'Claude Opus 5.5 (High)' "$P" | render 1 >/dev/null
check "third-party models get their own namespace" "limit-5h-agy-3p.d" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d limit-5h*3p*)"
printf 'VL_CLOCK=off\nVL_SEGMENTS="limit5h burn"\nVL_LIMIT_SYNC=1\n' > "$TMP/burnconf"
agy 'Gemini 4 Neon (High)' "$G" | CORALLINE_NO_SAMPLE=0 CORALLINE_CONFIG="$TMP/burnconf" "$BASH" "$SCRIPT" >/dev/null
check "agy burn samples land in their own file" "burn-5h-agy-gemini.tsv" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls burn-5h*.tsv)"

# With sync off an unopened agy 5h gets no projection from burn history: seed a
# steep 5h history in agy's burn file, then burn must bind to the weekly window.
printf 'VL_CLOCK=off\nVL_SEGMENTS="burn"\n' > "$TMP/nosyncconf"
i=0; while [ "$i" -lt 30 ]; do
  printf '%s\t%s.000\t%s\n' $(( now - 300 + i * 10 )) $(( 10 + i )) $(( now + 3600 ))
  i=$((i + 1))
done > "$CLAUDE_CONFIG_DIR/coralline/burn-5h-agy-gemini.tsv"
check "sync off: unopened agy 5h gets no burn projection" "7d" \
  "$(agy 'Gemini 4 Neon (High)' "$W" | CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$TMP/nosyncconf" COLUMNS=200 "$BASH" "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '[57][hd] ⇢' | cut -c1-2)"

# toks/ttft never sample agy's transcript nor show a seeded state; cost never pads $0.00.
# The payloads carry API time and token counts, so without the agy guard the
# sampler would write and show state.
printf 'VL_CLOCK=off\nVL_SEGMENTS="model toks ttft cost"\nVL_COST_ALWAYS_SHOW=1\n' > "$TMP/toksconf"
agyt() {  # $1=product ("" = a Claude Code payload) → visible text
  printf '{"product":"%s","session_id":"a68a158b-d5c0-444f-9c11-81a0ffb67c68","model":{"display_name":"Gemini 4 Neon (High)"},"context_window":{"total_input_tokens":10,"total_output_tokens":10},"cost":{"total_api_duration_ms":5000}}' "$1" |
    CORALLINE_NO_SAMPLE=0 CORALLINE_CONFIG="$TMP/toksconf" COLUMNS=200 "$BASH" "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g'
}
out=$(agyt antigravity)
check "agy with toks/ttft enabled writes no toks state" "" "$(cd "$CLAUDE_CONFIG_DIR/coralline" && ls -d toks-* 2>/dev/null)"
check "agy shows no cost under VL_COST_ALWAYS_SHOW" "" "$(printf '%s' "$out" | grep -o '\$[0-9.]*')"
printf 'a68a158b-d5c0-444f-9c11-81a0ffb67c68 5000 10:10 4321 10:10 5000 4321 250 0\n' > "$CLAUDE_CONFIG_DIR/coralline/toks-a68a158b-d5c0-444f-9c11-81a0ffb67c68"
check "control: a Claude payload shows the seeded toks state" "tok/s 0.3s" "$(agyt '' | grep -o 'tok/s\|0\.3s' | tr '\n' ' ' | sed 's/ $//')"
check "agy ignores a seeded toks state" "" "$(agyt antigravity | grep -o 'tok/s\|0\.3s')"

# subagents: only running entries count (agy keeps finished ones listed).
printf 'VL_CLOCK=off\nVL_SEGMENTS="model subagents"\n' > "$TMP/subconf"
sub() {  # $1=subagents JSON → the segment's text ("" = hidden)
  printf '{"product":"antigravity","model":{"display_name":"Gemini 4 Neon (High)"},"subagents":%s}' "$1" |
    CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$TMP/subconf" COLUMNS=200 "$BASH" "$SCRIPT" | sed 's/\x1b\[[0-9;]*m//g' | grep -o '⇉ [0-9]*'
}
R='{"name":"scout","role":"a","model":"Gemini 4 Hydrogen (High)","status":"running"}'
C='{"name":"scout","role":"b","model":"Gemini 4 Hydrogen (High)","status":"completed"}'
check "two running subagents"            "⇉ 2" "$(sub "[$R,$R,$C]")"
check "finished subagents are not shown" ""    "$(sub "[$C,$C]")"
check "empty list hidden"                ""    "$(sub '[]')"
check "malformed list hidden"            ""    "$(sub '{"status":"running"}')"
check "upper-case key counts nothing"    ""    "$(sub '[{"STATUS":"running"}]')"
check "soft hyphen or NUL counts nothing" ""   "$(sub '[{"sta\u00adtus":"running"},{"status":"run\u0000ning"}]')"
check "bad entries count nothing"         ""    "$(sub '["running",{"status":1},{"status":"Running"},null]')"
check "Claude Code payload hidden"       ""    "$(printf '{"model":{"display_name":"Opus"}}' | CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$TMP/subconf" "$BASH" "$SCRIPT" | grep -o '⇉')"

# reset_time is cut to whole-second UTC; any other offset drops the window.
rt() {  # $1=reset_time → the 5h pill's "label pct", rendered with sync on and an empty store
  agy 'Gemini 4 Neon (High)' "{\"gemini-5h\":{\"remaining_fraction\":0.5,\"reset_time\":\"$1\",\"reset_in_seconds\":7200}}" |
    CLAUDE_CONFIG_DIR="$TMP/cfg-rt" render | pills
}
check "fractional seconds accepted"  "5h 50%" "$(rt "${R5%Z}.123456789Z")"
check "+00:00 offset accepted"       "5h 50%" "$(rt "${R5%Z}+00:00")"
check "no offset dropped"            ""       "$(rt "${R5%Z}")"
check "other offset dropped"         ""       "$(rt "${R5%Z}+05:00")"

# An empty store path keeps that store off instead of landing beside the cwd.
mkdir -p "$TMP/cwd"
printf 'VL_CLOCK=off\nVL_SEGMENTS="limit5h burn"\nVL_LIMIT_SYNC=1\nBURN_FILE=""\nRL5H_FILE=""\n' > "$TMP/emptyconf"
( cd "$TMP/cwd" && agy 'Gemini 4 Neon (High)' "$G" | CORALLINE_NO_SAMPLE=0 CORALLINE_CONFIG="$TMP/emptyconf" "$BASH" "$SCRIPT" >/dev/null )
check "empty store path writes nothing in cwd" "" "$(ls -A "$TMP/cwd")"

exit "$fail"
