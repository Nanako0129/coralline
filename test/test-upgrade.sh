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

# ---- Section C: report_upgrade_delta -------------------------------------
eval "$(sed -n '/^report_upgrade_delta() {/,/^}/p' "$CONF")"

rep=$(report_upgrade_delta "$tmp/old.sh" "$tmp/new.sh" "/home/u/.claude/coralline/statusline.sh.bak.20260622-100501")
printf '%s\n' "$rep" | grep -q 'new since your installed copy' && check "report has header" 1 || check "report has header" 0
printf '%s\n' "$rep" | grep -qE 'segment +burn'                 && check "report lists burn segment" 1 || check "report lists burn segment" 0
printf '%s\n' "$rep" | grep -qE 'option +VL_FLOAT=1'            && check "report lists VL_FLOAT=1" 1 || check "report lists VL_FLOAT=1" 0
printf '%s\n' "$rep" | grep -q 'also write a plain-text readout' && check "report shows knob desc" 1 || check "report shows knob desc" 0
printf '%s\n' "$rep" | grep -q 'backup at /home/u/.claude/coralline/statusline.sh.bak.20260622-100501' && check "report names backup path" 1 || check "report names backup path" 0
printf '%s\n' "$rep" | grep -qE 'option +VL_BG_BURN' && check "report omits filtered color knob" 0 || check "report omits filtered color knob" 1

# No backup path → no backup line, but still a report.
rep2=$(report_upgrade_delta "$tmp/old.sh" "$tmp/new.sh" "")
printf '%s\n' "$rep2" | grep -q 'backup at' && check "no backup line when path empty" 0 || check "no backup line when path empty" 1

# Identical files → no delta → silent.
[ -z "$(report_upgrade_delta "$tmp/new.sh" "$tmp/new.sh" "")" ] && check "silent when no new segments/knobs" 1 || check "silent when no new segments/knobs" 0
# Missing old file → silent.
[ -z "$(report_upgrade_delta "$tmp/nope.sh" "$tmp/new.sh" "")" ] && check "silent when old file absent" 1 || check "silent when old file absent" 0

# No ANSI escapes when stdout is not a tty, even with real color vars set.
rep3=$(T_BOLD=$'\033[1m' T_RESET=$'\033[0m' T_CORAL=$'\033[38;5;173m' T_DIM=$'\033[2m' \
       report_upgrade_delta "$tmp/old.sh" "$tmp/new.sh" "")
case "$rep3" in *$'\033'*) check "no ANSI when piped (non-tty)" 0 ;; *) check "no ANSI when piped (non-tty)" 1 ;; esac

# ---- Section D: backup_statusline ----------------------------------------
eval "$(sed -n '/^backup_statusline() {/,/^}/p' "$CONF")"

mkdir -p "$tmp/inst/coralline"
printf 'OLD-RUNTIME\n' > "$tmp/inst/coralline/statusline.sh"
bpath=$(backup_statusline "$tmp/inst/coralline")
[ -n "$bpath" ] && [ -f "$bpath" ] && check "backup file created" 1 || check "backup file created" 0
[ "$(cat "$bpath" 2>/dev/null)" = "OLD-RUNTIME" ] && check "backup holds old statusline" 1 || check "backup holds old statusline" 0
case "$bpath" in "$tmp/inst/coralline/statusline.sh.bak."*) check "backup path matches statusline.sh.bak.<ts>" 1 ;; *) check "backup path matches statusline.sh.bak.<ts>" 0 ;; esac

# Keep only the 3 newest: seed 4 older backups, then back up once more.
for n in 1 2 3 4; do : > "$tmp/inst/coralline/statusline.sh.bak.2020010${n}-000000"; done
backup_statusline "$tmp/inst/coralline" >/dev/null
nbak=$(ls -1 "$tmp/inst/coralline"/statusline.sh.bak.* 2>/dev/null | wc -l | tr -d ' ')
[ "$nbak" = "3" ] && check "prunes to 3 newest backups" 1 || check "prunes to 3 newest backups (got $nbak)" 0

# Absent statusline → empty, no crash.
mkdir -p "$tmp/inst/empty"
[ -z "$(backup_statusline "$tmp/inst/empty")" ] && check "absent statusline → empty path" 1 || check "absent statusline → empty path" 0

# ---- Section E: install_files integration (sandboxed) --------------------
mk_old_install() {  # $1=home/.claude dir ; creates an OLD install missing seg_burn
  mkdir -p "$1/coralline"
  printf 'seg_dir() { :; }\nVL_ASCII=0\n' > "$1/coralline/statusline.sh"
  printf 'VL_THEME="claude-coral"\n'       > "$1/coralline.conf"
}

