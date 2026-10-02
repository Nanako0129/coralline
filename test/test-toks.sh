#!/usr/bin/env bash
# Regression test for the optional `toks` and `ttft` segments: decode speed and
# time to first token of the last response. The payload has neither, so
# toks_sample() keeps a per-session anchor in ~/.claude/coralline/toks-<sid> (the
# prefill-inclusive fallback rate) plus the last transcript resolution that
# toks_transcript() derives, and seg_toks()/seg_ttft() paint the render's one sample.
#
#   bash test/test-toks.sh
#
# The unit half extracts the live functions from statusline.sh so it can never
# drift. The end-to-end half runs the whole script, which is the only way to
# catch the jq field order against the `read` list, where the sampler sits
# relative to emit_float, and the CR a native Windows jq leaves on the last
# field; it needs jq and is skipped without it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
SAMPLE="$HERE/sample-input.json"

# Single-quoted, one per line: bash 3.2 mangles a sed script built in a loop.
eval "$(sed -n '/^toks_sample() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^toks_evict() {/,/^}/p'  "$SCRIPT")"
eval "$(sed -n '/^toks_transcript() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^seg_toks() {/,/^}/p'    "$SCRIPT")"
eval "$(sed -n '/^seg_ttft() {/,/^}/p'    "$SCRIPT")"
eval "$(sed -n '/^fmt_tok() {/,/^}/p'     "$SCRIPT")"
eval "$(sed -n '/^fmt_duration() {/,/^}/p' "$SCRIPT")"

fg()   { _FG="<$1>"; }
push() { _BG="$1"; _TEXT="$2"; }
VL_FG_TEXT=text ; VL_FG_DIM=dim ; VL_FG_OK=ok ; VL_BG_CTX=238 ; VL_BG_TOKS="" ; VL_TOKS_GLYPH=G
VL_BG_TTFT="" ; VL_TTFT_GLYPH=H
TOKS_KEEP=32 ; TOKS_TAIL=1048576 ; TOKS_TRIES=3
transcript=""                 # the anchor cases run without a transcript

fail=0
check() {  # $1=expected  $2=label  $3=actual
  if [ "$3" = "$1" ]; then
    printf 'ok    %-40s -> %q\n' "$2" "$3"
  else
    printf 'FAIL  %-40s want=%q got=%q\n' "$2" "$1" "$3"; fail=1
  fi
}

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/coralline-toks.XXXXXX") || exit 1
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
CORALLINE_DIR="$SANDBOX/unit"
SID="a1b2c3d4-0000-4000-8000-000000000000"
SLOT="$CORALLINE_DIR/toks-$SID"

sample() {  # $1=api_ms $2=tok_in $3=tok_out [$4=sid] → "<ok>|<rate>"
  api_ms="$1"; tok_in="$2"; tok_out="$3"; sid="${4-$SID}"
  toks_sample
  printf '%s|%s' "$_TOKS_OK" "$_TOKS_RATE"
}
state() { cat "$SLOT" 2>/dev/null; }
# Expected state line: $1=api $2=key $3=rate $4=tkey $5=t_api $6=decode $7=ttft $8=pkey $9=tries
line() { printf '%s %s %s %s %s %s %s %s %s %s' "$SID" "$1" "$2" "${3:--}" "${4:--}" "$5" "${6:--}" "${7:--}" "${8:--}" "${9:-0}"; }

# ── Unusable input: no state, segment suppressed ─────────────────────────────
check "0|" "empty session_id"                "$(sample 0 0 0 '')"
check "0|" "remote session_id (served:…)"    "$(sample 0 0 0 'served:unknown')"
check "0|" "unsafe session_id charset"       "$(sample 0 0 0 'a/../x')"
check "0|" "uppercase hex (not a CC uuid)"   "$(sample 0 0 0 'A1B2C3D4-0000')"
check "0|" "uppercase after a hex digit"     "$(sample 0 0 0 'a1B2c3d4-0000')"
check "0|" "non-integer api duration"        "$(sample 12.5 0 0)"
check ""   "nothing written for any of them" "$(ls "$CORALLINE_DIR" 2>/dev/null)"

