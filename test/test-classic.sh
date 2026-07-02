#!/usr/bin/env bash
# End-to-end test for VL_STYLE="classic": runs the REAL statusline.sh against a
# canned payload and asserts the rendered bytes, so the config-load fold is
# exercised through the whole pipeline (not just an extracted block). In
# particular it pins the fold's raison d'être — under VL_ASCII the cap drops but
# the bar still paints — which a variable-level unit test cannot prove.
#
#   bash test/test-classic.sh
#
# Needs jq (statusline.sh parses JSON) and test/sample-input.json.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
CONF_TMPL="$HERE/../themes/claude-coral.conf"
SAMPLE="$HERE/sample-input.json"
CAP=$(printf '\xee\x82\xb0')     # U+E0B0 — the trailing powerline cap glyph

fail=0
ok()    { printf 'ok    %s\n' "$1"; }
bad()   { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }

# Render statusline.sh with VL_STYLE=classic plus any extra config lines ($1),
# against the sample payload, in an isolated config so no cross-session store is
# touched (CORALLINE_NO_SAMPLE, #32). Output lands in $out.
render() {
  local extra="${1:-}" conf
  conf=$(mktemp "${TMPDIR:-/tmp}/coralline-classic.XXXXXX") || exit 1
  {
    printf '. %s\n' "$CONF_TMPL"
    printf 'VL_STYLE="classic"\n'
    printf 'VL_SEGMENTS="dir git model clock"\nVL_SEGMENTS2=""\n'
    printf 'VL_CLOCK="24h"\nVL_CLOCK_SECONDS=0\n'
    printf '%s' "$extra"
  } > "$conf"
  out=$(CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$SAMPLE")
  rm -f "$conf"
}

# (1) Default classic: one uniform 238 bar behind the row AND a trailing cap.
render ""
case "$out" in (*'[48;5;238m'*) check "classic paints the default 238 bar" 1 ;;
               (*)              check "classic paints the default 238 bar" 0 ;; esac
case "$out" in (*"$CAP"*) check "classic draws the trailing cap glyph" 1 ;;
               (*)        check "classic draws the trailing cap glyph" 0 ;; esac

# (2) The fold's reason for existing: under VL_ASCII the cap drops (VL_SEP was
#     cleared before the fold) but the bar still paints.
render 'VL_ASCII=1
'
case "$out" in (*'[48;5;238m'*) check "classic+ASCII keeps the bar" 1 ;;
               (*)              check "classic+ASCII keeps the bar" 0 ;; esac
case "$out" in (*"$CAP"*) check "classic+ASCII drops the cap glyph" 0 ;;
               (*)        check "classic+ASCII drops the cap glyph" 1 ;; esac

# (3) VL_BG_BAR feeds the bar colour when no explicit VL_LEAN_BG is set.
render 'VL_BG_BAR=234
'
case "$out" in (*'[48;5;234m'*) check "VL_BG_BAR sets the bar colour" 1 ;;
               (*)              check "VL_BG_BAR sets the bar colour" 0 ;; esac

# (4) An explicit VL_LEAN_BG overrides both VL_BG_BAR and the 238 default.
render 'VL_BG_BAR=234
VL_LEAN_BG="1,2,3"
'
case "$out" in (*'[48;2;1;2;3m'*) check "explicit VL_LEAN_BG overrides VL_BG_BAR" 1 ;;
                 (*)              check "explicit VL_LEAN_BG overrides VL_BG_BAR" 0 ;; esac

# (5) The wizard's index→style map (pure helper pulled live from configure.sh).
eval "$(sed -n '/^style_from_index() {/,/^}/p' "$HERE/../configure.sh")"
{ [ "$(style_from_index 0)" = pill ] && [ "$(style_from_index 1)" = lean ] \
  && [ "$(style_from_index 2)" = classic ]; } \
  && check "style_from_index maps 0/1/2 -> pill/lean/classic" 1 \
  || check "style_from_index maps 0/1/2 -> pill/lean/classic" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
