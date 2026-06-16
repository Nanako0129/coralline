#!/usr/bin/env bash
# coralline — a configurable, Powerlevel10k-inspired statusline for Claude Code
# https://github.com/Nanako0129/coralline
# Visual style is a tribute to https://github.com/romkatv/powerlevel10k
#
# Design goals:
#   * Minimal process spawning per render — helpers return via globals
#     (printf -v) instead of $(...) subshells, so it stays cheap even under
#     Git Bash on Windows, where fork() is emulated and expensive.
#   * One jq call, one git call. Pure bash arithmetic (no bc).
#   * Works on macOS bash 3.2 and Linux/Windows (Git Bash) bash 4+/5.
#   * Everything themeable via ~/.claude/coralline.conf (sourced bash)
#
# Requires: jq, and a Nerd Font terminal unless VL_ASCII=1

input=$(cat)

# ── Defaults (every value can be overridden by the config file) ──────────────
VL_STYLE="pill"                 # pill: powerline pills · lean: p10k-lean flat text
VL_LEAN_SEP=""                  # lean only — extra text between segments, e.g. "·"
VL_LAYOUT="fixed"               # fixed: one line per VL_SEGMENTS* var
                                # auto:  single line, wraps when the window is narrow
VL_MAX_LINES=3                  # auto only — wrap into at most this many lines
VL_WRAP_MARGIN=4                # auto only — keep this many columns free on the right.
                                # 4 covers Claude Code's full-width L/R padding (2 cols each)
VL_SEGMENTS="dir git model ctx limit5h limit7d cost clock"
VL_SEGMENTS2=""                 # fixed only — optional second line
VL_SEGMENTS3=""                 # fixed only — optional third line
VL_BAR_WIDTH=5
VL_BAR_FILL="▰"
VL_BAR_EMPTY="▱"
VL_CLOCK="12h"                  # 12h | 24h | off
VL_CLOCK_SECONDS=1
VL_PATH_DEPTH=4                 # collapse paths deeper than this
VL_NAME_MAX=0                   # max chars for project/git names before … truncation (0 = off)
VL_COST_DECIMALS=2
VL_WARN_PCT=50                  # percentage thresholds for bar colors
VL_HOT_PCT=75
VL_ASCII=0                      # 1 = no Nerd Font glyphs (plain colored blocks)

# Powerline glyphs (printf -v keeps these fork-free; cleared when VL_ASCII=1)
printf -v VL_CAP_L '\xee\x82\xb6'   # U+E0B6 left rounded cap
printf -v VL_CAP_R '\xee\x82\xb4'   # U+E0B4 right rounded cap
printf -v VL_SEP   '\xee\x82\xb0'   # U+E0B0 segment separator

# Default theme: claude-coral (steel blue · mauve · Claude coral)
VL_BG_DIR="81,166,199"
VL_BG_PROJECT=""               # optional; falls back to VL_BG_DIR when empty
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

VL_FG_TEXT=231
VL_FG_DIM=245
VL_FG_OK=114
VL_FG_WARN=179
VL_FG_HOT=167

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

# Current epoch, computed once. printf %(...)T is a fork-free builtin on
# bash 4.2+ (incl. Git Bash); fall back to a single date call on macOS 3.2.
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)

# ── Parse JSON (single jq call) ──────────────────────────────────────────────
# Fields are joined with \x1f (unit separator): unlike tab, a non-whitespace
# IFS preserves empty fields instead of collapsing consecutive delimiters.
IFS=$'\037' read -r cwd model ctx_pct tok_in tok_out tok_cr tok_cw \
                 fh_pct fh_rst wd_pct wd_rst cost \
                 lines_add lines_del out_style dur_ms <<JSON
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
  (.cost.total_duration_ms // 0)
] | map(tostring) | join("")' 2>/dev/null)
JSON

# ── ANSI primitives ──────────────────────────────────────────────────────────
R=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'