# ── The response lifecycle ───────────────────────────────────────────────────
# Anchor before the first request (api total 0), so the first response is timed.
sample 0 0 0 >/dev/null
check "$(line 0 0:0 '' '' 0)" "anchor at api 0" "$(state)"
# A render that already sees the new response but not its duration (same api
# total) must leave the anchor alone, or the completed response would later look
# like the old one and its time would be thrown away as foreign.
check "1|" "partial: response seen, no duration" "$(sample 0 5000 3)"
check "$(line 0 0:0 '' '' 0)" "partial leaves the anchor"  "$(state)"
check "1|75" "150 tok over 2000ms"               "$(sample 2000 5000 150)"
check "$(line 2000 5000:150 75 '' 0)" "state after timing" "$(state)"
check "1|75" "re-render, nothing new"            "$(sample 2000 5000 150)"
# API time with no new main response (a subagent, a side query) is absorbed into
# the anchor instead of being charged to the next response.
check "1|75" "foreign time keeps the rate"       "$(sample 4000 5000 150)"
check "$(line 4000 5000:150 75 '' 0)" "foreign time absorbed" "$(state)"
check "1|100" "next: 300 tok over 3000ms"        "$(sample 7000 6000 300)"
check "1|33" "rounds down (33.3)"                "$(sample 10000 7000 100)"
check "1|67" "rounds up (66.7)"                  "$(sample 13000 8000 200)"

# ── Re-anchoring ─────────────────────────────────────────────────────────────
check "1|" "api total fell (restart)"            "$(sample 1000 9000 50)"
check "$(line 1000 9000:50 '' '' 1000)" "restart re-anchors"  "$(state)"
# A foreign line in this session's own file (hand-copied, or a store from before
# the sid was in the name) is not this session's anchor.
printf 'a9999999-0000-4000-8000-000000000000 5000 1:1 9\n' >| "$SLOT"
check "1|" "foreign sid in own file"             "$(sample 6000 200 20)"
check "$(line 6000 200:20 '' '' 6000)" "foreign line replaced" "$(state)"
printf 'garbage line\n' >| "$SLOT"
check "1|" "garbage state"                       "$(sample 9000 300 30)"
printf '%s 9000 300:30 7x\n' "$SID" >| "$SLOT"
check "1|" "non-numeric stored rate dropped"     "$(sample 9000 300 30)"

# ── Live sessions never share a file ─────────────────────────────────────────
# Regression for the observed ping-pong: with refreshInterval every open session
# renders each second, and two sessions whose ids share a first digit used to
# share one slot and re-anchor each other forever. Interleave two such sessions
# render by render; both must time their own responses.
OTHER="a1ffffff-0000-4000-8000-000000000000"
sample 0 0 0 >/dev/null;          sample 0 0 0 "$OTHER" >/dev/null
sample 0 0 0 >/dev/null;          sample 0 0 0 "$OTHER" >/dev/null
check "1|50" "session A times 100 tok / 2s"  "$(sample 2000 10 100)"
check "1|30" "session B times 90 tok / 3s"   "$(sample 3000 20 90 "$OTHER")"
check "1|50" "A keeps its rate after B"      "$(sample 2000 10 100)"
check "1|30" "B keeps its rate after A"      "$(sample 3000 20 90 "$OTHER")"
rm -f "$CORALLINE_DIR/toks-$OTHER"
sample 0 0 0 >/dev/null

# ── Hostile or odd stored values (code review of the first cut) ──────────────
# A digits-only value with a leading zero is octal to $(( )), and an 8 or 9 in it
# made bash 3.2 abort the whole script, not just hide the pill.
printf '%s 0089 1:1 - - 0089 - - - 0\n' "$SID" >| "$SLOT"
check "1|500" "leading zeros are decimal"  "$(sample 0189 00010 0050)"   # 50 tok / 100 ms
check "$(line 189 10:50 500 '' 89)" "normalized on write" "$(state)"
# A link or a non-file in this session's name is never read, written through, or
# taken as missing (which used to evict another session's file every render).
T_LINK="$SANDBOX/target"; printf 'precious\n' >| "$T_LINK"
rm -f "$SLOT"; ln -s "$T_LINK" "$SLOT"
check "0|" "symlink in our name: suppressed" "$(sample 9000 1 1)"
check "precious" "symlink target untouched" "$(cat "$T_LINK")"
rm -f "$SLOT"; mkdir "$SLOT"
( TOKS_KEEP=1; sample 9000 1 1 >/dev/null )
check "1" "directory in our name: nothing evicted" "$(ls "$CORALLINE_DIR" | wc -l | tr -d ' ')"
rmdir "$SLOT"
printf '%s 1000 1:1 - - 1000 - - - 0\n' "$SID" >| "$SLOT"; chmod 000 "$SLOT"
err=$( { sample 5000 3 100 >/dev/null; } 2>&1 )
check "" "unreadable state prints nothing" "$err"
chmod 600 "$SLOT"

