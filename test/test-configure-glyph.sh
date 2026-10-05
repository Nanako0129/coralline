#!/usr/bin/env bash
# Verifies the wizard's glyph check (#47): write_candidate_config writes the
# fallback glyph knobs only for a row switched to its fallback, a run that keeps
# both defaults writes none of them, the written config renders the fallbacks,
# and the plain (non-TTY) choose_glyphs prompt asks one Yes/No question per glyph
# set, only the ctx/project one in ASCII mode (which swaps the gauge but not ⬡/⬢).
# Extracts the live functions from configure.sh so the test cannot drift.
#   bash test/test-configure-glyph.sh
# Needs jq for the render check (skipped without it).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CONF="$REPO/configure.sh"
SAMPLE="$HERE/sample-input.json"

eval "$(sed -n '/^shell_quote() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_assign() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_candidate_config() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^glyph_pick() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^check_mark() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^choose_glyph() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^choose_glyphs() {/,/^}/p' "$CONF")"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

# Minimal globals write_candidate_config reads.
theme="claude-coral" ; style="pill" ; layout="fixed" ; max_lines=3
segments="project ctx" ; segments2="" ; segments3=""
clock_mode="12h" ; clock_seconds=1 ; name_max=0 ; ascii_mode=0
lean_sep="" ; extra_config=""
float_enabled=0 ; float_segments="model ctx cost"
bar_glyphs="default" ; seg_glyphs="default"
runtime_theme_dir() { printf '%s/themes' "$REPO"; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/coralline-glyphcfg.XXXXXX") || exit 1
trap 'rm -rf "$TMPD"' EXIT

# The value $2 a config assigns, read by sourcing it (skipping the theme line)
# rather than matching text: printf %q escapes the glyph bytes in a C locale.
val() { ( eval "$(grep '^VL_' "$1")"; eval "printf '%s' \"\${$2-}\"" ); }

# The VL_ keys a config assigns, one per line, in file order.
keys() { sed -n 's/^\(VL_[A-Z0-9_]*\)=.*/\1/p' "$1" | tr '\n' ' '; }

# Golden: the pre-glyph-check output, i.e. the same function with the glyph
# block removed. Its key set is what a both-default run must still produce.
BASE_KEYS="VL_STYLE VL_LAYOUT VL_MAX_LINES VL_WRAP_MARGIN VL_SEGMENTS VL_SEGMENTS2 VL_SEGMENTS3 VL_CLOCK VL_CLOCK_SECONDS VL_BAR_WIDTH VL_COST_DECIMALS VL_PATH_DEPTH VL_NAME_MAX VL_ASCII VL_LEAN_SEP VL_FLOAT VL_FLOAT_SEGMENTS "

# (1) Both rows default: no glyph knob, no comment, and the file ends right
#     after the last pre-existing line, so it is byte-identical to before.
write_candidate_config "$TMPD/default.conf"
[ "$(keys "$TMPD/default.conf")" = "$BASE_KEYS" ] && ok "both default: exact pre-existing key set" || bad "both default: exact pre-existing key set"
grep -q 'Glyph fallbacks' "$TMPD/default.conf" && bad "both default: no glyph comment" || ok "both default: no glyph comment"
[ "$(tail -n 1 "$TMPD/default.conf")" = 'VL_FLOAT_SEGMENTS='"$(shell_quote "$float_segments")" ] \
  && ok "both default: file still ends at VL_FLOAT_SEGMENTS" || bad "both default: file still ends at VL_FLOAT_SEGMENTS"

# (2) Gauge fallback only.
bar_glyphs="fallback" ; seg_glyphs="default"
write_candidate_config "$TMPD/bar.conf"
[ "$(keys "$TMPD/bar.conf")" = "${BASE_KEYS}VL_BAR_FILL VL_BAR_EMPTY " ] && ok "gauge fallback: adds exactly the gauge pair" || bad "gauge fallback: adds exactly the gauge pair"
[ "$(val "$TMPD/bar.conf" VL_BAR_FILL)" = "▪" ] && [ "$(val "$TMPD/bar.conf" VL_BAR_EMPTY)" = "▫" ] && ok "gauge fallback: ▪ / ▫" || bad "gauge fallback: ▪ / ▫"
grep -q '^# Glyph fallbacks chosen in the wizard (issue #47)\.$' "$TMPD/bar.conf" && ok "gauge fallback: comment written" || bad "gauge fallback: comment written"

# (3) Segment fallback only.
bar_glyphs="default" ; seg_glyphs="fallback"
write_candidate_config "$TMPD/seg.conf"
[ "$(keys "$TMPD/seg.conf")" = "${BASE_KEYS}VL_CTX_GLYPH VL_PROJECT_GLYPH " ] && ok "segment fallback: adds exactly ctx/project" || bad "segment fallback: adds exactly ctx/project"
[ "$(val "$TMPD/seg.conf" VL_CTX_GLYPH)" = "◔" ] && [ "$(val "$TMPD/seg.conf" VL_PROJECT_GLYPH)" = "▣" ] && ok "segment fallback: ◔ / ▣" || bad "segment fallback: ◔ / ▣"

# (4) Both.
bar_glyphs="fallback" ; seg_glyphs="fallback"
write_candidate_config "$TMPD/both.conf"
[ "$(keys "$TMPD/both.conf")" = "${BASE_KEYS}VL_BAR_FILL VL_BAR_EMPTY VL_CTX_GLYPH VL_PROJECT_GLYPH " ] && ok "both fallback: all four knobs" || bad "both fallback: all four knobs"

# (5) The preview cache is keyed on the config's cksum, so every glyph choice
#     must produce different config bytes.
sums=$(for f in default bar seg both; do cksum < "$TMPD/$f.conf"; done | sort -u | wc -l | tr -d ' ')
[ "$sums" = 4 ] && ok "each glyph choice changes the preview cache key" || bad "each glyph choice changes the preview cache key"

# (6) The written config, sourced by the real statusline.sh, renders the fallbacks.
if command -v jq >/dev/null 2>&1; then
  # seg_project needs a real repo as cwd, or it self-suppresses (see test-glyph.sh).
  jq --arg d "$REPO" '.cwd=$d | .workspace.current_dir=$d' "$SAMPLE" > "$TMPD/payload.json" || exit 1
  out=$(CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$TMPD/both.conf" bash "$REPO/statusline.sh" < "$TMPD/payload.json")
  case "$out" in *▪*) ok "render: ▪ gauge" ;; *) bad "render: ▪ gauge" ;; esac
  case "$out" in *◔*) ok "render: ◔ ctx glyph" ;; *) bad "render: ◔ ctx glyph" ;; esac
  case "$out" in *▰*|*⬡*) bad "render: no ▰ or ⬡ left" ;; *) ok "render: no ▰ or ⬡ left" ;; esac
  out=$(CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$TMPD/default.conf" bash "$REPO/statusline.sh" < "$TMPD/payload.json")
  case "$out" in *▰*) ok "render: default config keeps ▰" ;; *) bad "render: default config keeps ▰" ;; esac