# fg/bg set $_FG / $_BG to an ANSI escape (no subshell). Accept a 256-color
# index, a "R,G,B" true-color triple, or empty (→ empty string, inherit color).
fg() {
  if [ -z "$1" ]; then _FG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _FG '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _FG '\033[38;5;%sm' "$1"; fi
}
bg() {
  if [ -z "$1" ]; then _BG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _BG '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _BG '\033[48;5;%sm' "$1"; fi
}

# ── Helpers (all return via a global, never via $() ) ─────────────────────────
make_bar() {  # → _BAR ; $1=pct $2=width
  local pct="${1:-0}" width="${2:-$VL_BAR_WIDTH}" i filled
  _BAR=""
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  for ((i=0; i<filled; i++));     do _BAR="${_BAR}${VL_BAR_FILL}";  done
  for ((i=filled; i<width; i++)); do _BAR="${_BAR}${VL_BAR_EMPTY}"; done
}

# 1234 → 1.2k · 1234567 → 1.2M (integer math only) → _TOK
fmt_tok() {
  local n="${1:-0}"
  case "$n" in (''|*[!0-9]*) _TOK="$n"; return ;; esac
  if   [ "$n" -ge 1000000 ]; then printf -v _TOK '%d.%dM' $((n/1000000)) $(((n%1000000)/100000))
  elif [ "$n" -ge 1000 ];    then printf -v _TOK '%d.%dk' $((n/1000))    $(((n%1000)/100))
  else _TOK="$n"; fi
}

# Accepts epoch seconds (with or without decimals) or an ISO 8601 timestamp → _EP
# Claude Code sends epoch ints, so the common path is fork-free; the ISO
# fallback (rare) is the only place that may shell out to date.
to_epoch() {
  local t="$1" s
  [ -z "$t" ] && return 1
  case "$t" in
    *T*)  # ISO 8601 — try GNU date, then BSD date (assume UTC if tz lost)
      _EP=$(date -u -d "$t" +%s 2>/dev/null) && return 0
      s="${t%%[.+]*}" ; s="${s%Z}"
      _EP=$(date -ju -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null) && return 0
      return 1 ;;
    *[0-9]*) _EP="${t%%.*}" ; return 0 ;;
    *) return 1 ;;
  esac
}

