#!/usr/bin/env bash
# Paired multi-arm N-scaling bench: attributes per-render cost inflation at high
# concurrency to (state store) vs (git) vs (interpreter/fork floor).
#
# Method per BENCHMARK.md: paired alternating rounds (all arms back to back each
# round), lead rotation (round r starts at arm r % count), a byte-identical
# control arm as the noise floor, medians across rounds. CPU time (user+sys) is
# the verdict metric; wall p50 is reported for the refresh-interval question.
# Host load is recorded per round: results on a loaded machine are valid only as
# paired ratios, not as absolute numbers.
#
# Usage:
#   bash tools/bench/bench-arms.sh [--bash /path/to/bash] [--rounds R]
#                                  [--renders N] [--ns "1 4 8 16"] [--outdir DIR]
#                                  [--pace-s S] [--allow-live-statusline]
#
# Renders are paced to 1 Hz by default, because that is the cadence the client
# actually runs at and the burn writer is elected once per second: a tight loop
# lets one render in three write and then reports the average as a per-second
# figure. Pacing is what makes agg_cpu_ms_per_s_at_1hz mean what it says, and it
# is also what makes a full default run take on the order of a quarter hour.
# --pace-s 0 restores the old tight loop for latency-only questions.
set -eu
# bash 3.2-safe: no mapfile, no arrays required beyond positional lists

HERE="$(cd "$(dirname "$0")" && pwd)"
ENGINE="$HERE/bench-statusline.sh"
BASH_BIN="${BASH_BIN:-/bin/bash}"
ROUNDS=3
RENDERS=10
NS="1 4 8 16"
OUTDIR=""
SL=""
PACE_S=1            # the client re-renders at 1 Hz; see the note above the arms
ALLOW_LIVE_FLAG=""  # forwarded to the engine, which refuses to measure otherwise

while [ $# -gt 0 ]; do
  case "$1" in
    --bash)    BASH_BIN="$2"; shift 2 ;;
    --rounds)  ROUNDS="$2"; shift 2 ;;
    --renders) RENDERS="$2"; shift 2 ;;
    --ns)      NS="$2"; shift 2 ;;
    --outdir)  OUTDIR="$2"; shift 2 ;;
    --statusline) SL="$2"; shift 2 ;;
    --pace-s)  PACE_S="$2"; shift 2 ;;
    --allow-live-statusline) ALLOW_LIVE_FLAG="--allow-live-statusline"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUTDIR" ] || OUTDIR="$(mktemp -d "${TMPDIR:-/tmp}/coralline-arms.XXXXXX")"
mkdir -p "$OUTDIR"

# ── arm configs ─────────────────────────────────────────────────────────────
# stateon:  burn + limit sync (the expensive path; matches the engine default)
# control:  byte-identical to stateon — its delta vs stateon is the noise floor
# stateoff: same segments minus burn, no limit sync (no state store at all)
# nogit:    stateoff minus git/stash (no git fork)
# floor:    a bare interpreter. nogit still runs the whole renderer (config load,
#           JSON parse, dir, model, ctx, limits, cost, clock, layout), so it is
#           not the interpreter/fork floor this script's header attributes the
#           residual to. This arm is: spawn the interpreter, do nothing, exit.
#           stateoff - floor is rendering cost; floor is what no change can remove.
cat > "$OUTDIR/conf.stateon" << 'EOF'
. ~/.claude/coralline/themes/claude-coral.conf
VL_STYLE="pill"
VL_LAYOUT="fixed"
VL_SEGMENTS="dir git model ctx limit5h limit7d burn cost clock"
VL_LIMIT_SYNC=1
VL_CLOCK="24h"
VL_CLOCK_SECONDS=1
VL_FLOAT=0
EOF
cp "$OUTDIR/conf.stateon" "$OUTDIR/conf.control"
sed -e 's/ burn//' -e 's/VL_LIMIT_SYNC=1/VL_LIMIT_SYNC=0/' \
  "$OUTDIR/conf.stateon" > "$OUTDIR/conf.stateoff"
