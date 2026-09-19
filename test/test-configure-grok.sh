#!/usr/bin/env bash
# --register-grok: append-if-absent Grok [ui.status_line], symlink-safe, no wizard,
# no Claude settings write, no coralline.conf rewrite. Invokes the real
# configure.sh argv exit path (not extracted helpers).
#
#   bash test/test-configure-grok.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CONF="$REPO/configure.sh"

fail=0
ok()    { printf 'ok    %s\n' "$1"; }
bad()   { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }

# Pin HOME plus every helper override. Sentinels sit on HOME's default paths;
# GROK_HOME / CORALLINE_* / CLAUDE_SETTINGS then point at the work sandbox so a
# missed override would mutate a sentinel.
new_sandbox() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/coralline-register-grok.XXXXXX") || exit 1
  SENTINEL_HOME="$SANDBOX/sentinel-home"
  mkdir -p "$SENTINEL_HOME/.grok" "$SENTINEL_HOME/.claude/coralline"
  printf 'SENTINEL_GROK\n' > "$SENTINEL_HOME/.grok/config.toml"
  printf 'SENTINEL_CONF\n' > "$SENTINEL_HOME/.claude/coralline.conf"
  printf 'SENTINEL_SETTINGS\n' > "$SENTINEL_HOME/.claude/settings.json"
  printf 'SENTINEL_STATUSLINE\n' > "$SENTINEL_HOME/.claude/coralline/statusline.sh"
  export HOME="$SENTINEL_HOME"
  export GROK_HOME="$SENTINEL_HOME/.grok"
  export CORALLINE_HOME="$SENTINEL_HOME/.claude/coralline"
  export CORALLINE_CONFIG="$SENTINEL_HOME/.claude/coralline.conf"
  export CLAUDE_SETTINGS="$SENTINEL_HOME/.claude/settings.json"

  WORK="$SANDBOX/work"
  mkdir -p "$WORK/grok" "$WORK/coralline"
  cp "$REPO/statusline.sh" "$WORK/coralline/statusline.sh"
  cp "$REPO/statusline-grok.sh" "$WORK/coralline/statusline-grok.sh"
  chmod +x "$WORK/coralline/statusline.sh" "$WORK/coralline/statusline-grok.sh"
  printf 'PREEXISTING_CONF\n' > "$WORK/coralline.conf"
  export GROK_HOME="$WORK/grok"
  export CORALLINE_HOME="$WORK/coralline"
  export CORALLINE_CONFIG="$WORK/coralline.conf"
  export CLAUDE_SETTINGS="$WORK/settings.json"
}

sentinels_ok() {
  [ "$(cat "$SENTINEL_HOME/.grok/config.toml")" = "SENTINEL_GROK" ] \
    && [ "$(cat "$SENTINEL_HOME/.claude/coralline.conf")" = "SENTINEL_CONF" ] \
    && [ "$(cat "$SENTINEL_HOME/.claude/settings.json")" = "SENTINEL_SETTINGS" ] \
    && [ "$(cat "$SENTINEL_HOME/.claude/coralline/statusline.sh")" = "SENTINEL_STATUSLINE" ]
}

conf_untouched() {
  [ "$(cat "$CORALLINE_CONFIG")" = "PREEXISTING_CONF" ]
}

settings_absent() {
  [ ! -e "$CLAUDE_SETTINGS" ]
}

run_register() {
  local outf
  outf=$(mktemp "${TMPDIR:-/tmp}/coralline-rg-out.XXXXXX") || exit 1
  # </dev/null is the whole timeout: --register-grok never opens the wizard, and
  # anything that did read stdin gets EOF immediately. An `alarm` wrapper here
  # would only add perl to the test dependencies.
  env CORALLINE_NO_SAMPLE=1 \
      HOME="$HOME" \
      GROK_HOME="$GROK_HOME" \
      CORALLINE_HOME="$CORALLINE_HOME" \
      CORALLINE_CONFIG="$CORALLINE_CONFIG" \
      CLAUDE_SETTINGS="$CLAUDE_SETTINGS" \
    bash "$CONF" --register-grok </dev/null >"$outf" 2>&1
  RG_RC=$?
  RG_OUT=$(cat "$outf")
  rm -f "$outf"
}

abs_statusline() {
  printf '%s/statusline-grok.sh\n' "$(cd "$GROK_HOME/coralline" && pwd)"
}

