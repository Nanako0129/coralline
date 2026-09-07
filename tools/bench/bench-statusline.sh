#!/usr/bin/env bash
# Statusline render benchmark: concurrent n=1,2,4,8,16
# Measures wall-clock latency (ms) per render and aggregate CPU (user+sys).
#
# Usage:
#   bash tools/bench/bench-statusline.sh [--bash /path/to/bash] [--label NAME]
#                                        [--renders N] [--waves W] [--out FILE]
#
# Isolates HOME + CORALLINE_* state under a temp dir and removes it on exit.
set -eu
# bash 3.2-safe: no mapfile, no &>, no ${var,,}

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BASH_BIN="${BASH_BIN:-bash}"
LABEL=""
RENDERS=20          # per-worker renders at each concurrency n
WAVES=1             # reserved; workers each do RENDERS sequential loops
OUT=""
NS="1 2 4 8 16"
KEEP_TMP=0
CONF_SRC=""         # --conf FILE: use this coralline.conf instead of the built-in one
SEED_BURN=0         # --seed-burn N: pre-fill burn-5h.tsv with N valid rows (steady-state fixture)
STATUSLINE=""       # --statusline FILE: benchmark this file instead of the repo's statusline.sh

while [ $# -gt 0 ]; do
  case "$1" in
    --bash)   BASH_BIN="$2"; shift 2 ;;
    --label)  LABEL="$2"; shift 2 ;;
    --renders) RENDERS="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --ns)     NS="$2"; shift 2 ;;
    --conf)   CONF_SRC="$2"; shift 2 ;;
    --seed-burn) SEED_BURN="$2"; shift 2 ;;
    --statusline) STATUSLINE="$2"; shift 2 ;;
    --keep-tmp) KEEP_TMP=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve bash to absolute path + version for the report
if command -v "$BASH_BIN" >/dev/null 2>&1; then
  BASH_BIN="$(command -v "$BASH_BIN" 2>/dev/null || echo "$BASH_BIN")"