sed -e 's/ git//' "$OUTDIR/conf.stateoff" > "$OUTDIR/conf.nogit"
# seeded: same config as stateon, but the burn TSV starts past BURN_TRIM so
# every mutating render pays the steady-state trim/rewrite path.
printf '#!/usr/bin/env bash\nexit 0\n' > "$OUTDIR/floor.sh"
chmod +x "$OUTDIR/floor.sh"
cp "$OUTDIR/conf.stateon" "$OUTDIR/conf.floor"
cp "$OUTDIR/conf.stateon" "$OUTDIR/conf.seeded"
# seedro: seeded store, read-only render (conf is sourced bash, so the no-sample
# guard can be set there). seeded - seedro = the write/trim path at cap.
{ cat "$OUTDIR/conf.stateon"; echo 'CORALLINE_NO_SAMPLE=1'; } > "$OUTDIR/conf.seedro"

ARMS="stateon control stateoff nogit floor seeded seedro"
ARM_COUNT=6

loadavg() { sysctl -n vm.loadavg 2>/dev/null || uptime; }

echo "=== coralline paired arm bench ===" >&2
echo "bash=$BASH_BIN rounds=$ROUNDS renders/worker=$RENDERS ns=$NS" >&2
echo "outdir=$OUTDIR" >&2

r=0
while [ "$r" -lt "$ROUNDS" ]; do
  echo "--- round $r  load(before)=$(loadavg)" >&2
  # rotate which arm leads this round
  lead=$((r % ARM_COUNT))
  # build rotated arm order
  set -- $ARMS
  order=""
  i=0
  for a in "$@"; do
    if [ "$i" -ge "$lead" ]; then order="$order $a"; fi
    i=$((i + 1))
  done
  i=0
  for a in "$@"; do
    if [ "$i" -lt "$lead" ]; then order="$order $a"; fi
    i=$((i + 1))
  done
  for arm in $order; do
    extra=""
    # Above BURN_TRIM + BURN_SLACK (2000), so the seeded arms actually cross the
    # rewrite threshold; 1600 sat under it and measured the read path only. The
    # engine restores this fixture before every cohort, so each cohort gets one
    # rewrite and then amortises, which is the steady state BURN_SLACK is for.
    # Without that restore the warmup would have spent the single rewrite before
    # any measurement, and 2100 would have behaved exactly like 1500.
    case "$arm" in seeded|seedro) extra="--seed-burn 2100" ;; esac
    arm_sl="$SL"
    case "$arm" in floor) arm_sl="$OUTDIR/floor.sh" ;; esac
    [ -n "$arm_sl" ] && extra="$extra --statusline $arm_sl"
    BASH_BIN= bash "$ENGINE" \
      --bash "$BASH_BIN" \
      --label "$arm.r$r" \
      --conf "$OUTDIR/conf.$arm" \
      --renders "$RENDERS" \
      --pace-s "$PACE_S" \
      $ALLOW_LIVE_FLAG \
      --ns "$NS" \
      $extra \
      --out "$OUTDIR/raw.$arm.r$r.csv" >/dev/null
  done
  echo "--- round $r  load(after)=$(loadavg)" >&2
  r=$((r + 1))
done

# ── summary: median across rounds per (arm, n) ──────────────────────────────
# engine CSV cols: 5=n 9=p50_ms 18=cpu_s_per_render
{
  echo "arm,n,rounds,med_cpu_ms_per_render,med_p50_ms,agg_cpu_ms_per_s_at_1hz"
  for arm in $ARMS; do
    awk -F, -v arm="$arm" '
      FNR > 1 { cpu[$5] = cpu[$5] " " $18 * 1000; p50[$5] = p50[$5] " " $9; seen[$5] = 1 }
      function median(s,   m, i, j, t, v) {
        m = split(s, v, " ")
        for (i = 2; i <= m; i++) { t = v[i]; j = i - 1
          while (j >= 1 && v[j] > t) { v[j+1] = v[j]; j-- } v[j+1] = t }
        if (m % 2) return v[(m + 1) / 2]
        return (v[m / 2] + v[m / 2 + 1]) / 2
      }
      END {
        for (n in seen) {
          c = median(cpu[n]); p = median(p50[n])
          printf "%s,%s,%d,%.1f,%.1f,%.0f\n", arm, n, split(cpu[n], junk, " "), c, p, n * c
        }
      }
    ' "$OUTDIR"/raw.$arm.r*.csv
  done
} | sort -t, -k1,1 -k2,2n > "$OUTDIR/summary.csv"

echo >&2
column -s, -t < "$OUTDIR/summary.csv" >&2
echo >&2
echo "noise floor = |stateon - control| per n; any smaller difference is not a result." >&2
echo "summary: $OUTDIR/summary.csv" >&2
echo "$OUTDIR/summary.csv"
