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

THEMES="claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night dracula mono"
SEGMENT_CHOICES="dir project git model ctx limit5h limit7d cost clock lines style duration effort stash"
DEFAULT_SEGMENTS="dir git model ctx limit5h limit7d cost clock"

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
extra_config=""
installed=0
install_only=0
setup_mode=""
screen_active=0
old_stty=""

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
    answer=$(ask "$prompt" "$default")
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) printf 'Answer y or n.\n' >&2 ;;
    esac
  done
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

clear_screen() {
  printf '\033[H\033[J'
}

clear_tail() {
  printf '\033[J'
}

redraw_menu_area() {
  printf '\033[u'
}

read_key() {
  local k k2 k3
  IFS= read -rsn1 k || return 1
  if [ "$k" = $'\033' ]; then
    IFS= read -rsn1 -t 1 k2 2>/dev/null || k2=""
    IFS= read -rsn1 -t 1 k3 2>/dev/null || k3=""
    k="$k$k2$k3"
  fi
  case "$k" in
    $'\033[A') printf 'up\n' ;;
    $'\033[B') printf 'down\n' ;;
    $'\033[C') printf 'right\n' ;;
    $'\033[D') printf 'left\n' ;;
    '') printf 'enter\n' ;;
    ' ') printf 'space\n' ;;
    q|Q) printf 'quit\n' ;;
    k|K) printf 'up\n' ;;
    j|J) printf 'down\n' ;;
    *) printf '%s\n' "$k" ;;
  esac
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
  cat > "$out" <<EOF
# coralline config
. "$theme_dir/$theme.conf"

VL_STYLE="$style"
VL_LAYOUT="$layout"
VL_MAX_LINES=$max_lines
VL_WRAP_MARGIN=4
VL_SEGMENTS="$segments"
VL_SEGMENTS2="$segments2"
VL_SEGMENTS3="$segments3"
VL_CLOCK="$clock_mode"
VL_CLOCK_SECONDS=$clock_seconds
VL_BAR_WIDTH=5
VL_COST_DECIMALS=2
VL_PATH_DEPTH=4
VL_NAME_MAX=$name_max
VL_ASCII=$ascii_mode
VL_LEAN_SEP="$lean_sep"
EOF
  if [ -n "$extra_config" ]; then
    printf '\n# Imported p10k color hints.\n' >> "$out"
    printf '%s' "$extra_config" >> "$out"
  fi
}

render_preview() {
  local tmp input statusline sample cols="${1:-120}"
  statusline=$(runtime_statusline)
  sample=$(runtime_sample)
  need_file "$statusline"
  [ -n "$sample" ] && need_file "$sample"
  tmp=$(mktemp "${TMPDIR:-/tmp}/coralline-config.XXXXXX") || exit 1
  input=$(mktemp "${TMPDIR:-/tmp}/coralline-input.XXXXXX") || exit 1
  write_candidate_config "$tmp"
  jq --arg cwd "$SCRIPT_DIR" '.cwd = $cwd | .workspace.current_dir = $cwd' "$sample" > "$input" 2>/dev/null || cp "$sample" "$input"
  printf '\nPreview (%s cols):\n' "$cols"
  CORALLINE_CONFIG="$tmp" COLUMNS="$cols" bash "$statusline" < "$input"
  rm -f "$tmp" "$input"
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
  for t in $THEMES; do
    if [ "$t" = "$theme" ]; then printf '%s\n' "$i"; return 0; fi
    i=$((i + 1))
  done
  printf '1\n'
}

step_header() {
  printf '\n────────────────────────────────────────\n'
  printf '%s\n' "$1"
  printf '────────────────────────────────────────\n'
}

show_current_state() {
  printf 'Theme: %s · Style: %s · Layout: %s' "$theme" "$style" "$layout"
  if [ "$layout" = "auto" ]; then printf ':%s' "$max_lines"; fi
  printf ' · Clock: %s' "$clock_mode"
  if [ "$clock_mode" != "off" ]; then
    [ "$clock_seconds" = "1" ] && printf '+seconds' || printf '-seconds'
  fi
  [ "$ascii_mode" = "1" ] && printf ' · ASCII' || printf ' · Nerd Font'
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
  printf 'coralline configure  ·  %s\n' "$1"
  printf '↑/↓ move · Space toggle · Enter accept · q quit\n\n'
  show_current_state
  printf '%s\n\n' "$preview"
  printf '\033[s'
}

