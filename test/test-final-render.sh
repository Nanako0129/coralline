#!/usr/bin/env bash
# Regression: the post-install "Verification render:" must print after a
# successful --install, regardless of VL_FLOAT, and must NOT print when the
# config write fails.
#
# write_final_config used to end with `[ "$float_enabled" = "1" ] && print_float_help`,
# whose exit status is 1 when float is off (the default). The caller runs
# `write_final_config || exit 0`, so that non-zero status silently skipped the
# verify_render step and the final "Verification render:" vanished. It now
# returns 0 on the success path (the only intentional non-zero is a declined
# overwrite), but guards mkdir/mv with `|| die` so a failed write still stops
# rather than reporting a false success.
#   bash test/test-final-render.sh
# Needs bash + jq (configure.sh merges Claude settings with jq).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
fail=0
check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }

# Drive a real --install with every path pinned into the sandbox. Pinning
# CORALLINE_HOME/CONFIG and CLAUDE_SETTINGS (not just HOME) keeps the test
# hermetic even when a dev/CI shell exports those overrides, so it can never
# write into the real ~/.claude. CORALLINE_NO_SAMPLE keeps the verify render off
# the cross-session stores (#32).
run_install() { # $1 = sandbox HOME, $2 = CONFIG_FILE path
  CORALLINE_NO_SAMPLE=1 HOME="$1" \
    CORALLINE_HOME="$1/.claude/coralline" \
    CLAUDE_SETTINGS="$1/.claude/settings.json" \
    CORALLINE_CONFIG="$2" \
    bash "$REPO/configure.sh" --install --default 2>&1
}

# --- Case 1: fresh install, float OFF (the default) -> render must print ------
h1=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
out1=$(run_install "$h1" "$h1/.claude/coralline.conf")
case "$out1" in
  *"Verification render:"*) check "post-install verification render prints (float off)" 1 ;;
  *)                        check "post-install verification render prints (float off)" 0 ;;
esac
[ -f "$h1/.claude/coralline.conf" ] && check "coralline.conf was written" 1 || check "coralline.conf was written" 0
rm -rf "$h1"

# --- Case 2: unwritable config path -> die, no false success render ----------
h2=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
: > "$h2/blocker"                                  # a regular file where a dir must be
out2=$(run_install "$h2" "$h2/blocker/coralline.conf"); rc2=$?
[ "$rc2" -ne 0 ] && check "failed config write exits non-zero" 1 || check "failed config write exits non-zero" 0
case "$out2" in
  *"Verification render:"*) check "no verification render after a failed write" 0 ;;
  *)                        check "no verification render after a failed write" 1 ;;
esac
rm -rf "$h2"

# --- Case 3: config path is a directory -> die before mv, no false success ---
# mv into a directory would otherwise "succeed" (temp file dropped inside it),
# leaving $CONFIG_FILE a directory that statusline.sh never sources.
h3=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
mkdir -p "$h3/.claude/coralline.conf"             # a DIRECTORY at the config path
out3=$(run_install "$h3" "$h3/.claude/coralline.conf"); rc3=$?
[ "$rc3" -ne 0 ] && check "directory config path exits non-zero" 1 || check "directory config path exits non-zero" 0
[ -d "$h3/.claude/coralline.conf" ] && check "directory config path left intact (no temp file dropped in)" "$([ -z "$(find "$h3/.claude/coralline.conf" -type f 2>/dev/null)" ] && echo 1 || echo 0)" || check "directory config path left intact" 0
case "$out3" in
  *"Verification render:"*) check "no verification render for a directory config path" 0 ;;
  *)                        check "no verification render for a directory config path" 1 ;;
esac
rm -rf "$h3"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
