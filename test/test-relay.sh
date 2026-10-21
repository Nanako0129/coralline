#!/usr/bin/env bash
# End-to-end test for the opt-in `relay` segment, which shows the model this
# session talks to through model-relay. Renders the real statusline.sh against a
# fixture CLAUDE_CONFIG_DIR holding the per-session status file model-relay's
# hook writes (model-relay-status/<session_id>, one line "kind<TAB>label").
# Renders run under the bash running this file, so `/bin/bash test/...` checks
# bash 3.2.
#
#   bash test/test-relay.sh
#
# Exits non-zero if any case fails. Needs bash and jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CLAUDE_CONFIG_DIR="$TMP/cfg" CORALLINE_NO_SAMPLE=1
SDIR="$CLAUDE_CONFIG_DIR/model-relay-status"
mkdir -p "$SDIR"

printf 'VL_CLOCK=off\nVL_SEGMENTS="model relay"\n' > "$TMP/conf"

render() {  # $1=session_id ("-" = none) → the relay text ("" when hidden), or
            # BROKEN when the model segment is missing too (the render failed)
  local payload='{"model":{"display_name":"Opus"}}'
  [ "$1" = - ] || payload="{\"session_id\":\"$1\",\"model\":{\"display_name\":\"Opus\"}}"
  printf '%s' "$payload" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" |
    perl -e 'local $/; $_ = <STDIN> // ""; print /Opus/ ? (/(\x{e2}\x{86}\x{aa} [^\e]*?) *(?:\e|$)/ ? $1 : "") : "BROKEN"'
}
status() { printf "$2" > "$SDIR/$1"; }   # $1=session_id $2=printf-format line

fail=0
check() {  # $1=label $2=expected $3=actual
  if [ "$3" = "$2" ]; then printf 'ok    %s\n' "$1"
  else printf 'FAIL  %s\n      want=[%s]\n      got =[%s]\n' "$1" "$2" "$3"; fail=1; fi
}

check "no status file"                         ""   "$(render s1)"

status s1 'claude\tclaude\n'
check "on Claude through the relay"            "↪ claude"                  "$(render s1)"
check "another session shows nothing"          ""                          "$(render s2)"
check "payload without session_id"             ""                          "$(render -)"
status s1 'pinned\taistudio-gemini-4-argon\n'
check "pinned to a provider's model"           "↪ aistudio-gemini-4-argon" "$(render s1)"
status s1 'failover\tglm-5.3[1m]\n'
check "failover, [1m] hint stripped"           "↪ glm-5.3 · failover"      "$(render s1)"
status s1 'limit\tclaude\n'
check "Claude's limit, nobody to hand over to" "↪ claude · limit"         "$(render s1)"
status s1 'offline\toffline\n'
check "relay offline"                          "↪ offline"                 "$(render s1)"
status s1 'direct\tclaude\n'
check "relay down, talking to Claude directly" "↪ claude · direct"         "$(render s1)"

status s1 'pinned\tgem\033[31mini\n'
check "escape sequence in the label dropped"   "↪ gem31mini"               "$(render s1)"
status s1 'surprise\tsomething\n'
check "unknown kind hidden"                    ""                          "$(render s1)"
status s1 'pinned\tgemini'
check "line caught mid-write (no newline) hidden" ""                       "$(render s1)"
status s1 'pinned\tgemini\n'
check "path-like session id refused"           ""                          "$(render ../model-relay-status/s1)"

# a FIFO at the session's name must not block the render
mkfifo "$SDIR/s3"
printf '{"session_id":"s3","model":{"display_name":"Opus"}}' |
  CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" > "$TMP/fout" &
fp=$!; i=0
while kill -0 "$fp" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$fp" 2>/dev/null; then
  : <> "$SDIR/s3"; wait "$fp"
  echo "FAIL  FIFO at the status path blocked the render"; fail=1
else
  wait "$fp"; case "$(cat "$TMP/fout")" in *Opus*) echo "ok    FIFO at the status path skipped" ;; *) echo "FAIL  FIFO render broken"; fail=1 ;; esac
fi

# the wizard preview's stand-in (configure.sh render_preview)
printf 'VL_CLOCK=off\nVL_SEGMENTS="model relay"\nVL_RELAY_PREVIEW=glm\n' > "$TMP/conf"
check "preview stand-in shown" "↪ glm" "$(render s2)"

exit "$fail"