theme_by_index() {
  local want="$1" i=0 t
  for t in $THEMES; do
    [ "$i" = "$want" ] && { printf '%s\n' "$t"; return 0; }
    i=$((i + 1))
  done
  printf '%s\n' "$theme"
}

choose_theme_screen() {
  local selected key i t mark pointer
  selected=$(( $(current_theme_index) - 1 ))
  while :; do
    theme=$(theme_by_index "$selected")
    draw_screen_header "Theme" 120
    i=0
    for t in $THEMES; do
      [ "$i" = "$selected" ] && pointer="❯" || pointer=" "
      [ "$i" = "$selected" ] && mark="✓" || mark=" "
      printf ' %s [%s] %s\n' "$pointer" "$mark" "$t"
      i=$((i + 1))
    done
    clear_tail
    key=$(read_key) || return 1
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" 7) ;;
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
    [ "$selected" = "0" ] && pointer="❯" || pointer=" "
    [ "$selected" = "0" ] && mark="✓" || mark=" "
    printf ' %s [%s] pill\n' "$pointer" "$mark"
    [ "$selected" = "1" ] && pointer="❯" || pointer=" "
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    printf ' %s [%s] lean\n' "$pointer" "$mark"
    clear_tail
    key=$(read_key) || return 1
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
  local selected=0 key count=15 dirty=1 reorder_index=14
  while :; do
    if [ "$dirty" = "1" ]; then
      draw_screen_header "Segments" 120
      dirty=0
    fi
    draw_segments_menu "$selected"
    key=$(read_key) || return 1
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      enter) return 0 ;;
      space)
        if [ "$selected" -lt 14 ]; then
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
          [ -n "$answer" ] && segments="$answer"
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
    [ "$i" = "$selected" ] && pointer="❯" || pointer=" "
    printf ' %s [%s] %s\n' "$pointer" "$(flag_mark "$enabled")" "$s"
    i=$((i + 1))
  done
  reorder_index=$i
  [ "$selected" = "$reorder_index" ] && pointer="❯" || pointer=" "
  printf ' %s [ ] reorder\n' "$pointer"
  printf '\nEnter done · Space toggle\n'
  clear_tail
}

layout_selected_index() {
  if [ "$layout" = "auto" ] && [ "$max_lines" -gt 1 ]; then printf '0\n'; return; fi
  if [ "$layout" = "auto" ] && [ "$max_lines" -eq 1 ]; then printf '1\n'; return; fi
  if [ "$layout" = "fixed" ] && [ -n "$segments2" ] && [ -z "$segments3" ]; then printf '2\n'; return; fi
  printf '3\n'
}

apply_layout_index() {
  case "$1" in
    0) layout="auto"; max_lines=3; segments2=""; segments3="" ;;
    1) layout="auto"; max_lines=1; segments2=""; segments3="" ;;
    2) layout="fixed"; max_lines=3; segments="dir git model"; segments2="ctx limit5h limit7d cost clock"; segments3="" ;;
    3) layout="fixed"; max_lines=3; segments="dir git model"; segments2="ctx limit5h limit7d"; segments3="cost clock" ;;
  esac
}

choose_layout_screen() {
  local selected key pointer mark
  selected=$(layout_selected_index)
  while :; do
    apply_layout_index "$selected"
    draw_screen_header "Layout" 80
    printf '80-column preview\n\n'
    [ "$selected" = "0" ] && pointer="❯" || pointer=" "; [ "$selected" = "0" ] && mark="✓" || mark=" "
    printf ' %s [%s] responsive wrap\n' "$pointer" "$mark"
    [ "$selected" = "1" ] && pointer="❯" || pointer=" "; [ "$selected" = "1" ] && mark="✓" || mark=" "
    printf ' %s [%s] always single line\n' "$pointer" "$mark"
    [ "$selected" = "2" ] && pointer="❯" || pointer=" "; [ "$selected" = "2" ] && mark="✓" || mark=" "
    printf ' %s [%s] fixed two lines\n' "$pointer" "$mark"
    [ "$selected" = "3" ] && pointer="❯" || pointer=" "; [ "$selected" = "3" ] && mark="✓" || mark=" "
    printf ' %s [%s] fixed three lines\n' "$pointer" "$mark"
    clear_tail
    key=$(read_key) || return 1
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" 4) ;;
      enter) apply_layout_index "$selected"; return 0 ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

