#!/usr/bin/env bash
# Unit test for configure.sh's subagent panel toggle: enable/disable write and
# remove .subagentStatusLine in settings.json (backup, other keys preserved,
# broken JSON leaves the original untouched), the shared settings_merge pipeline
# behind every settings.json write, the non-interactive --subagent-rows=on|off
# flag, and the wizard's preview render. Extracts the live functions from
# configure.sh so this test can never drift. Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"

eval "$(sed -n '/^settings_merge() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^subagent_enabled() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^subagent_foreign() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^settings_runs_coralline() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^update_settings() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^enable_subagent_statusline() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^disable_subagent_statusline() {/,/^}/p' "$CONF")"

die() { printf 'die: %s\n' "$*" >&2; exit 1; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/coralline-subcfg.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
SETTINGS_FILE="$TMPD/settings.json"
TARGET_DIR="$HOME/.claude/coralline"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

# (1) enable with no settings file creates one
subagent_enabled && bad "starts disabled" || ok "starts disabled"
enable_subagent_statusline >/dev/null
jq -e '.subagentStatusLine.type == "command" and (.subagentStatusLine.command | endswith("--subagent"))' \
  "$SETTINGS_FILE" >/dev/null && ok "enable creates entry" || bad "enable creates entry"
subagent_enabled && ok "state reads enabled" || bad "state reads enabled"

# (1b) enabled means a usable command schema, including documented custom configs
MAIN_SETTINGS="$SETTINGS_FILE"
SETTINGS_FILE="$TMPD/schema.json"
printf '%s\n' '{"subagentStatusLine":{"type":"command","command":"CORALLINE_CONFIG=/tmp/sub.conf bash /tmp/statusline.sh --subagent"}}' > "$SETTINGS_FILE"
subagent_enabled && ok "custom subagent command is enabled" || bad "custom subagent command is enabled"
for invalid in \
  '{"subagentStatusLine":true}' \
  '{"subagentStatusLine":"yes"}' \
  '{"subagentStatusLine":{}}' \
  '{"subagentStatusLine":{"type":"prompt","command":"bash x --subagent"}}' \
  '{"subagentStatusLine":{"type":"command","command":true}}' \
  '{"subagentStatusLine":{"type":"command","command":"bash x"}}'
do
  printf '%s\n' "$invalid" > "$SETTINGS_FILE"
  subagent_enabled && bad "invalid subagent schema rejected: $invalid" || ok "invalid subagent schema rejected"
done
SETTINGS_FILE="$MAIN_SETTINGS"

# (2) enable/disable preserve unrelated keys and write a backup
jq '.statusLine = {"type":"command","command":"x"} | .other = 1' "$SETTINGS_FILE" > "$TMPD/t" && mv "$TMPD/t" "$SETTINGS_FILE"
disable_subagent_statusline >/dev/null
jq -e 'has("subagentStatusLine") | not' "$SETTINGS_FILE" >/dev/null && ok "disable removes entry" || bad "disable removes entry"
jq -e '.other == 1 and .statusLine.command == "x"' "$SETTINGS_FILE" >/dev/null && ok "other keys preserved" || bad "other keys preserved"
ls "$SETTINGS_FILE".bak.* >/dev/null 2>&1 && ok "backup written" || bad "backup written"
subagent_enabled && bad "state reads disabled" || ok "state reads disabled"

# (3) broken JSON → die, original untouched
printf '{broken' > "$SETTINGS_FILE"
( enable_subagent_statusline ) >/dev/null 2>&1 && bad "broken json dies" || ok "broken json dies"
[ "$(cat "$SETTINGS_FILE")" = "{broken" ] && ok "original untouched on failure" || bad "original untouched on failure"

# (3a) an existing zero-byte file starts from an empty object, not empty jq output
EMPTYD="$TMPD/empty"; mkdir -p "$EMPTYD"; EMPTYFILE="$EMPTYD/settings.json"
: > "$EMPTYFILE"
SETTINGS_FILE="$EMPTYFILE"
enable_subagent_statusline >/dev/null
jq -e '.subagentStatusLine.command | endswith("--subagent")' "$EMPTYFILE" >/dev/null 2>&1 \
  && ok "zero-byte settings creates entry" || bad "zero-byte settings creates entry"
set -- "$EMPTYFILE".bak.*
[ -f "$1" ] && [ ! -s "$1" ] && ok "zero-byte settings backup preserved" || bad "zero-byte settings backup preserved"

EMPTYOFF="$EMPTYD/disabled.json"
: > "$EMPTYOFF"
SETTINGS_FILE="$EMPTYOFF"
disable_subagent_statusline >/dev/null 2>&1
[ ! -s "$EMPTYOFF" ] && ok "zero-byte settings is already disabled" || bad "zero-byte disable changed settings"
set -- "$EMPTYOFF".bak.*
[ ! -e "$1" ] && ok "zero-byte disable skips backup" || bad "zero-byte disable wrote backup"
SETTINGS_FILE="$MAIN_SETTINGS"

# (3b) backup and replacement failures stop before callers can report success
CPD="$TMPD/cp-fail"; mkdir -p "$CPD"; CPFILE="$CPD/settings.json"
printf '{"original":1}\n' > "$CPFILE"
CPOUT=$(
  SETTINGS_FILE="$CPFILE"
  cp() { printf 'partial\n' > "$2"; return 1; }
  enable_subagent_statusline 2>&1
  )
CPRC=$?
[ "$CPRC" != 0 ] && ok "backup failure exits non-zero" || bad "backup failure exits non-zero"
[ "$(cat "$CPFILE")" = '{"original":1}' ] && ok "backup failure preserves original" || bad "backup failure preserves original"
case "$CPOUT" in (*"Updated "*) bad "backup failure printed success" ;; (*) ok "backup failure prints no success" ;; esac
set -- "$CPFILE".bak.*; [ ! -e "$1" ] && ok "partial backup removed" || bad "partial backup removed"
set -- "$CPD"/.coralline-settings.*; [ ! -e "$1" ] && ok "backup failure temp removed" || bad "backup failure temp removed"

MVD="$TMPD/mv-fail"; mkdir -p "$MVD"; MVFILE="$MVD/settings.json"
printf '{"original":1}\n' > "$MVFILE"
MVOUT=$(
  SETTINGS_FILE="$MVFILE"
  mv() { return 1; }
  enable_subagent_statusline 2>&1
  )
MVRC=$?
[ "$MVRC" != 0 ] && ok "replace failure exits non-zero" || bad "replace failure exits non-zero"
[ "$(cat "$MVFILE")" = '{"original":1}' ] && ok "replace failure preserves original" || bad "replace failure preserves original"
case "$MVOUT" in (*"Updated "*) bad "replace failure printed success" ;; (*) ok "replace failure prints no success" ;; esac
ls "$MVFILE".bak.* >/dev/null 2>&1 && ok "replace failure keeps backup" || bad "replace failure keeps backup"
set -- "$MVD"/.coralline-settings.*; [ ! -e "$1" ] && ok "replace failure temp removed" || bad "replace failure temp removed"

# (3c) two writes in one second preserve both pre-write states
COLLD="$TMPD/collision"; mkdir -p "$COLLD"; COLLFILE="$COLLD/settings.json"
printf '{"step":0}\n' > "$COLLFILE"
(
  SETTINGS_FILE="$COLLFILE"
  date() { printf '20260716123456\n'; }
  settings_merge '.step = 1'
  settings_merge '.step = 2'
) >/dev/null
jq -e '.step == 0' "$COLLFILE.bak.20260716123456" >/dev/null 2>&1 \
  && ok "first same-second backup preserved" || bad "first same-second backup preserved"
jq -e '.step == 1' "$COLLFILE.bak.20260716123456.1" >/dev/null 2>&1 \
  && ok "second same-second backup preserved" || bad "second same-second backup preserved"

# (4) one shared settings.json merge pipeline — update_settings and the subagent
# toggle must go through the same settings_merge helper, not three hand copies
type settings_merge >/dev/null 2>&1 && ok "shared settings_merge helper exists" || bad "shared settings_merge helper exists"
rm -f "$SETTINGS_FILE" "$SETTINGS_FILE".bak.*
update_settings >/dev/null
jq -e '.statusLine.type == "command" and .statusLine.refreshInterval == 1' \
  "$SETTINGS_FILE" >/dev/null && ok "update_settings creates statusLine" || bad "update_settings creates statusLine"
enable_subagent_statusline >/dev/null
jq -e '.statusLine.refreshInterval == 1 and .subagentStatusLine.type == "command"' \
  "$SETTINGS_FILE" >/dev/null && ok "both keys coexist via shared helper" || bad "both keys coexist via shared helper"

# (4a) generated shell commands quote an install path containing spaces
SPACE_DIR="$TMPD/install with spaces"; mkdir -p "$SPACE_DIR"
cp "$HERE/../statusline.sh" "$SPACE_DIR/statusline.sh"
SPACE_SETTINGS="$TMPD/space-settings.json"
TARGET_DIR="$SPACE_DIR"; SETTINGS_FILE="$SPACE_SETTINGS"
update_settings >/dev/null
MAIN_COMMAND=$(jq -r '.statusLine.command' "$SPACE_SETTINGS")
MAIN_RENDER=$(CORALLINE_CONFIG=/dev/null bash -c "$MAIN_COMMAND" < "$HERE/sample-input.json")
[ -n "$MAIN_RENDER" ] && ok "statusLine command quotes spaced path" || bad "statusLine command quotes spaced path"
enable_subagent_statusline >/dev/null
SUB_COMMAND=$(jq -r '.subagentStatusLine.command' "$SPACE_SETTINGS")
SUB_RENDER=$(printf '%s\n' '{"tasks":[{"id":"space","type":"local_agent","label":"space path"}]}' \
  | CORALLINE_CONFIG=/dev/null bash -c "$SUB_COMMAND")
printf '%s\n' "$SUB_RENDER" | jq -e '.id == "space"' >/dev/null 2>&1 \
  && ok "subagent command quotes spaced path" || bad "subagent command quotes spaced path"
TARGET_DIR="$HOME/.claude/coralline"; SETTINGS_FILE="$MAIN_SETTINGS"

# (4b) the non-interactive flag drives the same toggle (AI-install path)
rm -f "$SETTINGS_FILE" "$SETTINGS_FILE".bak.*
CLAUDE_SETTINGS="$SETTINGS_FILE" bash "$CONF" --subagent-rows=on >/dev/null 2>&1
jq -e '.subagentStatusLine.command | endswith("--subagent")' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "--subagent-rows=on registers" || bad "--subagent-rows=on registers"
CLAUDE_SETTINGS="$SETTINGS_FILE" bash "$CONF" --subagent-rows=off >/dev/null 2>&1
jq -e 'has("subagentStatusLine") | not' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "--subagent-rows=off removes" || bad "--subagent-rows=off removes"

# (4b2) an update leaves a statusLine that already runs this install as the user
# has it: refreshInterval, padding and a wrapped command survive, byte for byte,
# and no backup is written. A statusLine that runs something else is replaced.
KEEPD="$TMPD/keep"; mkdir -p "$KEEPD"; SETTINGS_FILE="$KEEPD/settings.json"
printf '{"statusLine":{"type":"command","command":"CORALLINE_CONFIG=/tmp/x.conf bash %s/statusline.sh","refreshInterval":5,"padding":2},"other":1}\n' "$TARGET_DIR" > "$SETTINGS_FILE"
cp "$SETTINGS_FILE" "$KEEPD/before"
KEEPOUT=$(update_settings)
cmp -s "$SETTINGS_FILE" "$KEEPD/before" && ok "update keeps an existing coralline statusLine byte for byte" || bad "update keeps an existing coralline statusLine byte for byte"
ls "$SETTINGS_FILE".bak.* >/dev/null 2>&1 && bad "update without a change writes no backup" || ok "update without a change writes no backup"
case "$KEEPOUT" in (*"left as it is"*) ok "update says it left statusLine alone" ;; (*) bad "update says it left statusLine alone" ;; esac
printf '{"statusLine":{"type":"command","command":"bash /opt/other/prompt.sh","refreshInterval":9}}\n' > "$SETTINGS_FILE"
update_settings >/dev/null
jq -e --arg p "$TARGET_DIR/statusline.sh" '(.statusLine.command | contains($p)) and .statusLine.refreshInterval == 1' "$SETTINGS_FILE" >/dev/null 2>&1 \
  && ok "a statusLine that runs something else is replaced" || bad "a statusLine that runs something else is replaced"
ls "$SETTINGS_FILE".bak.* >/dev/null 2>&1 && ok "the replaced statusLine is backed up" || bad "the replaced statusLine is backed up"

# (4b3) a subagentStatusLine from another tool is never replaced or removed
printf '{"subagentStatusLine":{"type":"command","command":"other-tool --rows"}}\n' > "$SETTINGS_FILE"
cp "$SETTINGS_FILE" "$KEEPD/before"
enable_subagent_statusline >/dev/null 2>&1 && bad "enable refuses another tool's entry" || ok "enable refuses another tool's entry"
cmp -s "$SETTINGS_FILE" "$KEEPD/before" && ok "enable leaves another tool's entry" || bad "enable leaves another tool's entry"
disable_subagent_statusline >/dev/null 2>&1
cmp -s "$SETTINGS_FILE" "$KEEPD/before" && ok "disable leaves another tool's entry" || bad "disable leaves another tool's entry"
CLAUDE_SETTINGS="$SETTINGS_FILE" bash "$CONF" --subagent-rows=on >/dev/null 2>&1 && bad "--subagent-rows=on exits non-zero on another tool's entry" || ok "--subagent-rows=on exits non-zero on another tool's entry"
# our own entry, wrapped: enabling again changes nothing
printf '{"subagentStatusLine":{"type":"command","command":"CORALLINE_CONFIG=/tmp/s.conf bash /tmp/statusline.sh --subagent"}}\n' > "$SETTINGS_FILE"
cp "$SETTINGS_FILE" "$KEEPD/before"
enable_subagent_statusline >/dev/null 2>&1
cmp -s "$SETTINGS_FILE" "$KEEPD/before" && ok "enable keeps an existing wrapped entry" || bad "enable keeps an existing wrapped entry"
SETTINGS_FILE="$MAIN_SETTINGS"

# (4c) explicit no-menu setup modes must not ask the closing wizard question
DEFAULTD="$TMPD/default-mode"; mkdir -p "$DEFAULTD/home"
DEFOUT=$(HOME="$DEFAULTD/home" CORALLINE_CONFIG="$DEFAULTD/coralline.conf" \
  CLAUDE_SETTINGS="$DEFAULTD/settings.json" bash "$CONF" --default </dev/null 2>&1)
DEFRC=$?
[ "$DEFRC" = 0 ] && ok "--default exits successfully" || bad "--default exits: rc=$DEFRC"
case "$DEFOUT" in
  (*"Render subagent panel rows"*) bad "--default prompted for subagent rows" ;;
  (*) ok "--default skips subagent prompt" ;;
esac

# (5) the wizard's preview render shows every segment, including elapsed
installed=0
runtime_statusline() { printf '%s\n' "$HERE/../statusline.sh"; }
CONFIG_FILE=/dev/null
eval "$(sed -n '/^verify_subagent_render() {/,/^}/p' "$CONF")"
PREV=$(verify_subagent_render)
case "$PREV" in (*"⧖"*) ok "preview shows the elapsed segment" ;; (*) bad "preview shows the elapsed segment" ;; esac
case "$PREV" in (*"Haiku 4.5"*"▰"*) ok "preview shows model + gauge" ;; (*) bad "preview shows model + gauge" ;; esac

exit "$fail"
