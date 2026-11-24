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
status s1 'failover\t\344\270\255\n'
check "label with nothing ASCII still shows its kind" "↪ provider · failover" "$(render s1)"
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

# ── VL_RELAY_MODEL + SEC-04 hardening ────────────────────────────────────────
render_plain() {  # $1=session_id $2=conf $3=effort(optional) → ANSI-stripped rows joined by " | "
  local rsid="$1" rconf="$2" reff="${3:-}" payload
  if [ -n "$reff" ]; then
    payload="{\"session_id\":\"$rsid\",\"model\":{\"display_name\":\"Opus\"},\"effort\":{\"level\":\"$reff\"}}"
  else
    payload="{\"session_id\":\"$rsid\",\"model\":{\"display_name\":\"Opus\"}}"
  fi
  printf '%s' "$payload" |
    CORALLINE_CONFIG="$rconf" COLUMNS=200 "$BASH" "$SCRIPT" |
    perl -0777 -ne '
      s/\e\[[0-9;]*m//g;
      s/\xee\x82[\xb0\xb4\xb6]/ /g;
      my @rows = map { s/^\s+|\s+$//g; s/\s+/ /g; $_ } grep { /\S/ } split /\n/;
      print join(" | ", @rows);
    '
}

# 1. Inherited relay/relay_kind/relay_effort env vars must never leak into output
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_SEGMENTS="model effort"\n' > "$TMP/conf_me"
raw_clean=$(
  printf '{"session_id":"s_none","model":{"display_name":"Opus"},"effort":{"level":"high"}}' |
    CORALLINE_CONFIG="$TMP/conf_me" COLUMNS=200 "$BASH" "$SCRIPT"
)
raw_env=$(
  printf '{"session_id":"s_none","model":{"display_name":"Opus"},"effort":{"level":"high"}}' |
    relay=$'\033[31mINJ' relay_kind=pinned relay_effort=$'\033]0;X\007' \
    CORALLINE_CONFIG="$TMP/conf_me" COLUMNS=200 "$BASH" "$SCRIPT"
)
env_ok="MATCH"
[ "$raw_env" = "$raw_clean" ] || env_ok="DIFF"
case "$raw_env" in (*INJ*|*$'\033]'*|*$'\007'*) env_ok="LEAK" ;; esac
check "inherited relay env vars cleared (byte-identical, no escape leak)" "MATCH" "$env_ok"
check "inherited relay env vars render Claude model/effort" "◆ Opus ψ high" \
  "$(printf '%s' "$raw_env" | perl -0777 -ne '
      s/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g;
      s/^\s+|\s+$//g; s/\s+/ /g; print;
    ')"

# 2. Empty 2nd field must not shift 3rd field into relay (no IFS whitespace collapsing)
status s_empty2 'pinned\t\txhigh\n'
check "empty 2nd field -> provider + xhigh (no shift)" "◆ provider ψ xhigh" \
  "$(render_plain s_empty2 "$TMP/conf_me" low)"

# 3. CRLF 3-field: VL_RELAY_MODEL=1 shows relay model/effort & hides duplicate pinned relay;
#    VL_RELAY_MODEL=0 preserves Claude model/effort & shows head relay
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_HEAD_SEGMENTS="relay"\nVL_SEGMENTS="model effort"\n' > "$TMP/conf_head1"
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=0\nVL_HEAD_SEGMENTS="relay"\nVL_SEGMENTS="model effort"\n' > "$TMP/conf_head0"
status s_crlf 'pinned\tacp-gemini-4-neon[1m]\txhigh\r\n'
check "CRLF 3-field under VL_RELAY_MODEL=1 (no duplicate head relay)" \
  "◆ acp-gemini-4-neon ψ xhigh" "$(render_plain s_crlf "$TMP/conf_head1" high)"
check "CRLF 3-field under VL_RELAY_MODEL=0 (unchanged Claude + head relay)" \
  "↪ acp-gemini-4-neon | ◆ Opus ψ high" "$(render_plain s_crlf "$TMP/conf_head0" high)"

# 4. Crafted ANSI/OSC/bidi/unknown 3rd field dropped cleanly (falls back to payload effort)
status s_bad1 'pinned\tgemini-4\t\033[31mhigh\n'
check "ANSI in 3rd field rejected (falls back to payload effort)" \
  "◆ gemini-4 ψ low" "$(render_plain s_bad1 "$TMP/conf_me" low)"
status s_bad2 'pinned\tgemini-4\tgarbage\n'
check "unknown 3rd field rejected (falls back to payload effort)" \
  "◆ gemini-4 ψ low" "$(render_plain s_bad2 "$TMP/conf_me" low)"
status s_bad3 'pinned\tgemini-4\t\033]0;X\007\n'
check "OSC in 3rd field rejected (hidden when payload effort absent)" \
  "◆ gemini-4" "$(render_plain s_bad3 "$TMP/conf_me")"
status s_bad4 'pinned\tgemini-4\t\342\200\256high\n'
check "bidi in 3rd field rejected (falls back to payload effort)" \
  "◆ gemini-4 ψ low" "$(render_plain s_bad4 "$TMP/conf_me" low)"
status s_med 'pinned\tgemini-4\tmedium\n'
check "medium in 3rd field normalized to med" \
  "◆ gemini-4 ψ med" "$(render_plain s_med "$TMP/conf_me" low)"

# 5. Symlinked status file and leading-dot session_id refused
status s_target 'pinned\tacp-gemini-4-neon\txhigh\n'
ln -s "$SDIR/s_target" "$SDIR/s_link"
check "symlinked status file skipped" \
  "◆ Opus ψ low" "$(render_plain s_link "$TMP/conf_head1" low)"
status .dot_sid 'pinned\tacp-gemini-4-neon\txhigh\n'
check "leading-dot session_id refused" \
  "◆ Opus ψ low" "$(render_plain .dot_sid "$TMP/conf_head1" low)"

# 6. pinned claude/acct2 stays Claude in model/effort and still shows relay
status s_acct2 'pinned\tclaude/acct2\txhigh\n'
check "pinned claude/acct2 keeps Claude model/effort and relay" \
  "↪ claude/acct2 | ◆ Opus ψ high" "$(render_plain s_acct2 "$TMP/conf_head1" high)"

# 7. failover updates model/effort AND still shows relay with failover note
status s_fo 'failover\tglm-5.3[1m]\thigh\n'
check "failover updates model/effort and keeps relay note" \
  "↪ glm-5.3 · failover | ◆ glm-5.3 ψ high" "$(render_plain s_fo "$TMP/conf_head1" low)"

# 8. offline keeps Claude model and still shows offline relay
status s_off 'offline\toffline\n'
check "offline keeps Claude model and shows relay" \
  "↪ offline | ◆ Opus ψ high" "$(render_plain s_off "$TMP/conf_head1" high)"

# 9. Layout without model segment in _SEG_ROWS still shows pinned relay
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_SEGMENTS="relay"\n' > "$TMP/conf_relay_only"
status s_ro 'pinned\tacp-gemini-4-neon\n'
check "VL_RELAY_MODEL=1 without model segment still shows pinned relay" \
  "↪ acp-gemini-4-neon" "$(render_plain s_ro "$TMP/conf_relay_only")"

# 9b. The duplicate check follows what is drawn, not every configured row
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_LAYOUT=auto\nVL_SEGMENTS="relay"\nVL_SEGMENTS2="model"\n' > "$TMP/conf_auto2"
check "auto layout: model only in VL_SEGMENTS2 (not drawn) keeps pinned relay" \
  "↪ acp-gemini-4-neon" "$(render_plain s_ro "$TMP/conf_auto2")"
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_SEGMENTS="relay"\nVL_SEGMENTS2="model"\n' > "$TMP/conf_fixed2"
check "fixed layout: model on row 2 hides the duplicate pinned relay" \
  "◆ acp-gemini-4-neon" "$(render_plain s_ro "$TMP/conf_fixed2")"
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_SEGMENTS="model"\nVL_FLOAT=1\nVL_FLOAT_SEGMENTS="relay"\nVL_FLOAT_FILE=%s\n' "$TMP/float.txt" > "$TMP/conf_float"
render_plain s_ro "$TMP/conf_float" >/dev/null
check "float without model keeps pinned relay" "↪ acp-gemini-4-neon" "$(cat "$TMP/float.txt" 2>/dev/null)"

# 10. Wizard preview stand-in still shown under VL_RELAY_MODEL=1
printf 'VL_CLOCK=off\nVL_RELAY_MODEL=1\nVL_SEGMENTS="model relay"\nVL_RELAY_PREVIEW=glm\n' > "$TMP/conf_prev1"
check "preview stand-in shown under VL_RELAY_MODEL=1" \
  "◆ Opus ↪ glm" "$(render_plain s_none "$TMP/conf_prev1")"

exit "$fail"