choose_details_screen() {
  local selected=0 key count=6 dirty=1
  while :; do
    if [ "$dirty" = "1" ]; then
      draw_screen_header "Details" 120
      dirty=0
    fi
    draw_details_menu "$selected"
    key=$(read_key) || return 1
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
      enter) return 0 ;;
      space)
        case "$selected" in
          0) clock_mode="12h"; dirty=1 ;;
          1) clock_mode="24h"; dirty=1 ;;
          2) clock_mode="off"; dirty=1 ;;
          3) [ "$clock_seconds" = "1" ] && clock_seconds=0 || clock_seconds=1; dirty=1 ;;
          4) [ "$ascii_mode" = "1" ] && ascii_mode=0 || ascii_mode=1; dirty=1 ;;
          5)
            leave_screen
            name_max=$(ask "Max chars for project/git names, 0 disables truncation" "$name_max")
            case "$name_max" in ''|*[!0-9]*) name_max=0 ;; esac
            enter_screen
            dirty=1 ;;
        esac ;;
      quit) leave_screen; exit 69 ;;
    esac
  done
}

draw_details_menu() {
  local selected="$1" pointer mark
  redraw_menu_area
  printf 'Details\n\n'
  [ "$selected" = "0" ] && pointer="❯" || pointer=" "; [ "$clock_mode" = "12h" ] && mark="✓" || mark=" "
  printf ' %s [%s] clock: 12h\n' "$pointer" "$mark"
  [ "$selected" = "1" ] && pointer="❯" || pointer=" "; [ "$clock_mode" = "24h" ] && mark="✓" || mark=" "
  printf ' %s [%s] clock: 24h\n' "$pointer" "$mark"
  [ "$selected" = "2" ] && pointer="❯" || pointer=" "; [ "$clock_mode" = "off" ] && mark="✓" || mark=" "
  printf ' %s [%s] clock: off\n' "$pointer" "$mark"
  [ "$selected" = "3" ] && pointer="❯" || pointer=" "
  printf ' %s [%s] seconds\n' "$pointer" "$(flag_mark "$clock_seconds")"
  [ "$selected" = "4" ] && pointer="❯" || pointer=" "
  [ "$ascii_mode" = "0" ] && mark="✓" || mark=" "
  printf ' %s [%s] Nerd Font\n' "$pointer" "$mark"
  [ "$selected" = "5" ] && pointer="❯" || pointer=" "
  printf ' %s [ ] name max: %s\n' "$pointer" "$name_max"
  printf '\nEnter done · Space toggle\n'
  clear_tail
}

choose_theme() {
  local i t answer
  if [ -t 0 ] && [ -t 1 ]; then
    choose_theme_screen
    return 0
  fi
  while :; do
    show_step "Theme" 120
    printf '\nTheme\n'
    i=1
    for t in $THEMES; do
      printf '  %s) [%s] %s\n' "$i" "$(check_mark "$theme" "$t")" "$t"
      i=$((i + 1))
    done
    answer=$(ask "Theme number, Enter to keep" "$(current_theme_index)")
    case "$answer" in
      ''|*[!0-9]*) printf 'Choose a number from 1 to 7.\n' >&2 ;;
      *) if [ "$answer" -ge 1 ] && [ "$answer" -le 7 ]; then
           i=1
           for t in $THEMES; do
             if [ "$i" = "$answer" ]; then theme="$t"; break; fi
             i=$((i + 1))
           done
           show_step "Theme selected" 120
           return 0
         fi
         printf 'Choose a number from 1 to 7.\n' >&2 ;;
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
    segments="${segments}${segments:+ }$target"
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
        [ -n "$answer" ] && segments="$answer" ;;
      ''|*[!0-9]*) printf 'Choose a segment number, r, or d.\n' >&2 ;;
      *)
        i=1
        for s in $SEGMENT_CHOICES; do
          if [ "$i" = "$answer" ]; then toggle_segment "$s"; break; fi
          i=$((i + 1))
        done
        if [ "$i" -gt 14 ]; then printf 'Choose a segment number from 1 to 14.\n' >&2; fi ;;
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
        segments2=""
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      2)
        layout="auto"
        max_lines=1
        segments2=""
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      3)
        layout="fixed"
        max_lines=3
        segments=$(ask "Line 1 segments" "dir git model")
        segments2=$(ask "Line 2 segments" "ctx limit5h limit7d cost clock")
        segments3=""
        show_step "Layout selected" 80
        return 0 ;;
      4)
        layout="fixed"
        max_lines=3
        segments=$(ask "Line 1 segments" "dir git model")
        segments2=$(ask "Line 2 segments" "ctx limit5h limit7d")
        segments3=$(ask "Line 3 segments" "cost clock")
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

