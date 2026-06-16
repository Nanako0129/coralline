#!/usr/bin/env bash
# Unit test for seg_len() — the display-width measurement that drives auto-layout
# wrapping. Extracts the live function from statusline.sh so this test can never
# drift from the implementation it checks.
#
#   bash test/test-width.sh
#
# Exits non-zero if any case fails. Needs only bash (no jq, no git).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
ESC=$'\033'

# Pull just the seg_len function body out of the real script and define it here.
eval "$(sed -n '/^seg_len() {/,/^}/p' "$SCRIPT")"

fail=0
check() {  # $1=expected width  $2=label  $3=text
  seg_len "$3"
  if [ "$SEG_LEN_R" = "$1" ]; then
    printf 'ok    %-22s width=%s\n' "$2" "$SEG_LEN_R"
  else
    printf 'FAIL  %-22s want=%s got=%s\n' "$2" "$1" "$SEG_LEN_R"; fail=1
  fi
}

check 3  ascii            "abc"
check 0  empty            ""
check 11 ascii-spaces     " hello dir "
check 5  powerline-bar    "▰▰▰▱▱"             # each block glyph = 1 column
check 8  cjk-han          "期末專案"          # 4 wide CJK = 8 columns
check 6  mixed-cjk-ascii  "ab中文"            # 1+1+2+2
check 2  emoji            "🚀"                # 4-byte wide = 2 columns
check 7  icon-bar-pct     "⬡ ▰▱ 9%"           # hexagon + bars treated as narrow
check 5  ansi-stripped    "${ESC}[1m${ESC}[38;5;231mhello${ESC}[0m"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
