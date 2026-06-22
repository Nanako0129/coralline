#!/usr/bin/env bash
# Unit + integration tests for the agent-guided upgrade detection in configure.sh.
#   bash test/test-upgrade.sh
# Needs bash + jq + coreutils (grep/sed/cmp/cp).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
CONF="$REPO/configure.sh"
fail=0
check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/coralline-upgrade-test.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

# Color vars the report reads — left empty here; the no-ANSI test sets real ones.
T_BOLD="" ; T_RESET="" ; T_CORAL="" ; T_DIM=""

# Pull the pure functions out of configure.sh so the test cannot drift.
eval "$(sed -n '/^segment_names() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^knob_names() {/,/^}/p'    "$CONF")"

# ---- fixtures: an OLD and a NEW statusline.sh -----------------------------
cat > "$tmp/old.sh" <<'OLD'
seg_dir() { :; }
seg_model() { :; }
VL_ASCII=0
VL_NAME_MAX=0
VL_BG_DIR="0,0,0"
OLD
cat > "$tmp/new.sh" <<'NEW'
seg_dir() { :; }
seg_model() { :; }
seg_burn() { :; }
seg_effort() {  # reasoning effort level (low/medium/high)
  :
}
VL_ASCII=0
VL_NAME_MAX=0
VL_BG_DIR="0,0,0"
VL_BG_BURN="1,2,3"
VL_FLOAT=0                      # 1 = also write a plain-text readout to VL_FLOAT_FILE
VL_NOCOLOR=0                    # internal: fg()/bg() emit nothing when 1
# Cross-session limit sync (opt-in). Records high-water across sessions so
# idle sessions converge when they next redraw.
VL_LIMIT_SYNC=0
NEW

# ---- Section A: name extractors ------------------------------------------
segs=" $(segment_names "$tmp/new.sh") "
case "$segs" in *" burn "*)   check "segment_names finds burn"   1 ;; *) check "segment_names finds burn"   0 ;; esac
case "$segs" in *" effort "*) check "segment_names finds effort" 1 ;; *) check "segment_names finds effort" 0 ;; esac

knobs=" $(knob_names "$tmp/new.sh") "
case "$knobs" in *" VL_FLOAT "*)      check "knob_names finds VL_FLOAT"      1 ;; *) check "knob_names finds VL_FLOAT"      0 ;; esac
case "$knobs" in *" VL_LIMIT_SYNC "*) check "knob_names finds VL_LIMIT_SYNC" 1 ;; *) check "knob_names finds VL_LIMIT_SYNC" 0 ;; esac
case "$knobs" in *" VL_BG_BURN "*)    check "knob_names EXCLUDES color knob (non-0 default)" 0 ;; *) check "knob_names EXCLUDES color knob (non-0 default)" 1 ;; esac
case "$knobs" in *" VL_NOCOLOR "*)    check "knob_names EXCLUDES internal-tagged knob" 0 ;; *) check "knob_names EXCLUDES internal-tagged knob" 1 ;; esac

# ---- Section B: description extractors ------------------------------------
eval "$(sed -n '/^segment_desc() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^knob_desc() {/,/^}/p'    "$CONF")"

[ "$(segment_desc "$tmp/new.sh" effort)" = "reasoning effort level (low/medium/high)" ] \
  && check "segment_desc reads inline comment (effort)" 1 || check "segment_desc reads inline comment (effort)" 0
[ -z "$(segment_desc "$tmp/new.sh" burn)" ] \
  && check "segment_desc empty when no comment (burn)" 1 || check "segment_desc empty when no comment (burn)" 0

[ "$(knob_desc "$tmp/new.sh" VL_FLOAT)" = "1 = also write a plain-text readout to VL_FLOAT_FILE" ] \
  && check "knob_desc reads inline comment (VL_FLOAT)" 1 || check "knob_desc reads inline comment (VL_FLOAT)" 0
[ "$(knob_desc "$tmp/new.sh" VL_LIMIT_SYNC)" = "Cross-session limit sync (opt-in)" ] \
  && check "knob_desc reads first sentence of block (VL_LIMIT_SYNC)" 1 || check "knob_desc reads first sentence of block (VL_LIMIT_SYNC)" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