# ── CORALLINE_NO_SAMPLE: compute, never write ────────────────────────────────
printf '%s 1000 1:1 \n' "$SID" >| "$SLOT"
check "1|50" "no-sample still computes" "$(CORALLINE_NO_SAMPLE=1 sample 3000 2 100)"
check "$SID 1000 1:1 " "no-sample writes nothing" "$(state)"

# ── Bounded store ────────────────────────────────────────────────────────────
# Only a session creating its file evicts, and then only the single least-recently
# written file once TOKS_KEEP files exist. A session that already has its file
# never deletes anything.
E="$SANDBOX/evict"; mkdir -p "$E"
( CORALLINE_DIR="$E"; TOKS_KEEP=3
  printf 'x\n' >| "$E/toks-old"; touch -t 202001010000 "$E/toks-old"
  printf 'x\n' >| "$E/toks-mid"; touch -t 202101010000 "$E/toks-mid"
  printf 'x\n' >| "$E/burn-5h.tsv"; touch -t 201901010000 "$E/burn-5h.tsv"
  sample 0 0 0 'b0000000-0000-4000-8000-000000000000' >/dev/null   # 2 → 3 files, no eviction
  sample 0 0 0 'c0000000-0000-4000-8000-000000000000' >/dev/null   # at 3: evict toks-old
  sample 5 0 0 'c0000000-0000-4000-8000-000000000000' >/dev/null ) # existing file: no eviction
check "burn-5h.tsv toks-b0000000-0000-4000-8000-000000000000 toks-c0000000-0000-4000-8000-000000000000 toks-mid " \
  "evicts only the oldest toks file" "$(ls "$E" | tr '\n' ' ')"

# ── An unwritable store stays quiet ──────────────────────────────────────────
chmod 500 "$CORALLINE_DIR"
chmod 400 "$SLOT"
err=$( { sample 5000 3 100 >/dev/null; } 2>&1 )
check "" "read-only store prints nothing" "$err"
chmod 700 "$CORALLINE_DIR"; chmod 600 "$SLOT"

# ── seg_toks / seg_ttft ──────────────────────────────────────────────────────
paint() {  # $1=ok $2=api_ms $3=rate [$4=decode] → pushed text
  _TOKS_OK="$1"; api_ms="$2"; _TOKS_RATE="$3"; _TOKS_DEC="${4-}"; _BG=""; _TEXT=""
  seg_toks
  printf '%s' "$_TEXT"
}
paintt() {  # $1=ttft ms → pushed text
  _TOKS_OK=1; _TOKS_TTFT="$1"; _BG=""; _TEXT=""
  seg_ttft
  printf '%s' "$_TEXT"
}
check ""                  "suppressed without a sample"   "$(paint 0 5000 75)"
check ""                  "suppressed before any request" "$(paint 1 0 '')"
# Gauge inks, never VL_FG_TEXT: the ctx ground is dark and seven themes' TEXT is a
# dark pastel-pill ink, which rendered dark on dark (seen live under morning-haze).
check "<dim> G … tok/s "        "warming"                 "$(paint 1 5000 '')"
# The prefill-inclusive rate can only understate decode speed, so it carries ≥.
check "<ok> G ≥75 <dim>tok/s "  "fallback rate"           "$(paint 1 5000 75)"
check "<ok> G 120 <dim>tok/s "  "decode rate wins"        "$(paint 1 5000 75 120)"
check "<ok> G 1.2k <dim>tok/s " "four-digit decode"       "$(paint 1 5000 75 1234)"
VL_TOKS_GLYPH=""
check "<ok> 120 <dim>tok/s "    "no glyph (VL_ASCII)"     "$(paint 1 5000 75 120)"
VL_TOKS_GLYPH=G
check ""                     "ttft hidden when unknown"  "$(paintt '')"
check "<ok> H 2.4<dim>s "    "ttft in tenths"            "$(paintt 2378)"
check "<ok> H 0.0<dim>s "    "ttft under 50ms"           "$(paintt 40)"
check "<ok> H 28s<dim> "     "ttft from 10s up"          "$(paintt 28053)"
check "<ok> H 1m05s<dim> "   "ttft past a minute"        "$(paintt 65000)"
_TOKS_TTFT=2378; seg_ttft
check "238" "empty VL_BG_TTFT → ctx" "$_BG"
paint 1 5000 75 >/dev/null
check "238" "empty VL_BG_TOKS → ctx" "$_BG"
VL_BG_TOKS="1,2,3"; paint 1 5000 75 >/dev/null
check "1,2,3" "explicit VL_BG_TOKS" "$_BG"
VL_BG_TOKS=""

