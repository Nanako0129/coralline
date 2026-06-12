#!/usr/bin/env bash
# coralline — a configurable, Powerlevel10k-inspired statusline for Claude Code
# https://github.com/Nanako0129/coralline
# Visual style is a tribute to https://github.com/romkatv/powerlevel10k
#
# Design goals:
#   * One jq call, one git call — cheap enough for refreshInterval: 1
#   * Pure bash arithmetic (no bc), works on macOS bash 3.2 and Linux
#   * Everything themeable via ~/.claude/coralline.conf (sourced bash)
#
# Requires: jq, and a Nerd Font terminal unless VL_ASCII=1

input=$(cat)

# ── Defaults (every value can be overridden by the config file) ──────────────
VL_STYLE="pill"                 # pill: powerline pills · lean: p10k-lean flat text
VL_LEAN_SEP=""                  # lean only — extra text between segments, e.g. "·"
VL_LAYOUT="fixed"               # fixed: one line per VL_SEGMENTS* var
                                # auto:  single line, wraps when the window is narrow
VL_MAX_LINES=2                  # auto only — wrap into at most this many lines
# Athena fork default order: IP first · worktree beside git · agent beside model
# · 200k alert last. Reset to upstream with "dir git model ctx limit5h limit7d cost clock".
VL_SEGMENTS="ip dir git worktree model agent ctx limit5h limit7d cost clock warn200k"
VL_SEGMENTS2=""                 # fixed only — optional second line
VL_SEGMENTS3=""                 # fixed only — optional third line
VL_BAR_WIDTH=5
VL_BAR_FILL="▰"
VL_BAR_EMPTY="▱"
VL_CLOCK="12h"                  # 12h | 24h | off
VL_CLOCK_SECONDS=1
VL_PATH_DEPTH=4                 # collapse paths deeper than this
VL_COST_DECIMALS=2
VL_WARN_PCT=50                  # percentage thresholds for bar colors
VL_HOT_PCT=75
VL_ASCII=0                      # 1 = no Nerd Font glyphs (plain colored blocks)

# Powerline glyphs (overridable; cleared when VL_ASCII=1)
VL_CAP_L=$(printf '\xee\x82\xb6')   # U+E0B6 left rounded cap
VL_CAP_R=$(printf '\xee\x82\xb4')   # U+E0B4 right rounded cap
VL_SEP=$(printf '\xee\x82\xb0')     # U+E0B0 segment separator

# Default theme: claude-coral (steel blue · mauve · Claude coral)
VL_BG_DIR="81,166,199"
VL_BG_GIT_OK=65
VL_BG_GIT_DIRTY=130
VL_BG_MODEL=173
VL_BG_CTX=238
VL_BG_5H=237
VL_BG_7D=236
VL_BG_COST="212,125,145"
VL_BG_CLOCK="70,80,110"
VL_BG_LINES=240
VL_BG_STYLE=96
VL_BG_DURATION=60

# Athena fork segments (per-theme overrides live in the theme .conf files)
VL_BG_IP="72,160,170"           # machine IP — steel teal
VL_BG_AGENT=97                  # subagent — mauve (sits next to model)
VL_BG_WT=66                     # git worktree — teal-green (sits next to git)
VL_BG_WARN=""                   # 200k-token alert — empty = reuse the theme's hot color (VL_FG_HOT)

VL_FG_TEXT=231
VL_FG_DIM=245
VL_FG_OK=114
VL_FG_WARN=179
VL_FG_HOT=167
VL_FG_ALERT=""                  # text on the 200k alert pill — empty = reuse VL_FG_TEXT

# ── Load user config ─────────────────────────────────────────────────────────
VL_CONF="${CORALLINE_CONFIG:-$HOME/.claude/coralline.conf}"
[ -f "$VL_CONF" ] && . "$VL_CONF"

if [ "$VL_ASCII" = "1" ]; then
  VL_CAP_L="" ; VL_CAP_R="" ; VL_SEP=""
  VL_BAR_FILL="#" ; VL_BAR_EMPTY="-"
fi

# Lean style: no backgrounds or caps; each segment's VL_BG_* becomes its text
# accent color (an empty VL_FG_TEXT lets text inherit that accent).
if [ "$VL_STYLE" = "lean" ]; then
  VL_CAP_L="" ; VL_CAP_R=""
  VL_FG_TEXT="${VL_LEAN_FG:-}"
fi

