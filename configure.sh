#!/usr/bin/env bash
# coralline visual configuration wizard.
#
# Usage:
#   bash configure.sh
#   bash configure.sh --install

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TARGET_DIR="${CORALLINE_HOME:-$HOME/.claude/coralline}"
CONFIG_FILE="${CORALLINE_CONFIG:-$HOME/.claude/coralline.conf}"
SETTINGS_FILE="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
P10K_FILE="${P10K_CONFIG:-$HOME/.p10k.zsh}"

# Fallback list, used only when the runtime statusline cannot be scanned.
# The live list is derived from statusline.sh's seg_* functions by load_segment_choices.
SEGMENT_CHOICES="dir project git model effort ctx limit5h limit7d burn lines cost style duration stash clock"
DEFAULT_SEGMENTS="dir git model ctx limit5h limit7d cost clock"
THEME_CHOICES=""
theme_choices_loaded=0

theme="claude-coral"
style="pill"
layout="auto"
max_lines=3
segments="$DEFAULT_SEGMENTS"
segments2=""
segments3=""
clock_mode="12h"
clock_seconds=1
ascii_mode=0
name_max=0
lean_sep=""
float_enabled=0
float_segments="model ctx cost"
extra_config=""
installed=0
install_only=0
setup_mode=""
screen_active=0
old_stty=""
resized=0          # set by the SIGWINCH trap; consumed by read_key
KEY=""             # read_key writes the decoded key here (avoids a $() subshell)
last_size=""       # last seen "rows cols"; read_key's 1s poll redraws on a change
preview_input_file=""
preview_cache_dir=""

T_RESET=$(printf '\033[0m')
T_BOLD=$(printf '\033[1m')
T_DIM=$(printf '\033[2m')
T_BLUE=$(printf '\033[38;5;81m')
T_GREEN=$(printf '\033[38;5;114m')
T_RED=$(printf '\033[38;5;167m')
T_MAUVE=$(printf '\033[38;5;183m')
T_CORAL=$(printf '\033[38;5;173m')
T_WARN=$(printf '\033[38;5;179m')

usage() {
  cat <<'EOF'
coralline configure

Options:
  --install    Copy coralline into ~/.claude/coralline, update Claude settings,
               then run the visual wizard.
  --install-only
               Copy coralline into ~/.claude/coralline and update Claude settings,
               then exit without writing theme config.
  --default    Use the coralline default config without opening the setup menu.
  --import-p10k
               Import ~/.p10k.zsh without opening the setup menu.
  --wizard     Open the visual wizard directly.
  --help       Show this help.
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_file() {
  [ -f "$1" ] || die "missing required file: $1"
}

runtime_statusline() {
  if [ "$installed" = "1" ] && [ -f "$TARGET_DIR/statusline.sh" ]; then
    printf '%s\n' "$TARGET_DIR/statusline.sh"
  elif [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    printf '%s\n' "$SCRIPT_DIR/statusline.sh"
  else
    printf '%s\n' "$TARGET_DIR/statusline.sh"
  fi
}

runtime_theme_dir() {
  if [ "$installed" = "1" ] && [ -d "$TARGET_DIR/themes" ]; then
    printf '%s\n' "$TARGET_DIR/themes"
  elif [ -d "$SCRIPT_DIR/themes" ]; then
    printf '%s\n' "$SCRIPT_DIR/themes"
  else
    printf '%s\n' "$TARGET_DIR/themes"
  fi
}

theme_list() {
  local dir
  if [ "$theme_choices_loaded" = "1" ]; then
    printf '%s' "$THEME_CHOICES"
    return 0
  fi
  dir=$(runtime_theme_dir)
  [ -d "$dir" ] || return 0
  (cd "$dir" && find . -type f -name '*.conf' | sed 's#^\./##; s#\.conf$##' | sort)
}

load_theme_choices() {
  local dir
  dir=$(runtime_theme_dir)
  [ -d "$dir" ] || return 0
  THEME_CHOICES=$(cd "$dir" && find . -type f -name '*.conf' | sed 's#^\./##; s#\.conf$##' | sort; printf x)
  THEME_CHOICES=${THEME_CHOICES%x}
  theme_choices_loaded=1
}

theme_count() {
  theme_list | wc -l | tr -d ' '
}

# Derive the segment menu from the runtime's seg_* functions so a new segment in
# statusline.sh shows up here automatically — mirrors the theme auto-scan above.
load_segment_choices() {
  local statusline discovered s ordered=""
  statusline=$(runtime_statusline)
  [ -f "$statusline" ] || return 0
  discovered=" $(grep -oE '^seg_[A-Za-z0-9_]+' "$statusline" \
    | sed 's/^seg_//' | grep -Ev '^(len|limit)$' | tr '\n' ' ') "
  [ "$discovered" = "  " ] && return 0
  # Show segments in the canonical SEGMENT_CHOICES order (keeping only the ones
  # that still exist), then append any newly added segments not listed there, so
  # a new seg_* in statusline.sh still shows up automatically.
  for s in $SEGMENT_CHOICES; do
    case "$discovered" in *" $s "*) ordered="${ordered}${ordered:+ }$s"; discovered="${discovered/ $s / }" ;; esac
  done
  for s in $discovered; do ordered="${ordered}${ordered:+ }$s"; done
  SEGMENT_CHOICES="$ordered"
}

# Space-separated, sorted-unique segment names in a statusline file. Mirrors
# load_segment_choices' discovery so detection and the wizard agree on "segment".
segment_names() {  # $1=statusline file
  grep -oE '^seg_[A-Za-z0-9_]+' "$1" 2>/dev/null \
    | sed 's/^seg_//' | grep -Ev '^(len|limit)$' | sort -u | tr '\n' ' '
}

# Space-separated, sorted-unique opt-in knob names: VL_/CORALLINE_ assignments
# whose shipped default is exactly 0 and whose line is not tagged "internal".
# This excludes color knobs (non-0 defaults like "r,g,b") and internal vars,
# which would otherwise flood the upgrade report. A numeric 0-default knob can
# slip through, but such knobs pre-exist and so never appear as "new".
knob_names() {  # $1=statusline file
  grep -E '^(VL_|CORALLINE_)[A-Za-z0-9_]+=0([[:space:]]|$)' "$1" 2>/dev/null \
    | grep -iv 'internal' \
    | sed -E 's/=0.*$//' | sort -u | tr '\n' ' '
}

# Inline comment after `seg_<name>() {`, else empty.
segment_desc() {  # $1=statusline file $2=segment name
  local line
  line=$(grep -E "^seg_$2\(\) \{" "$1" 2>/dev/null | head -1)
  case "$line" in
    *\#*) printf '%s\n' "${line#*\#}" | sed 's/^[[:space:]]*//' ;;
  esac
}

# Trailing inline comment on the knob's declaration line; else the FIRST SENTENCE
# of the contiguous # comment block immediately above it; else empty.
knob_desc() {  # $1=statusline file $2=knob name
  local file="$1" name="$2" ln line i first=""
  ln=$(grep -nE "^$name=" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$ln" ] || return 0
  line=$(sed -n "${ln}p" "$file")
  case "$line" in
    *\#*) printf '%s\n' "${line#*\#}" | sed 's/^[[:space:]]*//'; return 0 ;;
  esac
  i=$((ln - 1))
  while [ "$i" -ge 1 ]; do
    line=$(sed -n "${i}p" "$file")
    case "$line" in
      \#*|[[:space:]]*\#*) first="$line"; i=$((i - 1)) ;;
      *) break ;;
    esac
  done
  [ -n "$first" ] || return 0
  first=$(printf '%s\n' "$first" | sed 's/^[[:space:]]*#[[:space:]]*//')
  # Keep just the first sentence so a multi-line block yields a clean summary
  # instead of a mid-sentence clause.
  printf '%s\n' "${first%%. *}"
}

# Print a "new since your installed copy" report when the new statusline adds
# segments or opt-in knobs the old one lacked. Silent on fresh install or no
# delta. Reports only — never writes config. Emits color only on a tty so the
# piped/agent path gets clean, parseable text.
report_upgrade_delta() {  # $1=old statusline $2=new statusline $3=backup path (may be empty)
  local old="$1" new="$2" bak="${3:-}"
  [ -f "$old" ] && [ -f "$new" ] || return 0
  local cb="" cr="" cc="" cd=""
  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    cb="${T_BOLD:-}"; cr="${T_RESET:-}"; cc="${T_CORAL:-}"; cd="${T_DIM:-}"
  fi
  local IFS=' '
  local old_segs new_segs old_knobs new_knobs s k d seglist="" knoblist=""
  old_segs=" $(segment_names "$old") " ; new_segs=" $(segment_names "$new") "
  for s in $new_segs; do
    case "$old_segs" in *" $s "*) : ;; *) seglist="${seglist}${seglist:+ }$s" ;; esac
  done
  old_knobs=" $(knob_names "$old") " ; new_knobs=" $(knob_names "$new") "
  for k in $new_knobs; do
    case "$old_knobs" in *" $k "*) : ;; *) knoblist="${knoblist}${knoblist:+ }$k" ;; esac
  done
  [ -n "$seglist" ] || [ -n "$knoblist" ] || return 0
  printf '\n%scoralline upgrade — new since your installed copy:%s\n' "$cb" "$cr"
  for s in $seglist; do
    d=$(segment_desc "$new" "$s")
    printf '  segment  %s%-16s%s %s\n' "$cc" "$s" "$cr" "$d"
  done
  for k in $knoblist; do
    d=$(knob_desc "$new" "$k")
    printf '  option   %s%-16s%s %s\n' "$cc" "${k}=1" "$cr" "$d"
  done
  printf '%s~/.claude/coralline.conf preserved%s' "$cd" "$cr"
  [ -n "$bak" ] && printf '%s · backup at %s%s' "$cd" "$bak" "$cr"
  printf '\n%senable: rerun configure.sh, or let Claude wire them in (see UPGRADE.md)%s\n' "$cd" "$cr"
}

