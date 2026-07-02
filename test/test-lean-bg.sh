#!/usr/bin/env bash
# Unit test for print_range()'s lean uniform-background option (VL_LEAN_BG).
# Extracts the live fg/bg/print_range from statusline.sh so this test can never
# drift from the implementation it checks.
#
#   bash test/test-lean-bg.sh
#
# Exits non-zero if any case fails. Needs only bash (no jq, no git).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
BGSEQ=$'\033[48;2;48;48;48m'   # what bg "48,48,48" emits

# Pull the real functions out of the script and define them here.
eval "$(sed -n '/^fg() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^bg() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^print_range() {/,/^}/p' "$SCRIPT")"

R=$'\033[0m' ; VL_NOCOLOR=0 ; VL_STYLE="lean" ; VL_LEAN_SEP="╱"
SEG_BGS=("0,135,175" "175,95,215" "95,135,135")   # 3 segments
SEG_TXT=(" a " " b " " c ")

fail=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }
count() { printf '%s' "$1" | grep -aoF "$BGSEQ" | wc -l | tr -d ' '; }

# (1) Empty VL_LEAN_BG → no background escape at all (byte-for-byte legacy form).
VL_LEAN_BG=""
out_empty=$(print_range 0 2)
case "$out_empty" in (*'[48;'*) check "empty VL_LEAN_BG emits no background" 0 ;;
                     (*)        check "empty VL_LEAN_BG emits no background" 1 ;; esac

# (2) Set VL_LEAN_BG → the background escape appears.
VL_LEAN_BG="48,48,48"
out_bg=$(print_range 0 2)
case "$out_bg" in (*"$BGSEQ"*) check "VL_LEAN_BG paints a background" 1 ;;
                  (*)          check "VL_LEAN_BG paints a background" 0 ;; esac

# (3) Re-asserted after every reset so the bar stays continuous: 3 segments +
#     2 separators = 5 places where the bg must follow a reset.
n=$(count "$out_bg")
[ "$n" -eq 5 ] && check "background re-asserted after each reset (n=$n)" 1 \
               || check "background re-asserted after each reset (n=$n, want 5)" 0

# (4) A 256-color index works too (bg "236" → 48;5;236m).
VL_LEAN_BG="236"
out_256=$(print_range 0 2)
case "$out_256" in (*$'\033[48;5;236m'*) check "256-index VL_LEAN_BG works" 1 ;;
                   (*)                   check "256-index VL_LEAN_BG works" 0 ;; esac

# (5) VL_LEAN_CAP_R appends a trailing cap glyph painted in the bar colour.
VL_LEAN_BG="48,48,48" ; VL_LEAN_CAP_R=$''
out_cap=$(print_range 0 2)
case "$out_cap" in (*$'\033[38;2;48;48;48m'*) check "VL_LEAN_CAP_R cap uses the bar colour" 1 ;;
                   (*)                              check "VL_LEAN_CAP_R cap uses the bar colour" 0 ;; esac

# (6) the cap is suppressed when there is no background to bevel.
VL_LEAN_BG="" ; VL_LEAN_CAP_R=$''
out_nocap=$(print_range 0 2)
case "$out_nocap" in (*$''*) check "no cap without VL_LEAN_BG" 0 ;;
                     (*)           check "no cap without VL_LEAN_BG" 1 ;; esac
VL_LEAN_CAP_R=""

# (7) VL_LEAN_CAP_L prepends a leading cap glyph painted in the bar colour, at
#     the very start of the row (before the first segment's background begins).
VL_LEAN_BG="48,48,48" ; VL_LEAN_CAP_L=$''
out_capl=$(print_range 0 2)
case "$out_capl" in ($'\033[0m\033[38;2;48;48;48m'*) check "VL_LEAN_CAP_L leads the row in the bar colour" 1 ;;
                    (*)                                    check "VL_LEAN_CAP_L leads the row in the bar colour" 0 ;; esac

# (8) the leading cap is suppressed when there is no background to bevel.
VL_LEAN_BG="" ; VL_LEAN_CAP_L=$''
out_nocapl=$(print_range 0 2)
case "$out_nocapl" in (*$''*) check "no leading cap without VL_LEAN_BG" 0 ;;
                      (*)               check "no leading cap without VL_LEAN_BG" 1 ;; esac
VL_LEAN_CAP_L=""

# (9) Classic fold: VL_STYLE=classic is resolved at config-load time to lean plus a
#     default dark bar and an end cap. The fold is an inline block (not a function),
#     so extract it the same way and eval it against controlled inputs (VL_SEP is
#     stubbed so the cap default is checkable without a Nerd Font glyph).
FOLD=$(sed -n '/^if \[ "$VL_STYLE" = "classic" \]; then/,/^fi/p' "$SCRIPT")
# Guard against a silent reformat making the anchor extract nothing → the eval
# below would be a no-op and the cases could pass vacuously.
[ -n "$FOLD" ] && check "classic fold block extracted (non-vacuous)" 1 || check "classic fold block extracted (non-vacuous)" 0

VL_SEP="SEP"
VL_STYLE="classic" ; VL_LEAN_BG="" ; VL_LEAN_CAP_R="" ; VL_BG_BAR=""
eval "$FOLD"
{ [ "$VL_STYLE" = "lean" ] && [ "$VL_LEAN_BG" = "238" ] && [ "$VL_LEAN_CAP_R" = "SEP" ]; } \
  && check "classic fold -> lean + default bar 238 + cap from VL_SEP" 1 \
  || check "classic fold -> lean + default bar 238 + cap from VL_SEP (style=$VL_STYLE bg=$VL_LEAN_BG cap=$VL_LEAN_CAP_R)" 0

# (10) VL_BG_BAR tunes the bar colour when no explicit VL_LEAN_BG is set.
VL_STYLE="classic" ; VL_LEAN_BG="" ; VL_LEAN_CAP_R="" ; VL_BG_BAR="60,60,60"
eval "$FOLD"
[ "$VL_LEAN_BG" = "60,60,60" ] && check "classic fold -> VL_BG_BAR sets the bar" 1 \
                               || check "classic fold -> VL_BG_BAR sets the bar (got $VL_LEAN_BG)" 0

# (11) An explicit VL_LEAN_BG / VL_LEAN_CAP_R still wins over the fold defaults.
VL_STYLE="classic" ; VL_LEAN_BG="1,2,3" ; VL_LEAN_CAP_R="X" ; VL_BG_BAR="60,60,60"
eval "$FOLD"
{ [ "$VL_LEAN_BG" = "1,2,3" ] && [ "$VL_LEAN_CAP_R" = "X" ]; } \
  && check "classic fold -> explicit VL_LEAN_BG / cap override defaults" 1 \
  || check "classic fold -> explicit overrides win (bg=$VL_LEAN_BG cap=$VL_LEAN_CAP_R)" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