# The 200k alert reuses the theme's hot/alert color and normal text unless the
# theme or user overrides them — softer and theme-consistent, not an alarm red.
: "${VL_BG_WARN:=$VL_FG_HOT}"
: "${VL_FG_ALERT:=$VL_FG_TEXT}"

# ── Parse JSON (single jq call) ──────────────────────────────────────────────
# Fields are joined with \x1f (unit separator): unlike tab, a non-whitespace
# IFS preserves empty fields instead of collapsing consecutive delimiters.
IFS=$'\037' read -r cwd model ctx_pct tok_in tok_out tok_cr tok_cw \
                 fh_pct fh_rst wd_pct wd_rst cost \
                 lines_add lines_del out_style dur_ms \
                 agent worktree exceeds200k <<JSON
$(printf '%s' "$input" | jq -r '[
  (.workspace.current_dir // .cwd // ""),
  (.model.display_name // ""),
  (.context_window.used_percentage // "" | tostring),
  (.context_window.total_input_tokens // 0),
  (.context_window.total_output_tokens // 0),
  (.context_window.current_usage.cache_read_input_tokens // 0),
  (.context_window.current_usage.cache_creation_input_tokens // 0),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.five_hour.resets_at // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring),
  (.rate_limits.seven_day.resets_at // "" | tostring),
  (.cost.total_cost_usd // "" | tostring),
  (.cost.total_lines_added // 0),
  (.cost.total_lines_removed // 0),
  (.output_style.name // ""),
  (.cost.total_duration_ms // 0),
  (.agent.name // ""),
  (.worktree.name // ""),
  (.exceeds_200k_tokens // false | tostring)
] | map(tostring) | join("\u001f")' 2>/dev/null)
JSON

# ── ANSI primitives ──────────────────────────────────────────────────────────
R=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'

# bg/fg accept 256-color (single number) or true-color ("R,G,B");
# an empty argument emits nothing (the text inherits the current color)
bg() {
  [ -n "$1" ] || return 0
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf '\033[48;5;%sm' "$1"; fi
}
fg() {
  [ -n "$1" ] || return 0
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf '\033[38;5;%sm' "$1"; fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────
make_bar() {
  local pct="${1:-0}" width="${2:-$VL_BAR_WIDTH}" bar="" i filled
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  for ((i=0; i<filled; i++));        do bar="${bar}${VL_BAR_FILL}";  done
  for ((i=filled; i<width; i++));    do bar="${bar}${VL_BAR_EMPTY}"; done
  printf '%s' "$bar"
}

# 1234 → 1.2k · 1234567 → 1.2M (integer math only)
fmt_tok() {
  local n="${1:-0}"
  case "$n" in (''|*[!0-9]*) printf '%s' "$n"; return ;; esac
  if   [ "$n" -ge 1000000 ]; then printf '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [ "$n" -ge 1000 ];    then printf '%d.%dk' $((n/1000))    $(((n%1000)/100))
  else printf '%s' "$n"; fi
}

# Accepts epoch seconds (with or without decimals) or an ISO 8601 timestamp.
to_epoch() {
  local t="$1" s
  [ -z "$t" ] && return 1
  case "$t" in
    *T*)  # ISO 8601 — try GNU date, then BSD date (assume UTC if tz lost)
      date -u -d "$t" +%s 2>/dev/null && return 0
      s="${t%%[.+]*}" ; s="${s%Z}"
      date -ju -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null && return 0
      return 1 ;;
    *[0-9]*) printf '%s' "${t%%.*}" ;;
    *) return 1 ;;
  esac
}

fmt_countdown() {
  local rst epoch now diff d h m
  rst=$(to_epoch "$1") || return 0
  now=$(date +%s)
  diff=$(( rst - now ))
  if [ "$diff" -le 0 ]; then printf 'now'; return; fi
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else                      printf '%dm' "$m"; fi
}

fmt_duration() {
  local ms="${1:-0}" s h m
  s=$(( ms / 1000 )); h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else                      printf '%ds' "$s"; fi
}

pct_fg() {
  local pct="${1:-0}"
  if   [ "$pct" -ge "$VL_HOT_PCT" ];  then printf '%s' "$VL_FG_HOT"
  elif [ "$pct" -ge "$VL_WARN_PCT" ]; then printf '%s' "$VL_FG_WARN"
  else                                     printf '%s' "$VL_FG_OK"; fi
}

# ── Git state (single subprocess, parsed once, used by git/stash segments) ──
GIT_BRANCH="" GIT_MARKS="" GIT_AB="" GIT_DIRTY=0
read_git() {
  local line oid="" head="" a="" b="" staged=0 unstaged=0 untracked=0
  [ -n "$cwd" ] || return
  while IFS= read -r line; do
    case "$line" in
      "# branch.oid "*)      oid="${line#\# branch.oid }" ;;
      "# branch.head "*)     head="${line#\# branch.head }" ;;
      "# branch.ab "*)       set -- ${line#\# branch.ab }; a="${1#+}"; b="${2#-}" ;;
      "? "*)                 untracked=1 ;;
      [12]" "*)              line="${line#? }"
                             case "${line:0:1}" in [!.]) staged=1 ;; esac
                             case "${line:1:1}" in [!.]) unstaged=1 ;; esac ;;
      "u "*)                 unstaged=1 ;;
    esac
  done <<GIT
$(git -C "$cwd" status --porcelain=v2 --branch 2>/dev/null)
GIT
  [ -z "$oid" ] && return                     # not a repo
  if [ "$head" = "(detached)" ] || [ -z "$head" ]; then
    GIT_BRANCH="${oid:0:7}"
  else
    GIT_BRANCH="$head"
  fi
  [ "$staged"    -eq 1 ] && GIT_MARKS="${GIT_MARKS}+"
  [ "$unstaged"  -eq 1 ] && GIT_MARKS="${GIT_MARKS}!"
  [ "$untracked" -eq 1 ] && GIT_MARKS="${GIT_MARKS}?"
  [ "${a:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇡${a}"
  [ "${b:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇣${b}"
  [ -n "$GIT_MARKS" ] && GIT_DIRTY=1
}
case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" git "*|*" stash "*) read_git ;; esac

# ── Local IP (cached; resolved only when the ip segment is enabled) ──────────
# A network lookup every refresh would defeat the one-jq/one-git budget, so the
# result is cached in TMPDIR for VL_IP_TTL seconds (IPs rarely change mid-session).
VL_IP=""
read_ip() {
  local cache="${TMPDIR:-/tmp}/coralline-ip" mt now iface
  now=$(date +%s)
  if [ -f "$cache" ]; then
    mt=$(stat -f %m "$cache" 2>/dev/null || stat -c %Y "$cache" 2>/dev/null || echo 0)
    if [ "$(( now - mt ))" -lt "${VL_IP_TTL:-30}" ]; then
      VL_IP=$(cat "$cache" 2>/dev/null); return
    fi
  fi
  if command -v ipconfig >/dev/null 2>&1; then            # macOS
    iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    [ -n "$iface" ] && VL_IP=$(ipconfig getifaddr "$iface" 2>/dev/null)
    [ -z "$VL_IP" ] && VL_IP=$(ipconfig getifaddr en0 2>/dev/null)
    [ -z "$VL_IP" ] && VL_IP=$(ipconfig getifaddr en1 2>/dev/null)
  fi
  if [ -z "$VL_IP" ] && command -v ip >/dev/null 2>&1; then   # Linux (iproute2)
    VL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  fi
  [ -z "$VL_IP" ] && command -v hostname >/dev/null 2>&1 && VL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '%s' "$VL_IP" > "$cache" 2>/dev/null
}
case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" ip "*) read_ip ;; esac

# ── Segments ─────────────────────────────────────────────────────────────────
# Each seg_* appends (background, text, visible width) to the segment arrays.
ESC=$'\033'
seg_len() {  # visible char count of $1 with ANSI sequences stripped → SEG_LEN_R
  local s="$1" plain=""
  while [ "${s#*$ESC}" != "$s" ]; do
    plain+="${s%%$ESC*}"
    s="${s#*$ESC}" ; s="${s#*m}"
  done
  plain+="$s"
  SEG_LEN_R=${#plain}
}
push() {
  seg_len "$2"
  SEG_BGS[${#SEG_BGS[@]}]="$1"
  SEG_TXT[${#SEG_TXT[@]}]="$2"
  SEG_LEN[${#SEG_LEN[@]}]="$SEG_LEN_R"
}

seg_dir() {
  [ -n "$cwd" ] || return 0
  local short="${cwd/#$HOME/~}" n
  local IFS='/'; set -- $short; n=$#
  if [ "$n" -gt "$VL_PATH_DEPTH" ]; then
    eval "last=\${$n}"
    short="$1/$2/…/$last"
  fi
  push "$VL_BG_DIR" "${BOLD}$(fg $VL_FG_TEXT) ${short} ${NORM}"
}

seg_git() {
  [ -n "$GIT_BRANCH" ] || return 0
  local bgc="$VL_BG_GIT_OK"
  [ "$GIT_DIRTY" -eq 1 ] && bgc="$VL_BG_GIT_DIRTY"
  push "$bgc" "${BOLD}$(fg $VL_FG_TEXT) ⎇ ${GIT_BRANCH}${GIT_MARKS}${GIT_AB} ${NORM}"
}

seg_model() {
  [ -n "$model" ] || return 0
  push "$VL_BG_MODEL" "${BOLD}$(fg $VL_FG_TEXT) ◆ ${model#Claude } ${NORM}"
}

seg_ctx() {
  [ -n "$ctx_pct" ] || return 0
  local ci bar cn
  ci=$(printf '%.0f' "$ctx_pct" 2>/dev/null) || ci=0
  bar=$(make_bar "$ci"); cn=$(pct_fg "$ci")
  push "$VL_BG_CTX" "$(fg $cn) ⬡ ${bar} ${ci}% $(fg $VL_FG_DIM)↑$(fmt_tok $tok_in) ↓$(fmt_tok $tok_out) cr:$(fmt_tok $tok_cr) cw:$(fmt_tok $tok_cw) "
}

seg_limit() {  # $1=label $2=pct $3=resets_at $4=bg
  [ -n "$2" ] || return 0
  local v bar cn cd rst=""
  v=$(printf '%.0f' "$2" 2>/dev/null) || v=0
  bar=$(make_bar "$v"); cn=$(pct_fg "$v")
  cd=$(fmt_countdown "$3")
  [ -n "$cd" ] && rst="$(fg $VL_FG_DIM)↺${cd}"
  push "$4" "$(fg $cn) $1 ${bar} ${v}% ${rst} "
}
seg_limit5h() { seg_limit "5h" "$fh_pct" "$fh_rst" "$VL_BG_5H"; }
seg_limit7d() { seg_limit "7d" "$wd_pct" "$wd_rst" "$VL_BG_7D"; }

seg_cost() {
  [ -n "$cost" ] && [ "$cost" != "0" ] || return 0
  local fmt
  fmt=$(printf "\$%.${VL_COST_DECIMALS}f" "$cost" 2>/dev/null) || fmt="\$$cost"
  push "$VL_BG_COST" "$(fg $VL_FG_TEXT) ${fmt} "
}

seg_clock() {
  [ "$VL_CLOCK" = "off" ] && return 0
  local t ap=""
  if [ "$VL_CLOCK" = "24h" ]; then
    t=$(date '+%H:%M'); [ "$VL_CLOCK_SECONDS" = "1" ] && t=$(date '+%H:%M:%S')
  else
    t=$(date '+%I:%M'); [ "$VL_CLOCK_SECONDS" = "1" ] && t=$(date '+%I:%M:%S')
    ap=" $(LC_ALL=C date '+%p' | tr '[:upper:]' '[:lower:]')"
  fi
  push "$VL_BG_CLOCK" "$(fg $VL_FG_TEXT) ⊙ ${t}${ap} "
}

seg_lines() {
  [ "${lines_add:-0}" -gt 0 ] 2>/dev/null || [ "${lines_del:-0}" -gt 0 ] 2>/dev/null || return 0
  push "$VL_BG_LINES" " $(fg $VL_FG_OK)+${lines_add} $(fg $VL_FG_HOT)-${lines_del} "
}

seg_style() {
  [ -n "$out_style" ] && [ "$out_style" != "default" ] || return 0
  push "$VL_BG_STYLE" "$(fg $VL_FG_TEXT) ✎ ${out_style} "
}

seg_duration() {
  [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null || return 0
  push "$VL_BG_DURATION" "$(fg $VL_FG_TEXT) ⧖ $(fmt_duration $dur_ms) "
}

seg_stash() {
  [ -n "$GIT_BRANCH" ] || return 0
  local n
  n=$(git -C "$cwd" rev-list --walk-reflogs --count refs/stash 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  push "$VL_BG_GIT_OK" "$(fg $VL_FG_TEXT) ⚑ ${n} "
}

# ── Athena fork segments ─────────────────────────────────────────────────────
seg_ip() {        # machine IP, pinned to the very start of the line
  [ -n "$VL_IP" ] || return 0
  push "$VL_BG_IP" "${BOLD}$(fg $VL_FG_TEXT) ⌂ ${VL_IP} ${NORM}"
}

seg_agent() {     # active subagent, sits right after the model
  [ -n "$agent" ] || return 0
  push "$VL_BG_AGENT" "${BOLD}$(fg $VL_FG_TEXT) ❖ ${agent} ${NORM}"
}

seg_worktree() {  # git worktree name, sits right after git
  [ -n "$worktree" ] || return 0
  push "$VL_BG_WT" "${BOLD}$(fg $VL_FG_TEXT) ⑂ ${worktree} ${NORM}"
}

seg_warn200k() {  # 200k-token overflow alert, pinned to the very end
  [ "$exceeds200k" = "true" ] || return 0
  push "$VL_BG_WARN" "${BOLD}$(fg $VL_FG_ALERT) ⚠ 200k ${NORM}"
}

# ── Render ───────────────────────────────────────────────────────────────────
build_segments() {
  local s
  SEG_BGS=() ; SEG_TXT=() ; SEG_LEN=()
  for s in $1; do
    command -v "seg_$s" >/dev/null 2>&1 && "seg_$s"
  done
}

print_range() {  # render segments $1..$2 (inclusive) as one row
  local i out next
  if [ "$VL_STYLE" = "lean" ]; then
    out=""
    for ((i=$1; i<=$2; i++)); do
      out+="${R}$(fg ${SEG_BGS[$i]})${SEG_TXT[$i]}"
      [ "$i" -lt "$2" ] && out+="${R}${VL_LEAN_SEP}"
    done
    printf '%s\n' "${out}${R}"
    return 0
  fi
  out="${R}$(fg ${SEG_BGS[$1]})${VL_CAP_L}"
  for ((i=$1; i<=$2; i++)); do
    out+="$(bg ${SEG_BGS[$i]})${SEG_TXT[$i]}"
    if [ "$i" -lt "$2" ]; then
      next="${SEG_BGS[$((i+1))]}"
      out+="$(bg $next)$(fg ${SEG_BGS[$i]})${VL_SEP}"
    fi
  done
  out+="${R}$(fg ${SEG_BGS[$2]})${VL_CAP_R}${R}"
  printf '%s\n' "$out"
}

# Terminal width for auto layout; 0 = unknown (then stay on one line).
term_cols() {
  local c=""
  if [ -n "$COLUMNS" ]; then
    c="$COLUMNS"
  else
    c=$(stty size 2>/dev/null </dev/tty) && c="${c#* }" || c=""
  fi
  case "$c" in (''|*[!0-9]*) c=0 ;; esac
  printf '%s' "$c"
}

if [ "$VL_LAYOUT" = "auto" ]; then
  build_segments "$VL_SEGMENTS"
  total=${#SEG_BGS[@]}
  [ "$total" -eq 0 ] && exit 0
  W=$(term_cols)
  if [ "$W" -le 0 ] || [ "$VL_MAX_LINES" -le 1 ]; then
    print_range 0 $((total - 1))
    exit 0
  fi
  # Greedy wrap: per line, width = caps + segment widths + separators.
  # Once VL_MAX_LINES is reached, everything left stays on the last line.
  if [ "$VL_STYLE" = "lean" ]; then CAP_W=0 ; SEP_W=${#VL_LEAN_SEP}
  else                              CAP_W=2 ; SEP_W=1 ; fi
  start=0 ; line=1 ; cur=$(( CAP_W + SEG_LEN[0] ))
  for ((i=1; i<total; i++)); do
    need=$(( cur + SEP_W + SEG_LEN[i] ))
    if [ "$need" -gt "$W" ] && [ "$line" -lt "$VL_MAX_LINES" ]; then
      print_range "$start" $((i - 1))
      start=$i ; line=$((line + 1)) ; cur=$(( CAP_W + SEG_LEN[i] ))
    else
      cur=$need
    fi
  done
  print_range "$start" $((total - 1))
else
  for list in "$VL_SEGMENTS" "$VL_SEGMENTS2" "$VL_SEGMENTS3"; do
    [ -n "$list" ] || continue
    build_segments "$list"
    [ "${#SEG_BGS[@]}" -gt 0 ] && print_range 0 $(( ${#SEG_BGS[@]} - 1 ))
  done
fi
exit 0
