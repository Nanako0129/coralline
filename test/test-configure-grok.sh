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
  chmod +x "$WORK/coralline/statusline.sh"
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
  perl -e 'alarm 10; exec @ARGV' \
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
  printf '%s/statusline.sh\n' "$(cd "$CORALLINE_HOME" && pwd)"
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
grep -Fq "$cmd" "$cfg" && grep -Fq "CORALLINE_CONFIG=" "$cfg" && grep -Fq "CORALLINE_DIR=" "$cfg" \
  && check "created command pins Grok conf/dir and statusline.sh" 1 \
  || check "created command pins Grok conf/dir and statusline.sh" 0
[ -f "$GROK_HOME/coralline.conf" ] && grep -q 'VL_LIMIT_SYNC=0' "$GROK_HOME/coralline.conf" \
  && check "created Grok coralline.conf with VL_LIMIT_SYNC=0" 1 \
  || check "created Grok coralline.conf with VL_LIMIT_SYNC=0" 0
[ -d "$GROK_HOME/coralline" ] && check "created Grok CORALLINE_DIR" 1 \
  || check "created Grok CORALLINE_DIR" 0
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

# --- [ui.status_line.extra] is not the status_line table -----------------------------
new_sandbox
printf '[ui.status_line.extra]\nfoo = 1\n' > "$GROK_HOME/config.toml"
run_register
grep -q '^\[ui.status_line\]$' "$GROK_HOME/config.toml" \
  && grep -q '^\[ui.status_line.extra\]$' "$GROK_HOME/config.toml" \
  && check "nested extra table does not block [ui.status_line]" 1 \
  || check "nested extra table does not block [ui.status_line]" 0
check "nested extra path exits 0" "$([ "$RG_RC" -eq 0 ] && echo 1 || echo 0)"
sentinels_ok && check "sentinels unmodified (nested extra)" 1 \
  || check "sentinels unmodified (nested extra)" 0
conf_untouched && check "coralline.conf byte-identical (nested extra)" 1 \
  || check "coralline.conf byte-identical (nested extra)" 0
rm -rf "$SANDBOX"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