write_final_config() {
  local tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/coralline-config.XXXXXX") || exit 1
  write_candidate_config "$tmp"
  if [ -f "$CONFIG_FILE" ]; then
    printf '\nExisting config diff:\n'
    diff -u "$CONFIG_FILE" "$tmp" || true
    if ! yes_no "Overwrite $CONFIG_FILE" n; then
      rm -f "$tmp"
      printf 'Config unchanged.\n'
      return 1
    fi
  fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  mv "$tmp" "$CONFIG_FILE"
  printf 'Wrote %s\n' "$CONFIG_FILE"
}

install_files() {
  local theme_dir
  command -v jq >/dev/null 2>&1 || die "jq is required by coralline and by the installer"
  need_file "$SCRIPT_DIR/statusline.sh"
  need_file "$SCRIPT_DIR/test/sample-input.json"
  [ -d "$SCRIPT_DIR/themes" ] || die "missing themes directory"

  mkdir -p "$TARGET_DIR/themes"
  cp "$SCRIPT_DIR/statusline.sh" "$TARGET_DIR/statusline.sh"
  cp "$SCRIPT_DIR/configure.sh" "$TARGET_DIR/configure.sh"
  cp "$SCRIPT_DIR/test/sample-input.json" "$TARGET_DIR/sample-input.json"
  theme_dir="$SCRIPT_DIR/themes"
  cp "$theme_dir"/*.conf "$TARGET_DIR/themes/"
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
    jq --arg command "bash $TARGET_DIR/statusline.sh" '.statusLine = {
      "type": "command",
      "command": $command,
      "refreshInterval": 1
    }' "$SETTINGS_FILE" > "$tmp"
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
  local statusline sample
  statusline=$(runtime_statusline)
  sample=$(runtime_sample)
  printf '\nVerification render:\n'
  CORALLINE_CONFIG="$CONFIG_FILE" COLUMNS=120 bash "$statusline" < "$sample"
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
    key=$(read_key) || return 1
    case "$key" in
      up|down) selected=$(menu_move "$selected" "$key" "$count") ;;
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
  [ "$selected" = "0" ] && pointer="❯" || pointer=" "
  [ "$selected" = "0" ] && mark="✓" || mark=" "
  printf ' %s [%s] Default\n' "$pointer" "$mark"
  if [ -f "$P10K_FILE" ]; then
    [ "$selected" = "1" ] && pointer="❯" || pointer=" "
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    printf ' %s [%s] Import p10k\n' "$pointer" "$mark"
    [ "$selected" = "2" ] && pointer="❯" || pointer=" "
    [ "$selected" = "2" ] && mark="✓" || mark=" "
    printf ' %s [%s] Configure Wizard\n' "$pointer" "$mark"
  else
    [ "$selected" = "1" ] && pointer="❯" || pointer=" "
    [ "$selected" = "1" ] && mark="✓" || mark=" "
    printf ' %s [%s] Configure Wizard\n' "$pointer" "$mark"
  fi
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
    --install-only) install_files; update_settings; install_only=1 ;;
    --default) setup_mode="default" ;;
    --import-p10k) setup_mode="import-p10k" ;;
    --wizard) setup_mode="wizard" ;;
    --help|-h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

trap 'leave_screen' EXIT
trap 'leave_screen; exit 130' INT TERM

[ "$install_only" = "1" ] && exit 0

main_menu
write_final_config || exit 0
verify_render
printf '\nDone. Restart Claude Code or open a new session to see coralline.\n'
printf 'Reconfigure anytime with:\n  bash %s/configure.sh\n' "$TARGET_DIR"
