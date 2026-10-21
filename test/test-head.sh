#!/usr/bin/env bash
# End-to-end test for VL_HEAD_SEGMENTS: segments drawn on a line of their own
# above the rest, in either layout. Renders the real statusline.sh under the
# bash running this file, so `/bin/bash test/...` checks bash 3.2.
#
#   bash test/test-head.sh
#
# Exits non-zero if any case fails. Needs bash, jq and git.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg" CORALLINE_NO_SAMPLE=1 GIT_CEILING_DIRECTORIES="$TMP"
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

render() {  # $1=config lines → rendered rows, ANSI and glyphs stripped to words
  printf '%b' "$1" > "$TMP/conf"
  printf '{"cwd":"%s","model":{"display_name":"Opus"},"cost":{"total_cost_usd":1.5}}' "$REPO" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=60 "$BASH" "$SCRIPT" |
    perl -pe 's/\e\[[0-9;]*m//g; s/[^\x20-\x7e\n]//g; s/ +/ /g; s/^ | $//g'
}

fail=0
check() {  # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n      want=[%s]\n      got =[%s]\n' "$1" "$2" "$3"; fail=1; fi
}
rows() { printf '%s\n' "$1" | wc -l | tr -d ' '; }
first() { printf '%s\n' "$1" | head -1; }

BASE='VL_CLOCK=off\nVL_SEGMENTS="model cost"\n'

check "fixed: head line comes first" "Opus" \
  "$(first "$(render "${BASE}VL_LAYOUT=fixed\nVL_HEAD_SEGMENTS=\"model\"\n")")"
check "fixed: head adds one row" "2" \
  "$(rows "$(render "${BASE}VL_LAYOUT=fixed\nVL_HEAD_SEGMENTS=\"model\"\n")")"
check "auto: head line comes first" "Opus" \
  "$(first "$(render "${BASE}VL_LAYOUT=auto\nVL_MAX_LINES=1\nVL_HEAD_SEGMENTS=\"model\"\n")")"
check "auto: head is not counted in VL_MAX_LINES" "2" \
  "$(rows "$(render "${BASE}VL_LAYOUT=auto\nVL_MAX_LINES=1\nVL_HEAD_SEGMENTS=\"model\"\n")")"
check "a head whose segments all hide prints nothing" "1" \
  "$(rows "$(render "${BASE}VL_LAYOUT=fixed\nVL_HEAD_SEGMENTS=\"relay\"\n")")"
case "$(first "$(render 'VL_CLOCK=off\nVL_LAYOUT=fixed\nVL_SEGMENTS="cost"\nVL_HEAD_SEGMENTS="git"\n')")" in
  *main*) check "a segment only in the head still gets its data" yes yes ;;
  *)      check "a segment only in the head still gets its data" yes no ;;
esac

exit "$fail"
