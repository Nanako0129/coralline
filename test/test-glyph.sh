#!/usr/bin/env bash
# Regression for the segment-glyph knobs (#47): VL_CTX_GLYPH, VL_PROJECT_GLYPH,
# and the gauge pair VL_BAR_FILL / VL_BAR_EMPTY.
#
# Why they exist: ⬡ U+2B21, ⬢ U+2B22 and ▱ U+25B1 are plain Unicode, not Nerd
# Font PUA icons, so Nerd Fonts never patches them in — a font that lacks them
# hands substitution to the terminal's own fallback, which can draw wider than
# one cell and shove the whole row out of alignment. (Measured: ▱ is absent from
# JetBrainsMono Nerd Font and falls back to Hiragino Sans W3 at 1.67 cell.) The
# knobs let a user swap in a glyph their font actually carries.
#
# These checks pin both directions: an override must reach the render, and the
# shipped defaults must not move — the fix is opt-in, so a default render still
# has to emit ⬡ / ⬢ / ▰ / ▱.
#
#   bash test/test-glyph.sh
#
# Needs jq (statusline.sh parses JSON, and the payload cwd is rewritten with it)
# and test/sample-input.json.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
SCRIPT="$REPO/statusline.sh"
CONF_TMPL="$REPO/themes/claude-coral.conf"
SAMPLE="$HERE/sample-input.json"

fail=0
ok()    { printf 'ok    %s\n' "$1"; }
bad()   { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }
# $out is set by render(); has/lacks read it so the callers stay one-liners.
has()   { case "$out" in (*"$1"*) printf 1 ;; (*) printf 0 ;; esac; }
lacks() { case "$out" in (*"$1"*) printf 0 ;; (*) printf 1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }

# seg_project resolves its name from `git -C "$cwd"`, and the shared sample's cwd
# (/Users/demo/projects/coralline) does not exist — it would self-suppress and the
# project assertions would pass vacuously. Point the payload at this checkout,
# which is a real repo, so the segment actually renders.
PAYLOAD=$(mktemp "${TMPDIR:-/tmp}/coralline-glyph-payload.XXXXXX") || exit 1
trap 'rm -f "$PAYLOAD"' EXIT
jq --arg d "$REPO" '.cwd=$d | .workspace.current_dir=$d' "$SAMPLE" > "$PAYLOAD" || exit 1

# Render the REAL statusline.sh with $1 as extra config lines, so the whole
# config-load path is exercised rather than an extracted block. CORALLINE_NO_SAMPLE
# keeps the cross-session stores untouched (#32).
render() {
  local extra="${1:-}" conf
  conf=$(mktemp "${TMPDIR:-/tmp}/coralline-glyph.XXXXXX") || exit 1
  {
    printf '. %s\n' "$CONF_TMPL"
    printf 'VL_SEGMENTS="project ctx"\nVL_SEGMENTS2=""\nVL_SEGMENTS3=""\n'
    printf 'VL_LAYOUT="fixed"\n'
    printf '%s' "$extra"
  } > "$conf"
  out=$(CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$PAYLOAD")
  rm -f "$conf"
}

# (1) Defaults are unchanged. The knobs are opt-in, so an untouched config must
#     still render the shipped glyphs.
render ""
check "default ctx glyph is still ⬡"        "$(has '⬡')"
check "default project glyph is still ⬢"    "$(has '⬢')"
check "default gauge still uses ▰ and ▱"    "$([ "$(has '▰')" = 1 ] && [ "$(has '▱')" = 1 ] && printf 1 || printf 0)"

# (2) VL_CTX_GLYPH reaches seg_ctx, and the default is gone rather than doubled.
render 'VL_CTX_GLYPH="◔"
'
check "VL_CTX_GLYPH renders the override"   "$(has '◔')"
check "VL_CTX_GLYPH drops the default ⬡"    "$(lacks '⬡')"

# (3) Same for VL_PROJECT_GLYPH / seg_project.
render 'VL_PROJECT_GLYPH="▣"
'
check "VL_PROJECT_GLYPH renders the override" "$(has '▣')"
check "VL_PROJECT_GLYPH drops the default ⬢"  "$(lacks '⬢')"

# (4) The gauge pair. This is the path the #47 workaround actually uses, and the
#     sample sits at 62.4% so a 5-cell bar carries both fill and empty glyphs.
render 'VL_BAR_FILL="▪"
VL_BAR_EMPTY="▫"
'
check "VL_BAR_FILL renders the override"    "$(has '▪')"
check "VL_BAR_EMPTY renders the override"   "$(has '▫')"
check "gauge overrides drop ▰ and ▱"        "$([ "$(lacks '▰')" = 1 ] && [ "$(lacks '▱')" = 1 ] && printf 1 || printf 0)"

# (5) The glyphs are independent: overriding one must not disturb the other.
render 'VL_CTX_GLYPH="◔"
'
check "VL_CTX_GLYPH leaves ⬢ alone"         "$(has '⬢')"

[ "$fail" = 0 ] && printf 'ALL PASS\n' || printf 'FAILURES\n'
exit "$fail"