# --- missing config.toml is created with the table --------------------------------
new_sandbox
run_register
cfg="$GROK_HOME/config.toml"
cmd=$(abs_statusline)
check "missing config.toml exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
[ -f "$cfg" ] && check "missing config.toml is created" 1 || check "missing config.toml is created" 0
grep -q '^\[ui.status_line\]$' "$cfg" && check "created table header" 1 || check "created table header" 0
grep -q '^type = "command"$' "$cfg" && check "created type = command" 1 || check "created type = command" 0
grep -q '^refresh_interval = 1$' "$cfg" && check "created refresh_interval = 1" 1 || check "created refresh_interval = 1" 0
case "$(cat "$cfg")" in
  *"bash $cmd"*|*"bash \"$cmd\""*) check "created command runs statusline-grok.sh via bash" 1 ;;
  *) check "created command runs statusline-grok.sh via bash" 0 ;;
esac
[ -f "$GROK_HOME/coralline.conf" ] && grep -q 'VL_LIMIT_SYNC=0' "$GROK_HOME/coralline.conf" \
  && check "created Grok coralline.conf with VL_LIMIT_SYNC=0" 1 \
  || check "created Grok coralline.conf with VL_LIMIT_SYNC=0" 0
[ -d "$GROK_HOME/coralline" ] && check "created Grok CORALLINE_DIR" 1 \
  || check "created Grok CORALLINE_DIR" 0
# The config is assembled in a sibling temp file and renamed into place; a
# leftover means a failure path skipped its cleanup.
[ -z "$(find "$GROK_HOME" -maxdepth 1 -name '.coralline-grok.*' 2>/dev/null)" ] \
  && check "no temp file left beside config.toml" 1 \
  || check "no temp file left beside config.toml" 0
[ -x "$GROK_HOME/coralline/statusline-grok.sh" ] && [ -f "$GROK_HOME/coralline/statusline.sh" ] \
  && check "Grok runtime scripts live under GROK_HOME/coralline" 1 \
  || check "Grok runtime scripts live under GROK_HOME/coralline" 0
case "$RG_OUT" in (*"Updated "*) check "prints Updated after append" 1 ;;
                 (*)             check "prints Updated after append" 0 ;; esac
sentinels_ok && check "sentinels unmodified (create)" 1 || check "sentinels unmodified (create)" 0
conf_untouched && check "pre-existing coralline.conf byte-identical (create)" 1 \
  || check "pre-existing coralline.conf byte-identical (create)" 0
settings_absent && check "sandbox CLAUDE_SETTINGS absent (create)" 1 \
  || check "sandbox CLAUDE_SETTINGS absent (create)" 0
rm -rf "$SANDBOX"

# --- existing unrelated TOML keys survive ----------------------------------------
new_sandbox
printf 'model = "grok-4"\nverbose = true\n' > "$GROK_HOME/config.toml"
run_register
cfg="$GROK_HOME/config.toml"
grep -q '^model = "grok-4"$' "$cfg" && grep -q '^verbose = true$' "$cfg" \
  && grep -q '^\[ui.status_line\]$' "$cfg" \
  && check "unrelated TOML keys survive append" 1 \
  || check "unrelated TOML keys survive append" 0
check "unrelated keys path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
sentinels_ok && check "sentinels unmodified (unrelated)" 1 || check "sentinels unmodified (unrelated)" 0
conf_untouched && check "coralline.conf byte-identical (unrelated)" 1 \
  || check "coralline.conf byte-identical (unrelated)" 0
settings_absent && check "CLAUDE_SETTINGS absent (unrelated)" 1 \
  || check "CLAUDE_SETTINGS absent (unrelated)" 0
rm -rf "$SANDBOX"

# --- existing [ui.status_line] is not rewritten ----------------------------------
new_sandbox
printf '[ui.status_line]\ntype = "command"\ncommand = "keep-me"\nrefresh_interval = 9\n' \
  > "$GROK_HOME/config.toml"
before=$(cat "$GROK_HOME/config.toml")
run_register
after=$(cat "$GROK_HOME/config.toml")
[ "$before" = "$after" ] && check "existing [ui.status_line] bytes stay" 1 \
  || check "existing [ui.status_line] bytes stay" 0
grep -q 'keep-me' "$GROK_HOME/config.toml" && grep -q 'refresh_interval = 9' "$GROK_HOME/config.toml" \
  && check "existing table body not replaced" 1 \
  || check "existing table body not replaced" 0
check "existing table path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
case "$RG_OUT" in (*unchanged*) check "prints unchanged when table exists" 1 ;;
                 (*)            check "prints unchanged when table exists" 0 ;; esac
sentinels_ok && check "sentinels unmodified (existing table)" 1 \
  || check "sentinels unmodified (existing table)" 0
conf_untouched && check "coralline.conf byte-identical (existing table)" 1 \
  || check "coralline.conf byte-identical (existing table)" 0