else
  printf 'SKIP  render checks (jq not available)\n'
fi

# (7) Plain prompt: stdin is not a tty, so choose_glyphs takes the numbered path
#     (show_step is stubbed out). Answers come through process substitution, not
#     a pipe, so the call stays in this shell and the globals it sets survive.
#     It asks the gauge question, then ctx/project; 1 is Yes, 2 is No (fallback).
show_step() { :; }
eval "$(sed -n '/^ask() {/,/^}/p' "$CONF")"
bar_glyphs="default" ; seg_glyphs="default"
choose_glyphs > "$TMPD/prompt.out" 2>&1 < <(printf '2\n1\n')
[ "$bar_glyphs" = "fallback" ] && [ "$seg_glyphs" = "default" ] \
  && ok "prompt: No then Yes picks gauge fallback, segment default" || bad "prompt: No then Yes picks gauge fallback, segment default"
grep -q -- '--->▰▰▰▱▱<---' "$TMPD/prompt.out" && grep -q '^  2) \[ \] No\..*Use ▪▪▪▫▫ instead\.$' "$TMPD/prompt.out" \
  && ok "prompt: gauge question shows the tight sample and its fallback" || bad "prompt: gauge question shows the tight sample and its fallback"
grep -q -- '--->⬡ ⬢<---' "$TMPD/prompt.out" && grep -q '^  2) \[ \] No\..*Use ◔ ▣ instead\.$' "$TMPD/prompt.out" \
  && ok "prompt: segment question shows the tight sample and its fallback" || bad "prompt: segment question shows the tight sample and its fallback"
