#!/usr/bin/env bash
# Verifies import_p10k reproduces a Powerlevel10k "classic" prompt as coralline's
# first-class classic style, carrying p10k's background/separator through the
# VL_LEAN_BG / VL_LEAN_CAP_R overrides (not pill), and leaves lean/rainbow imports
# unchanged. Extracts the live functions from configure.sh so the test cannot
# drift from the implementation it checks.
#   bash test/test-import-p10k.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"
fail=0
ok()    { printf 'ok    %s\n' "$1"; }
bad()   { printf 'FAIL  %s\n' "$1"; fail=1; }
check() { [ "$2" = 1 ] && ok "$1" || bad "$1"; }
has()   { case "$2" in (*"$1"*) return 0 ;; (*) return 1 ;; esac; }

# Pull the import helpers out of configure.sh (single source of truth).
eval "$(sed -n '/^add_extra() {/,/^}/p'       "$CONF")"
eval "$(sed -n '/^hex_to_rgb() {/,/^}/p'      "$CONF")"
eval "$(sed -n '/^normalize_color() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^p10k_value() {/,/^}/p'      "$CONF")"
eval "$(sed -n '/^map_p10k_color() {/,/^}/p'  "$CONF")"
eval "$(sed -n '/^shell_quote() {/,/^}/p'     "$CONF")"
eval "$(sed -n '/^write_assign() {/,/^}/p'    "$CONF")"
eval "$(sed -n '/^import_p10k() {/,/^}/p'     "$CONF")"

# Run import_p10k against a fixture ~/.p10k.zsh fed on stdin; a quoted heredoc
# keeps p10k's single quotes and \uXXXX escapes literal. Leaves $style and
# $extra_config set for assertions.
run_import() {
  P10K_FILE=$(mktemp "${TMPDIR:-/tmp}/p10k-fixture.XXXXXX") || exit 1
  cat > "$P10K_FILE"
  style="" ; extra_config="" ; clock_mode="12h" ; clock_seconds=0
  import_p10k
  rm -f "$P10K_FILE"
}

# ── (1) classic → classic style + uniform bg + end cap + fg colours────────────
run_import <<'EOF'
# Wizard options: nerdfont-v3 + powerline, small icons, classic, unicode, dark, 24h time.
  typeset -g POWERLEVEL9K_BACKGROUND=236
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR='\uE0BC'
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
  typeset -g POWERLEVEL9K_VCS_CLEAN_FOREGROUND=76
  typeset -g POWERLEVEL9K_TIME_FOREGROUND=66
EOF

[ "$style" = "classic" ]                  && check "classic -> VL_STYLE=classic (not pill)" 1 || check "classic -> VL_STYLE=classic (not pill)" 0
has 'VL_LEAN_BG="236"' "$extra_config"    && check "classic -> VL_LEAN_BG carries POWERLEVEL9K_BACKGROUND" 1 || check "classic -> VL_LEAN_BG carries POWERLEVEL9K_BACKGROUND" 0
# The separator must be DECODED to real bytes at import time (bash 3.2 does not
# expand $'\uXXXX') and emitted shell-quoted, so we assert on the SOURCED value —
# not the raw config text, which may be %q-escaped (e.g. $'\356\202\274') in a C
# locale. glyph = the real U+E0BC bytes.
glyph=$(printf '"\\uE0BC"' | jq -r . 2>/dev/null)
has 'VL_LEAN_CAP_R=' "$extra_config"      && check "classic -> VL_LEAN_CAP_R carries LEFT_SEGMENT_SEPARATOR" 1 || check "classic -> VL_LEAN_CAP_R carries LEFT_SEGMENT_SEPARATOR" 0
has 'VL_BG_DIR="31"' "$extra_config"      && check "classic -> dir foreground -> VL_BG_DIR (lean text colour)" 1 || check "classic -> dir foreground -> VL_BG_DIR" 0

# Sourcing the emitted line must yield the real glyph (not the literal \uXXXX
# escape, and not a broken value). eval re-parses %q or $'…' identically.
capline=$(printf '%s\n' "$extra_config" | grep '^VL_LEAN_CAP_R=')
VL_LEAN_CAP_R=""
eval "$capline"
[ "${VL_LEAN_CAP_R:-}" = "$glyph" ]       && check "VL_LEAN_CAP_R sources to the decoded glyph (locale-robust)" 1 || check "VL_LEAN_CAP_R sources to the decoded glyph (locale-robust)" 0

# ── (1b) Hardening: a separator with shell metacharacters must be emitted shell-
#    quoted so sourcing the config cannot break or inject. \u0022 decodes to a
#    double quote; the pre-fix code emitted it unquoted and broke the config.
run_import <<'HEOF'
# Wizard options: classic.
  typeset -g POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR='\u0022'
HEOF
capline=$(printf '%s\n' "$extra_config" | grep '^VL_LEAN_CAP_R=')
VL_LEAN_CAP_R=""
{ eval "$capline" 2>/dev/null && [ "$VL_LEAN_CAP_R" = '"' ]; } \
                                          && check "hostile separator is shell-quoted; sources safely to the literal char" 1 || check "hostile separator is shell-quoted; sources safely to the literal char" 0

# ── (2) lean → lean, and NO uniform background (regression guard) ─────────────
run_import <<'EOF'
# Wizard options: nerdfont-v3 + powerline, lean, unicode, dark.
  typeset -g POWERLEVEL9K_DIR_FOREGROUND=31
EOF
[ "$style" = "lean" ]                     && check "lean -> VL_STYLE=lean" 1 || check "lean -> VL_STYLE=lean" 0
has 'VL_LEAN_BG' "$extra_config"          && check "lean -> no VL_LEAN_BG (no uniform bar)" 0 || check "lean -> no VL_LEAN_BG (no uniform bar)" 1

# ── (3) rainbow → pill (regression guard) ────────────────────────────────────
run_import <<'EOF'
# Wizard options: nerdfont-v3 + powerline, rainbow, unicode, dark.
  typeset -g POWERLEVEL9K_DIR_BACKGROUND=4
EOF
[ "$style" = "pill" ]                     && check "rainbow -> VL_STYLE=pill" 1 || check "rainbow -> VL_STYLE=pill" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