# Back up an install dir's statusline.sh to statusline.sh.bak.<ts> (mirrors the
# settings.json.bak.<ts> convention), keep only the 3 newest, and echo the new
# backup path. Echo nothing on failure or when statusline.sh is absent (fail
# open). A single-file copy, so a symlinked install dir is harmless.
backup_statusline() {  # $1=install dir
  # Keep the N newest timestamped backups; prune older ones. A rollback safety
  # net, not history — a few recent copies cover slip-ups without piling up.
  local dir="$1" src="$1/statusline.sh" bak old keep_backups=3
  [ -f "$src" ] || return 0
  bak="${src}.bak.$(date +%Y%m%d-%H%M%S)"
  [ -e "$bak" ] && bak="${bak}.$$"
  cp "$src" "$bak" 2>/dev/null || return 0
  printf '%s\n' "$bak"
  ls -1t "${src}".bak.* 2>/dev/null | tail -n +$((keep_backups + 1)) | while IFS= read -r old; do
    rm -f "$old" 2>/dev/null
  done
}

segment_total() {
  set -- $SEGMENT_CHOICES
  printf '%s\n' "$#"
}

runtime_sample() {
  if [ "$installed" = "1" ] && [ -f "$TARGET_DIR/sample-input.json" ]; then
    printf '%s\n' "$TARGET_DIR/sample-input.json"
  elif [ -f "$SCRIPT_DIR/test/sample-input.json" ]; then
    printf '%s\n' "$SCRIPT_DIR/test/sample-input.json"
  elif [ -f "$TARGET_DIR/sample-input.json" ]; then
    printf '%s\n' "$TARGET_DIR/sample-input.json"
  else
    printf '%s\n' ""
  fi
}

prepare_preview_input() {
  local sample input
  if [ -n "$preview_input_file" ] && [ -f "$preview_input_file" ]; then
    printf '%s\n' "$preview_input_file"
    return 0
  fi
  sample=$(runtime_sample)
  [ -n "$sample" ] && need_file "$sample"
  input=$(mktemp "${TMPDIR:-/tmp}/coralline-input.XXXXXX") || exit 1
  if [ -n "$sample" ]; then
    jq --arg cwd "$SCRIPT_DIR" '.cwd = $cwd | .workspace.current_dir = $cwd' "$sample" > "$input" 2>/dev/null || cp "$sample" "$input"
  else
    jq -n --arg cwd "$SCRIPT_DIR" '{cwd: $cwd, workspace: {current_dir: $cwd}}' > "$input"
  fi
  preview_input_file="$input"
  printf '%s\n' "$preview_input_file"
}

preview_cache_path() {
  local config="$1" cols="$2" key crc bytes
  [ -n "$preview_cache_dir" ] || preview_cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-preview.XXXXXX") || exit 1
  key=$( (printf '%s\n' "$cols"; cat "$config") | cksum )
  set -- $key
  crc="$1"
  bytes="$2"
  printf '%s/%s-%s.out\n' "$preview_cache_dir" "$crc" "$bytes"
}

ask() {
  local prompt="$1" default="${2:-}" answer
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer
  [ -n "$answer" ] || answer="$default"
  printf '%s\n' "$answer"
}

ask_choice() {
  local prompt="$1" max="$2" default="$3" answer
  while :; do
    answer=$(ask "$prompt" "$default")
    case "$answer" in
      ''|*[!0-9]*) printf 'Choose a number from 1 to %s.\n' "$max" >&2 ;;
      *) if [ "$answer" -ge 1 ] && [ "$answer" -le "$max" ]; then
           printf '%s\n' "$answer"
           return 0
         fi
         printf 'Choose a number from 1 to %s.\n' "$max" >&2 ;;
    esac
  done
}