# (E1) upgrade with new content → report + backup, conf preserved
home="$tmp/h1/.claude"; mk_old_install "$home"
conf_before=$(cat "$home/coralline.conf")
out=$(CORALLINE_HOME="$home/coralline" CLAUDE_SETTINGS="$home/settings.json" \
      bash "$CONF" --install-only 2>&1)
printf '%s\n' "$out" | grep -q 'new since your installed copy' && check "E1 install-only prints report" 1 || check "E1 install-only prints report" 0
printf '%s\n' "$out" | grep -qE 'segment +burn' && check "E1 report includes burn" 1 || check "E1 report includes burn" 0
bak=$(ls -1 "$home"/coralline/statusline.sh.bak.* 2>/dev/null | head -1)
[ -n "$bak" ] && [ "$(head -1 "$bak" 2>/dev/null)" = "seg_dir() { :; }" ] \
  && check "E1 backup holds OLD statusline" 1 || check "E1 backup holds OLD statusline" 0
[ "$(cat "$home/coralline.conf")" = "$conf_before" ] && check "E1 coralline.conf untouched" 1 || check "E1 coralline.conf untouched" 0
grep -q 'seg_burn' "$home/coralline/statusline.sh" && check "E1 new runtime installed" 1 || check "E1 new runtime installed" 0

# (E2) fresh install (no prior) → no report, no backup
home2="$tmp/h2/.claude"; mkdir -p "$home2"
out2=$(CORALLINE_HOME="$home2/coralline" CLAUDE_SETTINGS="$home2/settings.json" bash "$CONF" --install-only 2>&1)
printf '%s\n' "$out2" | grep -q 'new since your installed copy' && check "E2 fresh: no report" 0 || check "E2 fresh: no report" 1
ls "$home2"/coralline/statusline.sh.bak.* >/dev/null 2>&1 && check "E2 fresh: no backup" 0 || check "E2 fresh: no backup" 1

# (E3) identical re-run → no backup, no report
home3="$tmp/h3/.claude"; mkdir -p "$home3/coralline"
cp "$REPO/statusline.sh" "$home3/coralline/statusline.sh"
out3=$(CORALLINE_HOME="$home3/coralline" CLAUDE_SETTINGS="$home3/settings.json" bash "$CONF" --install-only 2>&1)
printf '%s\n' "$out3" | grep -q 'new since your installed copy' && check "E3 identical: no report" 0 || check "E3 identical: no report" 1
ls "$home3"/coralline/statusline.sh.bak.* >/dev/null 2>&1 && check "E3 identical: no backup" 0 || check "E3 identical: no backup" 1

# (E4) bugfix-only overwrite (differs, but exposes no new seg/knob) → backup, NO report
home4="$tmp/h4/.claude"; mkdir -p "$home4/coralline"
sed '1s/^/# bugfix comment\n/' "$REPO/statusline.sh" > "$home4/coralline/statusline.sh"
out4=$(CORALLINE_HOME="$home4/coralline" CLAUDE_SETTINGS="$home4/settings.json" bash "$CONF" --install-only 2>&1)
printf '%s\n' "$out4" | grep -q 'new since your installed copy' && check "E4 bugfix-only: no report" 0 || check "E4 bugfix-only: no report" 1
ls "$home4"/coralline/statusline.sh.bak.* >/dev/null 2>&1 && check "E4 bugfix-only: backup taken" 1 || check "E4 bugfix-only: backup taken" 0

# (E5) unreadable old statusline → install still succeeds (fail-open)
home5="$tmp/h5/.claude"; mk_old_install "$home5"; chmod 000 "$home5/coralline/statusline.sh"
CORALLINE_HOME="$home5/coralline" CLAUDE_SETTINGS="$home5/settings.json" bash "$CONF" --install-only >/dev/null 2>&1
rc=$?; chmod 644 "$home5/coralline/statusline.sh" 2>/dev/null
[ "$rc" = "0" ] && check "E5 unreadable old: install succeeds" 1 || check "E5 unreadable old: install succeeds" 0

# (E6) unwritable backup target → install still succeeds, no backup line (fail-open)
home6="$tmp/h6/.claude"; mk_old_install "$home6"
chmod 500 "$home6/coralline"   # dir read+exec only → cp of new bak fails
out6=$(CORALLINE_HOME="$home6/coralline" CLAUDE_SETTINGS="$home6/settings.json" bash "$CONF" --install-only 2>&1)
rc6=$?; chmod 700 "$home6/coralline" 2>/dev/null
[ "$rc6" = "0" ] && check "E6 unwritable backup: install succeeds" 1 || check "E6 unwritable backup: install succeeds" 0
printf '%s\n' "$out6" | grep -q 'backup at' && check "E6 unwritable backup: no backup line" 0 || check "E6 unwritable backup: no backup line" 1

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
