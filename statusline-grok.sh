#!/usr/bin/env bash
# coralline — Grok Build statusline entrypoint
# https://github.com/Nanako0129/coralline
#
# Translates Grok's command-row JSON into the Claude-shaped payload
# statusline.sh already understands, then runs that renderer. Claude Code
# keeps calling statusline.sh directly. This file is the only Grok host
# adapter: field names, usage.json conversation cost, and GROK_HOME conf/store.

# ${0%/*} instead of $(cd "$(dirname "$0")" && pwd): two fewer forks on a path
# that runs every refresh_interval. Falls back to "." for a bare-name argv[0].
HERE="${0%/*}"
[ "$HERE" != "$0" ] || HERE="."
RENDERER="$HERE/statusline.sh"

# GROK_HOME is the only source of truth for conf and store. Deriving them from
# this script's own location cannot tell ~/.grok/coralline from
# ~/.claude/coralline -- install_files puts a copy in the latter, and that copy
# would then read Claude Code's conf and limit store, resurfacing 5h/7d/burn.
# statusline.sh:72 builds its store as "$CLAUDE_CONFIG_DIR/coralline" and
# ignores an inherited CORALLINE_DIR, so CLAUDE_CONFIG_DIR is what must move.
GROK_ROOT="${GROK_HOME:-$HOME/.grok}"
export CORALLINE_CONFIG="$GROK_ROOT/coralline.conf"
export CLAUDE_CONFIG_DIR="$GROK_ROOT"

# -d '' reads until NUL (all of stdin) without forking.
# -t 5 prevents zombie bash on MSYS2 where pipe EOF may never arrive.
read -t 5 -r -d '' input || true

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$RENDERER" ] || exit 0

# Grok's payload cost.total_cost_usd restarts at each process attach, so after a
# resume it is not the conversation total Claude's field means. The session
# ledger next to transcript_path carries the real total as costUsdTicks (USD *
# 10^10). Read it with jq: scanning the serialized text picks up whichever
# costUsdTicks the writer happened to emit first, and a real usage.json repeats
# that key under session.modelUsage and under every entry of turns[].
tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""
usage=""
if [ -n "$tp" ]; then
  usage="${tp%/*}/usage.json"
  [ "$usage" != "$tp" ] && [ -f "$usage" ] && [ -r "$usage" ] || usage=""
fi

# $u is the slurped ledger ([] when there is none). Missing fields stay missing
# rather than becoming 0, so segments Grok cannot source hide themselves.
FILTER='
  def member($obj; $name):
    if ($obj|type) == "object" and ($obj|has($name)) then $obj[$name] else null end;
  if type != "object" then empty else
  (((($u[0]? | .session? | .costUsdTicks?) // null)) as $t
   | if ($t|type) == "number" and $t >= 0 then ($t / 10000000000) else null end) as $usd |
  (member(member(.; "workspace"); "current_dir") // member(.; "cwd") // "") as $cwd |
  (member(.; "context_window")) as $ctx |
  (member(.; "cost")) as $cost |
  (member(.; "effort")) as $effort |
  {
    cwd: $cwd,
    workspace: { current_dir: $cwd },
    model: { display_name: (member(member(.; "model"); "display_name") // "") }
  }
  + (if $effort == null then {} else { effort: $effort } end)
  + (if $ctx == null then {}
     else {
       context_window: (
         {}
         + (if member($ctx; "used_percentage") != null then
              { used_percentage: member($ctx; "used_percentage") } else {} end)
         + (if member($ctx; "total_input_tokens") != null then
              { total_input_tokens: member($ctx; "total_input_tokens") }
            elif member($ctx; "context_tokens") != null then
              { total_input_tokens: member($ctx; "context_tokens") }
            else {} end)
       )
     } end)
  + (if $usd != null then
       { cost: (
           { total_cost_usd: $usd }
           + (if member($cost; "total_duration_ms") != null then
                { total_duration_ms: member($cost; "total_duration_ms") } else {} end)
         ) }
     elif $cost == null then {}
     else {
       cost: (
         {}
         + (if member($cost; "total_cost_usd") != null then
              { total_cost_usd: member($cost; "total_cost_usd") } else {} end)
         + (if member($cost; "total_duration_ms") != null then
              { total_duration_ms: member($cost; "total_duration_ms") } else {} end)
       )
     } end)
  end
'

mapped=""
if [ -n "$usage" ]; then
  mapped=$(printf '%s' "$input" | jq -c --slurpfile u "$usage" "$FILTER" 2>/dev/null) || mapped=""
fi
# A corrupt or unreadable ledger must not blank the row: retry without it.
[ -n "$mapped" ] || mapped=$(printf '%s' "$input" | jq -c --argjson u '[]' "$FILTER" 2>/dev/null) || mapped=""

[ -n "$mapped" ] || exit 0
# statusline.sh always prints ↑/↓/cr:/cw: and treats missing counts as 0.
# Strip the zeros Grok cannot source, rather than changing the Claude renderer.
out=$(printf '%s' "$mapped" | bash "$RENDERER")
[ -n "$out" ] || exit 0
out="${out// ↓0 cr:0 cw:0/}"
# ↑ goes too when neither source field was present, since a bare ↑0 fabricates
# a count exactly as ↓0 cr:0 cw:0 would. A payload that really carries
# total_input_tokens: 0 keeps its ↑0: that zero is measured, not invented.
case "$mapped" in
  *'"total_input_tokens"'*) ;;
  *) out="${out//↑0 /}" ;;
esac
printf '%s\n' "$out"