yes_no() {
  local prompt="$1" default="$2" answer
  while :; do
    case "$default" in
      y|Y) printf '%s [Y/n]: ' "$prompt" >&2 ;;
      *) printf '%s [y/N]: ' "$prompt" >&2 ;;
    esac
    IFS= read -r answer
    [ -n "$answer" ] || answer="$default"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Answer y or n.\n' >&2 ;;
    esac
  done
}

show_diff() {
  if [ -t 1 ]; then
    diff -u "$1" "$2" | while IFS= read -r line; do
      case "$line" in
        ---*|+++*) printf '%s%s%s\n' "$T_DIM" "$line" "$T_RESET" ;;
        @@*) printf '%s%s%s\n' "$T_MAUVE" "$line" "$T_RESET" ;;
        +*) printf '%s%s%s\n' "$T_GREEN" "$line" "$T_RESET" ;;
        -*) printf '%s%s%s\n' "$T_RED" "$line" "$T_RESET" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done
  else
    diff -u "$1" "$2"
  fi
}

enter_screen() {
  [ -t 0 ] && [ -t 1 ] || return 1
  old_stty=$(stty -g 2>/dev/null || true)
  tput smcup 2>/dev/null || true
  tput civis 2>/dev/null || true
  stty -echo 2>/dev/null || true
  screen_active=1
}

leave_screen() {
  [ "$screen_active" = "1" ] || return 0
  [ -n "$old_stty" ] && stty "$old_stty" 2>/dev/null || stty echo 2>/dev/null || true
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  screen_active=0
}

cleanup() {
  leave_screen
  [ -n "$preview_input_file" ] && rm -f "$preview_input_file"
  [ -n "$preview_cache_dir" ] && rm -rf "$preview_cache_dir"
}

clear_screen() {
  printf '\033[H\033[J'
}

clear_tail() {
  printf '\033[J'
}

redraw_menu_area() {
  printf '\033[u'
}

decode_key() {  # $1 = raw byte(s) → sets global KEY
  case "$1" in
    $'\033[A') KEY=up ;;
    $'\033[B') KEY=down ;;
    $'\033[C') KEY=right ;;
    $'\033[D') KEY=left ;;
    '') KEY=enter ;;
    ' ') KEY=space ;;
    q|Q) KEY=quit ;;
    k|K) KEY=up ;;
    j|J) KEY=down ;;
    *) KEY="$1" ;;
  esac
}

read_key() {  # sets global KEY; returns 1 only when there is no interactive input.
              # Polls with a 1s timeout so an idle terminal resize is still caught
              # (SIGWINCH may not interrupt a blocking read). bash 3.2 returns 1
              # from `read -t` on BOTH timeout and EOF (bash 4+ returns >128 on
              # timeout), so the old code misread every idle-second timeout as EOF
              # and raced the wizard forward (issue #23). The fix: a stdin that is
              # not a tty is rejected up front; after that, stdin is a tty in raw
              # mode where EOF cannot occur, so any non-key read result is a
              # timeout (or signal) — never EOF — and we just keep polling.
  local k k2 k3 rc now
  [ -t 0 ] || return 1
  while :; do
    IFS= read -rsn1 -t 1 k; rc=$?
    [ "$rc" = 0 ] && break                 # got a key
    if [ "$resized" = "1" ]; then resized=0; KEY="resize"; return 0; fi
    now=$(stty size 2>/dev/null || true)   # catch a resize SIGWINCH may have missed
    if [ -n "$now" ] && [ -n "$last_size" ] && [ "$now" != "$last_size" ]; then
      last_size="$now"; KEY="resize"; return 0
    fi
    [ -n "$now" ] && last_size="$now"
    # rc != 0 with no resize is the 1s poll timeout (tty raw mode has no EOF) → loop.
  done
  if [ "$k" = $'\033' ]; then
    IFS= read -rsn1 -t 1 k2 2>/dev/null || k2=""
    IFS= read -rsn1 -t 1 k3 2>/dev/null || k3=""
    k="$k$k2$k3"
  fi
  decode_key "$k"
}

menu_move() {
  local selected="$1" key="$2" count="$3"
  case "$key" in
    up) selected=$((selected - 1)); [ "$selected" -lt 0 ] && selected=$((count - 1)) ;;
    down) selected=$((selected + 1)); [ "$selected" -ge "$count" ] && selected=0 ;;
  esac
  printf '%s\n' "$selected"
}

add_extra() {
  extra_config="${extra_config}$1=\"$2\"
"
}