fmt_countdown() {  # → _CD ("" if no/expired input handled by caller); $1=resets_at
  local diff d h m
  _CD=""
  to_epoch "$1" || return 0
  diff=$(( _EP - NOW ))
  if [ "$diff" -le 0 ]; then _CD="now"; return; fi
  d=$(( diff / 86400 )); h=$(( (diff % 86400) / 3600 )); m=$(( (diff % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf -v _CD '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v _CD '%dh%02dm' "$h" "$m"
  else                      printf -v _CD '%dm' "$m"; fi
}

fmt_duration() {  # → _DUR ; $1=ms
  local ms="${1:-0}" s h m
  s=$(( ms / 1000 )); h=$(( s / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$h" -gt 0 ]; then printf -v _DUR '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf -v _DUR '%dm' "$m"
  else                      printf -v _DUR '%ds' "$s"; fi
}

pct_fg() {  # → _PFG (a color spec) ; $1=pct
  local pct="${1:-0}"
  if   [ "$pct" -ge "$VL_HOT_PCT" ];  then _PFG="$VL_FG_HOT"
  elif [ "$pct" -ge "$VL_WARN_PCT" ]; then _PFG="$VL_FG_WARN"
  else                                     _PFG="$VL_FG_OK"; fi
}

trunc() {  # → _TR ; $1 clipped to $2 visible chars, middle-truncated with … ; $2=0 → unchanged
  local s="$1" max="${2:-0}" head tail start
  case "$max" in (''|*[!0-9]*) max=0 ;; esac
  if [ "$max" -le 0 ] || [ "${#s}" -le "$max" ]; then _TR="$s"; return; fi
  if [ "$max" -lt 3 ]; then _TR="${s:0:max}"; return; fi   # no room for head+…+tail
  # Keep head and tail so names sharing a long prefix stay distinguishable.
  head=$(( (max - 1) / 2 )); tail=$(( max - 1 - head )); start=$(( ${#s} - tail ))
  _TR="${s:0:head}…${s:start}"
}

now_strftime() {  # → _T ; $1=strftime fmt. Fork-free on bash 4.2+, one date call on 3.2.
  # Force C locale so %p is AM/PM (matched/lowercased by the caller), not localized.
  LC_ALL=C printf -v _T "%($1)T" -1 2>/dev/null || _T=$(LC_ALL=C date "+$1")
}

# ── Git state (single subprocess, parsed once, used by git/stash segments) ──
GIT_BRANCH="" GIT_MARKS="" GIT_AB="" GIT_DIRTY=0 GIT_ROOT=""
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
  # Stable project name (seg_project): basename of the MAIN repo root, which is
  # shared by every linked worktree — so it stays constant whichever worktree
  # you're in. Resolved only when the project segment is enabled, to keep the
  # one-git-call default untouched.
  case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" project "*)
    local cdir
    cdir=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    [ -n "$cdir" ] || cdir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$cdir" ]; then
      cdir="${cdir%/}" ; cdir="${cdir%/.git}"
      GIT_ROOT="${cdir##*/}"
    fi ;;
  esac
  [ "$staged"    -eq 1 ] && GIT_MARKS="${GIT_MARKS}+"
  [ "$unstaged"  -eq 1 ] && GIT_MARKS="${GIT_MARKS}!"
  [ "$untracked" -eq 1 ] && GIT_MARKS="${GIT_MARKS}?"
  [ "${a:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇡${a}"
  [ "${b:-0}" -gt 0 ] 2>/dev/null && GIT_AB="${GIT_AB}⇣${b}"
  [ -n "$GIT_MARKS" ] && GIT_DIRTY=1
}
case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" git "*|*" stash "*|*" project "*) read_git ;; esac

# ── Segments ─────────────────────────────────────────────────────────────────
# Each seg_* appends (background, text, visible width) to the segment arrays.
ESC=$'\033'
# Visible DISPLAY WIDTH (terminal columns) of $1, ANSI stripped → SEG_LEN_R.
# Decodes UTF-8 straight from the bytes (LC_ALL=C forced locally) so the count is
# correct no matter what $LANG is. This matters: Git Bash usually leaves LANG empty,
# where ${#s} counts *bytes* — a 5-glyph "▰▰▰▱▱" bar then reads as 15 and a CJK path
# char as 3, inflating every segment so the auto-layout wrap fires far too early.
# Wide CJK / kana / Hangul / fullwidth / emoji code points count as 2 columns,
# combining and zero-width marks as 0, everything else as 1. Pure bash, no subprocess.
seg_len() {
  local s="$1" plain="" LC_ALL=C n i b cp c2 c3 c4 w=0
  while [ "${s#*$ESC}" != "$s" ]; do          # strip CSI "...m" color escapes
    plain+="${s%%$ESC*}"
    s="${s#*$ESC}" ; s="${s#*m}"
  done
  plain+="$s"
  n=${#plain} ; i=0
  while [ "$i" -lt "$n" ]; do
    printf -v b '%d' "'${plain:i:1}" ; [ "$b" -lt 0 ] && b=$((b + 256))
    if   [ "$b" -lt 192 ]; then cp=$b ; i=$((i + 1))                  # ASCII / stray byte
    elif [ "$b" -lt 224 ]; then                                      # 2-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      cp=$(( (b - 192) * 64 + (c2 - 128) )) ; i=$((i + 2))
    elif [ "$b" -lt 240 ]; then                                      # 3-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      printf -v c3 '%d' "'${plain:i+2:1}" ; [ "$c3" -lt 0 ] && c3=$((c3 + 256))
      cp=$(( (b - 224) * 4096 + (c2 - 128) * 64 + (c3 - 128) )) ; i=$((i + 3))
    else                                                             # 4-byte sequence
      printf -v c2 '%d' "'${plain:i+1:1}" ; [ "$c2" -lt 0 ] && c2=$((c2 + 256))
      printf -v c3 '%d' "'${plain:i+2:1}" ; [ "$c3" -lt 0 ] && c3=$((c3 + 256))
      printf -v c4 '%d' "'${plain:i+3:1}" ; [ "$c4" -lt 0 ] && c4=$((c4 + 256))
      cp=$(( (b - 240) * 262144 + (c2 - 128) * 4096 + (c3 - 128) * 64 + (c4 - 128) )) ; i=$((i + 4))
    fi
    if [ "$cp" -lt 768 ]; then w=$((w + 1)) ; continue ; fi          # ASCII + Latin fast path
    if   { [ "$cp" -ge 768 ]   && [ "$cp" -le 879 ]; }   \
      || { [ "$cp" -ge 8203 ]  && [ "$cp" -le 8207 ]; }  \
      || { [ "$cp" -ge 65024 ] && [ "$cp" -le 65039 ]; }; then
      :                                                              # combining / ZWSP / variation selector → 0 cols
    elif { [ "$cp" -ge 4352 ]   && [ "$cp" -le 4447 ]; }   \
      || { [ "$cp" -ge 11904 ]  && [ "$cp" -le 42191 ]; }  \
      || { [ "$cp" -ge 44032 ]  && [ "$cp" -le 55203 ]; }  \
      || { [ "$cp" -ge 63744 ]  && [ "$cp" -le 64255 ]; }  \
      || { [ "$cp" -ge 65040 ]  && [ "$cp" -le 65049 ]; }  \
      || { [ "$cp" -ge 65072 ]  && [ "$cp" -le 65103 ]; }  \
      || { [ "$cp" -ge 65280 ]  && [ "$cp" -le 65376 ]; }  \
      || { [ "$cp" -ge 65504 ]  && [ "$cp" -le 65510 ]; }  \
      || { [ "$cp" -ge 127744 ] && [ "$cp" -le 129791 ]; } \
      || { [ "$cp" -ge 131072 ] && [ "$cp" -le 262143 ]; }; then
      w=$((w + 2))                                                   # East-Asian wide / fullwidth / emoji → 2 cols
    else
      w=$((w + 1))
    fi
  done
  SEG_LEN_R=$w
}
push() {
  # SEG_LEN[] is read only by the auto-layout wrap; fixed-layout print_range never
  # touches it, so skip the per-char width scan entirely outside auto layout.
  if [ "$VL_LAYOUT" = "auto" ]; then seg_len "$2" ; else SEG_LEN_R=0 ; fi
  SEG_BGS[${#SEG_BGS[@]}]="$1"
  SEG_TXT[${#SEG_TXT[@]}]="$2"
  SEG_LEN[${#SEG_LEN[@]}]="$SEG_LEN_R"
}

seg_project() {  # repo-root name in a repo; falls back to dir outside one (unless dir is already shown)
  if [ -z "$GIT_ROOT" ]; then
    case " $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 " in *" dir "*) return 0 ;; esac
    seg_dir; return
  fi
  fg "$VL_FG_TEXT"; trunc "$GIT_ROOT" "$VL_NAME_MAX"
  push "${VL_BG_PROJECT:-$VL_BG_DIR}" "${BOLD}${_FG} ⬢ ${_TR} ${NORM}"
}

seg_dir() {
  [ -n "$cwd" ] || return 0
  local short="${cwd/#$HOME/~}" n last
  local IFS='/'; set -- $short; n=$#
  if [ "$n" -gt "$VL_PATH_DEPTH" ]; then
    eval "last=\${$n}"
    short="$1/$2/…/$last"
  fi
  fg "$VL_FG_TEXT"
  push "$VL_BG_DIR" "${BOLD}${_FG} ${short} ${NORM}"
}

seg_git() {
  [ -n "$GIT_BRANCH" ] || return 0
  local bgc="$VL_BG_GIT_OK"
  [ "$GIT_DIRTY" -eq 1 ] && bgc="$VL_BG_GIT_DIRTY"
  fg "$VL_FG_TEXT"; trunc "$GIT_BRANCH" "$VL_NAME_MAX"
  push "$bgc" "${BOLD}${_FG} ⎇ ${_TR}${GIT_MARKS}${GIT_AB} ${NORM}"
}

seg_model() {
  [ -n "$model" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_MODEL" "${BOLD}${_FG} ◆ ${model#Claude } ${NORM}"
}

seg_ctx() {
  [ -n "$ctx_pct" ] || return 0
  local ci fgc fgd ti to tcr tcw
  printf -v ci '%.0f' "$ctx_pct" 2>/dev/null || ci=0
  make_bar "$ci"; pct_fg "$ci"
  fg "$_PFG";       fgc="$_FG"
  fg "$VL_FG_DIM";  fgd="$_FG"
  fmt_tok "$tok_in"; ti="$_TOK"
  fmt_tok "$tok_out"; to="$_TOK"
  fmt_tok "$tok_cr"; tcr="$_TOK"
  fmt_tok "$tok_cw"; tcw="$_TOK"
  push "$VL_BG_CTX" "${fgc} ⬡ ${_BAR} ${ci}% ${fgd}↑${ti} ↓${to} cr:${tcr} cw:${tcw} "
}

seg_limit() {  # $1=label $2=pct $3=resets_at $4=bg
  [ -n "$2" ] || return 0
  local v fgc rst=""
  printf -v v '%.0f' "$2" 2>/dev/null || v=0
  make_bar "$v"; pct_fg "$v"
  fg "$_PFG"; fgc="$_FG"
  fmt_countdown "$3"
  if [ -n "$_CD" ]; then fg "$VL_FG_DIM"; rst="${_FG}↺${_CD}"; fi
  push "$4" "${fgc} $1 ${_BAR} ${v}% ${rst} "
}
seg_limit5h() { seg_limit "5h" "$fh_pct" "$fh_rst" "$VL_BG_5H"; }
seg_limit7d() { seg_limit "7d" "$wd_pct" "$wd_rst" "$VL_BG_7D"; }

seg_cost() {
  [ -n "$cost" ] && [ "$cost" != "0" ] || return 0
  local fmt
  printf -v fmt "\$%.${VL_COST_DECIMALS}f" "$cost" 2>/dev/null || fmt="\$$cost"
  fg "$VL_FG_TEXT"
  push "$VL_BG_COST" "${_FG} ${fmt} "
}

seg_clock() {
  [ "$VL_CLOCK" = "off" ] && return 0
  if [ "$VL_CLOCK" = "24h" ]; then
    [ "$VL_CLOCK_SECONDS" = "1" ] && now_strftime '%H:%M:%S' || now_strftime '%H:%M'
  else
    [ "$VL_CLOCK_SECONDS" = "1" ] && now_strftime '%I:%M:%S %p' || now_strftime '%I:%M %p'
    case "$_T" in *AM) _T="${_T% AM} am" ;; *PM) _T="${_T% PM} pm" ;; esac
  fi
  fg "$VL_FG_TEXT"
  push "$VL_BG_CLOCK" "${_FG} ⊙ ${_T} "
}

seg_lines() {
  [ "${lines_add:-0}" -gt 0 ] 2>/dev/null || [ "${lines_del:-0}" -gt 0 ] 2>/dev/null || return 0
  local fgo fgh
  fg "$VL_FG_OK";  fgo="$_FG"
  fg "$VL_FG_HOT"; fgh="$_FG"
  push "$VL_BG_LINES" " ${fgo}+${lines_add} ${fgh}-${lines_del} "
}

seg_style() {
  [ -n "$out_style" ] && [ "$out_style" != "default" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_STYLE" "${_FG} ✎ ${out_style} "
}

seg_duration() {
  [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null || return 0
  fmt_duration "$dur_ms"
  fg "$VL_FG_TEXT"
  push "$VL_BG_DURATION" "${_FG} ⧖ ${_DUR} "
}

seg_stash() {
  [ -n "$GIT_BRANCH" ] || return 0
  local n
  n=$(git -C "$cwd" rev-list --walk-reflogs --count refs/stash 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_GIT_OK" "${_FG} ⚑ ${n} "
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
  local i out
  if [ "$VL_STYLE" = "lean" ]; then
    out=""
    for ((i=$1; i<=$2; i++)); do
      fg "${SEG_BGS[$i]}"
      out+="${R}${_FG}${SEG_TXT[$i]}"
      [ "$i" -lt "$2" ] && out+="${R}${VL_LEAN_SEP}"
    done
    printf '%s\n' "${out}${R}"
    return 0
  fi
  fg "${SEG_BGS[$1]}"
  out="${R}${_FG}${VL_CAP_L}"
  for ((i=$1; i<=$2; i++)); do
    bg "${SEG_BGS[$i]}"
    out+="${_BG}${SEG_TXT[$i]}"
    if [ "$i" -lt "$2" ]; then
      bg "${SEG_BGS[$((i+1))]}"; fg "${SEG_BGS[$i]}"
      out+="${_BG}${_FG}${VL_SEP}"
    fi
  done
  fg "${SEG_BGS[$2]}"
  out+="${R}${_FG}${VL_CAP_R}${R}"
  printf '%s\n' "$out"
}

# Terminal width for auto layout; 0 = unknown (then stay on one line).
term_cols() {  # → _COLS
  local c=""
  if [ -n "$COLUMNS" ]; then
    c="$COLUMNS"
  else
    c=$(stty size 2>/dev/null </dev/tty) && c="${c#* }" || c=""
  fi
  case "$c" in (''|*[!0-9]*) c=0 ;; esac
  _COLS="$c"
}

if [ "$VL_LAYOUT" = "auto" ]; then
  build_segments "$VL_SEGMENTS"
  total=${#SEG_BGS[@]}
  [ "$total" -eq 0 ] && exit 0
  term_cols; W="$_COLS"
  if [ "$W" -le 0 ] || [ "$VL_MAX_LINES" -le 1 ]; then
    print_range 0 $((total - 1))
    exit 0
  fi
  # Reserve a right-hand margin so wrapped lines never touch the window edge.
  W=$(( W - VL_WRAP_MARGIN ))
  [ "$W" -lt 1 ] && W=1
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
