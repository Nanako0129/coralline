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

# ── VL_RELAY_ISOLATE ─────────────────────────────────────────────────────────
# Seed live Claude and agy-gemini synced stores in a dedicated non-symlinked dir.
ITMP=$(cd "$TMP" && pwd -P)/iso
mkdir -p "$ITMP/cfg/model-relay-status"
now=$(date +%s)
iso_utc() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}
R5=$(( now + 7200 )); R7=$(( now + 3 * 86400 ))
R5_ISO=$(iso_utc "$R5"); R7_ISO=$(iso_utc "$R7")

printf 'VL_CLOCK=off\nVL_LIMIT_SYNC=1\nVL_SEGMENTS="model limit5h limit7d burn"\n' > "$ITMP/seed.conf"
# Seed Claude synced stores (5h 82%, 7d 61%)
printf '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":82,"resets_at":%s},"seven_day":{"used_percentage":61,"resets_at":%s}}}' "$R5" "$R7" |
  CLAUDE_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=0 CORALLINE_CONFIG="$ITMP/seed.conf" COLUMNS=200 "$BASH" "$SCRIPT" >/dev/null
# Seed agy-gemini synced stores (5h 24%, 7d 18%)
printf '{"product":"antigravity","model":{"display_name":"Gemini 4 Neon (High)"},"quota":{"gemini-5h":{"remaining_fraction":0.76,"reset_time":"%s","reset_in_seconds":7200},"gemini-weekly":{"remaining_fraction":0.82,"reset_time":"%s","reset_in_seconds":259200}}}' "$R5_ISO" "$R7_ISO" |
  CLAUDE_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=0 CORALLINE_CONFIG="$ITMP/seed.conf" COLUMNS=200 "$BASH" "$SCRIPT" >/dev/null

# Per-session Claude limits file (would supply fable & own5/7 if not isolated)
printf '5h\t77\t%s\n7d\t55\t%s\n7d_oi\t44\t%s\n' "$R5" "$R7" "$R7" > "$ITMP/cfg/model-relay-status/s_glm.limits"
printf '5h\t77\t%s\n7d\t55\t%s\n7d_oi\t44\t%s\n' "$R5" "$R7" "$R7" > "$ITMP/cfg/model-relay-status/s_acp.limits"
printf '5h\t77\t%s\n7d\t55\t%s\n7d_oi\t44\t%s\n' "$R5" "$R7" "$R7" > "$ITMP/cfg/model-relay-status/s_cl.limits"

printf 'pinned\tglm-5.3[1m]\thigh\n'            > "$ITMP/cfg/model-relay-status/s_glm"
printf 'pinned\tacp-gemini-4-neon[1m]\txhigh\n' > "$ITMP/cfg/model-relay-status/s_acp"
printf 'pinned\tclaude/acct2\thigh\n'           > "$ITMP/cfg/model-relay-status/s_cl"

# Config without relay/VL_RELAY_MODEL to prove VL_RELAY_ISOLATE samples relay status on its own
printf 'VL_CLOCK=off\nVL_LIMIT_SYNC=1\nVL_RELAY_LIMITS=1\nVL_COST_ALWAYS_SHOW=1\nVL_RELAY_ISOLATE=1\nVL_SEGMENTS="model limit5h limit7d fable burn cost"\n' > "$ITMP/iso1.conf"
printf 'VL_CLOCK=off\nVL_LIMIT_SYNC=1\nVL_RELAY_LIMITS=1\nVL_COST_ALWAYS_SHOW=1\nVL_RELAY_ISOLATE=0\nVL_SEGMENTS="model limit5h limit7d fable burn cost"\n' > "$ITMP/iso0.conf"
printf 'VL_CLOCK=off\nVL_LIMIT_SYNC=0\nVL_RELAY_LIMITS=1\nVL_COST_ALWAYS_SHOW=1\nVL_RELAY_ISOLATE=1\nVL_SEGMENTS="model limit5h limit7d fable burn cost"\n' > "$ITMP/iso1_nosync.conf"