hex_to_rgb() {
  local h="$1" r g b
  h="${h#\#}"
  [ "${#h}" = "6" ] || return 1
  r=$((16#${h:0:2}))
  g=$((16#${h:2:2}))
  b=$((16#${h:4:2}))
  printf '%s,%s,%s\n' "$r" "$g" "$b"
}

normalize_color() {
  local v="$1"
  v="${v%% #*}"
  v="${v#\"}" ; v="${v%\"}"
  v="${v#\'}" ; v="${v%\'}"
  case "$v" in
    \#??????) hex_to_rgb "$v" ;;
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$v" ;;
  esac
}

p10k_value() {
  local name="$1" line
  line=$(grep -E "^[[:space:]]*(typeset -g )?${name}=" "$P10K_FILE" 2>/dev/null | tail -1) || return 1
  line="${line#*${name}=}"
  line="${line%%[[:space:]]#*}"
  line="${line#\"}" ; line="${line%\"}"
  line="${line#\'}" ; line="${line%\'}"
  printf '%s\n' "$line"
}

map_p10k_color() {
  local p10k_name="$1" coralline_name="$2" value color
  value=$(p10k_value "$p10k_name") || return 0
  color=$(normalize_color "$value") || return 0
  add_extra "$coralline_name" "$color"
}

shell_quote() {
  printf '%q' "$1"
}

write_assign() {
  printf '%s=%s\n' "$1" "$(shell_quote "$2")"
}

known_segment() {
  case " $SEGMENT_CHOICES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

normalize_segments() {
  local raw="$1" s next=""
  for s in $raw; do
    known_segment "$s" || continue
    next="${next}${next:+ }$s"
  done
  printf '%s\n' "$next"
}

import_p10k() {
  local wizard_options time_fmt
  [ -f "$P10K_FILE" ] || die "cannot import; $P10K_FILE does not exist"

  wizard_options=$(grep -E '^# Wizard options:' "$P10K_FILE" 2>/dev/null | tail -1)
  case "$wizard_options" in
    *lean*) style="lean" ;;
    *classic*|*rainbow*|*powerline*) style="pill" ;;
  esac
  case "$wizard_options" in
    *24h\ time*) clock_mode="24h" ;;
  esac

  time_fmt=$(p10k_value POWERLEVEL9K_TIME_FORMAT || true)
  case "$time_fmt" in
    *%H*) clock_mode="24h" ;;
  esac
  case "$time_fmt" in
    *%S*) clock_seconds=1 ;;
  esac

  if [ "$style" = "lean" ]; then
    map_p10k_color POWERLEVEL9K_DIR_FOREGROUND VL_BG_DIR
    map_p10k_color POWERLEVEL9K_VCS_CLEAN_FOREGROUND VL_BG_GIT_OK
    map_p10k_color POWERLEVEL9K_VCS_MODIFIED_FOREGROUND VL_BG_GIT_DIRTY
    map_p10k_color POWERLEVEL9K_VCS_UNTRACKED_FOREGROUND VL_BG_GIT_DIRTY
    map_p10k_color POWERLEVEL9K_TIME_FOREGROUND VL_BG_CLOCK
  else
    map_p10k_color POWERLEVEL9K_DIR_BACKGROUND VL_BG_DIR
    map_p10k_color POWERLEVEL9K_VCS_CLEAN_BACKGROUND VL_BG_GIT_OK
    map_p10k_color POWERLEVEL9K_VCS_MODIFIED_BACKGROUND VL_BG_GIT_DIRTY
    map_p10k_color POWERLEVEL9K_VCS_UNTRACKED_BACKGROUND VL_BG_GIT_DIRTY
    map_p10k_color POWERLEVEL9K_TIME_BACKGROUND VL_BG_CLOCK
  fi
  map_p10k_color POWERLEVEL9K_STATUS_OK_FOREGROUND VL_FG_OK
  map_p10k_color POWERLEVEL9K_STATUS_ERROR_FOREGROUND VL_FG_HOT
}

write_candidate_config() {
  local out="$1" theme_dir
  theme_dir=$(runtime_theme_dir)
  {
    printf '# coralline config\n'
    printf '. %s\n\n' "$(shell_quote "$theme_dir/$theme.conf")"
    write_assign VL_STYLE "$style"
    write_assign VL_LAYOUT "$layout"
    printf 'VL_MAX_LINES=%s\n' "$max_lines"
    printf 'VL_WRAP_MARGIN=4\n'
    write_assign VL_SEGMENTS "$segments"
    write_assign VL_SEGMENTS2 "$segments2"
    write_assign VL_SEGMENTS3 "$segments3"
    write_assign VL_CLOCK "$clock_mode"
    printf 'VL_CLOCK_SECONDS=%s\n' "$clock_seconds"
    printf 'VL_BAR_WIDTH=5\n'
    printf 'VL_COST_DECIMALS=2\n'
    printf 'VL_PATH_DEPTH=4\n'
    printf 'VL_NAME_MAX=%s\n' "$name_max"
    printf 'VL_ASCII=%s\n' "$ascii_mode"
    write_assign VL_LEAN_SEP "$lean_sep"
    write_assign VL_FLOAT "$float_enabled"
    write_assign VL_FLOAT_SEGMENTS "$float_segments"
  } > "$out"
  if [ -n "$extra_config" ]; then
    printf '\n# Imported p10k color hints.\n' >> "$out"
    printf '%s' "$extra_config" >> "$out"
  fi
}

render_preview() {
  local tmp input statusline cache cols="${1:-120}" sz
  # Cap the preview to the real terminal width so it never wraps on a narrow window.
  sz=$(stty size 2>/dev/null || true)
  if [ -n "$sz" ]; then set -- $sz; [ -n "${2:-}" ] && [ "$2" -gt 0 ] 2>/dev/null && [ "$cols" -gt "$2" ] && cols="$2"; fi
  statusline=$(runtime_statusline)
  need_file "$statusline"
  tmp=$(mktemp "${TMPDIR:-/tmp}/coralline-config.XXXXXX") || exit 1
  input=$(prepare_preview_input)
  write_candidate_config "$tmp"
  cache=$(preview_cache_path "$tmp" "$cols")
  printf '\nPreview (%s cols):\n' "$cols"
  if [ ! -f "$cache" ]; then
    if ! CORALLINE_CONFIG="$tmp" COLUMNS="$cols" bash "$statusline" < "$input" > "$cache"; then
      rm -f "$cache" "$tmp"
      return 1
    fi
  fi
  cat "$cache"
  rm -f "$tmp"
}

preview_current() {
  render_preview "${1:-120}"
}

check_mark() {
  if [ "$1" = "$2" ]; then printf '✓'; else printf ' '; fi
}

flag_mark() {
  if [ "$1" = "1" ]; then printf '✓'; else printf ' '; fi
}

current_theme_index() {
  local i=1 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if [ "$t" = "$theme" ]; then printf '%s\n' "$i"; return 0; fi
    i=$((i + 1))
  done <<THEMES
$(theme_list)
THEMES
  printf '1\n'
}

step_header() {
  printf '\n────────────────────────────────────────\n'
  printf '%s\n' "$1"
  printf '────────────────────────────────────────\n'
}

show_current_state() {
  printf '%sTheme%s: %s%s%s · %sStyle%s: %s%s%s · %sLayout%s: %s' \
    "$T_DIM" "$T_RESET" "$T_BOLD" "$theme" "$T_RESET" \
    "$T_DIM" "$T_RESET" "$T_BOLD" "$style" "$T_RESET" \
    "$T_DIM" "$T_RESET" "$layout"
  if [ "$layout" = "auto" ]; then printf ':%s' "$max_lines"; fi
  printf ' · %sClock%s: %s' "$T_DIM" "$T_RESET" "$clock_mode"
  if [ "$clock_mode" != "off" ]; then
    [ "$clock_seconds" = "1" ] && printf '%s' '+seconds' || printf '%s' '-seconds'
  fi
  [ "$ascii_mode" = "1" ] && printf ' · %sASCII%s' "$T_WARN" "$T_RESET" || printf ' · %sNerd Font%s' "$T_GREEN" "$T_RESET"
  printf '\n'
}

show_step() {
  step_header "$1"
  show_current_state
  preview_current "${2:-120}"
}

draw_screen_header() {
  local preview
  preview=$(render_preview "${2:-120}")
  clear_screen
  printf '%s%s%s %s·%s %s%s%s\n\n' "$T_BOLD" "$T_CORAL" "coralline configure" "$T_DIM" "$T_RESET" "$T_BOLD" "$1" "$T_RESET"
  show_current_state
  printf '\n%s\n\n' "$preview"
  printf '\033[s'
}

draw_screen_footer() {
  if [ "${1:-}" = "toggle" ]; then
    printf '\n%s↑/↓%s move · %sSpace%s toggle · %sEnter%s accept · %sq%s quit%s\n' \
      "$T_BLUE" "$T_RESET" "$T_BLUE" "$T_RESET" "$T_GREEN" "$T_RESET" "$T_CORAL" "$T_RESET" "$T_RESET"
  else
    printf '\n%s↑/↓%s move · %sEnter%s accept · %sq%s quit%s\n' \
      "$T_BLUE" "$T_RESET" "$T_GREEN" "$T_RESET" "$T_CORAL" "$T_RESET" "$T_RESET"
  fi
}

draw_option() {
  local selected="$1" mark="$2" label="$3"
  if [ "$selected" = "1" ]; then
    printf ' %s❯%s %s[%s]%s %s%s%s\n' "$T_CORAL" "$T_RESET" "$T_GREEN" "$mark" "$T_RESET" "$T_BOLD" "$label" "$T_RESET"
  else
    printf '   %s[%s]%s %s\n' "$T_DIM" "$mark" "$T_RESET" "$label"
  fi
}

theme_by_index() {
  local want="$1" i=0 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ "$i" = "$want" ] && { printf '%s\n' "$t"; return 0; }
    i=$((i + 1))
  done <<THEMES
$(theme_list)
THEMES
  return 1
}

choose_theme_screen() {
  local selected key i t mark pointer count win=14 start end
  count=$(theme_count)
  [ "$count" -gt 0 ] 2>/dev/null || die "no themes found in $(runtime_theme_dir)"
  selected=$(( $(current_theme_index) - 1 ))
  while :; do
    theme=$(theme_by_index "$selected")
    draw_screen_header "Theme" 120
    printf 'Theme %s/%s\n\n' "$((selected + 1))" "$count"
    start=$((selected - win / 2))
    [ "$start" -lt 0 ] && start=0
    end=$((start + win))
    if [ "$end" -gt "$count" ]; then
      end="$count"
      start=$((end - win))
      [ "$start" -lt 0 ] && start=0
    fi
    i="$start"
    while [ "$i" -lt "$end" ]; do
      t=$(theme_by_index "$i")
      [ "$i" = "$selected" ] && mark="✓" || mark=" "
      [ "$i" = "$selected" ] && draw_option 1 "$mark" "$t" || draw_option 0 "$mark" "$t"
      i=$((i + 1))
    done
    draw_screen_footer
    clear_tail
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      enter) theme=$(theme_by_index "$selected"); return 0 ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

choose_style_screen() {
  local selected key pointer mark
  [ "$style" = "lean" ] && selected=1 || selected=0
  while :; do
    [ "$selected" = "1" ] && style="lean" || style="pill"
    draw_screen_header "Style" 120
    [ "$selected" = "0" ] && mark="✓" || mark=" "
    [ "$selected" = "0" ] && draw_option 1 "$mark" "pill" || draw_option 0 "$mark" "pill"
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    [ "$selected" = "1" ] && draw_option 1 "$mark" "lean" || draw_option 0 "$mark" "lean"
    draw_screen_footer
    clear_tail
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" 2) ;;
      enter)
        [ "$selected" = "1" ] && style="lean" || style="pill"
        if [ "$style" = "lean" ]; then
          leave_screen
          lean_sep=$(ask "Lean separator, empty is okay" "$lean_sep")
          enter_screen
        else
          lean_sep=""
        fi
        return 0 ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

choose_segments_screen() {
  local selected=0 key seg_n reorder_index count dirty=1
  seg_n=$(segment_total)
  reorder_index=$seg_n          # the reorder row sits right after the segments
  count=$((seg_n + 1))          # segments + reorder row
  while :; do
    if [ "$dirty" = "1" ]; then
      draw_screen_header "Segments" 120
      dirty=0
    fi
    draw_segments_menu "$selected"
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      resize) dirty=1 ;;
      enter) return 0 ;;
      space)
        if [ "$selected" -lt "$seg_n" ]; then
          local i=0 s
          i=0
          for s in $SEGMENT_CHOICES; do
            if [ "$i" = "$selected" ]; then toggle_segment "$s"; break; fi
            i=$((i + 1))
          done
          dirty=1
        elif [ "$selected" = "$reorder_index" ]; then
          leave_screen
          local answer
          answer=$(ask "Segments in order" "$segments")
          [ -n "$answer" ] && segments=$(normalize_segments "$answer")
          enter_screen
          dirty=1
        fi ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

