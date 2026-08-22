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

# --subagent: speak Claude Code's subagentStatusLine protocol instead — one
# {"id","content"} JSON line per agent-panel row (see the branch after the
# render helpers). Everything else (config, theme, helpers) is shared.
SUBAGENT_MODE=0
[ "${1:-}" = "--subagent" ] && SUBAGENT_MODE=1

# -d '' reads until NUL (i.e. all of stdin, like cat) without forking.
# -t 5 prevents zombie bash on MSYS2 where pipe EOF may never arrive.
read -t 5 -r -d '' input || true

# ── Defaults (every value can be overridden by the config file) ──────────────
VL_STYLE="pill"                 # pill: powerline pills · lean: flat text · classic: lean on a dark bar
VL_LEAN_SEP=""                  # lean only — extra text between segments, e.g. "·"
VL_LEAN_BG=""                   # lean only — one uniform background behind the whole
                                # row ("R,G,B" or a 256 index); empty = none. Gives the
                                # p10k "classic" look: a dark bar with colored text.
VL_LEAN_CAP_R=""                # lean only — trailing cap glyph drawn in the VL_LEAN_BG
                                # colour to bevel the bar into the terminal (p10k's end
                                # separator, e.g. $''); needs VL_LEAN_BG, empty = flat
VL_LEAN_CAP_L=""                # lean only — leading cap glyph: the left-facing
                                # mirror of VL_LEAN_CAP_R at the bar's start; needs
                                # VL_LEAN_BG, empty = flat (stock p10k classic: flat)
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
# Segment glyphs. These four are plain Unicode, not Nerd Font PUA icons, so a
# font that lacks them leaves the substitution to the terminal's own fallback —
# which may land on a glyph wider than one cell and shove the rest of the row
# out of alignment (#47). Override with characters your terminal font carries.
VL_CTX_GLYPH="⬡"                # glyph for the ctx segment (main bar and subagent rows)
VL_PROJECT_GLYPH="⬢"            # glyph for the project segment
VL_CLOCK="12h"                  # 12h | 24h | off
VL_CLOCK_SECONDS=1
VL_PATH_DEPTH=4                 # collapse paths deeper than this
VL_NAME_MAX=0                   # max chars for project/git names before … truncation (0 = off)
VL_COST_DECIMALS=2
VL_CTX_ALWAYS_SHOW=0            # 1 = show an empty valid context window as 0%
VL_COST_ALWAYS_SHOW=0            # 1 = show a missing valid cost as $0.00
VL_WARN_PCT=50                  # percentage thresholds for bar colors
VL_HOT_PCT=75
VL_ASCII=0                      # 1 = no Nerd Font glyphs (plain colored blocks)
VL_FLOAT=0                      # 1 = also write a plain-text readout to VL_FLOAT_FILE (bring your own carrier)
VL_FLOAT_SEGMENTS="model ctx cost"  # segments rendered into the float line (plain text: keep color-driven limit warnings inline)
VL_FLOAT_SEP="  ·  "            # separator between float segments (plain text, no color)
# Base for every cross-session store below. Follows CLAUDE_CONFIG_DIR so two
# Claude config dirs keep separate burn/limit state instead of overwriting each
# other; unset (the common case) it is the historical $HOME/.claude/coralline.
CORALLINE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/coralline"
VL_FLOAT_FILE="$CORALLINE_DIR/float.txt"
VL_NOCOLOR=0                    # internal: fg()/bg() emit nothing when 1 (plain-text path)

# ── Subagent panel rows (--subagent mode) ────────────────────────────────────
VL_SUB_SEGMENTS="name model ctx elapsed"  # panel-row segment list (subseg_*)
VL_BG_SUB_MODEL=""              # panel-row colors; empty → fall back to the
VL_BG_SUB_CTX=""                #   main-bar counterparts (model/ctx/duration)
VL_BG_SUB_ELAPSED=""
# subseg_name tints the label by task status out of the main VL_FG_* palette,
# which is tuned for the gauge segments' dark backgrounds. On a light name pill
# those colors wash out (down to 1.0:1), so the pill takes that same dark ground
# and the statuses get their own inks:
#   VL_BG_SUB_NAME   name pill ground      VL_FG_SUB_TEXT  running
#   VL_FG_SUB_OK     completed             VL_FG_SUB_HOT   failed
#   VL_FG_SUB_DIM    queued / unknown
# They are left unset here rather than blank on purpose: the stock defaults are
# applied after the config loads, and only when the palette is still the built-in
# one (see below), so a custom theme that predates these knobs keeps falling back
# to its own colors. Empty → the VL_BG_DIR / VL_FG_* counterpart, the light pill.
# Unset rather than blank means an inherited environment value would read as a
# deliberate config, so clear them (and the theme-candidate names) first. Every
# other VL_* above is assigned outright, which already isolates it from the env.
unset VL_BG_SUB_NAME VL_FG_SUB_TEXT VL_FG_SUB_OK VL_FG_SUB_HOT VL_FG_SUB_DIM \
      _VL_SUB_BG_NAME _VL_SUB_FG_TEXT _VL_SUB_FG_OK _VL_SUB_FG_HOT _VL_SUB_FG_DIM \
      _VL_SUB_FP _VL_SUB_BAR

# ── Burn-rate segment (range-to-empty) ───────────────────────────────────────
# Opt in by adding `burn` to VL_SEGMENTS*; the sampler below runs only then.
CORALLINE_BURN_WINDOW=600       # recent-slope lookback for 5h, seconds
VL_BURN_GLYPH="↗"               # plain-Unicode, arrow family (kept in VL_ASCII)
VL_BG_BURN=""                   # empty → inherits VL_BG_5H at the use site
BURN_FILE="${CORALLINE_BURN_FILE:-$CORALLINE_DIR/burn-5h.tsv}"
BURN_TRIM=1500                  # internal: max rows kept in the sample file
BURN_SLACK=500                  # internal: rows past BURN_TRIM tolerated before a trim rewrite.
                                # Batches the steady-state trim: at the cap, appends land for
                                # ~BURN_SLACK seconds before one render rewrites, instead of every
                                # render rewriting every second. 1500+1000(max)+appends stays far
                                # below the reader's 4096-physical-row bail-out.

# Cross-session limit sync (opt-in). Claude Code only re-renders a session's
# statusline on activity, and the rate-limit % in each render's JSON is that
# session's last-seen snapshot, so a session that has not caught up to the next
# window shows a stale one. With this on, every render records its 5h/7d
# (reset, pct) to a small per-host store, and a session that has no valid reading
# of its own — no rate_limits in the payload, or a window that has already
# elapsed — displays the newest window any session recorded. A session WITH a
# valid reading always shows its own: the percentage can legitimately fall inside
# one window (upstream reset, plan upgrade) and no other session's snapshot is
# better evidence about it. It cannot refresh a session that is not redrawing at
# all (that is a Claude Code limit).
# The store is a directory-set (see rl_sample/rl_latest), race-free by design.
VL_LIMIT_SYNC=0
RL5H_FILE="${CORALLINE_RL5H_FILE:-$CORALLINE_DIR/limit-5h.tsv}"
RL7D_FILE="${CORALLINE_RL7D_FILE:-$CORALLINE_DIR/limit-7d.tsv}"
# Per-window ceilings for the sentinel guard (#32): a reset further out than its
# window can possibly be is corrupt (e.g. sample-input.json's 2030 value) and must
# never become the high-water. Kept per window because a stale 5h value a couple of
# days out would clear a shared 7d-sized bound, so the 5h path needs its own.
RL_MAX_5H=$(( 6 * 3600 ))       # internal: 5h window resets within ~5h (6h = +1h skew margin)
RL_MAX_7D=$(( 8 * 86400 ))      # internal: 7d window resets within 7d (8d = +1d skew margin)

# Powerline glyphs (printf -v keeps these fork-free; cleared when VL_ASCII=1)
printf -v VL_CAP_L '\xee\x82\xb6'   # U+E0B6 left rounded cap
printf -v VL_CAP_R '\xee\x82\xb4'   # U+E0B4 right rounded cap
printf -v VL_SEP   '\xee\x82\xb0'   # U+E0B0 segment separator

# Default theme: claude-coral (steel blue · mauve · Claude coral)
VL_BG_DIR="81,166,199"
VL_BG_PROJECT=""               # optional; falls back to VL_BG_DIR when empty
VL_BG_GIT_OK=65
VL_BG_STASH=""                 # optional; falls back to VL_BG_GIT_OK when empty
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
VL_BG_EFFORT=141
VL_BG_NODE=""                   # optional; falls back to VL_BG_MODEL when empty
VL_BG_PYTHON=""                 # optional; falls back to VL_BG_MODEL when empty
VL_BG_BAR=""                   # classic style only — the uniform bar behind the whole
                               # row ("R,G,B" or a 256 index); empty → p10k's 238.
                               # An explicit VL_LEAN_BG overrides it.
printf -v VL_NODE_GLYPH '\xee\x9c\x98'   # U+E718 Nerd Font node glyph (word in VL_ASCII)
printf -v VL_PY_GLYPH   '\xee\x9c\xbc'   # U+E73C Nerd Font python glyph (word in VL_ASCII)
VL_RUNTIME_PROBE=0              # node/python: 1 = also detect via `node`/`python3`
                               # on PATH when no pin file (forks per render; off by default)

VL_FG_TEXT=231
VL_FG_DIM=245
VL_FG_OK=114
VL_FG_WARN=179
VL_FG_HOT=167

# ── Load user config ─────────────────────────────────────────────────────────
VL_CONF="${CORALLINE_CONFIG:-$HOME/.claude/coralline.conf}"
# Fingerprint of the palette subseg_name draws with, so a config that retinted any
# of it is not mistaken for the stock one. The bar knobs are checked separately
# below, because they only matter in the styles that actually paint a bar.
_VL_STOCK="$VL_BG_DIR|$VL_FG_TEXT|$VL_FG_OK|$VL_FG_HOT|$VL_FG_DIM"
_VL_STOCK_BAR="$VL_BG_BAR|$VL_LEAN_BG"
[ -f "$VL_CONF" ] && . "$VL_CONF"

# Subagent name pill. Its colors have to be resolved here, after the whole config
# has run, because they are only safe while the palette they were solved against
# is still intact. A theme publishes candidates as _VL_SUB_* plus _VL_SUB_FP, the
# palette fingerprint as that theme left it; with no theme sourced the built-in
# palette is claude-coral's, so _VL_STOCK and claude-coral's candidates apply.
# Either way, adopt them only if nothing later retinted the palette. Retinting it
# (a p10k import appends VL_BG_* overrides after sourcing a theme, and configs
# survive upgrades) would strand a dark ink on the dark pill: `. claude-coral.conf`
# followed by VL_FG_OK="0,0,0" renders completed at 2.16:1, where the light pill
# it replaced was fine. When that holds these stay unset and subseg_name falls
# back to the config's own VL_BG_DIR / VL_FG_*, exactly as before this knob
# existed. An explicit value always wins, and an explicit empty string restores
# the light pill.
#
# Four more ways the ground stops being the one they were solved against, each
# bowing out for the same reason:
#   * bare lean (VL_STYLE="lean", no VL_LEAN_BG) paints no segment background at
#     all, so the label takes the segment's accent on the terminal's own
#     background, which no palette can predict
#   * lean/classic paint the row on the uniform bar rather than the pill, so a bar
#     the candidates were not tuned for disqualifies them; in pill style the bar
#     is inert and is not consulted, so a leftover VL_BG_BAR cannot disable this
#   * VL_LEAN_FG forces the row's text colour, and that request outranks a
#     status ink resolved here (the lean block below assigns it to VL_FG_TEXT)
#   * an explicit VL_BG_SUB_NAME is a ground of the user's choosing, so the inks
#     go back to the main palette rather than assuming this one
_VL_SUB_OK=1
[ -n "${VL_BG_SUB_NAME+s}" ] && _VL_SUB_OK=""
[ -n "${VL_LEAN_FG:-}" ] && _VL_SUB_OK=""
case "$VL_STYLE" in
  (lean)
    [ -z "$VL_LEAN_BG" ] && _VL_SUB_OK=""
    [ "$VL_BG_BAR|$VL_LEAN_BG" = "${_VL_SUB_BAR-$_VL_STOCK_BAR}" ] || _VL_SUB_OK=""
  ;;
  (classic)
    [ "$VL_BG_BAR|$VL_LEAN_BG" = "${_VL_SUB_BAR-$_VL_STOCK_BAR}" ] || _VL_SUB_OK=""
  ;;
esac
if [ -n "$_VL_SUB_OK" ] \
   && [ "$VL_BG_DIR|$VL_FG_TEXT|$VL_FG_OK|$VL_FG_HOT|$VL_FG_DIM" = "${_VL_SUB_FP-$_VL_STOCK}" ]; then
  VL_BG_SUB_NAME="${VL_BG_SUB_NAME-${_VL_SUB_BG_NAME-68,68,68}}"    # VL_BG_CTX 238 as RGB
  VL_FG_SUB_TEXT="${VL_FG_SUB_TEXT-${_VL_SUB_FG_TEXT-255,255,255}}" # running (9.74)
  VL_FG_SUB_OK="${VL_FG_SUB_OK-${_VL_SUB_FG_OK-}}"                  # completed (5.61, falls through)
  VL_FG_SUB_HOT="${VL_FG_SUB_HOT-${_VL_SUB_FG_HOT-231,157,157}}"    # failed (4.50)
  VL_FG_SUB_DIM="${VL_FG_SUB_DIM-${_VL_SUB_FG_DIM-177,177,177}}"    # queued / unknown (4.54)
fi

if [ "$VL_ASCII" = "1" ]; then
  VL_CAP_L="" ; VL_CAP_R="" ; VL_SEP=""
  VL_BAR_FILL="#" ; VL_BAR_EMPTY="-"
  VL_NODE_GLYPH="node" ; VL_PY_GLYPH="py"
fi

# Classic style: Powerlevel10k's stock "Classic" preset — lean rendering on one
# uniform dark bar (VL_BG_BAR, default p10k 238) with a solid trailing cap (VL_SEP,
# p10k's U+E0B0). It is lean plus those two structural defaults, so resolve it here.
# Placement matters: after the VL_ASCII block (so in ASCII mode VL_SEP is already
# cleared → the cap stays empty but the bar still paints) and before the lean block
# (so lean rendering then fires). The := chain lets an explicit VL_LEAN_BG /
# VL_LEAN_CAP_R win. Pure parameter expansion, run once — the render path stays
# fork-free.
if [ "$VL_STYLE" = "classic" ]; then
  VL_STYLE="lean"
  : "${VL_LEAN_BG:=${VL_BG_BAR:-238}}"
  : "${VL_LEAN_CAP_R:=$VL_SEP}"
fi

# Lean style: no caps and no per-segment pills; each segment's VL_BG_* becomes its
# text accent color (an empty VL_FG_TEXT lets text inherit that accent). VL_LEAN_BG
# can still paint one uniform background behind the row (the p10k "classic" look).
if [ "$VL_STYLE" = "lean" ]; then
  VL_CAP_L="" ; VL_CAP_R=""
  VL_FG_TEXT="${VL_LEAN_FG:-}"
fi

# Current epoch, computed once. printf %(...)T is a fork-free builtin on
# bash 4.2+ (incl. Git Bash); fall back to a single date call on macOS 3.2.
printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)

# ── ANSI primitives ──────────────────────────────────────────────────────────
R=$'\033[0m'
BOLD=$'\033[1m'
NORM=$'\033[22m'