# ── End to end: the whole script ─────────────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP  end-to-end cases: jq not available"
  exit "$fail"
fi
BASH_BIN="${BASH_BIN:-$BASH}"
REAL_JQ=$(command -v jq)

# ── toks_transcript: decode rate and TTFT from a transcript ──────────────────
# Entries are stamped at content_block_stop; a thinking entry also carries
# thinkingDurationMs (start to stop). ev builds one JSONL entry.
ev() {  # $1=type $2=ts(ss.mmm after 00:00) [$3=msg id $4=first block $5=thinkMs $6=in $7=out]
  jq -nc --arg ty "$1" --arg ts "2026-10-03T00:00:$2Z" --arg id "${3-}" --arg b "${4-text}" \
    --argjson tm "${5:-null}" --argjson in "${6:-0}" --argjson out "${7:-0}" '
    if $ty == "assistant" then {type: $ty, timestamp: $ts, thinkingDurationMs: $tm,
      message: {id: $id, content: [{type: $b}], usage: {input_tokens: 10,
        cache_read_input_tokens: ($in - 10), cache_creation_input_tokens: 0, output_tokens: $out}}}
    else {type: $ty, timestamp: $ts} end'
}
TR="$SANDBOX/t.jsonl"
{ ev user 00.000; ev attachment 00.500
  ev assistant 04.000 m2 thinking 1500 5000 400; ev assistant 06.500 m2 text "" 5000 400; } >| "$TR"
transcript="$TR"
# First token 04.000 − 1.5s = 02.500; end 06.500; request ≈ 00.500 (the attachment).
toks_transcript 5000 400; check "100 2000" "thinking-first: decode and ttft" "$_TT"
toks_transcript 5000 401; check "pending"  "no matching usage yet: pending"  "$_TT"
{ ev user 07.000; ev assistant 09.000 m3 text "" 6000 50; } >> "$TR"
toks_transcript 6000 50;  check "na"       "text-first newest after thinking-first" "$_TT"
toks_transcript 5000 400; check "100 2000" "older response still exact"     "$_TT"
# A stamp later than the first token is not the request start, even when an
# attachment written out of order sits before the response in the file.
{ ev user 10.000; ev attachment 13.000
  ev assistant 14.000 m4 thinking 3000 7000 300; ev assistant 17.000 m4 tool_use "" 7000 300; } >| "$TR"
toks_transcript 7000 300; check "50 1000" "out-of-order stamp excluded" "$_TT"
{ ev assistant 14.000 m5 thinking 3000 7000 300; } >| "$TR"
toks_transcript 7000 300; check "100 -" "no earlier stamp: ttft unknown" "$_TT"
{ ev assistant 14.000 m6 thinking 3000 7000 300; ev assistant 10.000 m6 text "" 7000 300; } >| "$TR"
toks_transcript 7000 300; check "na" "end not after first token: na" "$_TT"
# tail -c can cut the first line; that line must be skipped, not break the parse.
{ ev user 00.000; ev attachment 00.500
  ev assistant 04.000 m2 thinking 1500 5000 400; ev assistant 06.500 m2 text "" 5000 400; } >| "$TR"
( TOKS_TAIL=$(( $(wc -c < "$TR") - 5 )); toks_transcript 5000 400; check "100 2000" "cut first line skipped" "$_TT" )