draw_segments_menu() {
  local selected="$1" i=0 s enabled pointer reorder_index
  redraw_menu_area
  printf 'Segments: %s\n\n' "$segments"
  for s in $SEGMENT_CHOICES; do
    has_segment "$s" && enabled=1 || enabled=0
    [ "$i" = "$selected" ] && draw_option 1 "$(flag_mark "$enabled")" "$s" || draw_option 0 "$(flag_mark "$enabled")" "$s"
    i=$((i + 1))
  done
  reorder_index=$i
  [ "$selected" = "$reorder_index" ] && draw_option 1 " " "reorder" || draw_option 0 " " "reorder"
  draw_screen_footer toggle
  clear_tail
}

layout_selected_index() {
  if [ "$layout" = "auto" ] && [ "$max_lines" -gt 1 ]; then printf '0\n'; return; fi
  if [ "$layout" = "auto" ] && [ "$max_lines" -eq 1 ]; then printf '1\n'; return; fi
  if [ "$layout" = "fixed" ] && [ -n "$segments2" ] && [ -z "$segments3" ]; then printf '2\n'; return; fi
  printf '3\n'
}

split_segments() {  # $1=lines (2 or 3), $2=full list — distributes evenly into segments/segments2/segments3
  local n="$1" all="$2" total per i=0 line=1 s
  set -- $all; total=$#
  segments=""; segments2=""; segments3=""
  per=$(( (total + n - 1) / n )); [ "$per" -lt 1 ] && per=1
  for s in $all; do
    case "$line" in
      1) segments="${segments}${segments:+ }$s" ;;
      2) segments2="${segments2}${segments2:+ }$s" ;;
      3) segments3="${segments3}${segments3:+ }$s" ;;
    esac
    i=$((i + 1))
    if [ "$i" -ge "$per" ] && [ "$line" -lt "$n" ]; then line=$((line + 1)); i=0; fi
  done
}

apply_layout_index() {
  # Always recombine first so switching layouts (or navigating past them in the
  # menu) never drops segments that were parked on line 2/3.
  local all
  all=$(normalize_segments "$segments $segments2 $segments3")
  case "$1" in
    0) layout="auto";  max_lines=3; segments="$all"; segments2=""; segments3="" ;;
    1) layout="auto";  max_lines=1; segments="$all"; segments2=""; segments3="" ;;
    2) layout="fixed"; max_lines=3; split_segments 2 "$all" ;;
    3) layout="fixed"; max_lines=3; split_segments 3 "$all" ;;
  esac
}