iso_render() {  # $1=sid $2=conf $3=with_claude_rl(0|1) → plain text
  local p
  if [ "$3" = 1 ]; then
    p="{\"session_id\":\"$1\",\"model\":{\"display_name\":\"Opus\"},\"cost\":{\"total_cost_usd\":14.22},\"rate_limits\":{\"five_hour\":{\"used_percentage\":82,\"resets_at\":$R5},\"seven_day\":{\"used_percentage\":61,\"resets_at\":$R7}}}"
  else
    p="{\"session_id\":\"$1\",\"model\":{\"display_name\":\"Opus\"},\"cost\":{\"total_cost_usd\":14.22}}"
  fi
  printf '%s' "$p" |
    CLAUDE_CONFIG_DIR="$ITMP/cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=1 \
    CORALLINE_CONFIG="$2" COLUMNS=200 "$BASH" "$SCRIPT" |
    perl -0777 -ne '
      s/\e\[[0-9;]*m//g;
      s/\xee\x82[\xb0\xb4\xb6]/ /g;
      s/^\s+|\s+$//g; s/\s+/ /g; print;
    '
}
iso_summary() {  # strip reset countdowns & bar glyphs for deterministic checks
  printf '%s' "$1" | perl -ne '
    my @m;
    push @m, "5h:$1"    if /5h [▰▱]+ (\d+%)/;
    push @m, "7d:$1"    if /7d [▰▱]+ (\d+%)/;
    push @m, "fable:$1" if /fable [▰▱]+ (\d+%)/;
    push @m, "burn"     if /↗/;
    push @m, "cost:$1"  if /(\$\d+\.\d+)/;
    print join(" ", @m);
  '
}

# 11. VL_RELAY_ISOLATE=0 keeps default Claude cost/limits/fable on non-Claude routes
check "VL_RELAY_ISOLATE=0 leaves non-Claude route untouched" \
  "5h:82% 7d:61% fable:44% burn cost:\$14.22" \
  "$(iso_summary "$(iso_render s_acp "$ITMP/iso0.conf" 0)")"

# 12. VL_RELAY_ISOLATE=1 on non-agy provider (glm-5.3) hides cost, fable, limits, burn (even with stale Claude RL in payload)
check "VL_RELAY_ISOLATE=1 on glm hides cost, fable, limits, burn" \
  "" \
  "$(iso_summary "$(iso_render s_glm "$ITMP/iso1.conf" 1)")"

# 13. VL_RELAY_ISOLATE=1 on acp-gemini* hides cost & fable, reads agy-gemini synced stores (24% / 18%) instead of Claude (82% / 61%)
check "VL_RELAY_ISOLATE=1 on acp-gemini reads agy-gemini synced limits and hides cost/fable" \
  "5h:24% 7d:18% burn" \
  "$(iso_summary "$(iso_render s_acp "$ITMP/iso1.conf" 1)")"

# 14. VL_RELAY_ISOLATE=1 on acp-gemini* with VL_LIMIT_SYNC=0 hides limits, burn, cost, fable
check "VL_RELAY_ISOLATE=1 on acp-gemini with sync off hides everything Claude-only" \
  "" \
  "$(iso_summary "$(iso_render s_acp "$ITMP/iso1_nosync.conf" 1)")"

# 15. VL_RELAY_ISOLATE=1 on acp-gemini* with empty agy stores hides limits/burn cleanly
mkdir -p "$ITMP/empty_cfg/model-relay-status"
printf 'pinned\tacp-gemini-4-neon[1m]\txhigh\n' > "$ITMP/empty_cfg/model-relay-status/s_acp"
empty_out=$(printf '{"session_id":"s_acp","model":{"display_name":"Opus"},"cost":{"total_cost_usd":9.99}}' |
  CLAUDE_CONFIG_DIR="$ITMP/empty_cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/empty_cfg" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; print;')
check "VL_RELAY_ISOLATE=1 on acp-gemini with no agy store hides limits/burn/cost" \
  "" "$(iso_summary "$empty_out")"

# 16. VL_RELAY_ISOLATE=1 on Claude route (pinned claude/acct2) keeps Claude cost, fable, limits, burn
check "VL_RELAY_ISOLATE=1 on pinned claude/acct2 keeps Claude segments" \
  "5h:82% 7d:61% fable:44% burn cost:\$14.22" \
  "$(iso_summary "$(iso_render s_cl "$ITMP/iso1.conf" 1)")"

# 17. VL_RELAY_ISOLATE=1 on acp-gemini* is strictly read-only even with CORALLINE_NO_SAMPLE=0
mkdir -p "$ITMP/ro_cfg/coralline/limit-5h-agy-gemini.d" "$ITMP/ro_cfg/model-relay-status"
cp -R "$ITMP/cfg/coralline/." "$ITMP/ro_cfg/coralline/"
printf 'pinned\tacp-gemini-4-neon[1m]\txhigh\n' > "$ITMP/ro_cfg/model-relay-status/s_acp"
EXPIRED_ENT=$(printf '%010d_050.000' "$(( now - 600 ))")
mkdir -p "$ITMP/ro_cfg/coralline/limit-5h-agy-gemini.d/$EXPIRED_ENT"
before_ro=$(cd "$ITMP/ro_cfg/coralline" && find . | LC_ALL=C sort)
ro_out=$(printf '{"session_id":"s_acp","model":{"display_name":"Opus"},"cost":{"total_cost_usd":14.22},"rate_limits":{"five_hour":{"used_percentage":82,"resets_at":%s},"seven_day":{"used_percentage":61,"resets_at":%s}}}' "$R5" "$R7" |
  CLAUDE_CONFIG_DIR="$ITMP/ro_cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/ro_cfg" CORALLINE_NO_SAMPLE=0 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; s/^\s+|\s+$//g; s/\s+/ /g; print;')
after_ro=$(cd "$ITMP/ro_cfg/coralline" && find . | LC_ALL=C sort)
check "VL_RELAY_ISOLATE=1 acp-gemini read-only render shows agy-gemini limits" \
  "5h:24% 7d:18% burn" "$(iso_summary "$ro_out")"
check "VL_RELAY_ISOLATE=1 acp-gemini creates no ticks and runs no GC under CORALLINE_NO_SAMPLE=0" \
  "$before_ro" "$after_ro"

# 18. Expired 5h store + live 7d store with stale 5h TSV never leaks a 5h burn ETA
mkdir -p "$ITMP/exp5_cfg/coralline/limit-5h-agy-gemini.d" "$ITMP/exp5_cfg/coralline/limit-7d-agy-gemini.d" "$ITMP/exp5_cfg/model-relay-status"
cp -R "$ITMP/cfg/coralline/limit-7d-agy-gemini.d/." "$ITMP/exp5_cfg/coralline/limit-7d-agy-gemini.d/"
printf 'pinned\tacp-gemini-4-neon[1m]\txhigh\n' > "$ITMP/exp5_cfg/model-relay-status/s_acp"
OLD_R5=$(( now - 60 ))
printf '%s\t10.000\t%s\n%s\t40.000\t%s\n' "$(( now - 600 ))" "$OLD_R5" "$(( now - 120 ))" "$OLD_R5" > "$ITMP/exp5_cfg/coralline/burn-5h-agy-gemini.tsv"
exp5_out=$(printf '{"session_id":"s_acp","model":{"display_name":"Opus"},"cost":{"total_cost_usd":14.22}}' |
  CLAUDE_CONFIG_DIR="$ITMP/exp5_cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/exp5_cfg" CORALLINE_NO_SAMPLE=0 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; s/^\s+|\s+$//g; s/\s+/ /g; print;')
check "VL_RELAY_ISOLATE=1 with expired 5h store shows 7d+burn and hides 5h" \
  "7d:18% burn" "$(iso_summary "$exp5_out")"
exp5_has_5h=0
case "$exp5_out" in (*"5h ⇢"*) exp5_has_5h=1 ;; esac
check "expired 5h TSV does not leak 5h burn ETA" "0" "$exp5_has_5h"

# 18b. VL_RELAY_ISOLATE=1 on acp-gemini* with no coralline dir creates nothing under CORALLINE_NO_SAMPLE=0
mkdir -p "$ITMP/nodir_cfg/model-relay-status"
printf 'pinned\tacp-gemini-4-neon[1m]\txhigh\n' > "$ITMP/nodir_cfg/model-relay-status/s_acp"
printf '{"session_id":"s_acp","model":{"display_name":"Opus"},"cost":{"total_cost_usd":9.99}}' |
  CLAUDE_CONFIG_DIR="$ITMP/nodir_cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/nodir_cfg" CORALLINE_NO_SAMPLE=0 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" >/dev/null
nodir_exists=0; [ -e "$ITMP/nodir_cfg/coralline" ] && nodir_exists=1
check "VL_RELAY_ISOLATE=1 acp-gemini creates no store dir when empty under CORALLINE_NO_SAMPLE=0" "0" "$nodir_exists"

# 19. failover non-Claude isolates; failover agy/gemini* borrows agy-gemini; failover claude/acct2 stays Claude
printf 'failover\tglm-5.3[1m]\thigh\n'       > "$ITMP/cfg/model-relay-status/s_fo_glm"
printf 'failover\tagy/gemini-4[1m]\thigh\n'  > "$ITMP/cfg/model-relay-status/s_fo_agy"
printf 'failover\tclaude/acct2\thigh\n'      > "$ITMP/cfg/model-relay-status/s_fo_cl"
printf 'pinned\tacp-gemini4\thigh\n'         > "$ITMP/cfg/model-relay-status/s_acp4"
printf 'pinned\tagy-gemini4\thigh\n'         > "$ITMP/cfg/model-relay-status/s_agy4"
printf 'pinned\tagy/gemini4\thigh\n'         > "$ITMP/cfg/model-relay-status/s_agys4"
printf '5h\t77\t%s\n7d\t55\t%s\n7d_oi\t44\t%s\n' "$R5" "$R7" "$R7" > "$ITMP/cfg/model-relay-status/s_fo_cl.limits"
check "VL_RELAY_ISOLATE=1 on failover glm hides Claude segments" \
  "" "$(iso_summary "$(iso_render s_fo_glm "$ITMP/iso1.conf" 1)")"
check "VL_RELAY_ISOLATE=1 on failover agy/gemini borrows agy-gemini synced stores" \
  "5h:24% 7d:18% burn" "$(iso_summary "$(iso_render s_fo_agy "$ITMP/iso1.conf" 1)")"
check "VL_RELAY_ISOLATE=1 on failover claude/acct2 keeps Claude segments" \
  "5h:82% 7d:61% fable:44% burn cost:\$14.22" "$(iso_summary "$(iso_render s_fo_cl "$ITMP/iso1.conf" 1)")"
check "VL_RELAY_ISOLATE=1 on acp-gemini4 (no hyphen) borrows agy-gemini synced stores" \
  "5h:24% 7d:18% burn" "$(iso_summary "$(iso_render s_acp4 "$ITMP/iso1.conf" 1)")"
check "VL_RELAY_ISOLATE=1 on agy-gemini4 (no hyphen) borrows agy-gemini synced stores" \
  "5h:24% 7d:18% burn" "$(iso_summary "$(iso_render s_agy4 "$ITMP/iso1.conf" 1)")"
check "VL_RELAY_ISOLATE=1 on agy/gemini4 (no hyphen) borrows agy-gemini synced stores" \
  "5h:24% 7d:18% burn" "$(iso_summary "$(iso_render s_agys4 "$ITMP/iso1.conf" 1)")"

# 20. Native agy payload is never altered by VL_RELAY_ISOLATE=1 even with a relay status file for the same sid
agy_payload=$(printf '{"product":"antigravity","session_id":"s_glm","model":{"display_name":"Gemini 4 Neon (High)"},"cost":{"total_usd":1.25},"quota":{"gemini-5h":{"remaining_fraction":0.76,"reset_time":"%s","reset_in_seconds":7200},"gemini-weekly":{"remaining_fraction":0.82,"reset_time":"%s","reset_in_seconds":259200}}}' "$R5_ISO" "$R7_ISO")
agy_native_0=$(printf '%s' "$agy_payload" |
  CLAUDE_CONFIG_DIR="$ITMP/cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$ITMP/iso0.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; s/^\s+|\s+$//g; s/\s+/ /g; print;')
agy_native_1=$(printf '%s' "$agy_payload" |
  CLAUDE_CONFIG_DIR="$ITMP/cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; s/^\s+|\s+$//g; s/\s+/ /g; print;')
check "VL_RELAY_ISOLATE=1 leaves native agy payload identical to VL_RELAY_ISOLATE=0" \
  "$(iso_summary "$agy_native_0")" "$(iso_summary "$agy_native_1")"
check "VL_RELAY_ISOLATE=1 native agy keeps its own limits, burn, and cost" \
  "5h:24% 7d:18% fable:44% burn cost:\$1.25" "$(iso_summary "$agy_native_1")"

# 21. Inherited internal _STATE_RL* / _CUR*_CANON env vars do not leak limits on isolated routes
env_leak_out=$(printf '{"session_id":"s_glm","model":{"display_name":"Opus"},"cost":{"total_cost_usd":14.22}}' |
  _STATE_RL5_VALID=1 _STATE_RL5_PCT=50000 _STATE_RL5_RST="$R5" \
  _STATE_RL7_VALID=1 _STATE_RL7_PCT=60000 _STATE_RL7_RST="$R7" \
  _CUR5_CANON=50.000 _CUR5_PCT=50000 _CUR5_RST="$R5" \
  _CUR7_CANON=60.000 _CUR7_PCT=60000 _CUR7_RST="$R7" \
  CLAUDE_CONFIG_DIR="$ITMP/cfg" MODEL_RELAY_CONFIG_DIR="$ITMP/cfg" CORALLINE_NO_SAMPLE=1 \
  CORALLINE_CONFIG="$ITMP/iso1.conf" COLUMNS=200 "$BASH" "$SCRIPT" |
  perl -0777 -ne 's/\e\[[0-9;]*m//g; s/\xee\x82[\xb0\xb4\xb6]/ /g; s/^\s+|\s+$//g; s/\s+/ /g; print;')
check "VL_RELAY_ISOLATE=1 clears inherited _STATE_RL* and _CUR*_CANON env vars" \
  "" "$(iso_summary "$env_leak_out")"

exit "$fail"