# ── toks_sample with a transcript ────────────────────────────────────────────
# A tail wrapper on PATH counts transcript reads: they must happen only when a
# response closes (plus bounded retries), never in steady state.
B="$SANDBOX/bin"; mkdir -p "$B"
printf '#!/bin/bash\necho x >> "%s"\nexec "%s" "$@"\n' "$SANDBOX/tails" "$(command -v tail)" >| "$B/tail"
chmod +x "$B/tail"
reads() { [ -f "$SANDBOX/tails" ] && wc -l < "$SANDBOX/tails" | tr -d ' ' || echo 0; }
PATH="$B:$PATH"
rm -f "$SLOT"; : >| "$SANDBOX/tails"
sample 1000 4000 40 >/dev/null                       # anchor (old response 4000:40)
check 0 "anchor: no transcript read" "$(reads)"
sample 9000 5000 400 >/dev/null                      # in this shell: the globals are the result
check "50 100 2000" "closing render: fallback, decode, ttft" "$_TOKS_RATE $_TOKS_DEC $_TOKS_TTFT"
check "$(line 9000 5000:400 50 5000:400 9000 100 2000)" "resolution stored" "$(state)"
check 1 "one read for the closing render" "$(reads)"
sample 9000 5000 400 >/dev/null; sample 9000 5000 400 >/dev/null
check 1 "steady renders: no read" "$(reads)"
# Mid-stream: a new key before its time lands is skipped (api not past t_api).
sample 9000 5100 7 >/dev/null
check 1 "mid-stream partial key: no read" "$(reads)"
# Reverse order: the time lands with the old key (absorbed), the key arrives a render
# later at an equal total. The transcript step still resolves it on render B.
{ ev user 07.000; ev assistant 09.000 m7 thinking 1000 6000 200; ev assistant 11.000 m7 text "" 6000 200; } >> "$TR"
sample 12000 5000 400 >/dev/null                      # render A: api grew, old key
check 1 "render A (old key): no read" "$(reads)"
sample 12000 6000 200 >/dev/null                      # render B: new key, equal api
check "67 1000" "reverse order resolved on render B" "$_TOKS_DEC $_TOKS_TTFT"
check 2 "render B read the transcript" "$(reads)"
# Pending: the response is not in the transcript yet. Each retry is counted in the
# state line and the lookups stop after TOKS_TRIES, resolving it as not derivable.
sample 15000 7000 90 >/dev/null
check "$(line 15000 7000:90 30 6000:200 12000 67 1000 7000:90 1)" "pending counted" "$(state)"
check "67 1000" "pending keeps the last resolution" "$_TOKS_DEC $_TOKS_TTFT"
sample 15000 7000 90 >/dev/null; sample 15000 7000 90 >/dev/null
check "$(line 15000 7000:90 30 7000:90 15000)" "given up after three" "$(state)"
check "|" "given up: fallback, ttft hidden" "$_TOKS_DEC|$_TOKS_TTFT"
sample 15000 7000 90 >/dev/null; sample 15000 7000 90 >/dev/null
check 5 "no reads after giving up" "$(reads)"
# A state file that cannot be written must not turn into a read every render.
chmod 400 "$SLOT"
sample 18000 8000 10 >/dev/null; sample 18000 8000 10 >/dev/null
check 5 "read-only state: no reads" "$(reads)"
chmod 600 "$SLOT"
CORALLINE_NO_SAMPLE=1 sample 21000 8100 10 >/dev/null
check 5 "no-sample: no reads" "$(reads)"
transcript=""
payload() {  # $1=api_ms $2=tok_in $3=tok_out → sample-input with those fields
  jq -c --argjson ms "$1" --argjson in "$2" --argjson out "$3" --arg sid "$SID" \
    '.session_id = $sid | .cost.total_api_duration_ms = $ms
     | .context_window.total_input_tokens = $in | .context_window.total_output_tokens = $out' "$SAMPLE"
}
render() {  # $1=sandbox $2=config lines; stdin = payload. Every path pinned in.
  printf '%s\n' "$2" >| "$1/conf"
  HOME="$1" CLAUDE_CONFIG_DIR="$1" CORALLINE_CONFIG="$1/conf" COLUMNS=200 "$BASH_BIN" "$SCRIPT"
}
has() {  # $1=needle $2=render; matched on the text with colors stripped
  local plain; plain=$(printf '%s' "$2" | sed $'s/\x1b\\[[0-9;]*m//g')
  case "$plain" in (*"$1"*) echo 1 ;; (*) echo 0 ;; esac
}
# Decoded from the codepoint by jq, not hand-written bytes: a hand-written oracle
# once agreed with a wrong encoding (EE 83 A4 is U+E0E4, tofu in every font).
GL=$(jq -rn '"\uf0e4"')   # the shipped VL_TOKS_GLYPH, U+F0E4 fa-tachometer

