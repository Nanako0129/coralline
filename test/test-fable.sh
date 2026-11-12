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

# The physical path: the state stores refuse a path with a symlink in it, and
# macOS hands out temp dirs under /var, a link to /private/var.
TMP=$(cd "$(mktemp -d)" && pwd -P)
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

# ── limit5h / limit7d fall back to the session's own windows ───────────────────
# With no payload reading (a session just started or resumed) the gauges take the
# relay's file for this session before the shared store, which cannot say whose
# its entries are. A payload reading always wins.
R5=$(( NOW + 9000 )); R7=$(( NOW + 400000 ))
# Payloads are built here, outside any command substitution: bash 3.2 mangles
# escaped quotes nested inside "$(...)".
RL_BOTH=$(printf '{"five_hour":{"used_percentage":5,"resets_at":%s},"seven_day":{"used_percentage":6,"resets_at":%s}}' "$R5" "$R7")
RL_7D=$(printf '{"seven_day":{"used_percentage":6,"resets_at":%s}}' "$R7")
gauges() {  # $1=session_id $2=rate_limits JSON ("" = none) → "5h N% 7d N%" as drawn
  local rl=""; [ -z "$2" ] || rl=',"rate_limits":'"$2"
  printf '{"session_id":"%s","model":{"display_name":"Opus"}%s}' "$1" "$rl" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" |
    perl -e 'local $/; $_ = <STDIN> // ""; s/\e\[[0-9;]*m//g; my @o; push @o, "$1 $2" while /\b(5h|7d) \S+ (\d+%)/g; print /Opus/ ? join(" ", @o) : "BROKEN"'
}
limits s1 "5h\t61\t$R5\n7d\t10\t$R7\n7d_oi\t30\t$AHEAD\n"
export CORALLINE_NO_SAMPLE=1
for sync in 0 1; do
  printf 'VL_CLOCK=off\nVL_SEGMENTS="model limit5h limit7d"\nVL_LIMIT_SYNC=%s\n' "$sync" > "$TMP/conf"
  check "sync=$sync: off by default, the file is not used"          ""              "$(gauges s1 '')"
  printf 'VL_CLOCK=off\nVL_SEGMENTS="model limit5h limit7d"\nVL_LIMIT_SYNC=%s\nVL_RELAY_LIMITS=1\n' "$sync" > "$TMP/conf"
  check "sync=$sync: no payload window, own windows from the file"  "5h 61% 7d 10%" "$(gauges s1 '')"
  check "sync=$sync: another session has no file"                   ""              "$(gauges s2 '')"
  check "sync=$sync: a payload reading wins over the file"          "5h 5% 7d 6%"   "$(gauges s1 "$RL_BOTH")"
  # a payload with 7d but no 5h has no 5h window (#112): the file does not bring one back
  check "sync=$sync: payload 7d only, no 5h gauge from the file"    "7d 6%"         "$(gauges s1 "$RL_7D")"
  # listing fable reads the file anyway; it must not change what the gauges draw
  printf 'VL_CLOCK=off\nVL_SEGMENTS="model limit5h limit7d fable"\nVL_LIMIT_SYNC=%s\n' "$sync" > "$TMP/conf"
  check "sync=$sync: fable listed, knob off: gauges unchanged"      ""              "$(gauges s1 '')"
done
# With the sync, the file beats the shared store: a later window stored by another
# account in this config dir is not shown to a session with its own windows on file.
printf 'VL_CLOCK=off\nVL_SEGMENTS="model limit5h limit7d"\nVL_LIMIT_SYNC=1\nVL_RELAY_LIMITS=1\n' > "$TMP/conf"
S5="$CLAUDE_CONFIG_DIR/coralline/limit-5h.d"; S7="$CLAUDE_CONFIG_DIR/coralline/limit-7d.d"
mkdir -p "$S5/$(printf '%010d' $(( R5 + 600 )))_042.000" "$S7/$(printf '%010d' $(( R7 + 600 )))_043.000"
check "sync=1: own file beats a later stored window"    "5h 61% 7d 10%" "$(gauges s1 '')"
check "sync=1: without a file the store still fills in" "5h 42% 7d 43%" "$(gauges s2 '')"
# The same reset with a higher percent in the store is the same window read later
# by another session: the file's older value does not replace it.
rm -rf "$CLAUDE_CONFIG_DIR/coralline"; mkdir -p "$S5/$(printf '%010d' "$R5")_080.000" "$S7/$(printf '%010d' "$R7")_005.000"
check "sync=1: same window, the store's higher reading is kept" "5h 80% 7d 10%" "$(gauges s1 '')"
rm -rf "$CLAUDE_CONFIG_DIR/coralline"
# a 5h line further out than a 5h window can be is not one
limits s3 "5h\t61\t$(( NOW + 90000 ))\n"
check "a 5h reset further out than its window" "" "$(gauges s3 '')"

# ── the reader ─────────────────────────────────────────────────────────────────
printf 'VL_CLOCK=off\nVL_SEGMENTS="model fable"\n' > "$TMP/conf"
printf '5h\t6\t%s\n7d_oi\t30\t%s' "$R5" "$AHEAD" > "$SDIR/s4.limits"
check "a last line without a newline is read"   "fable 30% ↺1d01h"  "$(render s4)"
limits s4 "7d_oi\t150\t$AHEAD\n"
check "a percent past 100 is drawn as 100"      "fable 100% ↺1d01h" "$(render s4)"
limits s4 "7d_oi\t250\t$AHEAD\n"
check "a percent past 200 is not a percent"     ""                  "$(render s4)"
limits s4 "junk\n7d_oi\tx\t$AHEAD\n7d_oi\t31\t$AHEAD\n"
check "a bad line does not end the read"        "fable 31% ↺1d01h"  "$(render s4)"
if [ "$(id -u)" != 0 ]; then
  limits s5 "7d_oi\t30\t$AHEAD\n"; chmod 000 "$SDIR/s5.limits"
  ERR=$(printf '{"session_id":"s5","model":{"display_name":"Opus"}}' | CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" 2>&1 >/dev/null)
  chmod 644 "$SDIR/s5.limits"
  check "an unreadable file leaves stderr empty" "" "$ERR"
fi
# the wizard preview has no file: it names a percent
printf 'VL_CLOCK=off\nVL_SEGMENTS="model fable"\nVL_FABLE_PREVIEW=30\n' > "$TMP/conf"
OUTP=$(printf '{"session_id":"nofile","model":{"display_name":"Opus"}}' | CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 "$BASH" "$SCRIPT" | perl -pe 's/\e\[[0-9;]*m//g')
case "$OUTP" in (*"fable "*"30%"*) check "preview stand-in shown" x x ;; (*) check "preview stand-in shown" "fable 30%" "$OUTP" ;; esac

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
