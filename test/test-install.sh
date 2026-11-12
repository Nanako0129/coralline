#!/usr/bin/env bash
# End-to-end test for install.sh's remote path, without the network: the runtime
# files come from this checkout through --base-url file://, the script itself is
# run from a directory that is not a checkout (so it does not take the local
# path), and HOME, TMPDIR and every coralline path point into a sandbox.
#
#   bash test/test-install.sh
#
# Exits non-zero if any case fails. Needs bash, jq and curl (install.sh checks
# for curl before it knows the base URL is a file).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "SKIP  curl not available"; exit 0; }

SB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/coralline-install-test.XXXXXX")" && pwd -P)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/run" "$SB/tmp" "$SB/home"
cp "$REPO/install.sh" "$SB/run/install.sh"

fail=0
check() { if [ "$2" = 1 ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

run_install() {  # $1=base url; rest=extra arguments → output, exit code in RC
  local base="$1"; shift
  OUT=$(cd "$SB/run" && HOME="$SB/home" TMPDIR="$SB/tmp" CORALLINE_NO_SAMPLE=1 \
    CORALLINE_HOME="$SB/home/.claude/coralline" CORALLINE_CONFIG="$SB/home/.claude/coralline.conf" \
    CLAUDE_SETTINGS="$SB/home/.claude/settings.json" \
    "$BASH" "$SB/run/install.sh" --base-url "$base" --install-only "$@" </dev/null 2>&1)
  RC=$?
}
leftovers() { set -- "$SB/tmp"/coralline-*; [ -e "$1" ] && printf '%s\n' "$@"; }

# A clean remote install: the files land, settings.json is registered, and the
# temp dir holding the downloaded payload is gone.
run_install "file://$REPO"
[ "$RC" = 0 ] && check "install exits 0" 1 || { check "install exits 0 (rc=$RC)" 0; printf '%s\n' "$OUT" | tail -5; }
cmp -s "$REPO/statusline.sh" "$SB/home/.claude/coralline/statusline.sh" && check "statusline.sh installed" 1 || check "statusline.sh installed" 0
cmp -s "$REPO/configure.sh" "$SB/home/.claude/coralline/configure.sh" && check "configure.sh installed" 1 || check "configure.sh installed" 0
[ -x "$SB/home/.claude/coralline/statusline.sh" ] && check "statusline.sh is executable" 1 || check "statusline.sh is executable" 0
[ -f "$SB/home/.claude/coralline/themes/claude-coral.conf" ] && check "themes installed" 1 || check "themes installed" 0
jq -e '.statusLine.command | contains("coralline/statusline.sh")' "$SB/home/.claude/settings.json" >/dev/null 2>&1 \
  && check "settings.json registered" 1 || check "settings.json registered" 0
[ -z "$(leftovers)" ] && check "no temp dir left after a successful install" 1 || { check "no temp dir left after a successful install" 0; leftovers; }

# Running it again changes nothing in settings.json and still cleans up.
cp "$SB/home/.claude/settings.json" "$SB/settings.before"
run_install "file://$REPO"
[ "$RC" = 0 ] && cmp -s "$SB/home/.claude/settings.json" "$SB/settings.before" && check "a second run leaves settings.json as it is" 1 || check "a second run leaves settings.json as it is" 0
[ -z "$(leftovers)" ] && check "no temp dir left after the second run" 1 || check "no temp dir left after the second run" 0

# A failed download stops the install, leaves no temp dir, and does not block the
# next run (a temp file once kept its literal template name and did).
mkdir -p "$SB/broken"; cp "$REPO/configure.sh" "$SB/broken/configure.sh"   # no statusline.sh there
run_install "file://$SB/broken"
[ "$RC" != 0 ] && check "a failed download exits non-zero" 1 || check "a failed download exits non-zero" 0
[ -z "$(leftovers)" ] && check "no temp dir left after a failed download" 1 || { check "no temp dir left after a failed download" 0; leftovers; }
run_install "file://$REPO"
[ "$RC" = 0 ] && check "the run after a failure succeeds" 1 || check "the run after a failure succeeds (rc=$RC)" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
