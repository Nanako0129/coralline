#!/usr/bin/env bash
# Back navigation through the visual wizard: a step returning 2 (the left arrow
# on a TTY screen) re-runs the previous step, anything else advances, and back
# on the first step just shows it again. Extracts the live visual_wizard from
# configure.sh and stubs every step, so only the step loop is under test.
#   bash test/test-configure-back.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"

eval "$(sed -n '/^visual_wizard() {/,/^}/p' "$CONF")"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s  (got: %s)\n' "$1" "$2"; fail=1; }

enter_screen() { :; }
leave_screen() { :; }

# Each stub logs "name:can_back" and returns the next code from $QUEUE (a
# space-separated list consumed front to back; an empty queue means 0).
LOG=""
QUEUE=""
step() {
  local code=0
  LOG="${LOG}${LOG:+ }$1:${wizard_step_can_back}"
  if [ -n "$QUEUE" ]; then
    set -- $QUEUE
    code="$1"
    shift
    QUEUE="$*"
  fi
  return "$code"
}
choose_theme()    { step theme; }
choose_style()    { step style; }
choose_segments() { step segments; }
choose_layout()   { step layout; }
choose_details()  { step details; }
choose_glyphs()   { step glyphs; }

# run "<codes>" → sets $LOG; names only (can_back stripped) in $ORDER.
run() {
  LOG="" ; QUEUE="$1" ; wizard_step_can_back=0
  visual_wizard
  ORDER=$(printf '%s\n' "$LOG" | sed 's/:[01]//g')
}
expect() { [ "$ORDER" = "$2" ] && ok "$1" || bad "$1" "$ORDER"; }

run ""
expect "straight through" "theme style segments layout details glyphs"
[ "$LOG" = "theme:0 style:1 segments:1 layout:1 details:1 glyphs:1" ] \
  && ok "can_back is 0 on the first step and 1 after" || bad "can_back is 0 on the first step and 1 after" "$LOG"
[ "$wizard_step_can_back" = 0 ] && ok "can_back reset after the wizard" || bad "can_back reset after the wizard" "$wizard_step_can_back"

run "0 2"
expect "back once from style, then forward" "theme style theme style segments layout details glyphs"

run "2"
expect "back on the first step shows it again" "theme theme style segments layout details glyphs"

run "0 0 0 0 0 2"
expect "back from glyphs lands on details" "theme style segments layout details glyphs details glyphs"

run "0 0 0 0 0 2 2 2"
expect "back twice from glyphs, then forward to the end" \
  "theme style segments layout details glyphs details layout segments layout details glyphs"

# choose_glyphs pages: back from the segment page goes to the gauge page, back
# from the gauge page leaves the step; in ASCII mode (no gauge page) back from
# the segment page leaves the step directly.
eval "$(sed -n '/^choose_glyphs() {/,/^}/p' "$CONF")"
choose_glyph() { step "$1"; }
glyph_run() {
  LOG="" ; QUEUE="$1" ; ascii_mode="$2" ; wizard_step_can_back=1
  choose_glyphs ; RC=$?
  ORDER=$(printf '%s\n' "$LOG" | sed 's/:[01]//g')
}
glyph_run "" 0
expect "glyph pages in order" "bar_glyphs seg_glyphs"
glyph_run "0 2 0 0" 0
expect "back from segment page returns to the gauge page" "bar_glyphs seg_glyphs bar_glyphs seg_glyphs"
glyph_run "2" 0
[ "$ORDER" = "bar_glyphs" ] && [ "$RC" = 2 ] && ok "back from the gauge page leaves the step with 2" || bad "back from the gauge page leaves the step with 2" "$ORDER rc=$RC"
glyph_run "2" 1
[ "$ORDER" = "seg_glyphs" ] && [ "$RC" = 2 ] && ok "ascii: back from the only page leaves the step with 2" || bad "ascii: back from the only page leaves the step with 2" "$ORDER rc=$RC"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