# fg/bg set $_FG / $_BG to an ANSI escape (no subshell). Accept a 256-color
# index, a "R,G,B" true-color triple, or empty (→ empty string, inherit color).
fg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _FG=""; return; fi
  if [ -z "$1" ]; then _FG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _FG '\033[38;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _FG '\033[38;5;%sm' "$1"; fi
}
bg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _BG=""; return; fi
  if [ -z "$1" ]; then _BG=""; return; fi
  if [ "${1#*,}" != "$1" ]; then
    local IFS=','; set -- $1; printf -v _BG '\033[48;2;%s;%s;%sm' "$1" "$2" "$3"
  else printf -v _BG '\033[48;5;%sm' "$1"; fi
}

# ── Helpers (all return via a global, never via $() ) ─────────────────────────
make_bar() {  # → _BAR ; $1=pct $2=width
  local pct="${1:-0}" width="${2:-$VL_BAR_WIDTH}" i filled
  _BAR=""
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  filled=$(( (pct * width + 50) / 100 ))
  [ "$filled" -lt 0 ] && filled=0
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

# Canonical UTC ISO timestamp → _EP, using pure integer date math. Returns 1 for
# every non-canonical or calendar-invalid value; callers decide whether to fall
# back to the platform date command.
iso_epoch() {
  local t="$1" s tm Y Mo D H Mi S yy era yoe doy doe days dim
  case "$t" in (*T*) ;; (*) return 1 ;; esac
  tm="${t#*T}"
  case "$tm" in (*[+-]*) return 1 ;; esac
  s="${t%Z}" ; s="${s%%.*}"              # drop trailing Z and any fraction
  case "$s" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  # Fixed offsets are safe now that the exact shape is confirmed. 10# forces
  # base-10 so a leading zero (08, 09) is not read as octal.
  Y=$((10#${s:0:4})); Mo=$((10#${s:5:2})); D=$((10#${s:8:2}))
  H=$((10#${s:11:2})); Mi=$((10#${s:14:2})); S=$((10#${s:17:2}))
  dim=31                                    # days in month, for range validation
  case $Mo in
    4|6|9|11) dim=30 ;;
    2) dim=$(( (Y % 4 == 0 && (Y % 100 != 0 || Y % 400 == 0)) ? 29 : 28 )) ;;
  esac
  [ "$Mo" -ge 1 ] && [ "$Mo" -le 12 ] && [ "$D" -ge 1 ] && [ "$D" -le "$dim" ] \
    && [ "$H" -le 23 ] && [ "$Mi" -le 59 ] && [ "$S" -le 59 ] || return 1
  yy=$(( Y - (Mo <= 2) ))                   # days-from-civil (Howard Hinnant), UTC
  era=$(( (yy >= 0 ? yy : yy - 399) / 400 ))
  yoe=$(( yy - era * 400 ))
  doy=$(( (153 * (Mo + (Mo > 2 ? -3 : 9)) + 2) / 5 + D - 1 ))
  doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
  days=$(( era * 146097 + doe - 719468 ))
  _EP=$(( days * 86400 + H * 3600 + Mi * 60 + S ))
}

# Accepts epoch seconds (with or without decimals) or an ISO 8601 timestamp → _EP.
# Claude Code sends rate-limit resets_at as ISO UTC ("…Z"). The common shape is
# parsed fork-free by iso_epoch; non-standard or impossible values retain the old
# platform-date fallback so main-statusline behavior stays byte-compatible.
to_epoch() {
  local t="$1" s
  [ -z "$t" ] && return 1
  case "$t" in
    *T*)
      iso_epoch "$t" && return 0
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

fmt_duration() {  # → _DUR ; $1=ms $2=include seconds
  local ms="${1:-0}" s h m sec
  s=$(( ms / 1000 )); h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); sec=$(( s % 60 ))
  if [ "${2:-0}" = "1" ]; then
    if   [ "$h" -gt 0 ]; then printf -v _DUR '%dh%02dm%02ds' "$h" "$m" "$sec"
    elif [ "$m" -gt 0 ]; then printf -v _DUR '%dm%02ds' "$m" "$sec"
    else                      printf -v _DUR '%ds' "$s"; fi
  elif [ "$h" -gt 0 ]; then printf -v _DUR '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf -v _DUR '%dm' "$m"
  else                      printf -v _DUR '%ds' "$s"; fi
}

fmt_eta() {  # → _ETA ; $1=seconds (mirrors fmt_countdown's d/h/m formatting)
  local s="${1:-0}" d h m
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf -v _ETA '%dd%02dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf -v _ETA '%dh%02dm' "$h" "$m"
  else                      printf -v _ETA '%dm' "$m"; fi
}

# ── Mutable Bash burn / limit state ───────────────────────────────────────────
# Bash owns the validated TSV history and compact limit directory sets. The
# native immutable burn directory remains a separate, ignored namespace.
state_pct() {  # → _SP_MILLI _SP_CANON; strict raw decimal, ties-to-even at .001
  local raw="$1" whole frac six keep rest milli LC_ALL=C
  _SP_MILLI=""; _SP_CANON=""
  [ "${#raw}" -le 10 ] || return 1
  [[ "$raw" =~ ^(0|[1-9][0-9]?|100)(\.([0-9]{1,6}))?$ ]] || return 1
  whole="${BASH_REMATCH[1]}"; frac="${BASH_REMATCH[3]}"
  if [ "$whole" = 100 ]; then
    case "$frac" in (*[!0]*) return 1 ;; esac
  fi
  six="${frac}000000"; six="${six:0:6}"
  keep=${six:0:3}; rest=${six:3:3}
  milli=$(( 10#$whole * 1000 + 10#$keep ))
  if [ $(( 10#$rest )) -gt 500 ] || { [ $(( 10#$rest )) -eq 500 ] && [ $(( milli % 2 )) -eq 1 ]; }; then
    milli=$(( milli + 1 ))
  fi
  [ "$milli" -le 100000 ] || return 1
  _SP_MILLI=$milli
  printf -v _SP_CANON '%03d.%03d' $(( milli / 1000 )) $(( milli % 1000 ))
}

state_epoch() {  # → _SE_VALUE _SE_PAD; $1=strict epoch $2=width (10 or 12)
  local raw="$1" width="$2" value
  _SE_VALUE=""; _SE_PAD=""
  case "$width" in (10|12) ;; (*) return 1 ;; esac
  [ "${#raw}" -le "$width" ] || return 1
  case "$raw" in (0|[1-9][0-9]*) ;; (*) return 1 ;; esac
  case "$raw" in (*[!0-9]*) return 1 ;; esac
  value=$(( 10#$raw ))
  [ "$value" -ge 0 ] && [ "$value" -le 253402300799 ] || return 1
  [ "$width" != 10 ] || [ "$value" -le 9999999999 ] || return 1
  _SE_VALUE=$value
  printf -v _SE_PAD "%0${width}d" "$value"
}

state_payload_epoch() {  # → _SE_*; canonical ISO UTC or strict epoch only
  local raw="$1" width="$2" LC_ALL=C
  [ "${#raw}" -le 27 ] || return 1
  case "$raw" in
    (*T*)
      [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$ ]] || return 1
      iso_epoch "$raw" || return 1
      state_epoch "$_EP" "$width"
      ;;
    (*) state_epoch "$raw" "$width" ;;
  esac
}

state_round_even() {  # → _RE; exact nonnegative rational midpoint-to-even
  local n="$1" d="$2" q r twice
  _RE=0
  [ "$d" -gt 0 ] || return 1
  q=$(( n / d )); r=$(( n % d )); twice=$(( r * 2 ))
  if [ "$twice" -gt "$d" ] || { [ "$twice" -eq "$d" ] && [ $(( q % 2 )) -eq 1 ]; }; then
    q=$(( q + 1 ))
  fi
  _RE=$q
}

state_rate10() {  # → _RATE10; $1=scaled numerator $2=denominator
  local scaled
  state_round_even "$1" "$2" || { _RATE10="0.0000000000"; return 1; }
  scaled=$_RE
  printf -v _RATE10 '%d.%010d' $(( scaled / 10000000000 )) $(( scaled % 10000000000 ))
}

state_drive_lower() {  # → _SDL
  case "$1" in
    (A|a) _SDL=a ;; (B|b) _SDL=b ;; (C|c) _SDL=c ;; (D|d) _SDL=d ;;
    (E|e) _SDL=e ;; (F|f) _SDL=f ;; (G|g) _SDL=g ;; (H|h) _SDL=h ;;
    (I|i) _SDL=i ;; (J|j) _SDL=j ;; (K|k) _SDL=k ;; (L|l) _SDL=l ;;
    (M|m) _SDL=m ;; (N|n) _SDL=n ;; (O|o) _SDL=o ;; (P|p) _SDL=p ;;
    (Q|q) _SDL=q ;; (R|r) _SDL=r ;; (S|s) _SDL=s ;; (T|t) _SDL=t ;;
    (U|u) _SDL=u ;; (V|v) _SDL=v ;; (W|w) _SDL=w ;; (X|x) _SDL=x ;;
    (Y|y) _SDL=y ;; (Z|z) _SDL=z ;; (*) return 1 ;;
  esac
}

state_abs_path() {  # → _SAP; lexical absolute path, including MSYS drive forms
  local p="$1" drive rest part out=""
  _SAP=""
  [ -n "$p" ] && [ "${#p}" -le 4096 ] || return 1
  p="${p//\\//}"
  case "$p" in
    (//*) return 1 ;;
    ([abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ]:/*)
      drive=${p:0:1}; state_drive_lower "$drive" || return 1
      p="/${_SDL}/${p:3}" ;;
    (/*) ;;
    (*) p="$PWD/$p" ;;
  esac
  rest="${p#/}"
  while :; do
    part="${rest%%/*}"
    case "$part" in
      (''|.) ;;
      (..) [ -n "$out" ] || return 1; out="${out%/*}" ;;
      (*) out="${out:+$out/}$part" ;;
    esac
    [ "$rest" = "$part" ] && break
    rest="${rest#*/}"
  done
  _SAP="/${out}"
  [ "$_SAP" != "/" ] || _SAP="/"
}

state_no_symlink_path() {  # → _SNP; every existing ancestor and target is non-link
  local path="$1" rest part cur="" tail
  _SNP=""
  state_abs_path "$path" || return 1
  path="$_SAP"; rest="${path#/}"
  while [ -n "$rest" ]; do
    part="${rest%%/*}"; tail="${rest#*/}"
    cur="$cur/$part"
    [ -L "$cur" ] && return 1
    if [ "$tail" != "$rest" ] && [ -e "$cur" ] && [ ! -d "$cur" ]; then return 1; fi
    [ "$tail" = "$rest" ] && break
    rest="$tail"
  done
  _SNP="$path"
}

state_store_path() {  # → _SS_BASE _SS_ROOT from configured base
  state_abs_path "$1" || return 1
  _SS_BASE="$_SAP"
  _SS_ROOT="${_SS_BASE%.tsv}.d"
  [ "$_SS_ROOT" != "$_SS_BASE" ] || _SS_ROOT="${_SS_BASE}.d"
}

state_same_path() {  # true for proven or platform-conservative path identity
  local left="$1" right="$2" had_nocase=0 same=1
  [ "$left" = "$right" ] && return 0
  if [ -e "$left" ] && [ -e "$right" ] && [ "$left" -ef "$right" ]; then return 0; fi
  case "${OSTYPE:-}" in
    (darwin*|mingw*|msys*)
      shopt -q nocasematch && had_nocase=1
      shopt -s nocasematch
      [[ "$left" == "$right" ]] && same=0
      [ "$had_nocase" = 1 ] || shopt -u nocasematch
      return "$same"
      ;;
  esac
  return 1
}

state_limit_name() {  # → _SLN_RST _SLN_PCT for one strict limit basename
  local name="$1" pr pc LC_ALL=C
  _SLN_RST=""; _SLN_PCT=""
  [ "${#name}" -eq 18 ] || return 1
  [[ "$name" =~ ^([0-9]{10})_((0[0-9]{2}|100)\.[0-9]{3})$ ]] || return 1
  pr="${BASH_REMATCH[1]}"; pc="${BASH_REMATCH[2]}"
  _SLN_RST=$(( 10#$pr ))
  _SLN_PCT=$(( 10#${pc:0:3} * 1000 + 10#${pc:4:3} ))
  [ "$_SLN_PCT" -le 100000 ] || return 1
}

state_path_leaf() {  # $1=canonical path $2=f|d; caller validated ancestors
  local path="$1" kind="$2"
  [ ! -L "$path" ] || return 1
  if [ -e "$path" ]; then
    case "$kind" in (f) [ -f "$path" ] ;; (d) [ -d "$path" ] ;; (*) return 1 ;; esac
  fi
}

state_path_parent() {  # every existing ancestor of one canonical path is non-link
  local parent="${1%/*}"
  [ -n "$parent" ] || parent=/
  state_no_symlink_path "$parent" && [ "$_SNP" = "$parent" ]
}

state_path_object() {  # $1=canonical path $2=f|d; absent is allowed
  state_path_parent "$1" && state_path_leaf "$1" "$2"
}

state_paths_validate() {  # six canonical paths are safe, distinct state objects
  local bbase="$1" broot="$2" fbase="$3" froot="$4" sbase="$5" sroot="$6"
  local bp="${bbase%/*}" fp="${fbase%/*}" sp="${sbase%/*}" i j collision=0 had_nocase=0
  local paths=("$bbase" "$broot" "$fbase" "$froot" "$sbase" "$sroot") kinds=(f d f d f d)
  [ -n "$bp" ] || bp=/; [ -n "$fp" ] || fp=/; [ -n "$sp" ] || sp=/
  state_path_parent "$bbase" || return 1
  [ "$fp" = "$bp" ] || state_path_parent "$fbase" || return 1
  if [ "$sp" != "$bp" ] && [ "$sp" != "$fp" ]; then state_path_parent "$sbase" || return 1; fi
  for ((i=0; i<6; i++)); do state_path_leaf "${paths[$i]}" "${kinds[$i]}" || return 1; done
  case "${OSTYPE:-}" in
    (darwin*|mingw*|msys*)
      shopt -q nocasematch && had_nocase=1
      shopt -s nocasematch
      for ((i=0; i<6 && collision==0; i++)); do
        for ((j=i+1; j<6; j++)); do [[ "${paths[$i]}" == "${paths[$j]}" ]] && { collision=1; break; }; done
      done
      [ "$had_nocase" = 1 ] || shopt -u nocasematch
      ;;
    (*)
      for ((i=0; i<6 && collision==0; i++)); do
        for ((j=i+1; j<6; j++)); do [ "${paths[$i]}" = "${paths[$j]}" ] && { collision=1; break; }; done
      done
      ;;
  esac
  [ "$collision" = 0 ] || return 1
  for ((i=0; i<6; i++)); do
    for ((j=i+1; j<6; j++)); do
      if [ -e "${paths[$i]}" ] && [ -e "${paths[$j]}" ] && [ "${paths[$i]}" -ef "${paths[$j]}" ]; then return 1; fi
    done
  done
}

state_paths_check() {  # → _SPC_*; configured namespaces canonical, distinct, non-link
  state_store_path "$_STATE_BURN_CFG" || return 1
  _SPC_BBASE=$_SS_BASE; _SPC_BROOT=$_SS_ROOT
  state_store_path "$_STATE_RL5_CFG" || return 1
  _SPC_5BASE=$_SS_BASE; _SPC_5ROOT=$_SS_ROOT
  state_store_path "$_STATE_RL7_CFG" || return 1
  _SPC_7BASE=$_SS_BASE; _SPC_7ROOT=$_SS_ROOT
  state_paths_validate "$_SPC_BBASE" "$_SPC_BROOT" "$_SPC_5BASE" "$_SPC_5ROOT" "$_SPC_7BASE" "$_SPC_7ROOT"
}

state_paths_revalidate() {  # every mutation rechecks the cached canonical identities
  [ "${_STATE_PATHS_OK:-0}" = 1 ] || return 1
  state_paths_validate "$_SB_BASE" "$_SB_ROOT" "$_SL5_BASE" "$_SL5_ROOT" "$_SL7_BASE" "$_SL7_ROOT"
}

state_gate() {  # canonicalize one render's values and state namespaces
  _STATE_MUTATE=1; [ "${CORALLINE_NO_SAMPLE:-0}" = 1 ] && _STATE_MUTATE=0
  case "$CORALLINE_BURN_WINDOW" in (''|*[!0-9]*) CORALLINE_BURN_WINDOW=600 ;; esac
  [ "${#CORALLINE_BURN_WINDOW}" -le 5 ] && [ "$CORALLINE_BURN_WINDOW" -ge 60 ] 2>/dev/null \
    && [ "$CORALLINE_BURN_WINDOW" -le 86400 ] 2>/dev/null || CORALLINE_BURN_WINDOW=600
  case "$BURN_TRIM" in (''|*[!0-9]*) BURN_TRIM=1500 ;; esac
  [ "${#BURN_TRIM}" -le 4 ] && [ "$BURN_TRIM" -ge 1 ] 2>/dev/null \
    && [ "$BURN_TRIM" -le 3000 ] 2>/dev/null || BURN_TRIM=1500
  case "$BURN_SLACK" in (''|*[!0-9]*) BURN_SLACK=500 ;; esac
  [ "${#BURN_SLACK}" -le 4 ] && [ "$BURN_SLACK" -ge 0 ] 2>/dev/null \
    && [ "$BURN_SLACK" -le 1000 ] 2>/dev/null || BURN_SLACK=500

  _CUR5_VALID=0; _CUR7_VALID=0; _CUR_BURN_VALID=0
  _CUR5_PCT=0; _CUR5_CANON=""; _CUR5_TSV=""; _CUR5_RST=0
  _CUR7_PCT=0; _CUR7_CANON=""; _CUR7_TSV=""; _CUR7_RST=0
  _CUR_BURN_SAMP=0; _CUR_BURN_PCT=0; _CUR_BURN_TSV=""; _CUR_BURN_RST=0
  if state_pct "$fh_pct"; then
    _CUR5_PCT=$_SP_MILLI; _CUR5_CANON=$_SP_CANON
    printf -v _CUR5_TSV '%d.%03d' $(( _CUR5_PCT / 1000 )) $(( _CUR5_PCT % 1000 ))
    if state_payload_epoch "$fh_rst" 10; then
      _CUR5_RST=$_SE_VALUE
      [ "$_CUR5_RST" -gt "$NOW" ] && [ "$_CUR5_RST" -le $(( NOW + RL_MAX_5H )) ] && _CUR5_VALID=1
    fi
  fi
  if state_pct "$wd_pct"; then
    _CUR7_PCT=$_SP_MILLI; _CUR7_CANON=$_SP_CANON
    printf -v _CUR7_TSV '%d.%03d' $(( _CUR7_PCT / 1000 )) $(( _CUR7_PCT % 1000 ))
    if state_payload_epoch "$wd_rst" 10; then
      _CUR7_RST=$_SE_VALUE
      [ "$_CUR7_RST" -gt "$NOW" ] && [ "$_CUR7_RST" -le $(( NOW + RL_MAX_7D )) ] && _CUR7_VALID=1
    fi
  fi
  if [ "$_CUR5_VALID" = 1 ] && state_epoch "$NOW" 12; then
    _CUR_BURN_SAMP=$_SE_VALUE; _CUR_BURN_RST=$_CUR5_RST
    _CUR_BURN_PCT=$_CUR5_PCT; _CUR_BURN_TSV=$_CUR5_TSV; _CUR_BURN_VALID=1
  fi

  _STATE_BURN_CFG="$BURN_FILE"; _STATE_RL5_CFG="$RL5H_FILE"; _STATE_RL7_CFG="$RL7D_FILE"
  _SB_BASE=""; _SB_ROOT=""; _SL5_BASE=""; _SL5_ROOT=""; _SL7_BASE=""; _SL7_ROOT=""
  _STATE_PATHS_OK=0; _STATE_BURN_SAFE=0; _STATE_RL5_SAFE=0; _STATE_RL7_SAFE=0
  if state_paths_check; then
    _SB_BASE=$_SPC_BBASE; _SB_ROOT=$_SPC_BROOT
    _SL5_BASE=$_SPC_5BASE; _SL5_ROOT=$_SPC_5ROOT
    _SL7_BASE=$_SPC_7BASE; _SL7_ROOT=$_SPC_7ROOT
    _STATE_PATHS_OK=1; _STATE_BURN_SAFE=1; _STATE_RL5_SAFE=1; _STATE_RL7_SAFE=1
  fi
  _STATE_RL5_VALID=0; _STATE_RL5_RST=0; _STATE_RL5_PCT=0
  _STATE_RL7_VALID=0; _STATE_RL7_RST=0; _STATE_RL7_PCT=0
  _STATE_READY=1
}

# Per-(second, window, pct) burn-write election. N concurrent sessions on one
# account share one current 5h window and would otherwise each append a
# near-identical row every second, keeping the file permanently past BURN_TRIM
# so that every render pays a whole-file rewrite; measured at n=16 that write
# path alone is ~600ms CPU/s aggregate. The reader keeps only the MAX pct per
# (reset, sample) row (add_obs), so a reading at or below a pct already
# claimed for this (second, window) is exactly the row dedup would discard: a
# session appends only when it carries new information. Same-pct sessions (the
# storm case) collapse to one writer; a session with a HIGHER reading — e.g.
# the one actively burning while another idles on a stale snapshot — always
# still lands, and a session on a DIFFERENT window claims a different token,
# so the persisted series is exactly what every-session writes produce.
# Limit-store publishing (rl_sample) is deliberately NOT elected: those
# entries are idempotent bounded mkdirs with no rewrite cost, and any session
# may hold a newer window that must be able to reach the store.
# Tokens live beside the burn file and carry its name as prefix
# (<burnfile>.<epoch>.<reset>.<pctmilli>.tick), mirroring burn_tmp_sweep's
# provenance rule: in a shared parent directory only files that name THIS
# store are ever considered ours, so the sweep cannot touch foreign files.
# The claim is a noclobber `:` redirect (O_CREAT|O_EXCL, no fork). Losing, and
# every guard failure around the claim, leaves the store untouched; only a
# claim that fails while the token is genuinely absent (e.g. parent not yet
# created) fails OPEN to today's every-session-writes behavior, because the
# mutations downstream re-run their own TOCTOU guards and a fresh store must
# keep sampling from its first render.
state_burn_lead() {  # → 0 iff this render must run the burn write path
  case "${_BURN_LEAD:-}" in 1) return 0 ;; 0) return 1 ;; esac
  _BURN_LEAD=0
  [ "${_STATE_BURN_SAFE:-0}" = 1 ] || return 1
  local slot tok had_c=0 won=0 f n e r p c=0 best=-1
  # Same discipline as every store mutation: revalidate immediately before
  # touching the path. If revalidation cannot pass, fail open without creating
  # or deleting anything here.
  if ! state_paths_revalidate; then _BURN_LEAD=1; return 0; fi
  if [ "${_CUR_BURN_VALID:-0}" = 1 ]; then
    slot="$_SB_BASE.${NOW}.${_CUR_BURN_RST}"
    tok="$slot.${_CUR_BURN_PCT}.tick"
    # Lose only to a claim that already covers this reading: the highest pct
    # claimed for this (second, window) at or above ours makes our row
    # redundant.
    for f in "$slot".*.tick; do
      # Only a regular non-symlink file is a claim we made: a planted symlink
      # or directory must not stand in for a winner, or losing to it would
      # let a follower adopt a cached estimate with no live parse behind it.
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      p=${f#"$slot".}; p=${p%.tick}
      # Length caps mirror state_epoch's width rule: a planted name with an
      # oversized digit run must not reach [ -gt ] (integer overflow would
      # leak an error line onto the render's stderr).
      case "$p" in (''|*[!0-9]*) continue ;; esac
      [ "${#p}" -le 6 ] || continue
      [ "$p" -gt "$best" ] && best=$p
    done
    # A covering claim (pct at or above ours) is the one loss reason a
    # follower may trust: it proves a winner is computing this second, so the
    # published estimate is safe to adopt (_BURN_LOST gates burn_est_adopt,
    # and _BURN_LOST_PCT records the covering pct so the adopter can require
    # the estimate's embedded claim to be at least that complete).
    [ "$_CUR_BURN_PCT" -gt "$best" ] || { _BURN_LOST=1; _BURN_LOST_PCT=$best; return 1; }
  else
    # No reading of our own: maintenance-only claim under the reserved
    # window/pct 0.0, so trim, healing, and the tmp sweep never starve while
    # every rendering session happens to lack a current 5h payload. Any
    # same-second claimant (any window) makes maintenance redundant — a real
    # claimant runs the same mutate path — and burn_sample's own gate keeps a
    # maintenance winner from ever appending a row.
    for f in "$_SB_BASE.${NOW}".*.tick; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      return 1
    done
    tok="$_SB_BASE.${NOW}.0.0.tick"
  fi
  # A pre-existing symlink (or other oddity) planted at the token name is not
  # followed and not deleted; this render just loses the tick.
  state_no_symlink_path "$tok" && [ "$_SNP" = "$tok" ] || return 1
  case $- in *C*) had_c=1 ;; esac
  set -C
  if : 2>/dev/null > "$tok"; then won=1; fi
  [ "$had_c" = 1 ] || set +C
  if [ "$won" != 1 ]; then
    # EEXIST from a regular file: another session claimed this exact reading,
    # which also counts as a covering claim for adoption purposes.
    if [ -f "$tok" ] && [ ! -L "$tok" ]; then _BURN_LOST=1; _BURN_LOST_PCT=$_CUR_BURN_PCT; return 1; fi
    # A non-file object raced in: lose without trusting it.
    if [ -e "$tok" ] || [ -L "$tok" ]; then return 1; fi
    # Anything else (missing parent on a fresh store, transient fs error):
    # fail open so sampling never silently stops.
    _BURN_LEAD=1; return 0
  fi
  _BURN_LEAD=1
  # Winner duty: clear other seconds' tokens. A token is swept only once it is
  # at least 8s in the past: a render's NOW is fixed at startup, so a straggler
  # still finishing second T must find T's token intact while the second-T+1
  # winner runs, or it would reclaim T and double-write (observed in the n=16
  # concurrency regression; 8s outlives any render that is not already
  # pathological). Future-dated tokens (backwards clock step) drain
  # immediately. Same-NOW tokens stay. Only plain non-symlink files prefixed
  # by this store's own name with a strictly numeric epoch.window.pct shape
  # are ever deleted, and the identities are revalidated again before the
  # batched rm (mirrors burn_tmp_sweep's cap-and-batch pattern).
  state_paths_revalidate || return 0
  set --
  for f in "$_SB_BASE".*.tick; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    n=${f#"$_SB_BASE".}; n=${n%.tick}
    e=${n%%.*}
    case "$e" in (''|*[!0-9]*) continue ;; esac
    [ "${#e}" -le 12 ] || continue
    n=${n#*.}
    case "$n" in *.*) ;; *) continue ;; esac
    r=${n%%.*}; p=${n#*.}
    case "$r" in (''|*[!0-9]*) continue ;; esac
    [ "${#r}" -le 12 ] || continue
    case "$p" in (''|*[!0-9]*) continue ;; esac
    [ "${#p}" -le 6 ] || continue
    [ "$e" -le "$NOW" ] && [ "$e" -ge $(( NOW - 8 )) ] && continue
    set -- "$@" "$f"; c=$(( c + 1 ))
    [ "$c" -ge 8 ] && break
  done
  [ "$c" -gt 0 ] && rm -f "$@" 2>/dev/null
  return 0
}

burn_sample() {  # append one canonical validated 5h row; $1=sample $2=pct $3=reset
  local parent
  _BURN_APPENDED=0
  [ "${_STATE_MUTATE:-0}" = 1 ] && [ "${_STATE_BURN_SAFE:-0}" = 1 ] \
    && [ "${_CUR_BURN_VALID:-0}" = 1 ] || return 0
  state_burn_lead || return 0
  [ "$1" = "$_CUR_BURN_SAMP" ] && [ "$2" = "$_CUR_BURN_TSV" ] && [ "$3" = "$_CUR_BURN_RST" ] || return 0
  parent="${_SB_BASE%/*}"; [ -n "$parent" ] || parent=/
  if [ ! -d "$parent" ]; then
    state_paths_revalidate || return 0
    mkdir -p "$parent" 2>/dev/null || return 0
  fi
  state_paths_revalidate || return 0
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$_SB_BASE" 2>/dev/null && _BURN_APPENDED=1
}

rl_dir() {  # → _RLD from a canonical configured base
  state_store_path "$1" || { _RLD=""; return 1; }
  _RLD=$_SS_ROOT
}

state_limit_root_ok() {  # $1=canonical base $2=canonical root; read-only local check
  [ "${_STATE_PATHS_OK:-0}" = 1 ] || return 1
  if [ "$1" = "$_SL5_BASE" ] && [ "$2" = "$_SL5_ROOT" ]; then :
  elif [ "$1" = "$_SL7_BASE" ] && [ "$2" = "$_SL7_ROOT" ]; then :
  else return 1; fi
  state_path_parent "$1" && state_path_leaf "$1" f && state_path_leaf "$2" d
}

state_dir_empty() {  # exact limit entries are empty directories
  local child
  for child in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -e "$child" ] || [ -L "$child" ] || continue
    return 1
  done
  return 0
}

state_limit_entry_ok() {  # $1=base $2=root $3=path $4=name
  [ "$3" = "$2/$4" ] || return 1
  state_limit_root_ok "$1" "$2" || return 1
  state_limit_name "$4" || return 1
  state_no_symlink_path "$3" || return 1
  [ "$_SNP" = "$3" ] && [ -d "$3" ] && [ ! -L "$3" ] && state_dir_empty "$3"
}

rl_sample() {  # $1=canonical base $2=pct_milli $3=reset
  local base="$1" pct="$2" rst="$3" root name path
  [ "${_STATE_MUTATE:-0}" = 1 ] || return 0
  if [ "$base" = "${_SL5_BASE:-}" ]; then
    [ "${_STATE_RL5_SAFE:-0}" = 1 ] && [ "${_CUR5_VALID:-0}" = 1 ] \
      && [ "$pct" = "$_CUR5_PCT" ] && [ "$rst" = "$_CUR5_RST" ] || return 0
    root=$_SL5_ROOT
  elif [ "$base" = "${_SL7_BASE:-}" ]; then
    [ "${_STATE_RL7_SAFE:-0}" = 1 ] && [ "${_CUR7_VALID:-0}" = 1 ] \
      && [ "$pct" = "$_CUR7_PCT" ] && [ "$rst" = "$_CUR7_RST" ] || return 0
    root=$_SL7_ROOT
  else return 0; fi
  state_limit_root_ok "$base" "$root" || return 0
  if [ ! -d "$root" ]; then
    state_paths_revalidate || return 0
    mkdir -p "$root" 2>/dev/null || return 0
    state_limit_root_ok "$base" "$root" || return 0
  fi
  printf -v name '%010d_%03d.%03d' "$rst" $(( pct / 1000 )) $(( pct % 1000 ))
  state_limit_name "$name" || return 0
  path="$root/$name"
  state_no_symlink_path "$path" && [ "$_SNP" = "$path" ] || return 0
  if [ -e "$path" ] || [ -L "$path" ]; then
    state_limit_entry_ok "$base" "$root" "$path" "$name" >/dev/null 2>&1 || true
    return 0
  fi
  state_paths_revalidate || return 0
  state_no_symlink_path "$path" && [ "$_SNP" = "$path" ] && [ ! -e "$path" ] && [ ! -L "$path" ] || return 0
  mkdir "$path" 2>/dev/null || true
}

rl_latest() {  # $1=canonical base $2=max secs ahead $3=mutate → _LL_*
  local base="$1" max="$2" mutate="${3:-0}" root path name raw=0 complete=1 hi="" i cut gc=0 LC_ALL=C
  local names=() paths=() resets=() pcts=()
  _LL_VALID=0; _LL_PCT=""; _LL_PCT_MILLI=0; _LL_RST=""
  case "$max" in (''|*[!0-9]*) return 0 ;; esac
  [ "${#max}" -le 6 ] && [ "$max" -ge 1 ] 2>/dev/null || return 0
  rl_dir "$base" || return 0; root=$_RLD
  state_limit_root_ok "$base" "$root" || return 0
  [ -d "$root" ] || return 0
  cut=$(( NOW + max ))
  for path in "$root"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    raw=$(( raw + 1 )); if [ "$raw" -gt 512 ]; then complete=0; break; fi
    name=${path##*/}
    state_limit_name "$name" || continue
    [ -d "$path" ] && [ ! -L "$path" ] && state_dir_empty "$path" || continue
    i=${#names[@]}; names[$i]="$name"; paths[$i]="$path"; resets[$i]=$_SLN_RST; pcts[$i]=$_SLN_PCT
    if [ "$_SLN_RST" -gt "$NOW" ] && [ "$_SLN_RST" -le "$cut" ]; then
      [ -n "$hi" ] && [[ "$name" < "$hi" ]] || hi="$name"
    fi
  done
  [ "$complete" = 1 ] || return 0
  if [ -n "$hi" ]; then
    for ((i=0; i<${#names[@]}; i++)); do
      if [ "${names[$i]}" = "$hi" ] && state_limit_entry_ok "$base" "$root" "${paths[$i]}" "$hi"; then
        _LL_VALID=1; _LL_RST=${resets[$i]}; _LL_PCT_MILLI=${pcts[$i]}
        printf -v _LL_PCT '%03d.%03d' $(( _LL_PCT_MILLI / 1000 )) $(( _LL_PCT_MILLI % 1000 ))
        break
      fi
    done
  fi
  [ "$mutate" = 1 ] || return 0
  for ((i=0; i<${#names[@]}; i++)); do [ "${names[$i]}" = "$hi" ] || { gc=1; break; }; done
  [ "$gc" = 1 ] || return 0
  state_paths_revalidate && state_limit_root_ok "$base" "$root" || return 0
  for ((i=0; i<${#names[@]}; i++)); do
    [ "${names[$i]}" = "$hi" ] && continue
    state_limit_entry_ok "$base" "$root" "${paths[$i]}" "${names[$i]}" || continue
    rmdir "${paths[$i]}" 2>/dev/null || true
  done
}

# This session's own reading wins its own window. The store used to win on a
# higher pct for the same reset, which assumed usage inside a window only ever
# rises. That assumption breaks whenever the percentage legitimately DROPS while
# resets_at stays put: an upstream limit reset, a subscription upgrade (same
# usage, larger allowance), or any server-side adjustment. The recorded maximum
# then became unbeatable for the rest of the window — up to five hours for 5h and
# a full week for 7d — so the bar kept reporting a value no session was seeing.
# Nothing in the payload timestamps an observation, so a stale high reading is
# indistinguishable from a current one and cannot be aged out; the only reliable
# evidence for this session's own window is this session's own snapshot.
# The store keeps its purpose where it still has better information: it wins when
# it holds a NEWER reset (another session already rolled into the next window),
# and it is the sole source whenever this session has no valid reading at all.
rl_choose() {  # $1=5|7; this session's window beats the store; a newer stored window beats it
  local which="$1" valid="$_LL_VALID" rst="${_LL_RST:-0}" pct="$_LL_PCT_MILLI" crst cpct cvalid
  if [ "$which" = 5 ]; then cvalid=$_CUR5_VALID; crst=$_CUR5_RST; cpct=$_CUR5_PCT
  else cvalid=$_CUR7_VALID; crst=$_CUR7_RST; cpct=$_CUR7_PCT; fi
  if [ "$cvalid" = 1 ] && { [ "$valid" = 0 ] || [ "$crst" -ge "$rst" ]; }; then
    valid=1; rst=$crst; pct=$cpct
  fi
  if [ "$which" = 5 ]; then _STATE_RL5_VALID=$valid; _STATE_RL5_RST=$rst; _STATE_RL5_PCT=$pct
  else _STATE_RL7_VALID=$valid; _STATE_RL7_RST=$rst; _STATE_RL7_PCT=$pct; fi
}

# A killed render leaves its trim temporary behind: awk writes <base>.<pid>.tmp in
# full and the mv that would have consumed it never runs. Nothing ever retired
# those, so one busy host accumulated 1012 of them (38 MB) in three days. Sweep on
# the mutating path only, and without a fork per file: the name must be exactly
# <base>.<digits>.tmp, the object a regular non-symlink file, and older than the
# store it was derived from — a temporary a live render is still writing is never
# older than the base it is about to replace. Losing that race costs one trim (mv
# finds no file, the base stays intact), never data. One batched rm, capped so a
# pathological directory cannot build an unbounded argument list; what is left
# over is swept by the next render.
# The glob is eager: bash expands and sorts every match before the loop runs, so
# the cap bounds deletions and stat calls but not the expansion. That is accepted
# rather than fixed, because bash has no fork-free lazy directory walk and find is
# barred from the state path by both the fork budget and a regression test. The
# cost was measured on the real backlog that motivated this: a clean store is
# indistinguishable from bare interpreter startup (24 ms either way), and 1020
# orphans cost 137 ms on the worst render and drain in nine, after which they
# cannot come back, since 128 per render outruns accumulation by three orders of
# magnitude (about 48 per hour observed). Raising the cap to drain in one render
# is worse, not better: 1024 per pass measured 4385 ms, well past the one-second
# refresh, because the argument list grows with it.
burn_tmp_sweep() {  # remove trim temporaries orphaned by killed renders
  local f n c=0
  set --
  for f in "$_SB_BASE".*.tmp; do
    [ -e "$f" ] || continue
    n=${f#"$_SB_BASE".}; n=${n%.tmp}
    case "$n" in (''|*[!0-9]*) continue ;; esac
    [ -f "$f" ] && [ ! -L "$f" ] && [ "$f" -ot "$_SB_BASE" ] || continue
    set -- "$@" "$f"; c=$(( c + 1 ))
    [ "$c" -ge 128 ] && break
  done
  [ "$c" -gt 0 ] && rm -f "$@" 2>/dev/null
  return 0
}

# The single parser for one "state span delta latest ttr" estimator line.
# burn_eta_5h feeds it the awk's stdout; burn_est_adopt feeds it a line
# reconstructed from a published estimate. Exactly one validator existing is a
# deliberate security property: _B5_ETA and _B5_TTR flow into bash arithmetic
# downstream, so every producer must pass this same gate.
burn_b5_line() {  # → _B5_* from one estimator line; 1 = line rejected
  # The trailing newest-sample epoch is provenance for the cache, not input
  # to the estimate; it is read here only so it cannot land inside ttr.
  local state span delta latest ttr newest
  read -r state span delta latest ttr newest <<EOF
$1
EOF
  case "$state" in
    (active)
      case "$span$delta$latest$ttr" in (''|*[!0-9]*) return 1 ;; esac
      [ "$span" -gt 0 ] && [ "$delta" -gt 0 ] || return 1
      state_rate10 $(( delta * 10000000000 )) "$span"; _B5_RATE=$_RATE10
      state_round_even $(( (100000 - latest) * span )) $(( delta * 1000 )) || return 1
      _B5_STATE=active; _B5_ETA=$_RE; _B5_TTR=$ttr
      ;;
    (idle|warming)
      case "$ttr" in (''|*[!0-9]*) ttr=0 ;; esac
      _B5_STATE=$state; _B5_TTR=$ttr
      ;;
    (*) return 1 ;;
  esac
}

burn_eta_5h() {  # → _B5_* from canonical TSV; $1=allow trim/heal mutation
  local mutate="${1:-0}" src=/dev/null tmp="" write_tmp=0 out="" rc
  _B5_STATE=warming; _B5_ETA=inf; _B5_RATE="0.0000000000"; _B5_TTR=0; _B5_RAW=""
  if [ "${_STATE_BURN_SAFE:-0}" = 1 ] && state_path_object "$_SB_BASE" f; then src=$_SB_BASE; fi
  if [ "$mutate" = 1 ] && [ "$src" != /dev/null ]; then
    burn_tmp_sweep
    tmp="$_SB_BASE.$$.tmp"
    if state_paths_revalidate && state_no_symlink_path "$tmp" && [ "$_SNP" = "$tmp" ] \
       && [ ! -e "$tmp" ] && [ ! -L "$tmp" ]; then write_tmp=1; fi
  fi
  out=$(LC_ALL=C awk -F '\t' -v now="$NOW" -v win="$CORALLINE_BURN_WINDOW" \
    -v trim="$BURN_TRIM" -v slack="$BURN_SLACK" \
    -v maxahead="$RL_MAX_5H" -v mutate="$write_tmp" -v tmp="$tmp" \
    -v curvalid="${_CUR_BURN_VALID:-0}" -v csamp="${_CUR_BURN_SAMP:-0}" \
    -v cpct="${_CUR_BURN_PCT:-0}" -v crst="${_CUR_BURN_RST:-0}" '
    function epoch(raw, value) {
      if (length(raw) < 1 || length(raw) > 12 || raw !~ /^(0|[1-9][0-9]*)$/) return -1
      if (length(raw) == 12 && raw > "253402300799") return -1
      value = raw + 0
      if (value < 0 || value > 253402300799) return -1
      return value
    }
    function pct_milli(raw, parts, whole, frac, six, keep, rest, milli) {
      if (length(raw) < 1 || length(raw) > 10) return -1
      if (raw ~ /^[0-9][0-9][0-9]\.[0-9][0-9][0-9]$/) {
        whole = substr(raw, 1, 3) + 0; frac = substr(raw, 5, 3)
        if (whole > 100 || (whole == 100 && frac ~ /[1-9]/)) return -1
      } else {
        if (raw !~ /^(0|[1-9][0-9]?|100)(\.[0-9]{1,6})?$/) return -1
        parts = split(raw, pp, "."); whole = pp[1]; frac = (parts == 2 ? pp[2] : "")
        if (whole == "100" && frac ~ /[1-9]/) return -1
      }
      six = substr(frac "000000", 1, 6); keep = substr(six, 1, 3) + 0; rest = substr(six, 4, 3) + 0
      milli = (whole + 0) * 1000 + keep
      if (rest > 500 || (rest == 500 && milli % 2 == 1)) milli++
      if (milli < 0 || milli > 100000) return -1
      return milli
    }
    function canon(m) { return sprintf("%d.%03d", int(m / 1000), m % 1000) }
    function add_obs(r, s, p, key, at) {
      key = r SUBSEP s
      if (!(key in pos)) { at = ++n; pos[key] = at; rs[at] = r; sm[at] = s; pc[at] = p }
      else { at = pos[key]; if (p > pc[at]) pc[at] = p }
    }
    function qsort(a, lo, hi, i, j, mid, t) {
      while (lo < hi) {
        i = lo; j = hi; mid = a[int((lo + hi) / 2)] + 0
        while (i <= j) {
          while (a[i] + 0 < mid) i++
          while (a[j] + 0 > mid) j--
          if (i <= j) { t = a[i]; a[i] = a[j]; a[j] = t; i++; j-- }
        }
        if (j - lo < hi - i) { qsort(a, lo, j); lo = i } else { qsort(a, i, hi); hi = j }
      }
    }
    {
      physical++; bytes += length($0) + 1
      if (physical > 4096 || bytes > 1048576 || length($0) > 4096) { incomplete = 1; exit }
      nf = split($0, f, "\t")
      if (nf != 3) next
      s = epoch(f[1]); p = pct_milli(f[2]); r = epoch(f[3])
      if (s < 0 || p < 0 || r < 0) next
      if (s > now + 300 || r < s || r > now + maxahead) { heal = 1; next }
      add_obs(r, s, p)
    }
    END {
      if (incomplete) { print "incomplete"; exit }
      if (mutate && (physical > trim + slack || heal)) {
        lo = n - trim + 1; if (lo < 1) lo = 1
        printf "%s", "" > tmp
        for (i = lo; i <= n; i++) printf "%.0f\t%s\t%.0f\n", sm[i], canon(pc[i]), rs[i] >> tmp
        close(tmp)
      }
      if (curvalid) add_obs(crst + 0, csamp + 0, cpct + 0)
      maxrst = 0
      for (i = 1; i <= n; i++) if (rs[i] > maxrst) maxrst = rs[i]
      if (maxrst <= 0) { print "warming 0 0 0 0 0"; exit }
      m = 0
      for (i = 1; i <= n; i++) if (rs[i] == maxrst) {
        sk = sprintf("%.0f", sm[i])
        if (!(sk in sample_pct)) { order[++m] = sm[i]; sample_pct[sk] = pc[i] }
        else if (pc[i] > sample_pct[sk]) sample_pct[sk] = pc[i]
      }
      if (m == 0) { print "warming 0 0 0 0 0"; exit }
      qsort(order, 1, m)
      sk = sprintf("%.0f", order[m]); latest = sample_pct[sk]
      ttr = maxrst - now; if (ttr < 0) ttr = 0
      cutoff = now - win; minspan = int(win / 10)
      fc_t = 0; fc_p = -1; lc_t = 0; lc_p = -1; ncross = 0; anycross = 0
      for (i = 2; i <= m; i++) {
        psk = sprintf("%.0f", order[i-1]); sk = sprintf("%.0f", order[i])
        a = int(sample_pct[psk] / 1000); b = int(sample_pct[sk] / 1000)
        if (b > a) {
          anycross = 1; ct = order[i]
          if (ct >= cutoff && ct <= now) {
            if (fc_p < 0) { fc_t = ct; fc_p = b }
            lc_t = ct; lc_p = b; ncross++
          }
        }
      }
      if (ncross >= 2 && lc_t > fc_t && lc_p > fc_p && (lc_t - fc_t) >= minspan)
        printf "active %.0f %.0f %.0f %.0f %.0f\n", lc_t - fc_t, lc_p - fc_p, latest, ttr, order[m]
      else if (anycross && ncross == 0) printf "idle 0 0 %.0f %.0f %.0f\n", latest, ttr, order[m]
      else printf "warming 0 0 %.0f %.0f %.0f\n", latest, ttr, order[m]
    }
  ' "$src" 2>/dev/null); rc=$?

  if [ "$write_tmp" = 1 ] && [ -f "$tmp" ] && [ ! -L "$tmp" ]; then
    if [ "$rc" -eq 0 ] && state_paths_revalidate && state_no_symlink_path "$tmp" && [ "$_SNP" = "$tmp" ]; then
      if mv -f "$tmp" "$_SB_BASE" 2>/dev/null; then
        # rename(2) carries the temporary's own mtime onto the store, and that
        # timestamp predates the replacement - it is when awk wrote the file.
        # A replacement could therefore land looking OLDER than a concurrent
        # reader's snapshot marker, and that reader would treat a store it
        # never parsed as untouched. Stamping the store after the rename makes
        # every replacement advance past any marker taken before it. The stamp
        # is one empty line: both renderers skip a record that does not split
        # into three fields (awk's `nf != 3` here, ConvertFrom-BurnRecord's
        # length check in statusline.ps1), and the next rewrite drops it.
        state_paths_revalidate && printf '\n' >> "$_SB_BASE" 2>/dev/null || true
      fi
    elif state_paths_revalidate && state_no_symlink_path "$tmp" && [ "$_SNP" = "$tmp" ]; then
      rm -f "$tmp" 2>/dev/null || true
    fi
  fi
  [ "$rc" -eq 0 ] || return 0
  burn_b5_line "$out" || return 0
  _B5_RAW=$out
}

burn_eta_7d() {  # → _B7_*; $1=pct_milli $2=reset epoch
  local pct="${1:-}" rst="${2:-}" elapsed
  _B7_ETA=inf; _B7_RATE="0.0000000000"; _B7_TTR=0
  [ -n "$pct" ] && [ -n "$rst" ] || return 0
  _B7_TTR=$(( rst - NOW )); [ "$_B7_TTR" -lt 0 ] && _B7_TTR=0
  elapsed=$(( NOW - (rst - 604800) ))
  [ "$pct" -gt 0 ] && [ "$elapsed" -ge 1 ] && [ "$elapsed" -le "$RL_MAX_7D" ] || return 0
  state_rate10 $(( pct * 10000000 )) "$elapsed"; _B7_RATE=$_RATE10
  state_round_even $(( (100000 - pct) * elapsed )) "$pct"; _B7_ETA=$_RE
}

# Cross-session estimate sharing. The election winner already paid for the
# full TSV parse; publishing its validated result lets every same-second loser
# skip that parse entirely (the read side is ~75ms of a 141ms state-enabled
# render at n=16 — the dominant multi-session cost after the write election).
# The published file is display-only derived data with the TSV as the source
# of truth: ANY anomaly on the read side falls back to the full parse.
# Publish is rename-only through the store's tmp discipline — never an
# in-place write, which would follow a planted hardlink and tear reads. The
# tmp reuses "$_SB_BASE".$$.tmp strictly AFTER burn_eta_5h's own trim tmp
# lifecycle has ended (burn_estimate calls publish only once burn_eta_5h has
# returned), so burn_tmp_sweep's <base>.<digits>.tmp rule covers orphans from
# a killed render. Fork budget: one mv per second per store, paid by the
# winner, replacing N-1 whole-file awk parses.
# Unlinking is a mutation like any other: an ancestor swapped for a symlink
# after the temporary was written would make a bare rm traverse untrusted
# ground and delete a same-named file in the attacker's target. Every discard
# therefore re-proves the path identity first, mirroring burn_eta_5h's guarded
# cleanup. A temporary left behind because revalidation failed is not lost:
# burn_tmp_sweep owns the <base>.<digits>.tmp namespace and retires it.
burn_est_discard() {  # $1=our publish temporary; remove only through revalidated identities
  state_paths_revalidate && state_no_symlink_path "$1" && [ "$_SNP" = "$1" ] \
    && [ -f "$1" ] && [ ! -L "$1" ] && rm -f "$1" 2>/dev/null
  return 0
}

# The estimate has to describe the TSV as it stood when the parse READ it,
# not when the publish wrote it. A straggler appending in between would
# otherwise hand followers a summary that silently omits its row: the
# adopter's mtime test cannot catch that, because the estimate is written
# afterwards and is therefore legitimately newer. A zero-byte marker taken
# before the parse records that instant, and publication is abandoned if the
# TSV moved past it. The marker lives in the <base>.<digits>.tmp namespace
# burn_tmp_sweep owns, so a killed render leaves nothing permanent, and it is
# named apart from the pid-named temporaries the trim and the publish use. A
# trim rewrite during our own parse also trips the test and costs that
# second's publication: rare (once per BURN_SLACK appends), and the next tick
# publishes normally.
burn_est_snap() {  # → _BURN_SNAP: marker recording the pre-parse TSV state
  _BURN_SNAP=""
  local snap="$_SB_BASE.$(( $$ + 1000000 )).tmp" had_c=0
  state_paths_revalidate || return 0
  state_no_symlink_path "$snap" && [ "$_SNP" = "$snap" ] || return 0
  [ ! -e "$snap" ] && [ ! -L "$snap" ] || return 0
  case $- in *C*) had_c=1 ;; esac
  set -C
  : 2>/dev/null > "$snap" && _BURN_SNAP=$snap
  [ "$had_c" = 1 ] || set +C
  return 0
}

burn_est_publish() {  # winner only: publish "<now> <maxrst> <state> <span> <delta> <latest>"
  # The parse-time marker is claimed for this call and released on every exit
  # path below. No marker means the parse was never versioned, which is a
  # refusal, not a licence.
  local snap="${_BURN_SNAP:-}"
  _BURN_SNAP=""
  [ -n "$snap" ] || return 0
  [ "${_CUR_BURN_VALID:-0}" = 1 ] || { burn_est_discard "$snap"; return 0; }
  [ -n "${_B5_RAW:-}" ] || { burn_est_discard "$snap"; return 0; }
  local est="$_SB_BASE.est" tmp="$_SB_BASE.$$.tmp" s sp d l t nw p f had_c=0 won=0
  state_paths_revalidate || { burn_est_discard "$snap"; return 0; }
  # The est file is a seventh state object outside state_paths_validate's
  # six-path distinctness matrix; refuse to publish over any configured
  # namespace (state_same_path is conservative: unsure means same).
  for p in "$_SB_BASE" "$_SB_ROOT" "$_SL5_BASE" "$_SL5_ROOT" "$_SL7_BASE" "$_SL7_ROOT"; do
    if state_same_path "$est" "$p"; then burn_est_discard "$snap"; return 0; fi
  done
  # A symlink or directory planted at the est name is not followed, not
  # deleted, and aborts the publish; same rule as the election tokens.
  state_no_symlink_path "$est" && [ "$_SNP" = "$est" ] \
    || { burn_est_discard "$snap"; return 0; }
  state_path_leaf "$est" f || { burn_est_discard "$snap"; return 0; }
  state_no_symlink_path "$tmp" && [ "$_SNP" = "$tmp" ] \
    || { burn_est_discard "$snap"; return 0; }
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || { burn_est_discard "$snap"; return 0; }
  read -r s sp d l t nw <<EOF
$_B5_RAW
EOF
  case "${nw:-}" in (''|*[!0-9]*) nw=0 ;; esac
  case $- in *C*) had_c=1 ;; esac
  set -C
  # The trailing claim identity (our reset and pct) lets an adopter require
  # provenance ordering: an estimate whose embedded claim sits below the
  # covering claim the adopter lost to predates a row its own full parse
  # would include, and is rejected on the read side regardless of how writer
  # renames interleave.
  if printf '%s %s %s %s %s %s %s %s %s %s\n' "$NOW" $(( NOW + ${_B5_TTR:-0} )) "$s" "$sp" "$d" "$l" \
       "$_CUR_BURN_RST" "$_CUR_BURN_PCT" "$CORALLINE_BURN_WINDOW" "$nw" 2>/dev/null > "$tmp"; then won=1; fi
  [ "$had_c" = 1 ] || set +C
  # The redirection creates the file before printf runs, so a write that
  # fails afterwards (out of space, over quota) leaves a partial temporary
  # that burn_tmp_sweep cannot retire while the same failure keeps the TSV
  # from advancing past it. Discard it here instead of accumulating one per
  # winner render.
  [ "$won" = 1 ] || { burn_est_discard "$tmp"; burn_est_discard "$snap"; return 0; }
  # Divergent same-second winners publish in parse-completion order, which is
  # not claim order: a winner finishing late must never replace the estimate
  # of a covering claim whose parse includes a row ours does not. That covers
  # a higher pct in our own window AND any claim for a newer window (whose
  # estimate would supersede ours for every adopter our own would satisfy).
  # If a covering claim exists by the time we are about to rename, yield; if
  # it appears in the residual race window instead, its own publication
  # necessarily lands after ours and corrects the file.
  local cr
  for f in "$_SB_BASE.${NOW}".*.tick; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    p=${f#"$_SB_BASE.${NOW}".}; p=${p%.tick}
    case "$p" in *.*) ;; *) continue ;; esac
    cr=${p%%.*}; p=${p#*.}
    case "$cr" in (''|*[!0-9]*) continue ;; esac
    [ "${#cr}" -le 12 ] || continue
    case "$p" in (''|*[!0-9]*) continue ;; esac
    [ "${#p}" -le 6 ] || continue
    if [ "$cr" -gt "$_CUR_BURN_RST" ]; then
      burn_est_discard "$tmp"; burn_est_discard "$snap"; return 0
    fi
    if [ "$cr" -eq "$_CUR_BURN_RST" ] && [ "$p" -gt "$_CUR_BURN_PCT" ]; then
      burn_est_discard "$tmp"; burn_est_discard "$snap"; return 0
    fi
  done
  # The version test belongs HERE, immediately before the rename, not before
  # the temporary was written: a row landing in between would otherwise be
  # missing from an estimate that nonetheless carries a newer mtime than the
  # TSV, defeating the adopter's guard too. The marker must also still exist:
  # it shares burn_tmp_sweep's namespace, so a concurrent writer's sweep can
  # retire it mid-parse, and a vanished marker proves nothing about the
  # store. Both conditions failing mean the same thing - this estimate is not
  # provably a summary of the current TSV - so publication is abandoned.
  if [ -f "$snap" ] && [ ! -L "$snap" ] && [ ! "$_SB_BASE" -nt "$snap" ] \
     && state_paths_revalidate && state_no_symlink_path "$est" && [ "$_SNP" = "$est" ] \
     && state_path_leaf "$est" f; then
    if mv -f "$tmp" "$est" 2>/dev/null; then burn_est_discard "$snap"; return 0; fi
  fi
  burn_est_discard "$tmp"
  burn_est_discard "$snap"
  return 0
}

burn_est_adopt() {  # → 0 iff _B5_* adopted from a fresh, fully validated estimate
  local est="$_SB_BASE.est" LC_ALL=C pub rst s sp d l crst cpct cwin cnew t
  # Same defaults burn_eta_5h starts from: the adopter replaces that call
  # entirely, and downstream comparisons assume every _B5_* is populated.
  _B5_STATE=warming; _B5_ETA=inf; _B5_RATE="0.0000000000"; _B5_TTR=0; _B5_RAW=""
  [ "${_STATE_BURN_SAFE:-0}" = 1 ] || return 1
  state_path_object "$est" f || return 1
  [ -f "$est" ] && [ ! -L "$est" ] || return 1
  # Snapshot versioning: an estimate is a parse of the TSV as it stood at
  # publish time, so the source must still be there to be summarized. A
  # deleted TSV (history reset) makes the mtime test below vacuous - nothing
  # is newer than the estimate - and would let a summary outlive the file it
  # describes, where a full parse would report warming.
  [ -f "$_SB_BASE" ] && [ ! -L "$_SB_BASE" ] || return 1
  # A straggler from a prior tick (its token still inside the sweep's grace
  # window) may append after that publish; if the TSV has a later mtime than
  # the estimate, the cached parse is missing rows a read-only parse would
  # see, so fall back. Same-second mutations sit below test's mtime
  # granularity and are corrected by the next second's publish, a strictly
  # tighter bound than the 3s freshness allowance.
  [ "$_SB_BASE" -nt "$est" ] && return 1
  # -n (not -N: that is bash 4.1+) caps how much of a hostile oversized file
  # a render will ever ingest; trailing junk lands in the last field and
  # fails its digit check, so a malformed line is rejected, never truncated
  # into a plausible one.
  read -r -n 128 pub rst s sp d l crst cpct cwin cnew < "$est" 2>/dev/null || :
  # Every field is validated before it reaches any arithmetic context; the
  # published values bypass the awk whose internal caps normally guarantee
  # these bounds, so the reader must re-impose them itself.
  state_epoch "${pub:-}" 12 || return 1; pub=$_SE_VALUE
  state_epoch "${rst:-}" 12 || return 1; rst=$_SE_VALUE
  [ "$pub" -le "$NOW" ] && [ "$pub" -ge $(( NOW - 3 )) ] || return 1
  # An estimate for a window older than our own reading is a cache miss, not a
  # candidate: our observation alone would advance maxrst past it, so the full
  # parse must run. Without this, the 3s freshness allowance could span a 5h
  # reset and briefly revive the closed window's ETA. The far bound mirrors
  # the TSV estimator's implausibility rule (reset beyond NOW + RL_MAX_5H is
  # healed there, so it must never be adopted here either).
  [ "$rst" -ge "${_CUR_BURN_RST:-0}" ] || return 1
  [ "$rst" -le $(( NOW + RL_MAX_5H )) ] || return 1
  case "${s:-}" in (active|idle|warming) ;; (*) return 1 ;; esac
  # Leading zeros are rejected outright (our publisher never emits them, and
  # bash arithmetic downstream would read them as octal): the (0|[1-9]...)
  # shape mirrors state_epoch's rule.
  # Both crossings lie inside [NOW - win, NOW] in the producer, so the span
  # cannot exceed the lookback; the clamp ceiling is not the bound here.
  case "${sp:-}" in (''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#sp}" -le 5 ] && [ "$sp" -le "$CORALLINE_BURN_WINDOW" ] || return 1
  # delta is a difference of two whole-percent values in the producer, so 100
  # is its real ceiling; the pct-milli scale does not apply to it.
  case "${d:-}" in (''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#d}" -le 3 ] && [ "$d" -le 100 ] || return 1
  case "${l:-}" in (''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#l}" -le 6 ] && [ "$l" -le 100000 ] || return 1
  # Provenance ordering: the embedded claim must be at least as complete as
  # the covering claim we lost to. A claim for a newer window supersedes any
  # same-window pct; within our window the claim pct must reach the covering
  # pct, or the estimate predates a row our own full parse would include
  # (writer renames can interleave arbitrarily, so this is the check that
  # holds regardless of publication order).
  state_epoch "${crst:-}" 12 || return 1; crst=$_SE_VALUE
  # Producer invariant: a writer injects its own claimed observation into the
  # parse, so the window the estimate DESCRIBES can never precede the one its
  # writer CLAIMED, and the claim is bounded by the same horizon. Provenance
  # that no real publisher could have produced is a cache miss, not a licence
  # to skip the covering-claim comparison below.
  [ "$rst" -ge "$crst" ] || return 1
  [ "$crst" -le $(( NOW + RL_MAX_5H )) ] || return 1
  case "${cpct:-}" in (''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#cpct}" -le 6 ] && [ "$cpct" -le 100000 ] || return 1
  # The estimate is a parse under a specific lookback, and CORALLINE_BURN_WINDOW
  # is per-session config: sessions sharing one BURN_FILE with different
  # lookbacks compute genuinely different answers from identical rows, and a
  # wider window can report active where a narrower one reports warming.
  # Adopt only a parse run under our own lookback.
  case "${cwin:-}" in (''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#cwin}" -le 5 ] && [ "$cwin" -eq "$CORALLINE_BURN_WINDOW" ] || return 1
  state_epoch "${cnew:-}" 12 || return 1; cnew=$_SE_VALUE
  if [ "$crst" -le "${_CUR_BURN_RST:-0}" ]; then
    [ "$crst" -eq "${_CUR_BURN_RST:-0}" ] || return 1
    [ "$cpct" -ge "${_BURN_LOST_PCT:-100001}" ] || return 1
  fi
  # THE CONTRACT: the estimate is a cache of the full parse with a freshness
  # bound of three seconds. Within that bound it may lag rows that landed
  # after its publish; every guard above shrinks the lag (mtime versioning,
  # claim provenance, window bounds) but only the next publish or the
  # fallback parse closes it, because bash offers no atomic read of file
  # plus summary. What the cache must NEVER do is contradict what this
  # session itself knows: the full parse injects this session's own reading
  # as the newest sample of its window, and the estimator's latest is
  # defined by the newest sample, so a same-window adoption substitutes our
  # own current pct for the published latest. Percentages legitimately DROP
  # within a window (upstream resets, subscription upgrades - see rl_choose
  # above), so this is a substitution, not a max - but only for a PRIOR-tick
  # estimate: a same-tick winner's row shares our sample key, where add_obs
  # keeps the maximum, so the published latest already includes what our own
  # injection could contribute. The window that matters is the one the
  # estimate DESCRIBES (rst, the parse's newest window), not the one its
  # writer happened to claim: a writer on our window whose parse selected
  # newer rows published numbers our reading has no part in.
  if [ "$rst" -eq "${_CUR_BURN_RST:-0}" ] && [ "$pub" -lt "$NOW" ]; then
    # Our observation is the newest sample of this window, so the full parse
    # would fold it into the crossing detection, not just into latest. It can
    # only ADD a crossing by lifting the whole-percent value (the detector
    # compares integer percents, and a crossing needs a strict rise), which
    # would move span, delta, and possibly warming to active - none of them
    # correctable without the rows. Adopt only when our sample cannot change
    # them; then substituting latest is the entire difference.
    #
    # "Newest" is not an assumption either: the reader accepts samples up to
    # now + 300 for clock skew, so a future-dated row can outrank ours and
    # own latest, and inserting our row before it can even create a crossing
    # against it. The publisher therefore states the newest sample it saw,
    # and adoption falls back unless that proves ours comes after.
    [ "$cnew" -lt "$NOW" ] || return 1
    [ $(( _CUR_BURN_PCT / 1000 )) -gt $(( l / 1000 )) ] && return 1
    l=$_CUR_BURN_PCT
  fi
  # ttr derives locally from the published window and our own NOW, so a
  # 1-3s-old estimate cannot trip the rebind gate into warming flicker.
  t=$(( rst - NOW )); [ "$t" -lt 0 ] && t=0
  burn_b5_line "$s $sp $d $l $t"
}

burn_estimate() {  # → _BURN_STATE _BURN_LABEL _BURN_ETA _BURN_RATE _BURN_TTR
  local f5=0 f7=0 m=0
  # Trim/heal mutation follows the same per-(tick, window, pct) election as
  # the append: a claim winner runs the full parse (and publishes its result);
  # a session that lost to a covering claim adopts the published estimate
  # when it validates, and everything else takes the plain read-only parse.
  [ "${_STATE_MUTATE:-0}" = 1 ] && state_burn_lead && m=1
  if [ "$m" = 1 ]; then
    burn_est_snap
    burn_eta_5h 1
    burn_est_publish
  elif [ "${_BURN_LOST:-0}" = 1 ] && [ "${_CUR_BURN_VALID:-0}" = 1 ] && burn_est_adopt; then
    :
  else
    burn_eta_5h 0
  fi
  # The 5h projection needs the same rebinding the 7d one gets: whenever the synced
  # state is what the gauge draws, the ETA has to be projected from that same window.
  # Two ways they diverge. With no reading of our own the history can still sit on
  # the window that just closed, since an expired reset stays plausible to the reader
  # and its TTR clamps to zero. With a valid reading of our own that rl_choose lets a
  # NEWER stored window beat, the history holds only our older window, and the
  # session that published the newer one need not have burn enabled to contribute
  # samples for it. Both put an active ETA for one window beside a gauge for another,
  # so gate on the stored state alone, not on whether we have a reading. burn_eta_5h
  # reports the window it used as NOW + _B5_TTR; falling back to warming when it does
  # not match is honest, no samples for that window have been observed yet.
  if [ "$VL_LIMIT_SYNC" = 1 ] && [ "${_STATE_RL5_VALID:-0}" = 1 ] \
     && [ $(( NOW + _B5_TTR )) -ne "${_STATE_RL5_RST:-0}" ]; then
    _B5_STATE=warming; _B5_ETA=inf; _B5_RATE="0.0000000000"; _B5_TTR=0
  fi
  # The ownership rule covers the projection too, not just the gauge, and it has
  # to be the SAME rule: burn can bind to the 7d window, so any source seg_limit7d
  # is willing to display must also be the source the ETA is projected from, or
  # the bar and the gauge report different windows in one render.
  if [ "$VL_LIMIT_SYNC" = 1 ] && [ "${_STATE_RL7_VALID:-0}" = 1 ]; then
    burn_eta_7d "$_STATE_RL7_PCT" "$_STATE_RL7_RST"
  elif [ "${_CUR7_VALID:-0}" = 1 ]; then burn_eta_7d "$_CUR7_PCT" "$_CUR7_RST"
  else burn_eta_7d "" ""; fi
  [ "$_B5_ETA" != inf ] && f5=1
  [ "$_B7_ETA" != inf ] && f7=1
  if [ "$f5" = 1 ] && { [ "$f7" = 0 ] || [ "$_B5_ETA" -le "$_B7_ETA" ]; }; then
    _BURN_STATE=active; _BURN_LABEL=5h; _BURN_ETA=$_B5_ETA; _BURN_RATE=$_B5_RATE; _BURN_TTR=$_B5_TTR
  elif [ "$f7" = 1 ]; then
    _BURN_STATE=active; _BURN_LABEL=7d; _BURN_ETA=$_B7_ETA; _BURN_RATE=$_B7_RATE; _BURN_TTR=$_B7_TTR
  else
    _BURN_ETA=inf; _BURN_RATE="0.0000000000"; _BURN_TTR=0; _BURN_LABEL=""
    if [ "$_B5_STATE" = idle ]; then _BURN_STATE=idle; else _BURN_STATE=warming; fi
  fi
}

seg_burn() {  # range-to-empty ETA until the binding 5h/7d limit hits 100% at the recent burn rate
  if [ "${_STATE_READY:-0}" = 1 ]; then
    # Same sources the gauges accept: once a synced store can render 5h/7d for a
    # session that has reported nothing itself, hiding only the projection would
    # leave a gap between two segments that are describing the same windows.
    [ "${_CUR5_VALID:-0}" = 1 ] || [ "${_CUR7_VALID:-0}" = 1 ] \
      || [ "${_STATE_RL5_VALID:-0}" = 1 ] || [ "${_STATE_RL7_VALID:-0}" = 1 ] || return 0
  else
    [ -n "$fh_pct" ] || [ -n "$wd_pct" ] || return 0
  fi
  # _BURN_* is precomputed once per render (see the burn_estimate call beside the
  # sampler below), so the visible and float passes share one computation.
  local bg="${VL_BG_BURN:-$VL_BG_5H}"
  # Nothing to project yet. Idle (stopped burning) is genuinely all-good → dim ✓.
  # Warming (no samples yet, e.g. a fresh install) is "unknown", not healthy → a
  # distinct dim … so a cold start doesn't read as a reassuring green check.
  if [ "$_BURN_STATE" != "active" ]; then
    fg "$VL_FG_DIM"
    if [ "$_BURN_STATE" = "warming" ]; then
      push "$bg" "${_FG} ${VL_BURN_GLYPH} … "
    else
      push "$bg" "${_FG} ${VL_BURN_GLYPH} ✓ "
    fi
    return 0
  fi
  local eta="$_BURN_ETA" ttr="$_BURN_TTR" col win
  # All good: the projected empty is longer than the limit's whole window, so at
  # this pace you couldn't run it dry even from a fresh window — show ✓, not a
  # meaningless multi-day countdown. The window is per-limit (5h vs 7d).
  case "$_BURN_LABEL" in 5h) win=18000 ;; *) win=604800 ;; esac
  if [ "$eta" -gt "$win" ]; then
    fg "$VL_FG_OK"
    push "$bg" "${_FG} ${VL_BURN_GLYPH} ✓ "
    return 0
  fi
  if   [ "$eta" -le "$ttr" ];               then col="$VL_FG_HOT"
  elif [ $(( 10 * ttr )) -ge $(( 8 * eta )) ]; then col="$VL_FG_WARN"
  else                                            col="$VL_FG_OK"; fi
  fmt_eta "$eta"
  fg "$col"
  push "$bg" "${_FG} ${VL_BURN_GLYPH} ${_BURN_LABEL} ⇢ ${_ETA} "
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

# JSON-string escape for the --subagent output protocol → _JS. Pure bash so the
# per-row loop stays fork-free. Escapes \ " and the JSON control shorthands,
# maps ESC to \u001b (ANSI colors survive the round-trip), drops any other
# control character. Untrusted panel fields are scrubbed at the jq extraction
# (see the --subagent block), so the ESC mapping only sees our own codes.
json_escape() {
  local s="$1" out="" c i n
  case "$s" in
    (*[\"\\[:cntrl:]]*) ;;
    (*) _JS="$s"; return 0 ;;
  esac
  n=${#s}
  for ((i=0; i<n; i++)); do
    c="${s:i:1}"
    case "$c" in
      '"')     out+='\"'      ;;
      '\')     out+='\\'      ;;
      $'\033') out+='\u001b'  ;;
      $'\t')   out+='\t'      ;;
      $'\n')   out+='\n'      ;;
      $'\r')   out+='\r'      ;;
      [[:cntrl:]]) ;;
      *)       out+="$c"      ;;
    esac
  done
  _JS="$out"
}

# Resolved model ID → short display name → _MS. The subagent panel's per-task
# model is an ID (claude-haiku-4-5-20251001), not the main statusline's
# display_name. Strip claude- and a trailing date stamp, dot the version, map
# the known families (bash 3.2 has no ${var^}). Anything unrecognized passes
# through verbatim — never wrong, merely verbose.
model_short() {
  local s="$1" fam ver
  _MS="$1"
  case "$s" in (claude-*) ;; (*) return 0 ;; esac
  s="${s#claude-}"
  case "$s" in (*-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) s="${s%-*}" ;; esac
  fam="${s%%-*}" ; ver="${s#"$fam"}" ; ver="${ver#-}"
  case "$ver" in (''|*[!0-9-]*) return 0 ;; esac
  case "$fam" in
    (fable)  fam="Fable"  ;;
    (opus)   fam="Opus"   ;;
    (sonnet) fam="Sonnet" ;;
    (haiku)  fam="Haiku"  ;;
    (*) return 0 ;;
  esac
  _MS="$fam ${ver//-/.}"
}

# ── Git state (single subprocess, parsed once, used by git/stash segments) ──
# All git below is read-only probing. Disable git's optional index lock so a
# frequently-refreshed statusline never rewrites the index or contends for
# index.lock with a real git operation (notably on Windows). Set once, inherited
# by every git call here.
export GIT_OPTIONAL_LOCKS=0
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
  case "$_SEG_SCAN" in *" project "*)
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
  push "${VL_BG_PROJECT:-$VL_BG_DIR}" "${BOLD}${_FG} ${VL_PROJECT_GLYPH} ${_TR} ${NORM}"
}

seg_dir() {  # current directory, long paths collapsed to ~/a/…/z
  [ -n "$cwd" ] || return 0
  local tilde='~'; local short="${cwd/#"$HOME"/$tilde}" n last
  local IFS='/'; set -- $short; n=$#
  if [ "$n" -gt "$VL_PATH_DEPTH" ]; then
    eval "last=\${$n}"
    short="$1/$2/…/$last"
  fi
  fg "$VL_FG_TEXT"
  push "$VL_BG_DIR" "${BOLD}${_FG} ${short} ${NORM}"
}

seg_git() {  # branch with staged/modified/untracked and ahead/behind counts
  [ -n "$GIT_BRANCH" ] || return 0
  local bgc="$VL_BG_GIT_OK"
  [ "$GIT_DIRTY" -eq 1 ] && bgc="$VL_BG_GIT_DIRTY"
  fg "$VL_FG_TEXT"; trunc "$GIT_BRANCH" "$VL_NAME_MAX"
  push "$bgc" "${BOLD}${_FG} ⎇ ${_TR}${GIT_MARKS}${GIT_AB} ${NORM}"
}

seg_model() {  # active Claude model
  [ -n "$model" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_MODEL" "${BOLD}${_FG} ◆ ${model#Claude } ${NORM}"
}

seg_ctx() {  # context-window gauge with input/output/cache token counts
  if [ -z "$ctx_pct" ]; then
    [ "$VL_CTX_ALWAYS_SHOW" = 1 ] && [ "${_JSON_OK:-0}" = 1 ] \
      && [ "${_CTX_EMPTY:-0}" = 1 ] || return 0
  fi
  local ci fgc fgd ti to tcr tcw
  if [ -n "$ctx_pct" ]; then printf -v ci '%.0f' "$ctx_pct" 2>/dev/null || ci=0
  else ci=0
  fi
  make_bar "$ci"; pct_fg "$ci"
  fg "$_PFG";       fgc="$_FG"
  fg "$VL_FG_DIM";  fgd="$_FG"
  fmt_tok "$tok_in"; ti="$_TOK"
  fmt_tok "$tok_out"; to="$_TOK"
  fmt_tok "$tok_cr"; tcr="$_TOK"
  fmt_tok "$tok_cw"; tcw="$_TOK"
  push "$VL_BG_CTX" "${fgc} ${VL_CTX_GLYPH} ${_BAR} ${ci}% ${fgd}↑${ti} ↓${to} cr:${tcr} cw:${tcw} "
}

seg_limit() {  # $1=label $2=pct $3=resets_at $4=bg $5=canonical pct_milli(optional)
  [ -n "$2" ] || return 0
  local v fgc rst=""
  if [ -n "${5:-}" ]; then state_round_even "$5" 1000; v=$_RE
  else printf -v v '%.0f' "$2" 2>/dev/null || v=0; fi
  make_bar "$v"; pct_fg "$v"
  fg "$_PFG"; fgc="$_FG"
  fmt_countdown "$3"
  if [ -n "$_CD" ]; then fg "$VL_FG_DIM"; rst="${_FG}↺${_CD}"; fi
  push "$4" "${fgc} $1 ${_BAR} ${v}% ${rst} "
}
# With VL_LIMIT_SYNC, render the once-per-render canonical state result.
# A synced window is only "valid" while its reset is still ahead — that holds for
# the payload snapshot (state_gate) and for every store entry (rl_latest) alike.
# Claude Code re-renders an idle session from its last-seen snapshot, so the
# moment a window elapses with no interaction BOTH sources fall invalid in the
# same render and gating the segment on validity blanked it until the next
# keystroke delivered a fresh snapshot. Fall back to the ELAPSED window's last
# reading instead, which needs both halves of the snapshot to have survived
# validation: _CUR*_PCT means the pct passed state_pct, and a _CUR*_RST inside
# (0, NOW] means state_payload_epoch parsed a reset that has since passed. A
# missing or malformed reset leaves _CUR*_RST at 0 and must NOT render, or the
# bar would claim an elapsed window that was never observed; a reset beyond the
# window ceiling is the corrupt/sentinel snapshot rejected in #32 and must not
# render a countdown days or years out. seg_limit shows an elapsed reset as
# "now", which is what v0.11 displayed here.
# The fallback is for a window that JUST elapsed, so it is bounded by the same
# ceiling that validates a future reset. Claude Code keeps replaying the last
# snapshot an idle session ever received: observed here were sessions still
# reporting 41% for a window that closed 27 hours earlier and 55% for one that
# closed three days earlier. Rendering those as the current window is worse than
# rendering nothing, and past the bound the segment falls through to the store,
# which by construction only holds windows that are still open.
seg_limit_elapsed() {  # $1=canonical pct $2=parsed reset $3=max elapsed age; sets _SLE_OK
  _SLE_OK=0
  [ -n "$1" ] || return 0
  [ "$2" -gt 0 ] && [ "$2" -le "$NOW" ] && [ $(( NOW - $2 )) -le "$3" ] && _SLE_OK=1
  return 0
}
# Ownership is decided once, in rl_choose: this session's own reading always wins
# its own window, and the store wins only with a strictly newer reset. Requiring
# _CUR*_VALID again HERE did not add protection, it removed the store's documented
# last job — "the sole source whenever this session has no valid reading at all".
# The payload carries rate_limits only once the session has received an API
# response, so a freshly started, resumed, or idle session has no reading of its
# own and blanked both gauges even though the account-level window was known.
# Borrowing then is safe in a way it was not before #61/#62: rl_latest admits an
# entry only while its reset is still ahead of NOW, and garbage-collects every
# entry it outranks, so there is no fossil to inherit. What is still borrowed is
# the highest percentage recorded for the CURRENT window by any session, which is
# an over-estimate when sessions disagree; that is the accepted cost of showing
# the account's window instead of nothing. The store carries no account identity
# and the payload offers nothing to derive one from, so switching Claude accounts
# under one OS account can show the previous account's still-open window until the
# new one's first response lands. That is the same interval in which the gauge used
# to show nothing at all, and it ends as soon as this session has its own reading.
# Both windows use the same rule.
seg_limit5h() {  # 5h rate-limit gauge with reset countdown
  local p="$fh_pct" r="$fh_rst" m=""
  if [ "$VL_LIMIT_SYNC" = 1 ]; then
    seg_limit_elapsed "${_CUR5_CANON:-}" "${_CUR5_RST:-0}" "$RL_MAX_5H"
    if [ "${_STATE_RL5_VALID:-0}" = 1 ]; then m=$_STATE_RL5_PCT; r=$_STATE_RL5_RST
    elif [ "$_SLE_OK" = 1 ]; then m=$_CUR5_PCT; r=$_CUR5_RST
    else return 0; fi
    printf -v p '%d.%03d' $(( m / 1000 )) $(( m % 1000 ))
  fi
  seg_limit "5h" "$p" "$r" "$VL_BG_5H" "$m"
}
seg_limit7d() {  # 7d rate-limit gauge with reset countdown
  local p="$wd_pct" r="$wd_rst" m=""
  if [ "$VL_LIMIT_SYNC" = 1 ]; then
    seg_limit_elapsed "${_CUR7_CANON:-}" "${_CUR7_RST:-0}" "$RL_MAX_7D"
    if [ "${_STATE_RL7_VALID:-0}" = 1 ]; then m=$_STATE_RL7_PCT; r=$_STATE_RL7_RST
    elif [ "$_SLE_OK" = 1 ]; then m=$_CUR7_PCT; r=$_CUR7_RST
    else return 0; fi
    printf -v p '%d.%03d' $(( m / 1000 )) $(( m % 1000 ))
  fi
  seg_limit "7d" "$p" "$r" "$VL_BG_7D" "$m"
}

seg_cost() {  # session cost in USD
  local raw="${cost:-}" trimmed significand lexical_nonzero unsigned digits integer_part leading_zeroes significant exp_text exp_sign exp_value adjusted_exp fixed integer integer_len fraction parsed fmt LC_ALL=C
  case "${_COST_KIND:-invalid}" in
    missing)
      [ "$VL_COST_ALWAYS_SHOW" = 1 ] && [ "${_JSON_OK:-0}" = 1 ] || return 0
      raw=0
      ;;
    scalar) ;;
    (*) return 0 ;;
  esac

  if [ "${_COST_KIND:-invalid}" = scalar ]; then
    [ "${#raw}" -le 128 ] || return 0
    [[ "$raw" =~ ^\ *[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?\ *$ ]] || return 0
    trimmed="${raw#"${raw%%[! ]*}"}"
    trimmed="${trimmed%"${trimmed##*[! ]}"}"
    raw="$trimmed"
    significand="${trimmed%%[eE]*}"
    case "$significand" in (*[1-9]*) lexical_nonzero=1 ;; (*) lexical_nonzero=0 ;; esac
    case "$trimmed" in (-*) [ "$lexical_nonzero" = 1 ] && return 0 ;; esac
    case "$trimmed" in *[eE]*) exp_text="${trimmed##*[eE]}" ;; *) exp_text=0 ;; esac
    case "$exp_text" in
      (-*) exp_sign=-1; exp_text="${exp_text:1}" ;;
      (+*) exp_sign=1; exp_text="${exp_text:1}" ;;
      (*) exp_sign=1 ;;
    esac
    exp_text="${exp_text#"${exp_text%%[!0]*}"}"
    [ -n "$exp_text" ] || exp_text=0
    [ "${#exp_text}" -le 3 ] || return 0
    [ "$exp_text" -le 308 ] 2>/dev/null || return 0
    exp_value=$exp_text
    [ "$exp_sign" = -1 ] && exp_value=$(( -exp_value ))
    if [ "$lexical_nonzero" = 1 ]; then
      unsigned="${significand#[-+]}"
      case "$unsigned" in (*.*) integer_part="${unsigned%%.*}" ;; (*) integer_part="$unsigned" ;; esac
      digits="${unsigned/./}"
      leading_zeroes="${digits%%[1-9]*}"
      adjusted_exp=$(( exp_value + ${#integer_part} - ${#leading_zeroes} - 1 ))
      [ "$adjusted_exp" -ge -323 ] || return 0
      [ "$adjusted_exp" -le 9 ] || return 0
      if [ "$adjusted_exp" = 9 ]; then
        significant="${digits:${#leading_zeroes}}"
        [[ "$significant" =~ ^10*$ ]] || return 0
      fi
    fi
    parsed=""
    LC_ALL=C printf -v parsed '%.17g' "$raw" 2>/dev/null || :
    case "$parsed" in (*inf*|*nan*|'') return 0 ;; esac
    case "$parsed" in (-0) raw=0; parsed=0 ;; (-*) return 0 ;; esac
    [ "$parsed" = 0 ] && [ "$lexical_nonzero" = 1 ] && return 0
    fixed=""
    LC_ALL=C printf -v fixed '%.17f' "$raw" 2>/dev/null || :
    case "$fixed" in (*inf*|*nan*|'') return 0 ;; esac
    integer="${fixed%%.*}"
    integer="${integer#"${integer%%[!0]*}"}"
    [ -n "$integer" ] || integer=0
    integer_len=${#integer}
    [ "$integer_len" -le 10 ] || return 0
    [ "$integer_len" -ne 10 ] || { [ "$integer" \> 1000000000 ] && return 0; }
    if [ "$integer" = 1000000000 ]; then
      fraction="${fixed#*.}"
      case "$fraction" in *[1-9]*) return 0 ;; esac
    fi
    [ "$parsed" = 0 ] && { [ "$VL_COST_ALWAYS_SHOW" = 1 ] && [ "${_JSON_OK:-0}" = 1 ] || return 0; raw=0; }
  fi

  fmt=""
  LC_ALL=C printf -v fmt "\$%.${VL_COST_DECIMALS}f" "$raw" 2>/dev/null || :
  [ -n "$fmt" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_COST" "${_FG} ${fmt} "
}

seg_clock() {  # time, 12h or 24h
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

seg_lines() {  # lines added/removed this session
  [ "${lines_add:-0}" -gt 0 ] 2>/dev/null || [ "${lines_del:-0}" -gt 0 ] 2>/dev/null || return 0
  local fgo fgh
  fg "$VL_FG_OK";  fgo="$_FG"
  fg "$VL_FG_HOT"; fgh="$_FG"
  push "$VL_BG_LINES" " ${fgo}+${lines_add} ${fgh}-${lines_del} "
}

seg_style() {  # active output style
  [ -n "$out_style" ] && [ "$out_style" != "default" ] || return 0
  fg "$VL_FG_TEXT"
  push "$VL_BG_STYLE" "${_FG} ✎ ${out_style} "
}

seg_duration() {  # session wall-clock duration
  [ "${dur_ms:-0}" -gt 0 ] 2>/dev/null || return 0
  fmt_duration "$dur_ms"
  fg "$VL_FG_TEXT"
  push "$VL_BG_DURATION" "${_FG} ⧖ ${_DUR} "
}

seg_effort() {  # reasoning effort level (low/medium/high/xhigh/max); glyph ψ is editable
  [ -n "$effort" ] || return 0
  local label="$effort"
  case "$effort" in (medium) label="med" ;; esac
  fg "$VL_FG_TEXT"
  push "$VL_BG_EFFORT" "${_FG} ψ ${label} "
}

seg_stash() {  # git stash count
  [ -n "$GIT_BRANCH" ] || return 0
  local n
  n=$(git -C "$cwd" rev-list --walk-reflogs --count refs/stash 2>/dev/null) || return 0
  [ "${n:-0}" -gt 0 ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_STASH:-$VL_BG_GIT_OK}" "${_FG} ⚑ ${n} "
}

# ── Runtime detection (node / python segments) ───────────────────────────────
# Each sets the global _RT to a label for directory $1 (empty when nothing is
# detected), so the seg_* callers read a global instead of a $() subshell — the
# fork-free convention used by fg/_FG, trunc/_TR, seg_len/SEG_LEN_R.
#
# The pin-file path (.nvmrc / .python-version, walking up ancestors) is always
# tried first and never forks. The interpreter probe DOES fork, so it is gated
# behind VL_RUNTIME_PROBE, off by default (set it to 1 to detect e.g. nvm's
# active version in a repo with no pin file).
#
# Notes: `read` returns non-zero at EOF on a newline-less pin file, but $v IS
# set — so pre-clear and ignore read's status rather than `|| v=""`, which would
# discard the value. `[ -f ]` (not `[ -r ]`) so a directory named .nvmrc does
# not match and make `read` emit "Is a directory". The walk uses `case */*` to
# step up, since ${dir%/*} is a no-op once no slash is left and would otherwise
# spin forever on a relative/slash-less argument.
runtime_node() {  # -> _RT: active Node version label for directory $1
  local dir="$1" f v
  _RT=""
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    for f in .nvmrc .node-version; do
      if [ -f "$dir/$f" ]; then
        v=""; IFS= read -r v < "$dir/$f"
        v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
        [ -n "$v" ] && { _RT="${v#v}"; return 0; }   # normalize v20.x -> 20.x
      fi
    done
    case "$dir" in */*) dir="${dir%/*}" ;; *) break ;; esac
  done
  if [ "${VL_RUNTIME_PROBE:-0}" = "1" ] && command -v node >/dev/null 2>&1; then
    v=$(node --version 2>/dev/null) && [ -n "$v" ] && _RT="${v#v}"
  fi
}

runtime_python() {  # -> _RT: active Python env/version label for directory $1
  local dir="$1" v
  _RT=""
  [ -n "${VIRTUAL_ENV:-}" ] && { _RT="${VIRTUAL_ENV##*/}"; return 0; }
  # conda auto-activates `base` for most users, so it is not a meaningful "env".
  [ -n "${CONDA_DEFAULT_ENV:-}" ] && [ "$CONDA_DEFAULT_ENV" != base ] \
    && { _RT="$CONDA_DEFAULT_ENV"; return 0; }
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    if [ -f "$dir/.python-version" ]; then
      v=""; IFS= read -r v < "$dir/.python-version"
      v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
      [ -n "$v" ] && { _RT="$v"; return 0; }
    fi
    case "$dir" in */*) dir="${dir%/*}" ;; *) break ;; esac
  done
  if [ "${VL_RUNTIME_PROBE:-0}" = "1" ] && command -v python3 >/dev/null 2>&1; then
    v=$(python3 --version 2>&1); v="${v#Python }"   # some builds print to stderr
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ -n "$v" ] && _RT="$v"
  fi
}

seg_node() {  # active Node version (.nvmrc/.node-version/nvm); silent when none
  [ -n "$cwd" ] || return 0
  runtime_node "$cwd"; [ -n "$_RT" ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_NODE:-$VL_BG_MODEL}" "${_FG} ${VL_NODE_GLYPH} ${_RT} "
}

seg_python() {  # active Python env (venv/conda/pyenv); silent when none detected
  [ -n "$cwd" ] || return 0
  runtime_python "$cwd"; [ -n "$_RT" ] || return 0
  fg "$VL_FG_TEXT"
  push "${VL_BG_PYTHON:-$VL_BG_MODEL}" "${_FG} ${VL_PY_GLYPH} ${_RT} "
}

# ── Subagent panel row segments (--subagent mode) ────────────────────────────
# Same push() convention as seg_*; input is one task's t_* globals set by the
# --subagent loop below the render helpers. Per-field degradation: a missing
# field hides its segment (ctx shrinks to a bare count); the row always renders.

sub_epoch() {  # → _EP ; strict startTime parser for the per-task loop.
  # Accepts only shapes it can resolve fork-free: pure-digit epoch seconds,
  # pure-digit epoch milliseconds (13+ digits), and canonical valid UTC ISO.
  # Anything else hides elapsed instead of reaching to_epoch's date fallback.
  local t="$1"
  case "$t" in
    ('') return 1 ;;
    (*[!0-9]*) iso_epoch "$t" ;;
    (*)
      if [ "${#t}" -ge 13 ]; then _EP=$(( 10#$t / 1000 ))
      else _EP=$(( 10#$t )); fi
      return 0 ;;
  esac
}

subagent_role() {  # → _SUB_ROLE ; $1=transcript path $2=task id
  local transcript="$1" id="$2" path line role
  _SUB_ROLE=""
  case "$id" in (''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;; esac
  case "$transcript" in (*.jsonl) path="${transcript%.jsonl}/subagents/agent-${id}.meta.json" ;; (*) return 1 ;; esac
  path="${path//\\//}"  # native Windows payload paths use backslashes; Git Bash accepts C:/...
  [ -r "$path" ] || return 1
  IFS= read -r line < "$path" || [ -n "$line" ] || return 1
  case "$line" in
    (*'"agentType":"'*) role="${line#*\"agentType\":\"}" ; role="${role%%\"*}" ;;
    (*) return 1 ;;
  esac
  case "$role" in (''|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-]*) return 1 ;; esac
  _SUB_ROLE="$role"
}

subseg_name() {  # identity + task label; each falls back independently
  local identity="${t_name:-${t_role:-}}" detail="${t_label:-${t_desc:-}}" label col
  if [ -n "${t_name:-}" ] && [ -n "${t_role:-}" ] && [ "$t_name" != "$t_role" ]; then
    identity="$t_name ($t_role)"
  fi
  if [ -n "$identity" ]; then
    label="$identity"
    [ -n "$detail" ] && [ "$detail" != "${t_name:-}" ] && [ "$detail" != "${t_role:-}" ] && label="$label · $detail"
  else
    label="${detail:-$t_type}"
  fi
  [ -n "$label" ] || return 0
  case "$t_status" in
    (running|in_progress|active) col="${VL_FG_SUB_TEXT:-$VL_FG_TEXT}" ;;
    (completed|success|done)     col="${VL_FG_SUB_OK:-$VL_FG_OK}"     ;;
    (failed|error|cancelled)     col="${VL_FG_SUB_HOT:-$VL_FG_HOT}"   ;;
    (*)                          col="${VL_FG_SUB_DIM:-$VL_FG_DIM}"   ;;  # incl. missing → unknown
  esac
  fg "$col"; trunc "$label" "$VL_NAME_MAX"
  push "${VL_BG_SUB_NAME:-$VL_BG_DIR}" "${BOLD}${_FG} ${_TR} ${NORM}"
}

subseg_model() {  # per-task resolved model, short-named; hidden when unresolved
  [ -n "$t_model" ] || return 0
  model_short "$t_model"
  fg "$VL_FG_TEXT"
  push "${VL_BG_SUB_MODEL:-$VL_BG_MODEL}" "${BOLD}${_FG} ◆ ${_MS} ${NORM}"
}

subseg_ctx() {  # per-task context gauge; bare token count without a window size
  local tokint="${t_tok%%.*}" cws="$t_cws" ci fgc fgd
  case "$tokint" in (''|*[!0-9]*) return 0 ;; esac
  # ponytail: 16 digits keeps *100 inside signed 64-bit Bash arithmetic; use
  # non-overflow ratio math before widening this display-only ceiling.
  [ "${#tokint}" -le 16 ] || return 0
  tokint=$(( 10#$tokint ))
  fmt_tok "$tokint"
  case "$cws" in (''|*[!0-9]*) cws=0 ;; esac
  if [ "${#cws}" -le 16 ]; then cws=$(( 10#$cws )); else cws=0; fi
  if [ "$cws" -gt 0 ]; then
    ci=$(( (tokint * 100) / cws )); [ "$ci" -gt 100 ] && ci=100
    make_bar "$ci"; pct_fg "$ci"
    fg "$_PFG";      fgc="$_FG"
    fg "$VL_FG_DIM"; fgd="$_FG"
    push "${VL_BG_SUB_CTX:-$VL_BG_CTX}" "${fgc} ${VL_CTX_GLYPH} ${_BAR} ${ci}% ${fgd}${_TOK} "
  else
    fg "$VL_FG_DIM"
    push "${VL_BG_SUB_CTX:-$VL_BG_CTX}" "${_FG} ${VL_CTX_GLYPH} ${_TOK} "
  fi
}

subseg_elapsed() {  # wall-clock since startTime; hidden when unparseable
  [ -n "$t_start" ] || return 0
  sub_epoch "$t_start" || return 0
  local diff=$(( NOW - _EP ))
  [ "$diff" -ge 0 ] || return 0
  fmt_duration $(( diff * 1000 )) 1
  fg "$VL_FG_TEXT"
  push "${VL_BG_SUB_ELAPSED:-$VL_BG_DURATION}" "${_FG} ⧖ ${_DUR} "
}

# ── Render ───────────────────────────────────────────────────────────────────
build_segments() {
  local s
  SEG_BGS=() ; SEG_TXT=() ; SEG_LEN=()
  for s in $1; do
    command -v "seg_$s" >/dev/null 2>&1 && "seg_$s"
  done
}

render_range() {  # → _ROW ; assemble segments $1..$2 (inclusive) as one row
  local i out lbg=""
  if [ "$VL_STYLE" = "lean" ]; then
    # VL_LEAN_BG paints one uniform background behind the row; re-assert it after
    # every reset so the bar stays continuous across separators (p10k "classic").
    [ -n "${VL_LEAN_BG:-}" ] && { bg "$VL_LEAN_BG"; lbg="$_BG"; }
    out=""
    # VL_LEAN_CAP_L bevels the bar's start into the terminal — the mirror of
    # VL_LEAN_CAP_R — drawn in the bar colour on the default background.
    if [ -n "$lbg" ] && [ -n "${VL_LEAN_CAP_L:-}" ]; then
      fg "$VL_LEAN_BG"; out="${R}${_FG}${VL_LEAN_CAP_L}"
    fi
    for ((i=$1; i<=$2; i++)); do
      fg "${SEG_BGS[$i]}"
      out+="${R}${lbg}${_FG}${SEG_TXT[$i]}"
      [ "$i" -lt "$2" ] && out+="${R}${lbg}${VL_LEAN_SEP}"
    done
    # VL_LEAN_CAP_R bevels the bar's end into the terminal (p10k's trailing segment
    # separator): the cap glyph is drawn in the bar colour on the default background.
    if [ -n "$lbg" ] && [ -n "${VL_LEAN_CAP_R:-}" ]; then
      fg "$VL_LEAN_BG"; out+="${R}${_FG}${VL_LEAN_CAP_R}"
    fi
    _ROW="${out}${R}"
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
  _ROW="$out"
}

print_range() {  # render segments $1..$2 (inclusive) as one row
  render_range "$1" "$2"
  printf '%s\n' "$_ROW"
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

# ── Subagent panel mode ──────────────────────────────────────────────────────
# stdin: {columns, tasks:[…]} (Claude Code subagentStatusLine, v2.1.205+ for
# model/contextWindowSize). stdout: one {"id","content"} line per row. Reuses
# the theme and render_range, so panel rows match the main bar. jq failure or
# an empty tasks list prints nothing → Claude Code keeps its default rows.
# Placement matters: this branch exits before every main-bar-only side effect
# below (git probe, burn/limit sampling, float readout — and the main JSON
# parse), so none of them needs a mode guard.
if [ "$SUBAGENT_MODE" = "1" ]; then
  # Panel rows are single independent rows: SEG_LEN[] (auto-layout wrap input)
  # is never read, so force non-auto layout — push() then skips its
  # per-character width scan for every panel segment.
  VL_LAYOUT=fixed
  # scrub drops C0, DEL, and C1 control characters from every extracted field
  # BEFORE the stream below is framed with newlines and unit separators.
  # That one pass is both the security scrub — a crafted label could otherwise
  # smuggle terminal escapes (ESC[2J confirmed live) into the rendered row —
  # and the framing guard: a literal newline or 0x1f inside a field would
  # otherwise split it into extra lines/fields, letting a task forge a whole
  # {"id",...} row or shift every field after it. json_escape below therefore
  # only ever sees coralline's own ANSI codes.
  #
  # Claude Code can deliver several concatenated {columns,tasks} documents in
  # one read (no newlines between them; captured live). Each is a full panel
  # snapshot, so only the newest is current: slurp the stream (-s) and render
  # just the last document — otherwise stale rows (and duplicate ids) would
  # precede the fresh ones.
  SUB_LINES=$(printf '%s' "$input" | jq -rs '
    def scrub: tostring | gsub("[\\x00-\\x1f\\x7f\u0080-\u009f]"; "");
    (last // {}) as $d |
    ($d.tasks[]? | [
      "task",
      ($d.transcript_path // ""),
      (.id // ""),
      (.name // ""),
      (.label // ""),
      (.description // ""),
      (.type // ""),
      (.status // ""),
      (.startTime // ""),
      (.model // ""),
      (.contextWindowSize // ""),
      (.tokenCount // "")
    ] | map(scrub) | join("\u001f"))' 2>/dev/null)
  while IFS=$'\037' read -r sub_kind t_transcript t_id t_name t_label t_desc t_type t_status t_start t_model t_cws t_tok; do
    [ "$sub_kind" = "task" ] || continue
    t_tok="${t_tok%$'\r'}"  # native Windows jq writes CRLF; input CR was scrubbed above
    [ -n "$t_id" ] || continue
    t_role=""
    [ "$t_type" = "local_agent" ] && subagent_role "$t_transcript" "$t_id" && t_role="$_SUB_ROLE"
    SEG_BGS=() ; SEG_TXT=() ; SEG_LEN=()
    for s in $VL_SUB_SEGMENTS; do
      command -v "subseg_$s" >/dev/null 2>&1 && "subseg_$s"
    done
    [ "${#SEG_BGS[@]}" -gt 0 ] || continue
    render_range 0 $(( ${#SEG_BGS[@]} - 1 ))
    json_escape "$_ROW" ; sub_row="$_JS"
    json_escape "$t_id"
    printf '{"id":"%s","content":"%s"}\n' "$_JS" "$sub_row"
  done <<SUB
$SUB_LINES
SUB
  exit 0
fi

# ── Parse JSON (single jq call) ──────────────────────────────────────────────
# Fields are joined with \x1f (unit separator): unlike tab, a non-whitespace
# IFS preserves empty fields instead of collapsing consecutive delimiters.
_JSON_OK=0; _CTX_EMPTY=0; _COST_KIND=invalid; _JSON_FIELDS=""
if _JSON_FIELDS=$(printf '%s' "$input" | jq -r '
  def scrub: tostring | gsub("[\\x00-\\x1f\\x7f\u0080-\u009f]"; "");
  def member($obj; $name):
    if ($obj|type) == "object" and ($obj|has($name)) then $obj[$name] else null end;
  def ctx_value:
    member(member(.; "context_window"); "used_percentage") as $value |
    if ($value|type) == "number" or ($value|type) == "string" then $value else null end;
  def ctx_empty:
    (member(.; "context_window")) as $ctx |
    if $ctx == null then true
    elif ($ctx|type) != "object" then false
    elif (($ctx|has("used_percentage")) == false) then true
    else (($ctx.used_percentage == null) or (($ctx.used_percentage|type) == "string" and $ctx.used_percentage == "")) end;
  def cost_value:
    member(member(.; "cost"); "total_cost_usd");
  if type != "object" then error("non-object root") else
  [
    (member(member(.; "workspace"); "current_dir") // member(.; "cwd") // ""),
    (member(member(.; "model"); "display_name") // ""),
    (ctx_value | if (. == null) or (. == false) then "" else tostring end),
    (ctx_empty | if . then "1" else "0" end),
    (member(member(.; "context_window"); "total_input_tokens") // 0),
    (member(member(.; "context_window"); "total_output_tokens") // 0),
    (member(member(member(.; "context_window"); "current_usage"); "cache_read_input_tokens") // 0),
    (member(member(member(.; "context_window"); "current_usage"); "cache_creation_input_tokens") // 0),
    (member(member(member(.; "rate_limits"); "five_hour"); "used_percentage") // "" | tostring),
    (member(member(member(.; "rate_limits"); "five_hour"); "resets_at") // "" | tostring),
    (member(member(member(.; "rate_limits"); "seven_day"); "used_percentage") // "" | tostring),
    (member(member(member(.; "rate_limits"); "seven_day"); "resets_at") // "" | tostring),
    (cost_value | if (. == null) or (. == false) then "" else tostring end),
    ((member(.; "cost")) as $cost |
      if $cost == null then "missing"
      elif ($cost|type) != "object" then "invalid"
      elif (($cost|has("total_cost_usd")) == false) then "missing"
      else (member($cost; "total_cost_usd")) as $v |
        if ($v == null) or (($v|type) == "string" and $v == "") then "missing"
        elif (($v|type) == "string" and (($v|scrub) != $v)) then "invalid"
        elif (($v|type) == "string") or (($v|type) == "number") then "scalar"
        else "invalid" end
      end),
    (member(member(.; "cost"); "total_lines_added") // 0),
    (member(member(.; "cost"); "total_lines_removed") // 0),
    (member(member(.; "output_style"); "name") // ""),
    (member(member(.; "cost"); "total_duration_ms") // 0),
    (member(member(.; "effort"); "level") // "")
  ] | map(scrub) | join("\u001f")
  end' 2>/dev/null); then
  _JSON_OK=1
fi
IFS=$'\037' read -r cwd model ctx_pct _CTX_EMPTY tok_in tok_out tok_cr tok_cw \
                 fh_pct fh_rst wd_pct wd_rst cost _COST_KIND \
                 lines_add lines_del out_style dur_ms effort <<JSON
$_JSON_FIELDS
JSON

_SEG_SCAN=" $VL_SEGMENTS $VL_SEGMENTS2 $VL_SEGMENTS3 "
[ "$VL_FLOAT" = "1" ] && _SEG_SCAN="$_SEG_SCAN$VL_FLOAT_SEGMENTS "
case "$_SEG_SCAN" in *" git "*|*" stash "*|*" project "*) read_git ;; esac

# The disabled/default path performs no state work. Enabled paths canonicalize
# values and namespaces once, then use the released TSV/compact-directory flow.
# CORALLINE_NO_SAMPLE keeps every read but forbids all state mutation.
_STATE_READY=0; _STATE_BURN_GATE=0; _STATE_RL5_GATE=0; _STATE_RL7_GATE=0
case "$_SEG_SCAN" in (*" burn "*) _STATE_BURN_GATE=1 ;; esac
if [ "$VL_LIMIT_SYNC" = 1 ]; then
  # burn takes both gates, not just 7d. It can bind to either window, its projection
  # is rebound to the synced 5h state in burn_estimate, and its own source gate
  # accepts that state, so a layout with burn but no limit5h would otherwise leave
  # _STATE_RL5_VALID permanently 0 and hide the segment for a session that has no
  # payload reading but does have a usable stored window.
  case "$_SEG_SCAN" in (*" limit5h "*|*" burn "*) _STATE_RL5_GATE=1 ;; esac
  case "$_SEG_SCAN" in (*" limit7d "*|*" burn "*) _STATE_RL7_GATE=1 ;; esac
fi
if [ "$_STATE_BURN_GATE" = 1 ] || [ "$_STATE_RL5_GATE" = 1 ] || [ "$_STATE_RL7_GATE" = 1 ]; then
  state_gate
  if [ "$_STATE_MUTATE" = 1 ]; then
    [ "$_STATE_BURN_GATE" != 1 ] || burn_sample "$_CUR_BURN_SAMP" "$_CUR_BURN_TSV" "$_CUR_BURN_RST"
    [ "$_STATE_RL5_GATE" != 1 ] || rl_sample "${_SL5_BASE:-}" "$_CUR5_PCT" "$_CUR5_RST"
    [ "$_STATE_RL7_GATE" != 1 ] || rl_sample "${_SL7_BASE:-}" "$_CUR7_PCT" "$_CUR7_RST"
  fi
  if [ "$VL_LIMIT_SYNC" = 1 ]; then
    if [ "$_STATE_RL5_GATE" = 1 ]; then rl_latest "${_SL5_BASE:-}" "$RL_MAX_5H" "$_STATE_MUTATE"; rl_choose 5; fi
    if [ "$_STATE_RL7_GATE" = 1 ]; then rl_latest "${_SL7_BASE:-}" "$RL_MAX_7D" "$_STATE_MUTATE"; rl_choose 7; fi
  fi
  case "$_SEG_SCAN" in (*" burn "*) burn_estimate ;; esac
fi

# Defensive ANSI stripper (the VL_NOCOLOR path should already emit none) → _PLAIN.
strip_ansi() {
  local s="$1" out=""
  while [ "${s#*$ESC}" != "$s" ]; do
    out+="${s%%$ESC*}" ; s="${s#*$ESC}" ; s="${s#*m}"
  done
  _PLAIN="$out$s"
}

# Build VL_FLOAT_SEGMENTS with color emission neutralized and write a single
# plain-text line atomically to VL_FLOAT_FILE. Saves/restores the color globals
# so the normal render that follows is unaffected.
emit_float() {
  local _nc="$VL_NOCOLOR" _b="$BOLD" _n="$NORM" _r="$R"
  local dir line i s tmp
  VL_NOCOLOR=1 ; BOLD="" ; NORM="" ; R=""
  build_segments "$VL_FLOAT_SEGMENTS"
  line=""
  for ((i=0; i<${#SEG_TXT[@]}; i++)); do
    strip_ansi "${SEG_TXT[$i]}" ; s="$_PLAIN"
    s="${s#"${s%%[![:space:]]*}"}" ; s="${s%"${s##*[![:space:]]}"}"   # trim
    [ -n "$s" ] || continue
    line="${line:+$line$VL_FLOAT_SEP}$s"
  done
  VL_NOCOLOR="$_nc" ; BOLD="$_b" ; NORM="$_n" ; R="$_r"
  dir=$(dirname "$VL_FLOAT_FILE")
  mkdir -p "$dir"
  tmp="$dir/.float.tmp.$$"
  printf '%s\n' "$line" > "$tmp" && mv -f "$tmp" "$VL_FLOAT_FILE" || rm -f "$tmp"
}

[ "$VL_FLOAT" = "1" ] && emit_float

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
  if [ "$VL_STYLE" = "lean" ]; then CAP_W=$(( ${#VL_LEAN_CAP_L} + ${#VL_LEAN_CAP_R} )) ; SEP_W=${#VL_LEAN_SEP}
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