choose_layout_screen() {
  local selected key pointer mark
  selected=$(layout_selected_index)
  while :; do
    apply_layout_index "$selected"
    draw_screen_header "Layout" 80
    printf '80-column preview\n\n'
    [ "$selected" = "0" ] && mark="✓" || mark=" "
    [ "$selected" = "0" ] && draw_option 1 "$mark" "responsive wrap" || draw_option 0 "$mark" "responsive wrap"
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    [ "$selected" = "1" ] && draw_option 1 "$mark" "always single line" || draw_option 0 "$mark" "always single line"
    [ "$selected" = "2" ] && mark="✓" || mark=" "
    [ "$selected" = "2" ] && draw_option 1 "$mark" "fixed two lines" || draw_option 0 "$mark" "fixed two lines"
    [ "$selected" = "3" ] && mark="✓" || mark=" "
    [ "$selected" = "3" ] && draw_option 1 "$mark" "fixed three lines" || draw_option 0 "$mark" "fixed three lines"
    draw_screen_footer
    clear_tail
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" 4) ;;
      enter) apply_layout_index "$selected"; return 0 ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

choose_details_screen() {
  local selected=0 key count=7 dirty=1
  while :; do
    if [ "$dirty" = "1" ]; then
      draw_screen_header "Details" 120
      dirty=0
    fi
    draw_details_menu "$selected"
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      resize) dirty=1 ;;
      enter) return 0 ;;
      space)
        case "$selected" in
          0) clock_mode="12h"; dirty=1 ;;
          1) clock_mode="24h"; dirty=1 ;;
          2) clock_mode="off"; dirty=1 ;;
          3) [ "$clock_seconds" = "1" ] && clock_seconds=0 || clock_seconds=1; dirty=1 ;;
          4) [ "$ascii_mode" = "1" ] && ascii_mode=0 || ascii_mode=1; dirty=1 ;;
          5)
            # Drop to cooked mode for the prompt so the cursor, echo and backspace
            # all work normally (an in-TUI digit editor has no visible cursor).
            leave_screen
            name_max=$(ask "Max chars for project/git names, 0 disables truncation" "$name_max")
            case "$name_max" in ''|*[!0-9]*) name_max=0 ;; esac
            enter_screen
            dirty=1 ;;
          6) [ "$float_enabled" = "1" ] && float_enabled=0 || float_enabled=1; dirty=1 ;;
        esac ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

draw_details_menu() {
  local selected="$1" pointer mark
  redraw_menu_area
  printf 'Details\n\n'
  [ "$clock_mode" = "12h" ] && mark="✓" || mark=" "
  [ "$selected" = "0" ] && draw_option 1 "$mark" "clock: 12h" || draw_option 0 "$mark" "clock: 12h"
  [ "$clock_mode" = "24h" ] && mark="✓" || mark=" "
  [ "$selected" = "1" ] && draw_option 1 "$mark" "clock: 24h" || draw_option 0 "$mark" "clock: 24h"
  [ "$clock_mode" = "off" ] && mark="✓" || mark=" "
  [ "$selected" = "2" ] && draw_option 1 "$mark" "clock: off" || draw_option 0 "$mark" "clock: off"
  mark=$(flag_mark "$clock_seconds")
  [ "$selected" = "3" ] && draw_option 1 "$mark" "seconds" || draw_option 0 "$mark" "seconds"
  [ "$ascii_mode" = "0" ] && mark="✓" || mark=" "
  [ "$selected" = "4" ] && draw_option 1 "$mark" "Nerd Font" || draw_option 0 "$mark" "Nerd Font"
  [ "$name_max" != "0" ] && mark="✓" || mark=" "
  [ "$selected" = "5" ] && draw_option 1 "$mark" "name max (0=off): $name_max" || draw_option 0 "$mark" "name max (0=off): $name_max"
  mark=$(flag_mark "$float_enabled")
  [ "$selected" = "6" ] && draw_option 1 "$mark" "float readout (VL_FLOAT)" || draw_option 0 "$mark" "float readout (VL_FLOAT)"
  draw_screen_footer toggle
  clear_tail
}

choose_theme() {
  local i t answer count
  count=$(theme_count)
  [ "$count" -gt 0 ] 2>/dev/null || die "no themes found in $(runtime_theme_dir)"
  if [ -t 0 ] && [ -t 1 ]; then
    choose_theme_screen
    return 0
  fi
  while :; do
    show_step "Theme" 120
    printf '\nTheme\n'
    i=1
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '  %s) [%s] %s\n' "$i" "$(check_mark "$theme" "$t")" "$t"
      i=$((i + 1))
    done <<THEMES
$(theme_list)
THEMES
    answer=$(ask "Theme number, Enter to keep" "$(current_theme_index)")
    case "$answer" in
      ''|*[!0-9]*) printf 'Choose a number from 1 to %s.\n' "$count" >&2 ;;
      *) if [ "$answer" -ge 1 ] && [ "$answer" -le "$count" ]; then
           i=1
           while IFS= read -r t; do
             [ -n "$t" ] || continue
             if [ "$i" = "$answer" ]; then theme="$t"; break; fi
             i=$((i + 1))
           done <<THEMES
$(theme_list)
THEMES
           show_step "Theme selected" 120
           return 0
         fi
         printf 'Choose a number from 1 to %s.\n' "$count" >&2 ;;
    esac
  done
}

choose_style() {
  local answer
  if [ -t 0 ] && [ -t 1 ]; then
    choose_style_screen
    return 0
  fi
  while :; do
    show_step "Style" 120
    printf '\nPick a style.\n'
    printf '  1) [%s] pill\n' "$(check_mark "$style" "pill")"
    printf '  2) [%s] lean\n' "$(check_mark "$style" "lean")"
    answer=$(ask "Style number, Enter to keep" "$([ "$style" = "lean" ] && printf 2 || printf 1)")
    case "$answer" in
      1) style="pill"; lean_sep=""; show_step "Style selected" 120; return 0 ;;
      2) style="lean"; lean_sep=$(ask "Lean separator, empty is okay" "$lean_sep"); show_step "Style selected" 120; return 0 ;;
      *) printf 'Choose 1 or 2.\n' >&2 ;;
    esac
  done
}

