#!/usr/bin/env bash
# Differential test for stats_file() in tools/bench/bench-statusline.sh.
#
# The harness summarizes latency samples with python3 when it is available and
# with a pure-awk fallback otherwise, which is the arm Git Bash usually takes.
# The two must agree: a benchmark whose percentiles depend on which interpreter
# the host happens to have is not a measurement. They disagreed before, because
# the python arm indexes a 0-based list while awk arrays are 1-based and the
# shift was missing, so the awk arm reported the p50 of two samples as their
# minimum and interpolated every larger sample one element low.
#
#   bash test/test-bench-stats.sh
#
# Extracts the live function from the harness, then forces each arm by running
# it with and without python3 visible on PATH. Skips if python3 is absent, since
# there is then no reference arm to compare against.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../tools/bench/bench-statusline.sh"

[ -f "$SCRIPT" ] || { echo "SKIP  tools/bench/bench-statusline.sh not present"; exit 0; }
command -v python3 >/dev/null 2>&1 && python3 -c 'import statistics' 2>/dev/null \
  || { echo "SKIP  python3 with statistics is the reference arm"; exit 0; }

# Single-quoted and on one line: see test/test-cache.sh for why a loop-built sed
# script breaks under bash 3.2.
eval "$(sed -n '/^stats_file() {/,/^}/p' "$SCRIPT")"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/coralline-benchstats.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# Force the awk arm with a python3 stub that fails the `import statistics`
# probe the fallback branches on. Replacing PATH wholesale would also hide awk,
# which is the thing under test; prepending keeps the rest of the environment.
mkdir -p "$TMP/stub"
printf '#!/bin/sh\nexit 1\n' > "$TMP/stub/python3"
chmod +x "$TMP/stub/python3"
awk_arm() { PATH="$TMP/stub:$PATH" stats_file "$1"; }
py_arm()  { stats_file "$1"; }

fail=0
check() {  # $1=expected  $2=label  $3=actual
  if [ "$3" = "$1" ]; then
    printf 'ok    %-40s -> %s\n' "$2" "$3"
  else
    printf 'FAIL  %-40s want=%s got=%s\n' "$2" "$1" "$3"; fail=1
  fi
}

samples() {  # write one sample per line
  local f="$TMP/s.txt"; : > "$f"
  local v
  for v in "$@"; do printf '%s\n' "$v" >> "$f"; done
  printf '%s' "$f"
}

# Every arm must agree with the reference on the same input. The two-sample case
# is the one the old code got wrong outright; the rest cover interpolation, exact
# hits, and the degenerate sizes.
compare() {  # $1=label, rest=samples
  local label="$1"; shift
  local f; f=$(samples "$@")
  check "$(py_arm "$f")" "$label" "$(awk_arm "$f")"
}

compare "n=1"                     5
compare "n=2 (p50 is the midpoint)" 10 20
compare "n=3"                     1 2 3
compare "n=4 interpolating"       1 2 3 4
compare "n=5 exact hits"          1 2 3 4 5
compare "n=10 spread"             1 2 3 4 5 6 7 8 9 100
compare "unsorted input"          9 1 8 2 7 3
compare "all equal"               4 4 4 4
compare "fractional"              1.5 2.25 3.125 4.0625

# The specific regression, stated as a value rather than as agreement: the p50
# of 10 and 20 is 15, not 10.
f=$(samples 10 20)
check "15.000" "n=2 p50 is 15.000, not the minimum" "$(awk_arm "$f" | cut -d' ' -f2)"

# An empty file must not divide by zero in either arm.
: > "$TMP/empty.txt"
check "$(py_arm "$TMP/empty.txt")" "empty input" "$(awk_arm "$TMP/empty.txt")"

exit "$fail"