fi
# macOS /bin/bash and brew bash: prefer explicit path if given
case "$BASH_BIN" in
  /*) ;;
  *) BASH_BIN="$(command -v "$BASH_BIN")" ;;
esac
BASH_VER="$("$BASH_BIN" -c 'echo ${BASH_VERSION}')"
[ -n "$LABEL" ] || LABEL="bash-$BASH_VER"

[ -n "$STATUSLINE" ] || STATUSLINE="$ROOT/statusline.sh"
[ -f "$STATUSLINE" ] || { echo "missing $STATUSLINE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq required on PATH (Git Bash: /usr/bin/jq)" >&2; exit 1; }
HAVE_PY=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import time,statistics' 2>/dev/null; then
  HAVE_PY=1
fi
# bash 3.2 workers need a real python3; bash 5+ uses EPOCHREALTIME.
if [ "$HAVE_PY" != "1" ]; then
  bv="$("$BASH_BIN" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null || echo 0)"
  if [ "$bv" -lt 5 ] 2>/dev/null; then
    echo "python3 (with time/statistics) required for bash < 5" >&2
    exit 1
  fi
fi

# ── isolated state ──────────────────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/coralline-bench.XXXXXX")"
# Canonicalize: macOS TMPDIR sits under /var -> /private/var, and the state
# store's hardened validators reject any path with a symlinked ancestor. A
# symlinked TMP silently disables the whole store and benchmarks a degraded
# render (this bit the first N-scaling result set).
TMP="$(cd "$TMP" && pwd -P)"
cleanup() {
  if [ "$KEEP_TMP" = "1" ]; then
    echo "kept tmp: $TMP" >&2
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT INT TERM

# Strip inherited configuration before establishing our own (BENCHMARK.md's
# environment-control rule; an earlier benchmark inherited it and had to be
# discarded). Changing HOME alone does not isolate the renderer: CORALLINE_CONFIG
# points it at a config outside $HOME, CLAUDE_CONFIG_DIR moves the state store,
# CORALLINE_BURN_FILE relocates the fixture this harness just generated, and
# CORALLINE_NO_SAMPLE silences the very writes the steady-state arm measures. A
# REMORA_* variable rewrites the segment list, so the run would time a different
# statusline than the one it reports. Any of them turns a clean-looking CSV into
# a measurement of something else. ${!prefix@} is bash 3.2-safe and expands to
# nothing when no variable matches, which `set -u` accepts.
for _inherited in ${!CORALLINE_@} ${!REMORA_@} CLAUDE_CONFIG_DIR; do
  unset "$_inherited"
done
unset _inherited

export HOME="$TMP/home"
mkdir -p "$HOME/.claude/coralline/themes"
# Prefer repo themes; fall back if missing
if [ -d "$ROOT/themes" ]; then
  cp -R "$ROOT/themes/." "$HOME/.claude/coralline/themes/"
fi
if [ -n "$CONF_SRC" ]; then
  [ -f "$CONF_SRC" ] || { echo "missing --conf file: $CONF_SRC" >&2; exit 1; }
  cp "$CONF_SRC" "$HOME/.claude/coralline.conf"
else
cat > "$HOME/.claude/coralline.conf" << 'EOF'
. ~/.claude/coralline/themes/claude-coral.conf
VL_STYLE="pill"
VL_LAYOUT="fixed"
VL_SEGMENTS="dir git model ctx limit5h limit7d burn cost clock"
VL_LIMIT_SYNC=1
VL_CLOCK="24h"
VL_CLOCK_SECONDS=1
VL_FLOAT=0
EOF
fi

# Steady-state fixture: a burn TSV already past BURN_TRIM makes every mutating
# render exercise the trim/rewrite path, which an empty store never reaches.
# Rows are valid per the reader: sample <= now, sample < reset <= now + 6h,
# pct in canonical d.ddd form, monotonically rising toward the payload's 41.2.
if [ "$SEED_BURN" -gt 0 ] 2>/dev/null; then
  now_s="$(date +%s)"
  awk -v n="$SEED_BURN" -v now="$now_s" 'BEGIN {
    rst = now + 3600
    for (i = n; i >= 1; i--) {
      p = 40 - i * 0.001; if (p < 0) p = 0
      printf "%d\t%.3f\t%d\n", now - i, p, rst
    }
  }' > "$HOME/.claude/coralline/burn-5h.tsv"
fi

# Payload: real repo cwd so the git probe actually runs (fork cost included).
# Prefer jq (already required by statusline) over python for portability.
RST5="$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
RST7="$(date -u -v+3d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+3 days' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg cwd "$ROOT" --arg r5 "$RST5" --arg r7 "$RST7" '
  .cwd = $cwd
  | .workspace.current_dir = $cwd
  | .rate_limits.five_hour = {used_percentage: 41.2, resets_at: $r5}
  | .rate_limits.seven_day = {used_percentage: 78.9, resets_at: $r7}
' "$ROOT/test/sample-input.json" > "$TMP/input.json"

# Warmup (JIT nothing, but fills burn sample + page cache)
i=0
while [ "$i" -lt 5 ]; do
  "$BASH_BIN" "$STATUSLINE" < "$TMP/input.json" >/dev/null
  i=$((i + 1))
done

# Worker: time each statusline invoke.
# Prefer pure-bash timing on bash 5+ (EPOCHREALTIME) so Git Bash/Windows needs no Python.
# Fall back to a short python3 helper on bash 3.2 (macOS stock).
cat > "$TMP/worker.sh" << 'WORKER'
#!/usr/bin/env bash
# args: out renders bash_bin statusline input home
set +e
out="$1"
renders="$2"
bash_bin="$3"
statusline="$4"
input="$5"
export HOME="$6"
: > "$out"
r=0
if [ -n "${EPOCHREALTIME-}" ] || [ "${BASH_VERSINFO[0]}" -ge 5 ] 2>/dev/null; then
  while [ "$r" -lt "$renders" ]; do
    start=$EPOCHREALTIME
    "$bash_bin" "$statusline" < "$input" >/dev/null 2>&1
    end=$EPOCHREALTIME
    # awk portable float ms
    awk -v s="$start" -v e="$end" 'BEGIN{printf "%.3f\n", (e-s)*1000}' >> "$out"
    r=$((r + 1))
  done
else
  # bash 3.2: python3 high-res timer wrapper (one process per worker, not per render)
  python3 - "$out" "$renders" "$bash_bin" "$statusline" "$input" "$HOME" << 'PY'
import os, subprocess, sys, time
out, renders_s, bash_bin, statusline, input_path, home = sys.argv[1:7]
renders = int(renders_s)
env = os.environ.copy()
env["HOME"] = home
with open(input_path, "rb") as inf:
    payload = inf.read()
with open(out, "w") as f:
    for _ in range(renders):
        t0 = time.perf_counter()
        subprocess.run(
            [bash_bin, statusline],
            input=payload,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            env=env,
        )
        f.write(f"{(time.perf_counter() - t0) * 1000.0:.3f}\n")
PY
fi
exit 0
WORKER
chmod +x "$TMP/worker.sh"

stats_file() {
  # $1 = latency file → mean p50 p95 p99 min max count
  # Prefer python3; fall back to awk (Git Bash may only have a Store stub for python).
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import statistics' 2>/dev/null; then
    python3 - "$1" << 'PY'
import sys, statistics
path = sys.argv[1]
xs = []
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if line:
            xs.append(float(line))
if not xs:
    print("0 0 0 0 0 0 0"); raise SystemExit
xs.sort()
def pct(p):
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p / 100.0
    f = int(k); c = min(f + 1, len(xs) - 1)
    if f == c:
        return xs[f]
    return xs[f] + (xs[c] - xs[f]) * (k - f)
print(f"{statistics.mean(xs):.3f} {pct(50):.3f} {pct(95):.3f} {pct(99):.3f} {xs[0]:.3f} {xs[-1]:.3f} {len(xs)}")
PY
    return
  fi
  # pure awk percentiles
  awk '
    # Linear interpolation between order statistics, matching the python arm
    # above. That one indexes a 0-based list, so its k runs 0..n-1; awk arrays
    # here are 1-based and k must be shifted to 1..n. Without the shift the p50
    # of two samples returned a[1] instead of their midpoint, and every larger
    # sample interpolated one element low.
    function pct(p,   k,f,c) {
      if (n == 1) return a[1]
      k = (n - 1) * p / 100.0 + 1
      f = int(k); c = f + 1; if (c > n) c = n
      if (f == c) return a[f]
      return a[f] + (a[c] - a[f]) * (k - f)
    }
    NF { a[++n] = $1 + 0; sum += $1 + 0 }
    END {
      if (n == 0) { printf "0 0 0 0 0 0 0\n"; exit }
      for (i = 2; i <= n; i++) {
        v = a[i]; j = i - 1
        while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- }
        a[j+1] = v
      }
      printf "%.3f %.3f %.3f %.3f %.3f %.3f %d\n", sum/n, pct(50), pct(95), pct(99), a[1], a[n], n
    }
  ' "$1"
}

if [ -z "$OUT" ]; then
  OUT="$TMP/results.csv"
fi
mkdir -p "$(dirname "$OUT")"
{
  echo "platform,label,bash,bash_version,n,renders_per_worker,total_renders,mean_ms,p50_ms,p95_ms,p99_ms,min_ms,max_ms,wall_s,user_s,sys_s,cpu_pct,cpu_s_per_render"
} > "$OUT"

uname_s="$(uname -s 2>/dev/null || echo unknown)"
echo "=== coralline statusline bench ===" >&2
echo "label=$LABEL  bash=$BASH_BIN ($BASH_VER)  host=$uname_s" >&2
echo "root=$ROOT  renders/worker=$RENDERS  ns=$NS" >&2
echo "tmp=$TMP (cleaned on exit)" >&2

# External `time -p` only (quoted "time" is NOT the shell keyword). Git Bash has
# no /usr/bin/time — fall back to bash TIMEFORMAT in that case.
TIME_BIN=""
for cand in /usr/bin/time /bin/time gtime; do
  if [ -x "$cand" ]; then
    TIME_BIN="$cand"
    break
  fi
done

for n in $NS; do
  lat_dir="$TMP/lat.$n"
  rm -rf "$lat_dir"
  mkdir -p "$lat_dir"

  # Batch runner: spawn n workers, wait.
  cat > "$TMP/batch.$n.sh" << BATCH
#!/usr/bin/env bash
set -eu
n="$n"
renders="$RENDERS"
lat_dir="$lat_dir"
worker="$TMP/worker.sh"
bash_bin="$BASH_BIN"
statusline="$STATUSLINE"
input="$TMP/input.json"
home="$HOME"
i=0
while [ "\$i" -lt "\$n" ]; do
  bash "\$worker" "\$lat_dir/w.\$i" "\$renders" "\$bash_bin" "\$statusline" "\$input" "\$home" &
  i=\$((i + 1))
done
wait
BATCH
  chmod +x "$TMP/batch.$n.sh"

  time_file="$TMP/time.$n"
  if [ -n "${EPOCHREALTIME-}" ] || [ "${BASH_VERSINFO[0]}" -ge 5 ] 2>/dev/null; then
    wall_start=$EPOCHREALTIME
  else
    wall_start="$(date +%s)"
  fi
  if [ -n "$TIME_BIN" ]; then
    # -p: real/user/sys on stderr. Keep stdout quiet; merge time -p into time_file only.
    "$TIME_BIN" -p bash "$TMP/batch.$n.sh" 1>/dev/null 2>"$time_file" || true
  else
    # bash TIMEFORMAT (works on Git Bash / MSYS where no external time exists)
    # shellcheck disable=SC2039
    TIMEFORMAT=$'real %R\nuser %U\nsys %S'
    { time bash "$TMP/batch.$n.sh" 1>/dev/null; } 2>"$time_file" || true
  fi
  if [ -n "${EPOCHREALTIME-}" ] || [ "${BASH_VERSINFO[0]}" -ge 5 ] 2>/dev/null; then
    wall_end=$EPOCHREALTIME
    wall_s="$(awk -v s="$wall_start" -v e="$wall_end" 'BEGIN{printf "%.6f", e-s}')"
  else
    wall_end="$(date +%s)"
    wall_s="$(awk -v s="$wall_start" -v e="$wall_end" 'BEGIN{printf "%.6f", e-s}')"
  fi

  # Parse time -p (last real/user/sys win if mixed with script noise)
  user_s="$(awk '/^user /{u=$2} END{print u+0}' "$time_file")"
  sys_s="$(awk '/^sys /{s=$2} END{print s+0}' "$time_file")"
  real_s="$(awk '/^real /{r=$2} END{print r+0}' "$time_file")"
  # Prefer our perf_counter wall if time real is 0
  case "$real_s" in
    0|0.0|0.00|0.000) real_s="$wall_s" ;;
  esac

  cat "$lat_dir"/w.* > "$TMP/all.$n.lat" 2>/dev/null || : > "$TMP/all.$n.lat"
  # Avoid set -- word-split pitfalls: read stats as one line
  stats_line="$(stats_file "$TMP/all.$n.lat")"
  mean_ms="$(echo "$stats_line" | awk '{print $1}')"
  p50="$(echo "$stats_line" | awk '{print $2}')"
  p95="$(echo "$stats_line" | awk '{print $3}')"
  p99="$(echo "$stats_line" | awk '{print $4}')"
  min_ms="$(echo "$stats_line" | awk '{print $5}')"
  max_ms="$(echo "$stats_line" | awk '{print $6}')"
  count="$(echo "$stats_line" | awk '{print $7}')"
  total=$((n * RENDERS))
  cpu_pct="$(awk -v u="$user_s" -v s="$sys_s" -v r="$real_s" 'BEGIN{ if(r<=0) r=1e-9; printf "%.1f", (u+s)/r*100 }')"
  cpu_per="$(awk -v u="$user_s" -v s="$sys_s" -v c="$count" 'BEGIN{ if(c<1) c=1; printf "%.6f", (u+s)/c }')"
  cpu_sum="$(awk -v u="$user_s" -v s="$sys_s" 'BEGIN{ printf "%.3f", u+s }')"

  printf '%s\n' "$uname_s,$LABEL,$BASH_BIN,$BASH_VER,$n,$RENDERS,$total,$mean_ms,$p50,$p95,$p99,$min_ms,$max_ms,$real_s,$user_s,$sys_s,$cpu_pct,$cpu_per" >> "$OUT"

  printf 'n=%-2s  mean=%7sms  p50=%7s  p95=%7s  p99=%7s  wall=%ss  user+sys=%ss  cpu=%s%%\n' \
    "$n" "$mean_ms" "$p50" "$p95" "$p99" "$real_s" \
    "$cpu_sum" \
    "$cpu_pct" >&2
done

echo "CSV: $OUT" >&2
# Copy CSV out of tmp before trap removes it, if OUT was inside TMP
if [ "${OUT#$TMP}" != "$OUT" ]; then
  final="${ROOT}/tools/bench/results/${LABEL//\//_}.csv"
  mkdir -p "$(dirname "$final")"
  cp "$OUT" "$final"
  echo "copied to $final" >&2
  OUT="$final"
fi
# Print path for callers
echo "$OUT"