settings_absent && check "CLAUDE_SETTINGS absent (existing table)" 1 \
  || check "CLAUDE_SETTINGS absent (existing table)" 0
rm -rf "$SANDBOX"

# --- symlink: target receives the append; symlink path still points at it --------
new_sandbox
printf 'foo = 1\n' > "$WORK/real.toml"
ln -s "$WORK/real.toml" "$GROK_HOME/config.toml"
run_register
[ -L "$GROK_HOME/config.toml" ] && check "config path remains a symlink" 1 \
  || check "config path remains a symlink" 0
[ "$(readlink "$GROK_HOME/config.toml")" = "$WORK/real.toml" ] \
  && check "symlink still points at the target" 1 \
  || check "symlink still points at the target" 0
grep -q '^foo = 1$' "$WORK/real.toml" && grep -q '^\[ui.status_line\]$' "$WORK/real.toml" \
  && check "symlink target received the append" 1 \
  || check "symlink target received the append" 0
check "symlink path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
sentinels_ok && check "sentinels unmodified (symlink)" 1 || check "sentinels unmodified (symlink)" 0
conf_untouched && check "coralline.conf byte-identical (symlink)" 1 \
  || check "coralline.conf byte-identical (symlink)" 0
settings_absent && check "CLAUDE_SETTINGS absent (symlink)" 1 \
  || check "CLAUDE_SETTINGS absent (symlink)" 0
rm -rf "$SANDBOX"

# --- nested symlink: the append reaches the FINAL target -------------------------
# The write ends in a rename, and a rename replaces the path it is handed. Stop
# at an intermediate link and that link becomes a regular file while the real
# config never changes, which is what happened before the chain was followed.
new_sandbox
printf 'foo = 1\n' > "$WORK/final.toml"
ln -s "$WORK/final.toml" "$WORK/mid.toml"
ln -s "$WORK/mid.toml" "$GROK_HOME/config.toml"
run_register
check "nested symlink path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
[ -L "$GROK_HOME/config.toml" ] && [ -L "$WORK/mid.toml" ] \
  && check "every link in the chain stays a link" 1 \
  || check "every link in the chain stays a link" 0
grep -q '^foo = 1$' "$WORK/final.toml" && grep -q '^\[ui.status_line\]$' "$WORK/final.toml" \
  && check "final target received the append" 1 \
  || check "final target received the append" 0
rm -rf "$SANDBOX"

# --- symlink cycle terminates instead of spinning --------------------------------
new_sandbox
ln -s "$WORK/loop-b.toml" "$WORK/loop-a.toml"
ln -s "$WORK/loop-a.toml" "$WORK/loop-b.toml"
ln -s "$WORK/loop-a.toml" "$GROK_HOME/config.toml"
run_register
check "symlink cycle fails instead of hanging" "$([ "$RG_RC" -ne 0 ] && echo 1 || echo 0)"
case "$RG_OUT" in
  (*"too many levels of symbolic links"*) check "symlink cycle names the reason" 1 ;;
  (*)                                     check "symlink cycle names the reason" 0 ;;
esac
rm -rf "$SANDBOX"

# --- [ui.status_line.extra] already defines the parent; do not append -------------
new_sandbox
printf '[ui.status_line.extra]\nfoo = 1\n' > "$GROK_HOME/config.toml"
run_register
if grep -q '^\[ui.status_line\]$' "$GROK_HOME/config.toml"; then
  check "nested extra does not append [ui.status_line]" 0
else
  check "nested extra does not append [ui.status_line]" 1
fi
grep -q '^\[ui.status_line.extra\]$' "$GROK_HOME/config.toml" \
  && check "nested extra table remains" 1 \
  || check "nested extra table remains" 0
check "nested extra path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
sentinels_ok && check "sentinels unmodified (nested extra)" 1 \
  || check "sentinels unmodified (nested extra)" 0
conf_untouched && check "coralline.conf byte-identical (nested extra)" 1 \
  || check "coralline.conf byte-identical (nested extra)" 0
rm -rf "$SANDBOX"

# --- CRLF [ui.status_line] is still treated as present -----------------------------
new_sandbox
printf '[ui.status_line]\r\ntype = "command"\r\n' > "$GROK_HOME/config.toml"
run_register
grep -c '\[ui.status_line\]' "$GROK_HOME/config.toml" | grep -qx 1 \
  && check "CRLF table is not duplicated" 1 \
  || check "CRLF table is not duplicated" 0
check "CRLF table path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
rm -rf "$SANDBOX"

