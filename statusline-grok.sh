#!/usr/bin/env bash
# coralline — Grok Build statusline entrypoint
# https://github.com/Nanako0129/coralline
#
# Translates Grok's command-row JSON into the Claude-shaped payload
# statusline.sh already understands, then runs that renderer. Claude Code
# keeps calling statusline.sh directly. This file is the only Grok host
# adapter: field names, usage.json conversation cost, and GROK_HOME conf/store.

HERE=$(cd "$(dirname "$0")" && pwd)
RENDERER="$HERE/statusline.sh"

GROK_ROOT="${GROK_HOME:-$HOME/.grok}"
export CORALLINE_CONFIG="${CORALLINE_CONFIG:-$GROK_ROOT/coralline.conf}"
export CORALLINE_DIR="${CORALLINE_DIR:-$GROK_ROOT/coralline}"
# statusline.sh (unchanged) sets CORALLINE_DIR from CLAUDE_CONFIG_DIR.
# Point that at Grok's store so the Claude renderer does not use ~/.claude.
case "$CORALLINE_DIR" in
  */coralline) export CLAUDE_CONFIG_DIR="${CORALLINE_DIR%/coralline}" ;;
  *)           export CLAUDE_CONFIG_DIR="$CORALLINE_DIR" ;;
esac

# -d '' reads until NUL (all of stdin) without forking.
# -t 5 prevents zombie bash on MSYS2 where pipe EOF may never arrive.
read -t 5 -r -d '' input || true

grok_usage_usd() {  # $1=transcript_path → _GUSD
  local usage line ticks d r
  _GUSD=""
  [ -n "$1" ] || return 0
  usage="${1%/*}/usage.json"
  [ "$usage" != "/usage.json" ] && [ "$usage" != "$1" ] || return 0
  [ -f "$usage" ] && [ -r "$usage" ] || return 0
  ticks=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *'"costUsdTicks":'*)
        ticks="${line#*\"costUsdTicks\":}"
        ticks="${ticks%%,*}"
        ticks="${ticks%%\}*}"
        ticks="${ticks#"${ticks%%[![:space:]]*}"}"
        ticks="${ticks%"${ticks##*[![:space:]]}"}"
        break
        ;;
    esac
  done < "$usage"
  case "$ticks" in (''|*[!0-9]*) return 0 ;; esac
  [ "${#ticks}" -le 18 ] || return 0
  d=$((10#$ticks / 10000000000))
  r=$((10#$ticks % 10000000000))
  printf -v _GUSD '%d.%010d' "$d" "$r"
}

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$RENDERER" ] || exit 0

tp=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || tp=""
grok_usage_usd "$tp"

mapped=$(printf '%s' "$input" | jq -c --arg usd "${_GUSD:-}" '
  def member($obj; $name):
    if ($obj|type) == "object" and ($obj|has($name)) then $obj[$name] else null end;
  if type != "object" then empty else
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
         + (if member($ctx; "context_tokens") != null then
              { total_input_tokens: member($ctx; "context_tokens") }
            elif member($ctx; "total_input_tokens") != null then
              { total_input_tokens: member($ctx; "total_input_tokens") }
            else {} end)
       )
     } end)
  + (if $usd != "" then
       { cost: (
           { total_cost_usd: ($usd | tonumber) }
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
' 2>/dev/null) || mapped=""

[ -n "$mapped" ] || exit 0
# statusline.sh always prints ↑/↓/cr:/cw: and treats missing counts as 0.
# Strip the zeros Grok cannot source, rather than changing the Claude renderer.
out=$(printf '%s' "$mapped" | bash "$RENDERER")
[ -n "$out" ] || exit 0
out="${out// ↓0 cr:0 cw:0/}"
printf '%s\n' "$out"
