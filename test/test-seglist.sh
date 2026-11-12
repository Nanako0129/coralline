#!/usr/bin/env bash
# End-to-end regressions for how segment lists and paths are split:
#   - a tab or a newline between segment names must still run the segment's
#     sampler (the scan used to match only space-separated names),
#   - seg_dir must not glob-expand a directory name while splitting the path,
#   - the float file is written without a fork for its directory and without
#     noise on stderr when it cannot be written.
#
#   bash test/test-seglist.sh
#
# Exits non-zero if any case fails. Needs bash, jq and git.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
REPO=$(cd "$HERE/.." && pwd)

# The physical path: macOS hands out temp dirs under /var, a link to /private/var.
TMP=$(cd "$(mktemp -d)" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg" CORALLINE_NO_SAMPLE=1
mkdir -p "$CLAUDE_CONFIG_DIR"

fail=0
check() {  # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n      want=[%s]\n      got =[%s]\n' "$1" "$2" "$3"; fail=1; fi
}
plain() { perl -pe 's/\e\[[0-9;]*m//g'; }
render() {  # $1=cwd; conf is $TMP/conf → plain text of the bar
  printf '{"cwd":"%s","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"}}' "$1" "$1" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" 2>"$TMP/err" | plain
}
has() { case "$2" in (*"$1"*) echo yes ;; (*) echo no ;; esac; }

# ── segment names separated by a tab or a newline ─────────────────────────────
printf 'VL_CLOCK=off\nVL_SEGMENTS="model git"\n' > "$TMP/conf"
check "space-separated list draws git"   yes "$(has '⎇' "$(render "$REPO")")"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model\tgit"\n' > "$TMP/conf"
check "tab-separated list draws git"     yes "$(has '⎇' "$(render "$REPO")")"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model\ngit"\n' > "$TMP/conf"
check "newline-separated list draws git" yes "$(has '⎇' "$(render "$REPO")")"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_HEAD_SEGMENTS="\tgit\t"\n' > "$TMP/conf"
check "a head list padded with tabs draws git" yes "$(has '⎇' "$(render "$REPO")")"

# ── a directory name with glob characters ─────────────────────────────────────
# The render runs with $TMP/w as its working directory, where the pattern would
# match real entries.
# Windows file systems refuse * and ? in a name, so these run where the
# directories can be made.
GLOBDIRS=1
mkdir -p "$TMP/w/a*b" "$TMP/w/a1b" "$TMP/w/a22b" "$TMP/w/x?y" "$TMP/w/[abc]" 2>/dev/null || GLOBDIRS=0
if [ "$GLOBDIRS" = 1 ]; then
# A long path is collapsed to its first two parts and its last one, taken from
# the split, so an expanded component changes what is shown.
printf 'VL_CLOCK=off\nVL_SEGMENTS="dir"\nVL_PATH_DEPTH=3\n' > "$TMP/conf"
for d in 'a*b' 'x?y' '[abc]'; do
  out=$(cd "$TMP/w" && render "$TMP/w/$d")
  check "seg_dir keeps the name $d" yes "$(has "/…/$d " "$out")"
done
out=$(cd "$TMP/w" && render "$TMP/w/a*b")
check "seg_dir does not expand a*b to its matches" no "$(has 'a22b' "$out")"
fi
# a segment name with a glob character is not turned into a matching file name
mkdir -p "$TMP/g"; : > "$TMP/g/git"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model g?t"\n' > "$TMP/conf"
out=$(cd "$TMP/g" && render "$REPO")
check "a globbing segment name draws nothing" no "$(has '⎇' "$out")"
# noglob set in coralline.conf is still set when the segments are built
printf 'VL_CLOCK=off\nVL_SEGMENTS="model dir"\nset -f\nseg_probe() { case $- in (*f*) push 1 " noglob-kept " ;; (*) push 1 " noglob-lost " ;; esac; }\nVL_SEGMENTS="model probe"\n' > "$TMP/conf"
check "noglob from the config survives" yes "$(has 'noglob-kept' "$(render "$REPO")")"
# no helper is named like a segment (the wizard lists every seg_* function)
check "no seg_ helper for the list split" "" "$(grep -oE '^seg_(words|list)[a-z_]*' "$SCRIPT")"

# ── the float file ────────────────────────────────────────────────────────────
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="%s"\n' "$TMP/new/deep/float.txt" > "$TMP/conf"
render "$REPO" >/dev/null
check "float file created in a directory that did not exist" yes "$([ -f "$TMP/new/deep/float.txt" ] && echo yes || echo no)"
check "float file holds the segment" yes "$(has 'Opus' "$(cat "$TMP/new/deep/float.txt" 2>/dev/null)")"
check "no temp file left beside it" "" "$(ls -A "$TMP/new/deep" | grep -v '^float.txt$')"
# path shapes: a bare file name (written in the working directory), an existing
# directory and a trailing slash (both skipped, nothing left behind)
mkdir -p "$TMP/cwd" "$TMP/isdir"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="bare-float.txt"\n' > "$TMP/conf"
( cd "$TMP/cwd" && render "$REPO" >/dev/null )
check "a bare float file name lands in the working directory" yes "$(has 'Opus' "$(cat "$TMP/cwd/bare-float.txt" 2>/dev/null)")"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="%s"\n' "$TMP/isdir" > "$TMP/conf"
render "$REPO" >/dev/null
check "a float path that is a directory gets nothing put inside it" "" "$(ls -A "$TMP/isdir")"
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="%s/"\n' "$TMP/ts/sub" > "$TMP/conf"
render "$REPO" >/dev/null
check "a float path with a trailing slash creates nothing" no "$([ -e "$TMP/ts" ] && echo yes || echo no)"
if [ "$(id -u)" != 0 ] && [ "$GLOBDIRS" = 1 ]; then   # chmod does not block writes on Windows either
  mkdir -p "$TMP/ro"; chmod 500 "$TMP/ro"
  printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="%s"\n' "$TMP/ro/float.txt" > "$TMP/conf"
  out=$(render "$REPO")
  check "an unwritable float dir still draws the bar" yes "$(has 'Opus' "$out")"
  check "an unwritable float dir leaves stderr empty" "" "$(cat "$TMP/err")"
  printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="model"\nVL_FLOAT_FILE="%s"\n' "$TMP/ro/sub/float.txt" > "$TMP/conf"
  out=$(render "$REPO")
  check "a float dir that cannot be created leaves stderr empty" "" "$(cat "$TMP/err")"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
