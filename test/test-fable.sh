#!/usr/bin/env bash
# End-to-end test for the opt-in `fable` segment: the weekly window of the model
# with its own limit, which Claude Code's payload does not carry. Renders the real
# statusline.sh against a fixture relay directory holding the per-session limits
# file model-relay's router writes (model-relay-status/<session_id>.limits, one
# line "window<TAB>percent<TAB>reset" per window).
#
#   bash test/test-fable.sh
#
# Exits non-zero if any case fails. Needs bash and jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg" CORALLINE_NO_SAMPLE=1
unset MODEL_RELAY_CONFIG_DIR
SDIR="$CLAUDE_CONFIG_DIR/model-relay-status"
mkdir -p "$SDIR"

printf 'VL_CLOCK=off\nVL_SEGMENTS="model fable"\n' > "$TMP/conf"
NOW=$(date +%s)
AHEAD=$(( NOW + 91800 ))   # 1d01h30m away, so a slow render still reads 1d01h

render() {  # $1=session_id → "fable <pct>% <countdown>" ("" when hidden), or BROKEN
            # when the model segment is missing too (the render failed)
  printf '{"session_id":"%s","model":{"display_name":"Opus"}}' "$1" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" |
    perl -e 'local $/; $_ = <STDIN> // ""; s/\e\[[0-9;]*m//g; print /Opus/ ? (/fable \S+ (\d+%) (\S+)/ ? "fable $1 $2" : "") : "BROKEN"'
}
limits() { printf "$2" > "$SDIR/$1.limits"; }   # $1=session_id $2=printf-format lines

fail=0
check() {  # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n      want=[%s]\n      got =[%s]\n' "$1" "$2" "$3"; fail=1; fi
}

check "no limits file"                        ""                    "$(render s1)"

limits s1 "5h\t6\t$AHEAD\n7d\t95\t$AHEAD\n7d_oi\t30\t$AHEAD\n"
check "the 7d_oi line among others"           "fable 30% ↺1d01h"    "$(render s1)"
check "another session shows nothing"         ""                    "$(render s2)"

limits s1 "5h\t6\t$AHEAD\n7d\t95\t$AHEAD\n"
check "a file without 7d_oi"                  ""                    "$(render s1)"

limits s1 "7d_oi\t30\t$(( NOW - 10 ))\n"
check "a reset already past"                  ""                    "$(render s1)"

limits s1 "7d_oi\t30\t$AHEAD\r\n"
check "a CRLF line"                           "fable 30% ↺1d01h"    "$(render s1)"

limits s1 "7d_oi\t100\t$AHEAD\n"
check "at the limit"                          "fable 100% ↺1d01h"   "$(render s1)"

limits s1 "7d_oi\tx\t$AHEAD\n"
check "a percent that is not a number"        ""                    "$(render s1)"
limits s1 "7d_oi\t30\t\$(id)\n"
check "a reset that is not a number"          ""                    "$(render s1)"
limits s1 "7d_oi\t030\t0$AHEAD\n"
check "leading zeros are decimal, not octal"  "fable 30% ↺1d01h"    "$(render s1)"
limits s1 "7d_oi\t30\t$(( NOW + 9000000 ))\n"
check "a reset further out than a week"       ""                    "$(render s1)"
limits s1 "7d_oi\t30\n"
check "a line without its reset"              ""                    "$(render s1)"
check "path-like session id refused"          ""                    "$(render ../model-relay-status/s1)"

# A second account's window finds the relay through MODEL_RELAY_CONFIG_DIR.
mkdir -p "$TMP/relay/model-relay-status"
printf '7d_oi\t42\t%s\n' "$AHEAD" > "$TMP/relay/model-relay-status/s9.limits"
check "the relay's directory, not the window's" "fable 42% ↺1d01h"  "$(MODEL_RELAY_CONFIG_DIR="$TMP/relay" render s9)"

# Not listed: the file is never opened and the default bar is unchanged.
printf 'VL_CLOCK=off\nVL_SEGMENTS="model"\n' > "$TMP/conf"
limits s1 "7d_oi\t30\t$AHEAD\n"
check "segment not listed"                    ""                    "$(render s1)"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
