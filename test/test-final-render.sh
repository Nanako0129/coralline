#!/usr/bin/env bash
# Regression: the post-install "Verification render:" must print after a
# successful --install, regardless of VL_FLOAT.
#
# write_final_config used to end with `[ "$float_enabled" = "1" ] && print_float_help`,
# whose exit status is 1 when float is off (the default). The caller runs
# `write_final_config || exit 0`, so that non-zero status silently skipped the
# verify_render step and the final render vanished. write_final_config now
# returns 0 on the success path (the only intentional non-zero is a declined
# overwrite). This test drives a real install and asserts the render prints.
#   bash test/test-final-render.sh
# Needs bash + jq (configure.sh merges Claude settings with jq).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
fail=0
check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP  jq not available"; exit 0; }

# Fresh sandbox HOME, no pre-existing config -> float defaults off: the exact
# case the regression hid. CORALLINE_NO_SAMPLE keeps the verify render from
# touching the cross-session stores (#32).
home=$(mktemp -d "${TMPDIR:-/tmp}/coralline-final-render.XXXXXX") || exit 1
trap 'rm -rf "$home"' EXIT
out=$(CORALLINE_NO_SAMPLE=1 HOME="$home" bash "$REPO/configure.sh" --install --default 2>&1)

case "$out" in
  *"Verification render:"*) check "post-install verification render prints (float off)" 1 ;;
  *)                        check "post-install verification render prints (float off)" 0 ;;
esac
# Sanity: we reached the success path (config actually written), not the decline path.
[ -f "$home/.claude/coralline.conf" ] && check "coralline.conf was written" 1 || check "coralline.conf was written" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