has_segment() {
  case " $segments " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

toggle_segment() {
  local target="$1" s next=""
  if has_segment "$target"; then
    for s in $segments; do
      [ "$s" = "$target" ] && continue
      next="${next}${next:+ }$s"
    done
    segments="$next"
  else
    # Re-emit in the canonical SEGMENT_CHOICES order so a newly enabled segment
    # lands in its defined position instead of being appended in toggle order.
    for s in $SEGMENT_CHOICES; do
      { has_segment "$s" || [ "$s" = "$target" ]; } && next="${next}${next:+ }$s"
    done
    segments="$next"
  fi
}

choose_segments() {
  local answer i s enabled
  if [ -t 0 ] && [ -t 1 ]; then
    choose_segments_screen
    return 0
  fi
  while :; do
    show_step "Segments" 120
    printf '\nSegments: %s\n' "$segments"
    i=1
    for s in $SEGMENT_CHOICES; do
      has_segment "$s" && enabled=1 || enabled=0
      printf '  %2s) [%s] %s\n' "$i" "$(flag_mark "$enabled")" "$s"
      i=$((i + 1))
    done
    printf '   r) reorder\n'
    printf '   d) done\n'
    answer=$(ask "Toggle number, r, or d" "d")
    case "$answer" in
      d|D|'') return 0 ;;
      r|R)
        answer=$(ask "Segments in order" "$segments")
        [ -n "$answer" ] && segments=$(normalize_segments "$answer") ;;
      ''|*[!0-9]*) printf 'Choose a segment number, r, or d.\n' >&2 ;;
      *)
        i=1
        for s in $SEGMENT_CHOICES; do
          if [ "$i" = "$answer" ]; then toggle_segment "$s"; break; fi
          i=$((i + 1))
        done
        if [ "$i" -gt "$(segment_total)" ]; then printf 'Choose a segment number from 1 to %s.\n' "$(segment_total)" >&2; fi ;;
    esac
  done
}

choose_layout() {
  local answer rows
  if [ -t 0 ] && [ -t 1 ]; then
    choose_layout_screen
    return 0
  fi
  while :; do
    show_step "Layout" 80
    printf '\nLayout\n'
    printf '  1) [%s] responsive wrap\n' "$([ "$layout" = "auto" ] && [ "$max_lines" -gt 1 ] && printf '✓' || printf ' ')"
    printf '  2) [%s] always single line\n' "$([ "$layout" = "auto" ] && [ "$max_lines" -eq 1 ] && printf '✓' || printf ' ')"
    printf '  3) [%s] fixed two lines\n' "$([ "$layout" = "fixed" ] && [ -n "$segments2" ] && [ -z "$segments3" ] && printf '✓' || printf ' ')"
    printf '  4) [%s] fixed three lines\n' "$([ "$layout" = "fixed" ] && [ -n "$segments3" ] && printf '✓' || printf ' ')"
    answer=$(ask "Layout number, Enter to keep" "1")
    case "$answer" in
      1)
        layout="auto"
        rows=$(ask_choice "Maximum rows" 3 3)
        max_lines="$rows"
        segments=$(normalize_segments "$segments $segments2 $segments3")
        segments2=""
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      2)
        layout="auto"
        max_lines=1
        segments=$(normalize_segments "$segments $segments2 $segments3")
        segments2=""
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      3)
        layout="fixed"
        max_lines=3
        segments=$(normalize_segments "$(ask "Line 1 segments" "dir git model")")
        segments2=$(normalize_segments "$(ask "Line 2 segments" "ctx limit5h limit7d cost clock")")
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      4)
        layout="fixed"
        max_lines=3
        segments=$(normalize_segments "$(ask "Line 1 segments" "dir git model")")
        segments2=$(normalize_segments "$(ask "Line 2 segments" "ctx limit5h limit7d")")
        segments3=$(normalize_segments "$(ask "Line 3 segments" "cost clock")")
        show_step "Layout selected" 80
        return 0 ;;
      *) printf 'Choose a layout number from 1 to 4.\n' >&2 ;;
    esac
  done
}

choose_details() {
  local answer
  if [ -t 0 ] && [ -t 1 ]; then
    choose_details_screen
    return 0
  fi
  while :; do
    show_step "Details" 120
    printf '\nToggle details.\n'
    printf '  1) [%s] clock: 12h\n' "$(check_mark "$clock_mode" "12h")"
    printf '  2) [%s] clock: 24h\n' "$(check_mark "$clock_mode" "24h")"
    printf '  3) [%s] clock: off\n' "$(check_mark "$clock_mode" "off")"
    printf '  4) [%s] show seconds\n' "$(flag_mark "$clock_seconds")"
    printf '  5) [%s] Nerd Font\n' "$([ "$ascii_mode" = "0" ] && printf '✓' || printf ' ')"
    printf '  6) name truncation: %s\n' "$name_max"
    printf '  d) done\n'
    answer=$(ask "Detail number or d" "d")
    case "$answer" in
      d|D|'') return 0 ;;
      1) clock_mode="12h" ;;
      2) clock_mode="24h" ;;
      3) clock_mode="off" ;;
      4) [ "$clock_seconds" = "1" ] && clock_seconds=0 || clock_seconds=1 ;;
      5) [ "$ascii_mode" = "1" ] && ascii_mode=0 || ascii_mode=1 ;;
      6)
        name_max=$(ask "Max chars for project/git names, 0 disables truncation" "$name_max")
        case "$name_max" in ''|*[!0-9]*) name_max=0 ;; esac ;;
      *) printf 'Choose 1-6 or d.\n' >&2 ;;
    esac
  done
}

visual_wizard() {
  if [ -t 0 ] && [ -t 1 ]; then
    enter_screen
  fi
  choose_theme
  choose_style
  choose_segments
  choose_layout
  choose_details
  leave_screen
}

print_float_help() {
  cat <<'EOF'

Float readout (VL_FLOAT) is enabled. statusline.sh now writes a plain-text
readout to ~/.claude/coralline/float.txt on every render. coralline does not
ship a display carrier — bring your own (a terminal status bar, tmux, a
menu-bar app, ...). A worked iTerm2 carrier lives in the repo under
example/float-display-iterm2/ — copy it into your dotfiles and adapt.
EOF
}

write_final_config() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/coralline-config.XXXXXX") || exit 1
  write_candidate_config "$tmp"
  if [ -f "$CONFIG_FILE" ]; then
    printf '\n%sExisting config diff:%s\n' "$T_BOLD" "$T_RESET"
    show_diff "$CONFIG_FILE" "$tmp" || true
    if ! yes_no "Overwrite $CONFIG_FILE" n; then
      rm -f "$tmp"
      printf '%sConfig unchanged.%s\n' "$T_WARN" "$T_RESET"
      return 1
    fi
  fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  mv "$tmp" "$CONFIG_FILE"
  printf '%sWrote%s %s\n' "$T_GREEN" "$T_RESET" "$CONFIG_FILE"
  [ "$float_enabled" = "1" ] && print_float_help
}

