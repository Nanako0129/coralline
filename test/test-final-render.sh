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
    "$BASH" "$REPO/configure.sh" --install --default 2>&1
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

# --- Case 4: overwriting an existing config keeps the old file beside it ------
# The wizard builds the new config from its own answers, so anything added by
# hand is dropped by the overwrite; the previous file must survive as a backup.
hb=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
mkdir -p "$hb/.claude"
printf 'VL_SEGMENTS="dir"\nMY_HAND_KNOB=1\n' > "$hb/.claude/coralline.conf"
outb=$(printf 'y\n' | run_install "$hb" "$hb/.claude/coralline.conf")
set -- "$hb/.claude"/coralline.conf.bak.*
if [ -f "$1" ] && grep -q '^MY_HAND_KNOB=1$' "$1"; then check "overwritten config is kept as a backup" 1; else check "overwritten config is kept as a backup" 0; fi
grep -q 'MY_HAND_KNOB' "$hb/.claude/coralline.conf" && check "the new config is the wizard's" 0 || check "the new config is the wizard's" 1
case "$outb" in (*"Previous config kept at"*) check "the backup path is printed" 1 ;; (*) check "the backup path is printed" 0 ;; esac
# declining the overwrite writes no backup
printf 'VL_SEGMENTS="dir"\nMY_HAND_KNOB=1\n' > "$hb/.claude/coralline.conf"; rm -f "$hb/.claude"/coralline.conf.bak.*
printf 'n\n' | run_install "$hb" "$hb/.claude/coralline.conf" >/dev/null
set -- "$hb/.claude"/coralline.conf.bak.*
[ -e "$1" ] && check "a declined overwrite writes no backup" 0 || check "a declined overwrite writes no backup" 1
rm -rf "$hb"

# --- Case 5: a symlinked coralline.conf stays a symlink ----------------------
# The new config lands in the link's target (a dotfiles copy), replaced by
# rename so it is never half-written; the link itself is not turned into a file.
hl=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
mkdir -p "$hl/.claude" "$hl/dotfiles"
printf 'VL_SEGMENTS="dir"\nMY_HAND_KNOB=1\n' > "$hl/dotfiles/coralline.conf"
ln -s "$hl/dotfiles/coralline.conf" "$hl/.claude/coralline.conf"
printf 'y\n' | run_install "$hl" "$hl/.claude/coralline.conf" >/dev/null
[ -L "$hl/.claude/coralline.conf" ] && check "a symlinked config is still a symlink" 1 || check "a symlinked config is still a symlink" 0
grep -q 'MY_HAND_KNOB' "$hl/dotfiles/coralline.conf" && check "the link target holds the new config" 0 || check "the link target holds the new config" 1
set -- "$hl/dotfiles"/*.new.*; [ -e "$1" ] && check "no temp file left beside the target" 0 || check "no temp file left beside the target" 1
# a dangling link whose target directory does not exist: fail loudly, leak nothing
rm -f "$hl/.claude/coralline.conf"; ln -s "$hl/nowhere/coralline.conf" "$hl/.claude/coralline.conf"
before=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^coralline-config\.')
outd=$(run_install "$hl" "$hl/.claude/coralline.conf"); rcd=$?
[ "$rcd" -ne 0 ] && check "a dangling config link exits non-zero" 1 || check "a dangling config link exits non-zero" 0
[ -L "$hl/.claude/coralline.conf" ] && check "the dangling link is left as it is" 1 || check "the dangling link is left as it is" 0
after=$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep -c '^coralline-config\.')
[ "$after" -le "$before" ] && check "no config temp file leaked" 1 || check "no config temp file leaked" 0
rm -rf "$hl"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