grep -q '^  1) \[✓\] Yes\. Five separate cells' "$TMPD/prompt.out" && grep -q 'Answer number \[1\]' "$TMPD/prompt.out" \
  && ok "prompt: Yes is the default on a fresh run" || bad "prompt: Yes is the default on a fresh run"
grep -q 'overlap between$' "$TMPD/prompt.out" && grep -q '^them or with the arrows?$' "$TMPD/prompt.out" \
  && ok "prompt: question names both failure modes" || bad "prompt: question names both failure modes"

# Yes Yes leaves both default, and the config is the one a run without the check writes.
bar_glyphs="default" ; seg_glyphs="default"
choose_glyphs > /dev/null 2>&1 < <(printf '1\n1\n')
write_candidate_config "$TMPD/yy.conf"
[ "$bar_glyphs" = "default" ] && [ "$seg_glyphs" = "default" ] && cmp -s "$TMPD/yy.conf" "$TMPD/default.conf" \
  && ok "prompt: Yes Yes keeps both defaults, config byte-identical" || bad "prompt: Yes Yes keeps both defaults, config byte-identical"

# Bare Enter keeps the current value (the default answer follows it).
bar_glyphs="fallback" ; seg_glyphs="default"
choose_glyphs > "$TMPD/enter.out" 2>&1 < <(printf '\n\n')
[ "$bar_glyphs" = "fallback" ] && [ "$seg_glyphs" = "default" ] && grep -q 'Answer number \[2\]' "$TMPD/enter.out" \
  && ok "prompt: Enter keeps the current values" || bad "prompt: Enter keeps the current values"

# An invalid answer is rejected and the question repeats.
bar_glyphs="default" ; seg_glyphs="default"
choose_glyphs > "$TMPD/bad.out" 2>&1 < <(printf '3\ny\n2\n2\n')
[ "$(grep -c 'Choose 1 or 2\.' "$TMPD/bad.out")" = 2 ] && [ "$bar_glyphs" = "fallback" ] && [ "$seg_glyphs" = "fallback" ] \
  && ok "prompt: invalid answers rejected, then accepted" || bad "prompt: invalid answers rejected, then accepted"

# (8) ASCII mode: statusline.sh swaps the gauge for #/- but still draws ⬡/⬢,
#     so only the ctx/project question is asked.
ascii_mode=1 ; bar_glyphs="default" ; seg_glyphs="default"
choose_glyphs > "$TMPD/ascii.out" 2>&1 < <(printf '2\n')
[ "$seg_glyphs" = "fallback" ] && [ "$bar_glyphs" = "default" ] \
  && ok "ascii prompt: No picks segment fallback only" || bad "ascii prompt: No picks segment fallback only"
[ "$(grep -c 'Answer number' "$TMPD/ascii.out")" = 1 ] && ok "ascii prompt: asks one question" || bad "ascii prompt: asks one question"
grep -q '▰\|▪\|gauge' "$TMPD/ascii.out" && bad "ascii prompt: no gauge question" || ok "ascii prompt: no gauge question"
ascii_mode=0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