# --- every legal spelling of the key blocks the append ----------------------------
# Appending a second definition of ui.status_line does not break that one key,
# it makes the WHOLE file unparseable. A guard that only matches the spelling we
# write leaves the realistic cases -- a status line already configured under an
# existing [ui] table -- silently corrupted, with "Updated" printed.
spelling_case() { # $1 label $2 config.toml body
  new_sandbox
  printf '%s' "$2" > "$GROK_HOME/config.toml"
  before=$(cat "$GROK_HOME/config.toml")
  run_register
  after=$(cat "$GROK_HOME/config.toml")
  [ "$before" = "$after" ] && check "$1: config.toml is left byte-identical" 1 \
    || check "$1: config.toml is left byte-identical" 0
  grep -q '^\[ui.status_line\]$' "$GROK_HOME/config.toml" \
    && check "$1: no [ui.status_line] appended" 0 \
    || check "$1: no [ui.status_line] appended" 1
  check "$1: exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
  case "$RG_OUT" in
    (*"command = \"bash "*) check "$1: prints the command to set by hand" 1 ;;
    (*)                     check "$1: prints the command to set by hand" 0 ;;
  esac
  sentinels_ok && check "$1: sentinels unmodified" 1 || check "$1: sentinels unmodified" 0
  rm -rf "$SANDBOX"
}
spelling_case "spaced header"  '[ ui.status_line ]
type = "command"
'
spelling_case "quoted keys"    '["ui"."status_line"]
type = "command"
'
spelling_case "inline table"   '[ui]
status_line = { type = "command", command = "mine" }
'
spelling_case "dotted key"     '[ui]
status_line.type = "command"
status_line.command = "mine"
'
# A quoted key may spell the name with escapes and carry none of the literal
# text. Both of these parse to ui.status_line; appending after either is invalid
# TOML (checked with tomllib). The backslash is built with printf '\134' rather
# than written literally so no layer between here and the file can fold the
# escape back into an "s" -- which is exactly what happened to an earlier
# version of these two cases, leaving them silent duplicates of "quoted keys".
bs=$(printf '\134')
spelling_case "escaped header" "[\"ui\".\"${bs}u0073tatus_line\"]
type = \"command\"
"
spelling_case "escaped key"    "[ui]
\"${bs}u0073tatus_line\".type = \"command\"
"

# ...but an escape in a VALUE is ordinary TOML, and appending after it is valid.
# Refusing on every \u in the file would block honest configs for nothing.
new_sandbox
printf '%s' "[ui]
greeting = \"caf${bs}u00e9\"
" > "$GROK_HOME/config.toml"
run_register
grep -q '^\[ui.status_line\]$' "$GROK_HOME/config.toml" \
  && check "escape in a value does not block registration" 1 \
  || check "escape in a value does not block registration" 0
grep -q 'caf' "$GROK_HOME/config.toml" \
  && check "escape in a value survives the append" 1 \
  || check "escape in a value survives the append" 0
rm -rf "$SANDBOX"

# --- Grok-only machine: nothing is created under the Claude tree ------------------
new_sandbox
export CORALLINE_HOME="$WORK/no-claude-here/coralline"
run_register
check "Grok-only exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
[ -e "$WORK/no-claude-here" ] \
  && check "Grok-only does not create a Claude runtime dir" 0 \
  || check "Grok-only does not create a Claude runtime dir" 1
[ -x "$GROK_HOME/coralline/statusline-grok.sh" ] \
  && check "Grok-only still installs the Grok runtime" 1 \
  || check "Grok-only still installs the Grok runtime" 0
sentinels_ok && check "sentinels unmodified (Grok-only)" 1 \
  || check "sentinels unmodified (Grok-only)" 0
rm -rf "$SANDBOX"

# --- themes travel with the Grok runtime ------------------------------------------
new_sandbox
run_register
[ -f "$GROK_HOME/coralline/themes/claude-coral.conf" ] \
  && check "themes are installed under GROK_HOME" 1 \
  || check "themes are installed under GROK_HOME" 0
# The generated conf must source the Grok copy: a Grok-only user is told not to
# run --install, so a $TARGET_DIR path would break the moment Claude's tree goes.
# Only the source line: the header comment mentions ~/.claude/coralline.conf.
# The path is matched by suffix because gdir comes from `cd … && pwd`, which
# resolves symlinks (macOS /var -> /private/var).
srcline=$(grep '^\. ' "$GROK_HOME/coralline.conf")
case "$srcline" in
  (*/.claude/*)                            check "generated conf sources the Grok theme copy" 0 ;;
  (*coralline/themes/claude-coral.conf*)   check "generated conf sources the Grok theme copy" 1 ;;
  (*)                                      check "generated conf sources the Grok theme copy" 0 ;;
esac
rm -rf "$SANDBOX"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