# (a) The wizard-preview path: sample-input under CORALLINE_NO_SAMPLE shows the
# warming pill and creates no state.
E="$SANDBOX/e2e-a"; mkdir -p "$E"
out=$(CORALLINE_NO_SAMPLE=1 render "$E" 'VL_SEGMENTS="model toks"' < "$SAMPLE")
check 1 "preview shows the warming pill" "$(has " $GL … tok/s " "$out")"
check "" "preview creates no state" "$(ls "$E/coralline" 2>/dev/null)"

# (b) Two renders: anchor, then a response of 150 tokens over 2000ms.
E="$SANDBOX/e2e-b"; mkdir -p "$E"
payload 1000 5000 40  | render "$E" 'VL_SEGMENTS="model toks"' >/dev/null
out=$(payload 3000 6000 150 | render "$E" 'VL_SEGMENTS="model toks"')
check 1 "second render shows ≥75 tok/s" "$(has " $GL ≥75 tok/s " "$out")"
check 0 "default segments untouched"   "$(has 'tok/s' "$(payload 3000 6000 150 | render "$E" '')")"

# (c) toks in both the main row and the float file: one sample per render, so
# the float pass neither re-advances the anchor nor paints a different value.
E="$SANDBOX/e2e-c"; mkdir -p "$E"
cfg=$(printf '%s\n' 'VL_SEGMENTS="model toks"' 'VL_FLOAT=1' 'VL_FLOAT_SEGMENTS="toks"' "VL_FLOAT_FILE=\"$E/float.txt\"")
payload 1000 5000 40  | render "$E" "$cfg" >/dev/null
out=$(payload 3000 6000 150 | render "$E" "$cfg")
check 1 "main row with float on"     "$(has " $GL ≥75 tok/s " "$out")"
check "$GL ≥75 tok/s" "float file"    "$(cat "$E/float.txt" 2>/dev/null)"
check "$(line 3000 6000:150 75 '' 1000)" "state advanced once" "$(cat "$E/coralline/toks-$SID" 2>/dev/null)"

# (d) A native Windows jq ends its output with CRLF, which leaves a CR on the
# last parsed field (session_id). Simulate it with a jq wrapper on PATH.
E="$SANDBOX/e2e-d"; mkdir -p "$E/bin"
{ printf '#!/bin/bash\nset -o pipefail\n'
  printf '"%s" "$@" | awk '\''{ printf "%%s\\r\\n", $0 }'\''\n' "$REAL_JQ"; } >| "$E/bin/jq"
chmod +x "$E/bin/jq"
payload 1000 5000 40  | PATH="$E/bin:$PATH" render "$E" 'VL_SEGMENTS="model toks"' >/dev/null
out=$(payload 3000 6000 150 | PATH="$E/bin:$PATH" render "$E" 'VL_SEGMENTS="model toks"')
check 1 "CRLF jq still times the response" "$(has " $GL ≥75 tok/s " "$out")"

# (e) With a transcript the pills show the decode rate and the TTFT, and `ttft`
# works on its own: the sampler is gated on toks OR ttft.
GT=$(jq -rn '"\uf251"')   # the shipped VL_TTFT_GLYPH, U+F251 fa-hourglass-start
tpay() { payload "$@" | jq -c --arg t "$TR" '.transcript_path = $t'; }
{ ev user 00.000; ev attachment 00.500
  ev assistant 04.000 m2 thinking 1500 5000 400; ev assistant 06.500 m2 text "" 5000 400; } >| "$TR"
E="$SANDBOX/e2e-e"; mkdir -p "$E"
tpay 1000 4000 40 | render "$E" 'VL_SEGMENTS="model toks ttft"' >/dev/null
out=$(tpay 9000 5000 400 | render "$E" 'VL_SEGMENTS="model toks ttft"')
check 1 "decode rate pill"  "$(has " $GL 100 tok/s " "$out")"
check 1 "ttft pill"         "$(has " $GT 2.0s " "$out")"
E="$SANDBOX/e2e-f"; mkdir -p "$E"
tpay 1000 4000 40 | render "$E" 'VL_SEGMENTS="model ttft"' >/dev/null
out=$(tpay 9000 5000 400 | render "$E" 'VL_SEGMENTS="model ttft"')
check 1 "ttft alone works"  "$(has " $GT 2.0s " "$out")"
check 0 "no toks pill there" "$(has "tok/s" "$out")"

exit "$fail"
