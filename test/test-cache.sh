#!/usr/bin/env bash
# Unit test for seg_cache() — the optional `cache` segment, which reads
# prompt_cache.hit_ratio and prompt_cache.expires_at out of the statusline
# payload. Extracts the live function from statusline.sh so this test can never
# drift from the code it checks.
#
#   bash test/test-cache.sh
#
# Exits non-zero if any case fails. Needs only bash (no jq, no git).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

# Pull the segment and the helpers it calls out of the real script. Relies on
# each function's closing brace being the only `}` at column 0.
#
# The sed scripts stay single-quoted and spelled out one per line rather than
# built in a loop: on bash 3.2, `eval "$(sed -n "…{…}…" "$f")"` loses the inner
# quotes, and the `{/,/^}` then brace-expands into two broken sed scripts.
eval "$(sed -n '/^seg_cache() {/,/^}/p'    "$SCRIPT")"
eval "$(sed -n '/^pct_fg() {/,/^}/p'       "$SCRIPT")"
eval "$(sed -n '/^to_epoch() {/,/^}/p'     "$SCRIPT")"
eval "$(sed -n '/^iso_epoch() {/,/^}/p'    "$SCRIPT")"
eval "$(sed -n '/^fmt_duration() {/,/^}/p' "$SCRIPT")"

# Stand-ins for the render machinery: record what seg_cache would paint instead
# of emitting real escapes, so a case can assert on plain text and on the color
# role that the inverted threshold picked.
fg()   { _FG="<$1>"; }
push() { _BG="$1"; _TEXT="$2"; }

VL_WARN_PCT=50 ; VL_HOT_PCT=75
VL_FG_OK=ok ; VL_FG_WARN=warn ; VL_FG_HOT=hot ; VL_FG_DIM=dim
VL_BG_CTX=238 ; VL_BG_CACHE="" ; VL_CACHE_GLYPH="C"
NOW=1000000

fail=0
check() {  # $1=expected  $2=label  $3=actual
  if [ "$3" = "$1" ]; then
    printf 'ok    %-34s -> %q\n' "$2" "$3"
  else
    printf 'FAIL  %-34s want=%q got=%q\n' "$2" "$1" "$3"; fail=1
  fi
}

render() {  # $1=hit pct  $2=expires_at ; → the pushed text, colors as <role>
  cache_pct="$1"; cache_exp="$2"
  _BG=""; _TEXT=""
  seg_cache
  printf '%s' "$_TEXT"
}

# ── Suppression ──────────────────────────────────────────────────────────────
# No prompt_cache in the payload (a session that has issued no request yet), and
# a payload whose hit_ratio is null, both leave cache_pct empty: render nothing
# rather than an empty pill.
check "" "no prompt_cache"           "$(render '' '')"
check "" "null hit_ratio, live TTL"  "$(render '' '1000300')"

# ── Countdown ────────────────────────────────────────────────────────────────
# Under an hour the seconds are shown, because the short TTL is five minutes and
# a minute-only countdown would sit on "4m" for most of the cache's life. From an
# hour up they are dropped. The boundary is exactly 3600s: 59m59s still carries
# seconds, 1h00m00s does not.
check "<ok> C 98% <dim>↺5m00s "  "warm 5m TTL"       "$(render '98.12' '1000300')"
check "<ok> C 98% <dim>↺42s "    "under a minute"    "$(render '98.12' '1000042')"
check "<ok> C 98% <dim>↺59m59s " "just under 1h"     "$(render '98.12' '1003599')"
check "<ok> C 98% <dim>↺1h00m "  "1h TTL at issue"   "$(render '98.12' '1003600')"
check "<ok> C 98% <dim>↺1h00m "  "one second past 1h" "$(render '98.12' '1003601')"

# expires_at keeps its last value after the cache goes cold, so a non-positive
# remainder is the cold case and must print no countdown at all.
check "<ok> C 98%  "  "expired (cold)"   "$(render '98.12' '999999')"
check "<ok> C 98%  "  "expiring exactly" "$(render '98.12' '1000000')"
check "<ok> C 98%  "  "no expires_at"    "$(render '98.12' '')"

# ── Inverted thresholds ──────────────────────────────────────────────────────
# A high hit ratio is the good outcome, so the color roles run opposite to a
# usage gauge: pct_fg is fed 100-v. With WARN 50 / HOT 75 that puts the warn
# boundary at 50% hit and the hot boundary at 25% hit.
check "<ok> C 100%  "  "100% hit is ok"    "$(render '100' '')"
check "<ok> C 51%  "   "51% hit is ok"     "$(render '51' '')"
check "<warn> C 50%  " "50% hit warns"     "$(render '50' '')"
check "<warn> C 26%  " "26% hit warns"     "$(render '26' '')"
check "<hot> C 25%  "  "25% hit is hot"    "$(render '25' '')"
check "<hot> C 0%  "   "0% hit is hot"     "$(render '0' '')"

# ── Rounding and malformed input ─────────────────────────────────────────────
# jq hands over hit_ratio * 100, which routinely arrives with float noise.
check "<ok> C 98%  " "98.4 rounds down"  "$(render '98.4' '')"
check "<ok> C 99%  " "98.6 rounds up"    "$(render '98.6' '')"
# printf %.0f is IEEE round-half-to-even, the same rule seg_ctx and seg_limit
# already display under. Both ties land on 98, not on 98 and 99.
check "<ok> C 98%  " "98.5 ties to even" "$(render '98.5' '')"
check "<ok> C 98%  " "97.5 ties to even" "$(render '97.5' '')"
check "<ok> C 98%  " "float noise"       "$(render '98.00000000000001' '')"
check "<hot> C 0%  " "non-numeric → 0%"  "$(render 'abc' '' 2>/dev/null)"

# ── Background fallback ──────────────────────────────────────────────────────
# Themes that define no cache swatch must inherit the ctx pill, not a hardcoded
# color; an explicit VL_BG_CACHE wins.
render '98' '' >/dev/null
check "238" "empty VL_BG_CACHE → ctx" "$_BG"
VL_BG_CACHE="1,2,3"
render '98' '' >/dev/null
check "1,2,3" "explicit VL_BG_CACHE" "$_BG"
VL_BG_CACHE=""

exit "$fail"
