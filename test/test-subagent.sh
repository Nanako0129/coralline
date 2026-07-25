#!/usr/bin/env bash
# Unit + end-to-end test for the --subagent panel mode. Extracts live helpers
# from statusline.sh (sed) so it can never drift; the end-to-end block runs the
# real script against test/sample-subagent-input.json. Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/coralline-subtest.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT

eval "$(sed -n '/^make_bar() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^iso_epoch() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^json_escape() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^model_short() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^fmt_duration() {/,/^}/p' "$SCRIPT")"
eval "$(sed -n '/^sub_epoch() {/,/^}/p' "$SCRIPT")"

fail=0
ok()   { printf 'ok    %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; fail=1; }

# ── json_escape ──────────────────────────────────────────────────────────────
json_escape 'plain text'
[ "$_JS" = 'plain text' ] && ok "passthrough" || bad "passthrough: got [$_JS]"

json_escape 'say "hi" \ done'
[ "$_JS" = 'say \"hi\" \\ done' ] && ok "quote+backslash" || bad "quote+backslash: got [$_JS]"

json_escape $'\033[38;5;231mX\033[0m'
[ "$_JS" = '\u001b[38;5;231mX\u001b[0m' ] && ok "ESC becomes \\u001b" || bad "ESC: got [$_JS]"

ESC_JS="$_JS"   # keep the hard (ANSI/ESC) case for the round-trip check below

json_escape $'a\tb\nc'
[ "$_JS" = 'a\tb\nc' ] && ok "tab+newline" || bad "tab+newline: got [$_JS]"

json_escape $'drop\001this'
[ "$_JS" = 'dropthis' ] && ok "other control chars dropped" || bad "control: got [$_JS]"

# The composed result must be valid JSON — proven on the ANSI/ESC case, the
# hardest escape json_escape produces, not the last (plain) _JS.
printf '{"id":"x","content":"%s"}\n' "$ESC_JS" | jq -e .content >/dev/null \
  && ok "escaped content is valid JSON" || bad "escaped content is valid JSON"

# ── model_short ──────────────────────────────────────────────────────────────
ms() { model_short "$1"; [ "$_MS" = "$2" ] && ok "model_short $1 → $2" || bad "model_short $1: got [$_MS] want [$2]"; }
ms claude-fable-5                 "Fable 5"
ms claude-opus-4-8                "Opus 4.8"
ms claude-sonnet-5                "Sonnet 5"
ms claude-haiku-4-5-20251001      "Haiku 4.5"
ms claude-foo-2                   "claude-foo-2"      # unknown family → raw id
ms gpt-oss-120b                   "gpt-oss-120b"      # non-claude → raw id
ms claude-fable-next              "claude-fable-next" # non-numeric version → raw id

# ── elapsed precision ─────────────────────────────────────────────────────────
fmt_duration 125000
[ "$_DUR" = "2m" ] && ok "main duration keeps compact minutes" || bad "main duration: got [$_DUR]"
fmt_duration 125000 1
[ "$_DUR" = "2m05s" ] && ok "subagent duration keeps seconds" || bad "subagent duration: got [$_DUR]"
fmt_duration 3723000 1
[ "$_DUR" = "1h02m03s" ] && ok "subagent duration keeps seconds after hours" || bad "subagent hour duration: got [$_DUR]"

# ── strict timestamp parsing ─────────────────────────────────────────────────
DATE_MARK="$TMPD/date-called"
date() { printf 'called\n' >> "$DATE_MARK"; printf '1234567890\n'; }
sub_epoch 2024-02-29T00:00:00Z; erc=$?
[ "$erc" = 0 ] && [ "$_EP" = 1709164800 ] && ok "valid ISO stays fork-free" || bad "valid ISO: rc=$erc epoch=[${_EP:-}]"
sub_epoch 2026-02-31T00:00:00Z; erc=$?
[ "$erc" != 0 ] && ok "invalid calendar ISO rejected" || bad "invalid calendar ISO accepted: [${_EP:-}]"
sub_epoch 2026-99-99T99:99:99Z; erc=$?
[ "$erc" != 0 ] && ok "invalid ISO ranges rejected" || bad "invalid ISO ranges accepted: [${_EP:-}]"
[ ! -e "$DATE_MARK" ] && ok "strict ISO path never calls date" || bad "strict ISO path called date"
unset -f date

# ── defensive gauge bounds ───────────────────────────────────────────────────
VL_BAR_WIDTH=5; VL_BAR_FILL="▰"; VL_BAR_EMPTY="▱"
make_bar -30
[ "$_BAR" = "▱▱▱▱▱" ] && ok "negative pct clamps to empty bar" || bad "negative pct bar: [$_BAR]"

# ── end-to-end: --subagent protocol ──────────────────────────────────────────
SAMPLE="$HERE/sample-subagent-input.json"
OUT=$(CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent < "$SAMPLE")

n=$(printf '%s\n' "$OUT" | grep -c .)
[ "$n" = 3 ] && ok "three rows out" || bad "three rows out (got $n)"

printf '%s\n' "$OUT" | while IFS= read -r line; do
  printf '%s' "$line" | jq -e .id >/dev/null || exit 1
done && ok "every line is valid JSON with id" || bad "every line is valid JSON with id"

ids=$(printf '%s\n' "$OUT" | jq -j '.id, " "')
[ "$ids" = "task-1 task-2 task-3 " ] && ok "ids in task order" || bad "ids: got [$ids]"

c1=$(printf '%s\n' "$OUT" | sed -n 1p | jq -r .content)
case "$c1" in (*"Haiku 4.5"*"▰"*"%"*) ok "row1 has model+gauge" ;; (*) bad "row1: [$c1]" ;; esac
case "$c1" in (*"Explore config sources"*) ok "row1 uses label when name absent" ;; (*) bad "row1 label: [$c1]" ;; esac
case "$c1" in (*"local_agent"*) bad "row1 must not show raw type: [$c1]" ;; (*) ok "row1 hides local_agent type" ;; esac
case "$c1" in (*$'\033['*) ok "row1 carries ANSI" ;; (*) bad "row1 ANSI" ;; esac
case "$c1" in (*"⧖"*) ok "row1 has elapsed" ;; (*) bad "row1 elapsed: [$c1]" ;; esac
case "$c1" in (*"⬡"*) ok "row1 uses the default ctx glyph" ;; (*) bad "row1 ctx glyph: [$c1]" ;; esac

# VL_CTX_GLYPH has to reach the panel too, not just the main bar: the glyph it
# replaces is plain Unicode that some Nerd Fonts lack, so a user who overrides it
# for the main row would otherwise keep a broken hexagon here (#47).
GCONF=$(mktemp "${TMPDIR:-/tmp}/coralline-subglyph.XXXXXX") || exit 1
printf 'VL_CTX_GLYPH="◔"\n' > "$GCONF"
GOUT=$(CORALLINE_CONFIG="$GCONF" bash "$SCRIPT" --subagent < "$SAMPLE" | sed -n 1p | jq -r .content)
rm -f "$GCONF"
case "$GOUT" in (*"◔"*) ok "VL_CTX_GLYPH reaches the subagent ctx row" ;; (*) bad "subagent VL_CTX_GLYPH: [$GOUT]" ;; esac
case "$GOUT" in (*"⬡"*) bad "subagent row kept the default glyph: [$GOUT]" ;; (*) ok "subagent override displaces the default" ;; esac

# Claude omits agentType from the payload, but writes it to the task sidecar.
# Recover that native role without a subprocess; explicit payload names still win.
ROLE_BASE="$TMPD/role-session"
ROLE_TRANSCRIPT="${ROLE_BASE}.jsonl"
mkdir -p "$ROLE_BASE/subagents"
printf '%s\n' '{"agentType":"scout","description":"fixture"}' > "$ROLE_BASE/subagents/agent-role-1.meta.json"
ROLE_PAYLOAD_TRANSCRIPT="$ROLE_TRANSCRIPT"
if [ -n "${MSYSTEM:-}" ]; then ROLE_PAYLOAD_TRANSCRIPT=$(cygpath -w "$ROLE_TRANSCRIPT"); fi
ROLE=$(jq -nc --arg tp "$ROLE_PAYLOAD_TRANSCRIPT" '{transcript_path:$tp,tasks:[{id:"role-1",type:"local_agent",label:"payload label",status:"running"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$ROLE" in (*"scout"*) ok "agentType recovered from task sidecar" ;; (*) bad "agentType sidecar: [$ROLE]" ;; esac
case "$ROLE" in (*"payload label"*) ok "agentType and task label both render" ;; (*) bad "agentType label pair: [$ROLE]" ;; esac

NAMED=$(jq -nc --arg tp "$ROLE_PAYLOAD_TRANSCRIPT" '{transcript_path:$tp,tasks:[{id:"role-1",name:"friendly-name",type:"local_agent",label:"payload label",status:"running"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$NAMED" in (*"friendly-name"*"scout"*"payload label"*) ok "name, agentType, and label compose" ;; (*) bad "name/role/label composition: [$NAMED]" ;; esac

printf '{"agentType":"scout\033[2J"}\n' > "$ROLE_BASE/subagents/agent-role-1.meta.json"
UNSAFE_ROLE=$(jq -nc --arg tp "$ROLE_PAYLOAD_TRANSCRIPT" '{transcript_path:$tp,tasks:[{id:"role-1",type:"local_agent",label:"safe fallback",status:"running"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$UNSAFE_ROLE" in (*"safe fallback"*) ok "unsafe sidecar role rejected" ;; (*) bad "unsafe sidecar role: [$UNSAFE_ROLE]" ;; esac

c2=$(printf '%s\n' "$OUT" | sed -n 2p | jq -r .content)
case "$c2" in (*"Fable 5"*) ok "row2 model" ;; (*) bad "row2 model: [$c2]" ;; esac
case "$c2" in (*"big-refactor"*) ok "row2 explicit name" ;; (*) bad "row2 name: [$c2]" ;; esac
case "$c2" in (*"Refactor renderer"*) ok "row2 keeps task label beside name" ;; (*) bad "row2 label: [$c2]" ;; esac

c3=$(printf '%s\n' "$OUT" | sed -n 3p | jq -r .content)
case "$c3" in (*"just-spawned"*) ok "row3 renders name-only" ;; (*) bad "row3: [$c3]" ;; esac
case "$c3" in (*"◆"*|*"⬡"*|*"⧖"*) bad "row3 must omit model/ctx/elapsed: [$c3]" ;; (*) ok "row3 omits missing segments" ;; esac
case "$c3" in (*'[38;5;245m'*) ok "row3 unknown status is dim" ;; (*) bad "row3 dim: [$c3]" ;; esac

# tokenCount without contextWindowSize → bare count, no bar
NOBAR=$(printf '{"tasks":[{"id":"x","name":"n","type":"t","tokenCount":42000}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$NOBAR" in (*"⬡ 42.0k"*) ok "ctx degrades to bare count" ;; (*) bad "ctx degrade: [$NOBAR]" ;; esac
case "$NOBAR" in (*"▰"*|*"%"*) bad "ctx degrade must drop bar/% : [$NOBAR]" ;; (*) ok "no bar without window size" ;; esac

# 16 digits remain arithmetic-safe; oversized fields degrade without arithmetic
SAFE16=$(printf '{"tasks":[{"id":"x","name":"n","tokenCount":"4000000000000000","contextWindowSize":"8000000000000000"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$SAFE16" in (*"50%"*) ok "16-digit ctx remains valid" ;; (*) bad "16-digit ctx: [$SAFE16]" ;; esac

LEADERR="$TMPD/leading-zero.err"
LEAD=$(printf '{"tasks":[{"id":"x","name":"n","tokenCount":"0800000000000000","contextWindowSize":"1600000000000000"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent 2> "$LEADERR")
printf '%s\n' "$LEAD" | jq -e '(.id == "x") and (.content | contains("50%"))' >/dev/null 2>&1 \
  && [ ! -s "$LEADERR" ] && ok "leading-zero ctx stays decimal JSON" || bad "leading-zero ctx: [$LEAD]"

BIGTOK=$(printf '{"tasks":[{"id":"x","name":"n","tokenCount":"10000000000000000","contextWindowSize":200000}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$BIGTOK" in (*"⬡"*|*"%"*) bad "17-digit token must hide ctx: [$BIGTOK]" ;; (*) ok "17-digit token hides ctx" ;; esac

BIGWIN=$(printf '{"tasks":[{"id":"x","name":"n","tokenCount":42000,"contextWindowSize":"10000000000000000"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$BIGWIN" in (*"⬡ 42.0k"*) ok "oversized window degrades to bare count" ;; (*) bad "oversized window: [$BIGWIN]" ;; esac
case "$BIGWIN" in (*"▰"*|*"%"*) bad "oversized window must drop bar/%: [$BIGWIN]" ;; (*) ok "oversized window drops bar" ;; esac

# The previously confirmed overflow payload must terminate rather than making
# make_bar count upward from a huge negative filled value.
ADV_OUT="$TMPD/adversarial.jsonl"
( printf '{"tasks":[{"id":"x","name":"n","tokenCount":"4601686018427387904","contextWindowSize":1}]}' \
    | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent > "$ADV_OUT" ) & wpid=$!
( sleep 5; kill -9 "$wpid" 2>/dev/null ) & kpid=$!
if wait "$wpid" 2>/dev/null; then
  kill "$kpid" 2>/dev/null; wait "$kpid" 2>/dev/null
  ADV=$(jq -r .content "$ADV_OUT" 2>/dev/null)
  case "$ADV" in (*"⬡"*|*"%"*) bad "overflow token must hide ctx: [$ADV]" ;; (*) ok "overflow token terminates safely" ;; esac
else
  wait "$kpid" 2>/dev/null
  bad "overflow token renderer hung"
fi

# digit-bearing garbage startTime → elapsed hidden, not misparsed as epoch
BADT=$(printf '{"tasks":[{"id":"x","name":"n","type":"t","startTime":"abc123xyz"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$BADT" in (*"⧖"*) bad "garbage startTime must hide elapsed: [$BADT]" ;; (*) ok "garbage startTime hides elapsed" ;; esac

BADDATE=$(printf '{"tasks":[{"id":"x","name":"n","type":"t","startTime":"2026-02-31T00:00:00Z"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$BADDATE" in (*"⧖"*) bad "invalid calendar date must hide elapsed: [$BADDATE]" ;; (*) ok "invalid calendar date hides elapsed" ;; esac

# a crafted label must not smuggle escape sequences into the terminal
INJ=$(printf '{"tasks":[{"id":"x","type":"local_agent","label":"A\\u001b[2JB"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$INJ" in (*$'\033'"[2J"*) bad "label ESC injection reaches terminal" ;; (*) ok "label ESC injection stripped" ;; esac
case "$INJ" in (*"A[2JB"*) ok "label text survives sans control bytes" ;; (*) bad "label text mangled: [$INJ]" ;; esac

# C1 CSI (U+009B) must be scrubbed even in a byte-oriented C locale
C1=$(printf '{"tasks":[{"id":"x","type":"local_agent","label":"A\\u009b2JB"}]}' \
  | LC_ALL=C LANG=C CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent \
  | LC_ALL=C LANG=C jq -r .content)
C1_CSI=$'\302\233'
case "$C1" in (*"$C1_CSI"*) bad "label C1 CSI injection reaches terminal" ;; (*) ok "label C1 CSI injection stripped" ;; esac
case "$C1" in (*"A2JB"*) ok "C1 label text survives sans control bytes" ;; (*) bad "C1 label text mangled: [$C1]" ;; esac

# columns is metadata, not a row source; framing bytes there must emit no rows
COLS=$(printf '{"columns":"120\\nforged\\u001fforged-row\\u001f\\u001f\\u001ft\\u001frunning\\u001f\\u001f\\u001f\\u001f","tasks":[]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent)
[ -z "$COLS" ] && ok "hostile columns cannot fabricate a row" || bad "columns framing: [$COLS]"

# a literal newline in an untrusted field must not split the field stream and
# fabricate an extra row whose id the attacker controls
NL=$(printf '{"tasks":[{"id":"task-A","name":"evil\\nsplit","type":"t","status":"running","model":"claude-fable-5","contextWindowSize":200000,"tokenCount":1000},{"id":"task-B","name":"real","type":"t"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent)
nn=$(printf '%s\n' "$NL" | grep -c .)
[ "$nn" = 2 ] && ok "newline in name cannot fabricate a row" || bad "newline framing: got $nn rows"
nids=$(printf '%s\n' "$NL" | jq -j '.id, " "')
[ "$nids" = "task-A task-B " ] && ok "newline row ids intact" || bad "newline ids: [$nids]"

# an embedded 0x1f (the join separator) must not shift the fields that follow it
US=$(printf '{"tasks":[{"id":"x","name":"evil\\u001fname","type":"t","status":"running","model":"claude-fable-5","contextWindowSize":200000,"tokenCount":42000}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$US" in (*"Fable 5"*) ok "0x1f cannot shift fields" ;; (*) bad "0x1f field shift: [$US]" ;; esac

# absent status is "unknown" → dim, not the running text color (per README table)
NOST=$(printf '{"tasks":[{"id":"x","name":"nostatus","type":"t"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$NOST" in (*'[38;5;245m'*) ok "missing status renders dim" ;; (*) bad "missing status dim: [$NOST]" ;; esac

# description (documented task field) beats type in the display-name fallback
DESC=$(printf '{"tasks":[{"id":"x","type":"local_agent","description":"Summarize the diff"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$DESC" in (*"Summarize the diff"*) ok "description fallback used" ;; (*) bad "description fallback: [$DESC]" ;; esac
case "$DESC" in (*"local_agent"*) bad "type shown despite description: [$DESC]" ;; (*) ok "type hidden when description present" ;; esac

# tz-offset ISO startTime → elapsed hidden by design (stays fork-free per row)
TZT=$(printf '{"tasks":[{"id":"x","name":"n","type":"t","startTime":"2026-07-15T04:00:00+02:00"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent | jq -r .content)
case "$TZT" in (*"⧖"*) bad "tz-offset startTime must hide elapsed: [$TZT]" ;; (*) ok "tz-offset startTime hides elapsed" ;; esac

# VL_SUB_SEGMENTS is honored
CONF=$(mktemp "${TMPDIR:-/tmp}/coralline-conf.XXXXXX")
printf 'VL_SUB_SEGMENTS="model"\n' > "$CONF"
ONLYM=$(CORALLINE_CONFIG="$CONF" bash "$SCRIPT" --subagent < "$SAMPLE" | sed -n 1p | jq -r .content)
rm -f "$CONF"
case "$ONLYM" in (*"Haiku 4.5"*) ok "VL_SUB_SEGMENTS honored (model shown)" ;; (*) bad "VL_SUB_SEGMENTS: [$ONLYM]" ;; esac
case "$ONLYM" in (*"⬡"*|*"Explore"*) bad "VL_SUB_SEGMENTS must drop others: [$ONLYM]" ;; (*) ok "VL_SUB_SEGMENTS drops others" ;; esac

# ASCII mode drops Nerd/gauge glyphs but stays valid
CONF=$(mktemp "${TMPDIR:-/tmp}/coralline-conf.XXXXXX")
printf 'VL_ASCII=1\n' > "$CONF"
ASC=$(CORALLINE_CONFIG="$CONF" bash "$SCRIPT" --subagent < "$SAMPLE" | sed -n 1p | jq -r .content)
rm -f "$CONF"
case "$ASC" in (*"▰"*) bad "ASCII mode still emits ▰: [$ASC]" ;; (*) ok "ASCII bar substituted" ;; esac

# Claude Code delivers concatenated snapshots without newlines; each doc is a
# full panel snapshot, so only the LAST one may render (no stale/duplicate ids)
CAT=$(printf '{"tasks":[{"id":"A","name":"OLD","type":"t"}]}{"tasks":[{"id":"A","name":"NEW","type":"t"},{"id":"B","name":"fresh","type":"t"}]}' \
  | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent)
cn=$(printf '%s\n' "$CAT" | grep -c .)
[ "$cn" = 2 ] && ok "concatenated payloads render last snapshot only" || bad "concatenated: got $cn rows"
case "$CAT" in (*OLD*) bad "stale snapshot leaked: [$CAT]" ;; (*) ok "stale snapshot dropped" ;; esac
case "$CAT" in (*NEW*) ok "fresh snapshot rendered" ;; (*) bad "fresh snapshot missing: [$CAT]" ;; esac

# malformed stdin → empty output, exit 0
ERR=$(printf 'not json' | CORALLINE_CONFIG=/dev/null bash "$SCRIPT" --subagent; echo "rc=$?")
[ "$ERR" = "rc=0" ] && ok "bad input: silent, exit 0" || bad "bad input: [$ERR]"

# main mode untouched by the flag machinery
MAIN=$(CORALLINE_NO_SAMPLE=1 CORALLINE_CONFIG=/dev/null COLUMNS=120 bash "$SCRIPT" < "$HERE/sample-input.json")
case "$MAIN" in (*"Fable 5"*) ok "main mode still renders" ;; (*) bad "main mode" ;; esac

exit "$fail"