install_files() {
  local theme_dir rel
  command -v jq >/dev/null 2>&1 || die "jq is required by coralline and by the installer"
  need_file "$SCRIPT_DIR/statusline.sh"
  need_file "$SCRIPT_DIR/test/sample-input.json"
  [ -d "$SCRIPT_DIR/themes" ] || die "missing themes directory"

  # Upgrade path: on a real overwrite, back up the old statusline.sh, and (only
  # in install-only/agent mode, so the interactive wizard's alt-screen isn't
  # clobbered) report what is new. Gated on a real change so identical re-runs
  # leave no backup.
  local _bak=""
  if [ -f "$TARGET_DIR/statusline.sh" ] \
    && ! cmp -s "$TARGET_DIR/statusline.sh" "$SCRIPT_DIR/statusline.sh"; then
    _bak=$(backup_statusline "$TARGET_DIR")
    if [ "$install_only" = "1" ]; then
      report_upgrade_delta "$TARGET_DIR/statusline.sh" "$SCRIPT_DIR/statusline.sh" "$_bak"
    fi
  fi
  mkdir -p "$TARGET_DIR/themes"
  cp "$SCRIPT_DIR/statusline.sh" "$TARGET_DIR/statusline.sh"
  cp "$SCRIPT_DIR/configure.sh" "$TARGET_DIR/configure.sh"
  cp "$SCRIPT_DIR/test/sample-input.json" "$TARGET_DIR/sample-input.json"
  theme_dir="$SCRIPT_DIR/themes"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$TARGET_DIR/themes/$(dirname "$rel")"
    cp "$theme_dir/$rel" "$TARGET_DIR/themes/$rel"
  done <<THEMES
$(cd "$theme_dir" && find . -type f -name '*.conf' | sed 's#^\./##')
THEMES
  chmod +x "$TARGET_DIR/statusline.sh" "$TARGET_DIR/configure.sh"
  installed=1
}

update_settings() {
  local tmp backup
  command -v jq >/dev/null 2>&1 || die "jq is required to merge Claude settings"
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/coralline-settings.XXXXXX") || exit 1
  if [ -f "$SETTINGS_FILE" ]; then
    backup="$SETTINGS_FILE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SETTINGS_FILE" "$backup"
    if ! jq --arg command "bash $TARGET_DIR/statusline.sh" '.statusLine = {
      "type": "command",
      "command": $command,
      "refreshInterval": 1
    }' "$SETTINGS_FILE" > "$tmp"; then
      rm -f "$tmp"
      die "failed to parse $SETTINGS_FILE; original left unchanged, backup written to $backup"
    fi
  else
    cat > "$tmp" <<EOF
{
  "statusLine": {
    "type": "command",
    "command": "bash $TARGET_DIR/statusline.sh",
    "refreshInterval": 1
  }
}
EOF
  fi
  mv "$tmp" "$SETTINGS_FILE"
  printf 'Updated %s\n' "$SETTINGS_FILE"
}

verify_render() {
  local statusline sample input
  statusline=$(runtime_statusline)
  sample=$(runtime_sample)
  printf '\nVerification render:\n'
  if [ -n "$sample" ]; then
    need_file "$sample"
    CORALLINE_CONFIG="$CONFIG_FILE" COLUMNS=120 bash "$statusline" < "$sample"
  else
    input=$(mktemp "${TMPDIR:-/tmp}/coralline-input.XXXXXX") || exit 1
    jq -n --arg cwd "$SCRIPT_DIR" '{cwd: $cwd, workspace: {current_dir: $cwd}}' > "$input"
    CORALLINE_CONFIG="$CONFIG_FILE" COLUMNS=120 bash "$statusline" < "$input"
    rm -f "$input"
  fi
}

main_menu_screen() {
  local selected=0 key count drawn=0
  [ -f "$P10K_FILE" ] && count=3 || count=2
  while :; do
    if [ "$drawn" = "0" ]; then
      draw_screen_header "Setup mode" 120
      drawn=1
    fi
    draw_main_menu "$selected"
    read_key || return 1; key="$KEY"
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      resize) drawn=0 ;;
      enter)
        leave_screen
        if [ -f "$P10K_FILE" ]; then
          case "$selected" in
            0) preview_current 120 ;;
            1) import_p10k; preview_current 120 ;;
            2) visual_wizard ;;
          esac
        else
          case "$selected" in
            0) preview_current 120 ;;
            1) visual_wizard ;;
          esac
        fi
        return 0 ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

draw_main_menu() {
  local selected="$1" pointer mark
  redraw_menu_area
  printf 'Setup\n\n'
  [ "$selected" = "0" ] && mark="✓" || mark=" "
  [ "$selected" = "0" ] && draw_option 1 "$mark" "Default" || draw_option 0 "$mark" "Default"
  if [ -f "$P10K_FILE" ]; then
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    [ "$selected" = "1" ] && draw_option 1 "$mark" "Import p10k" || draw_option 0 "$mark" "Import p10k"
    [ "$selected" = "2" ] && mark="✓" || mark=" "
    [ "$selected" = "2" ] && draw_option 1 "$mark" "Configure Wizard" || draw_option 0 "$mark" "Configure Wizard"
  else
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    [ "$selected" = "1" ] && draw_option 1 "$mark" "Configure Wizard" || draw_option 0 "$mark" "Configure Wizard"
  fi
  draw_screen_footer
  clear_tail
}

main_menu() {
  local answer max default_choice
  case "$setup_mode" in
    default)
      preview_current 120
      return 0
      ;;
    import-p10k)
      [ -f "$P10K_FILE" ] || die "cannot import $P10K_FILE: file not found"
      import_p10k
      preview_current 120
      return 0
      ;;
    wizard)
      visual_wizard
      return 0
      ;;
  esac
  if [ -t 0 ] && [ -t 1 ]; then
    enter_screen
    main_menu_screen
    return 0
  fi
  printf 'coralline visual setup\n'
  printf '\nChoose how to create your theme config:\n'
  printf '  1) Use the coralline default\n'
  if [ -f "$P10K_FILE" ]; then
    printf '     Found %s. Choose import only if you want to use it.\n' "$P10K_FILE"
    printf '  2) Import local .p10k.zsh colors\n'
    printf '  3) Visual wizard\n'
    max=3
    default_choice=1
  else
    printf '  2) Visual wizard\n'
    max=2
    default_choice=2
  fi
  answer=$(ask_choice "Mode" "$max" "$default_choice")
  if [ -f "$P10K_FILE" ]; then
    case "$answer" in
      1) preview_current 120 ;;
      2) import_p10k; preview_current 120 ;;
      3) visual_wizard ;;
    esac
  else
    case "$answer" in
      1) preview_current 120 ;;
      2) visual_wizard ;;
    esac
  fi
}

for arg in "$@"; do
  case "$arg" in
    --install) install_files; update_settings ;;
    --install-only) install_only=1; install_files; update_settings ;;
    --default) setup_mode="default" ;;
    --import-p10k) setup_mode="import-p10k" ;;
    --wizard) setup_mode="wizard" ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT TERM
trap 'resized=1' WINCH

[ "$install_only" = "1" ] && exit 0

load_segment_choices
load_theme_choices
main_menu
write_final_config || exit 0
verify_render
printf '\n%sDone.%s Restart Claude Code or open a new session to see coralline.\n' "$T_GREEN" "$T_RESET"
printf '%sReconfigure anytime with:%s\n  %sbash %s/configure.sh%s\n' "$T_DIM" "$T_RESET" "$T_CORAL" "$TARGET_DIR" "$T_RESET"
