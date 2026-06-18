# iTerm2 Right-Corner Floating Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a compact coralline readout (`ctx limit5h limit7d cost`) floating in iTerm2's native top status bar while a Claude Code session runs, by emitting a plain-text file from `statusline.sh` that a small bash companion transports to iTerm2 via a `SetUserVar` OSC sequence.

**Architecture:** `statusline.sh` gains an opt-in plain-text render path (`VL_FLOAT=1`) that writes `~/.claude/coralline/float.txt` atomically each render, reusing the existing `seg_*` functions with color emission neutralized. A new "dumb" companion script `coralline-float` holds the real session tty (which Claude Code's sanitized stdout cannot reach), polls `float.txt`, base64-encodes it, and writes the `SetUserVar` OSC to that tty. iTerm2's top status bar renders `\(user.coralline)`. A `cf` shell function launches the companion alongside `claude` and reaps it on exit.

**Tech Stack:** Pure bash (macOS bash 3.2 + Linux/Git Bash bash 4/5 compatible), `jq` (already a coralline dependency), `base64` (BSD/GNU portable), `stat` (BSD/GNU portable). No Python, no daemon framework.

## Global Constraints

These apply to every task. Values copied verbatim from the spec.

- **Default float content:** `ctx limit5h limit7d cost`
- **Opt-in only:** `VL_FLOAT` defaults to `0`; the float path must add zero side effects when off, preserving the current fork-free default.
- **No ANSI in `float.txt`:** iTerm2's `Interpolated String` component renders plain text and does not interpret ANSI, so the float line must carry no escape bytes.
- **Atomic writes:** write to a temp file in the **same directory** as the target, then `mv` into place (rename, not cross-device copy), so a reader never sees a half-written line.
- **`base64` portability:** use a form that works on both BSD (macOS) and GNU; avoid GNU-only flags. GNU `base64` wraps at 76 cols — strip newlines with `tr -d '\n'`.
- **bash 3.2 compatible:** no associative arrays, no `${var^^}`, helpers return via globals (`printf -v`), not `$()`, in the hot render path.
- **The companion is dumb:** it contains **no formatting logic** — it only transports `float.txt`. All rendering stays in `statusline.sh` (single source of visual truth).

### Config keys (verbatim from spec)

| Key | Default | Meaning |
|---|---|---|
| `VL_FLOAT` | `0` | `1` = emit `float.txt` each render |
| `VL_FLOAT_SEGMENTS` | `ctx limit5h limit7d cost` | segments rendered into the float line |
| `CORALLINE_FLOAT_INTERVAL` | `1` | companion poll seconds |
| `CORALLINE_FLOAT_STALE` | `5` | seconds after which `float.txt` is treated as stale and the bar is cleared |

Plus two implementation-local keys this plan introduces:

| Key | Default | Meaning |
|---|---|---|
| `VL_FLOAT_FILE` | `$HOME/.claude/coralline/float.txt` | float file path (overridable for tests) |
| `VL_STATE` / `VL_STATE_FILE` | `0` / `$HOME/.claude/coralline/state.json` | optional raw-fields JSON for Spec B |

### Data contracts

- **`~/.claude/coralline/float.txt`** — one line of plain UTF-8, no ANSI. Overwritten atomically each render. Absence/staleness ⇒ companion clears the bar.
- **`~/.claude/coralline/state.json`** — raw parsed fields (`ctx_pct`, `fh_pct`, `fh_rst`, `wd_pct`, `wd_rst`, `cost`, `model`) as JSON. Foundation for Spec B.

---

## File Structure

- `statusline.sh` *(modify)* — add float config defaults, a `VL_NOCOLOR` no-op path in `fg()`/`bg()`, `strip_ansi()`, `emit_float()`, `emit_state()`, and two guarded dispatch calls. Single source of visual truth.
- `coralline-float` *(create, repo root)* — the companion. Captures tty, polls `float.txt`, emits the `SetUserVar` OSC. Sourceable/`--once`-testable.
- `test/test-float.sh` *(create)* — asserts `VL_FLOAT=1` produces a plain-text `float.txt` with expected segments and **no ANSI bytes**.
- `test/test-state.sh` *(create)* — asserts `VL_STATE=1` produces valid `state.json` with the raw fields.
- `test/test-float-companion.sh` *(create)* — asserts the companion emits the correct base64 OSC for a fresh `float.txt` and clears the bar when stale.
- `test/test-configure-float.sh` *(create)* — asserts `write_candidate_config` persists `VL_FLOAT` / `VL_FLOAT_SEGMENTS`.
- `configure.sh` *(modify)* — persist the float keys, add a Details-menu toggle, copy `coralline-float` during install, print iTerm2 + `cf` setup help when float is enabled.
- `install.sh` *(modify)* — download `coralline-float` in the remote-install path.
- `README.md`, `INSTALL.md` *(modify)* — document the iTerm2 status-bar setup, the `cf` snippet, and the new config keys.

---

## Task 1: Validation spike (manual gate — do this before building anything)

The whole design rests on one load-bearing assumption. Confirm it manually before writing code. This task has no automated test; its deliverable is a recorded PASS/FAIL.

**Files:** none (manual procedure).

- [ ] **Step 1: Open a fresh iTerm2 tab and start Claude Code**

In a new iTerm2 tab, run `claude` (or `cf`-less `claude`) so Claude Code owns the screen and is actively rendering its bottom statusline.

- [ ] **Step 2: Find that tab's tty**

In a *second* terminal/tab, list ttys to identify the device of the CC tab. The CC tab's `tty` is what the companion will hold; for the spike, discover it via `ps` or by running `tty` in the CC tab's shell before launching CC. Record it, e.g. `/dev/ttys003`.

- [ ] **Step 3: Configure the iTerm2 status bar (one-time)**

- iTerm2 → Settings → Profiles → Session → enable **Status bar** → **Configure Status Bar** → add an **Interpolated String** component → set its value to exactly: `\(user.coralline)`
- iTerm2 → Settings → Appearance → General → **Status bar location** → **Top**

- [ ] **Step 4: From the second process, write the OSC to the CC tab's tty**

```bash
printf '\033]1337;SetUserVar=coralline=%s\007' "$(printf 'spike-ok' | base64 | tr -d '\n')" > /dev/ttys003
```

(Substitute the real device from Step 2.)

- [ ] **Step 5: Observe and record the result**

Expected: the iTerm2 top-right status bar updates to `spike-ok`, **and Claude Code's bottom frame stays clean** (no corruption, no stray text).

- If PASS: write "Spike PASSED on <date>: external OSC to a CC session's tty updates the bar without corrupting CC's frame." into the spec's "Validation spike" section and proceed to Task 2.
- If FAIL (bar corrupts CC, or does not update): **stop.** Fall back to the iTerm2 Python API delivery path (spec "option B") and revise this plan before continuing.

---

## Task 2: Plain-text float render path in `statusline.sh`

**Files:**
- Modify: `statusline.sh` (defaults block ~line 39; `fg()`/`bg()` ~lines 122–133; new functions before the layout dispatch ~line 491; two guarded calls before `if [ "$VL_LAYOUT" = "auto" ]` ~line 493)
- Test: `test/test-float.sh` (create)

**Interfaces:**
- Consumes: existing parsed globals (`ctx_pct`, `fh_pct`, `fh_rst`, `wd_pct`, `wd_rst`, `cost`, `tok_*`, `model`), the `seg_*` functions, `build_segments`, `SEG_TXT[]`, `ESC`, `R`/`BOLD`/`NORM`.
- Produces: writes a plain-text line to `$VL_FLOAT_FILE` when `VL_FLOAT=1`. Adds globals `VL_FLOAT`, `VL_FLOAT_SEGMENTS`, `VL_FLOAT_FILE`, `VL_NOCOLOR`, and functions `strip_ansi` (→ `_PLAIN`) and `emit_float`.

- [ ] **Step 1: Write the failing test**

Create `test/test-float.sh`:

```bash
#!/usr/bin/env bash
# Verifies VL_FLOAT=1 makes statusline.sh emit a plain-text float.txt
# containing the expected segments and NO ANSI escape bytes.
#   bash test/test-float.sh
# Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
SAMPLE="$HERE/sample-input.json"
ESC=$'\033'
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-float-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
conf="$tmpdir/c.conf"
floatf="$tmpdir/float.txt"

cat > "$conf" <<EOF
VL_FLOAT=1
VL_FLOAT_FILE="$floatf"
VL_FLOAT_SEGMENTS="ctx limit5h limit7d cost"
EOF

CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$SAMPLE" >/dev/null

check() {  # $1=description ; $2=1 if pass
  if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi
}

[ -f "$floatf" ]; check "float.txt created" "$([ -f "$floatf" ] && echo 1 || echo 0)"

# No ESC bytes anywhere in the file.
if LC_ALL=C grep -q "$ESC" "$floatf"; then check "no ANSI escapes" 0; else check "no ANSI escapes" 1; fi

# Expected rendered tokens (ctx 62%, 5h 41%, 7d 79%, cost $1.23).
grep -q '62%' "$floatf"        && check "ctx 62%"  1 || check "ctx 62%"  0
grep -q '41%' "$floatf"        && check "5h 41%"   1 || check "5h 41%"   0
grep -q '79%' "$floatf"        && check "7d 79%"   1 || check "7d 79%"   0
grep -qF '$1.23' "$floatf"     && check "cost"     1 || check "cost"     0

# Exactly one line.
lines=$(wc -l < "$floatf" | tr -d ' ')
[ "$lines" = "1" ]; check "single line (got $lines)" "$([ "$lines" = "1" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-float.sh`
Expected: FAIL — `float.txt created` fails because `VL_FLOAT` does nothing yet.

- [ ] **Step 3: Add the float config defaults**

In `statusline.sh`, immediately after the `VL_ASCII=0` line (currently line 39), add:

```bash
VL_FLOAT=0                      # 1 = also emit a plain-text float line (for coralline-float)
VL_FLOAT_SEGMENTS="ctx limit5h limit7d cost"  # segments rendered into the float line
VL_FLOAT_FILE="$HOME/.claude/coralline/float.txt"
VL_NOCOLOR=0                    # internal: fg()/bg() emit nothing when 1 (plain-text path)
```

- [ ] **Step 4: Make `fg()` and `bg()` honor `VL_NOCOLOR`**

In `statusline.sh`, change the top of `fg()` (currently line 122) from:

```bash
fg() {
  if [ -z "$1" ]; then _FG=""; return; fi
```

to:

```bash
fg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _FG=""; return; fi
  if [ -z "$1" ]; then _FG=""; return; fi
```

And the top of `bg()` (currently line 128) from:

```bash
bg() {
  if [ -z "$1" ]; then _BG=""; return; fi
```

to:

```bash
bg() {
  if [ "$VL_NOCOLOR" = "1" ]; then _BG=""; return; fi
  if [ -z "$1" ]; then _BG=""; return; fi
```

- [ ] **Step 5: Add `strip_ansi()` and `emit_float()` before the layout dispatch**

In `statusline.sh`, immediately after the `term_cols()` function closes (currently line 491, just before `if [ "$VL_LAYOUT" = "auto" ]; then`), insert:

```bash
# Defensive ANSI stripper (the VL_NOCOLOR path should already emit none) → _PLAIN.
strip_ansi() {
  local s="$1" out=""
  while [ "${s#*$ESC}" != "$s" ]; do
    out+="${s%%$ESC*}" ; s="${s#*$ESC}" ; s="${s#*m}"
  done
  _PLAIN="$out$s"
}

# Build VL_FLOAT_SEGMENTS with color emission neutralized and write a single
# plain-text line atomically to VL_FLOAT_FILE. Saves/restores the color globals
# so the normal render that follows is unaffected.
emit_float() {
  local _nc="$VL_NOCOLOR" _b="$BOLD" _n="$NORM" _r="$R"
  local dir line i s tmp
  VL_NOCOLOR=1 ; BOLD="" ; NORM="" ; R=""
  build_segments "$VL_FLOAT_SEGMENTS"
  line=""
  for ((i=0; i<${#SEG_TXT[@]}; i++)); do
    strip_ansi "${SEG_TXT[$i]}" ; s="$_PLAIN"
    s="${s#"${s%%[![:space:]]*}"}" ; s="${s%"${s##*[![:space:]]}"}"   # trim
    [ -n "$s" ] || continue
    line="${line:+$line }$s"
  done
  VL_NOCOLOR="$_nc" ; BOLD="$_b" ; NORM="$_n" ; R="$_r"
  dir=$(dirname "$VL_FLOAT_FILE")
  mkdir -p "$dir"
  tmp="$dir/.float.tmp.$$"
  printf '%s\n' "$line" > "$tmp" && mv -f "$tmp" "$VL_FLOAT_FILE"
}
```

- [ ] **Step 6: Add the guarded dispatch call before the layout block**

In `statusline.sh`, immediately before `if [ "$VL_LAYOUT" = "auto" ]; then` (currently line 493), insert:

```bash
[ "$VL_FLOAT" = "1" ] && emit_float
```

(Placed *before* the render: `emit_float` saves/restores color globals and the
layout block rebuilds `SEG_*` for display, so order is safe and no render
refactor is needed.)

- [ ] **Step 7: Run the test to verify it passes**

Run: `bash test/test-float.sh`
Expected: `ALL PASS`

- [ ] **Step 8: Confirm the float path is a no-op when off**

Run: `bash statusline.sh < test/sample-input.json >/dev/null && echo "default render OK (no VL_FLOAT)"`
Expected: prints `default render OK (no VL_FLOAT)` and creates no `float.txt` in `~/.claude/coralline/` from this run (no config sets `VL_FLOAT=1`).

- [ ] **Step 9: Commit**

```bash
git add statusline.sh test/test-float.sh
git commit -m "feat(float): emit plain-text float.txt when VL_FLOAT=1"
```

---

## Task 3: `state.json` emission (foundation for Spec B)

**Files:**
- Modify: `statusline.sh` (defaults block after the Task 2 additions; new `emit_state()` next to `emit_float()`; one guarded call after the float call)
- Test: `test/test-state.sh` (create)

**Interfaces:**
- Consumes: parsed globals `ctx_pct`, `fh_pct`, `fh_rst`, `wd_pct`, `wd_rst`, `cost`, `model`; `jq`.
- Produces: writes `$VL_STATE_FILE` (valid JSON) when `VL_STATE=1`. Adds globals `VL_STATE`, `VL_STATE_FILE`, function `emit_state`.

- [ ] **Step 1: Write the failing test**

Create `test/test-state.sh`:

```bash
#!/usr/bin/env bash
# Verifies VL_STATE=1 makes statusline.sh emit a valid state.json with raw fields.
#   bash test/test-state.sh
# Needs bash + jq.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"
SAMPLE="$HERE/sample-input.json"
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-state-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
conf="$tmpdir/c.conf"
statef="$tmpdir/state.json"

cat > "$conf" <<EOF
VL_STATE=1
VL_STATE_FILE="$statef"
EOF

CORALLINE_CONFIG="$conf" bash "$SCRIPT" < "$SAMPLE" >/dev/null

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }

[ -f "$statef" ]; check "state.json created" "$([ -f "$statef" ] && echo 1 || echo 0)"
jq -e . "$statef" >/dev/null 2>&1; check "valid JSON" "$([ $? -eq 0 ] && echo 1 || echo 0)"
[ "$(jq -r '.ctx_pct' "$statef" 2>/dev/null)" = "62.4" ]; check "ctx_pct=62.4" "$([ "$(jq -r '.ctx_pct' "$statef" 2>/dev/null)" = "62.4" ] && echo 1 || echo 0)"
[ "$(jq -r '.fh_pct' "$statef" 2>/dev/null)" = "41.2" ]; check "fh_pct=41.2" "$([ "$(jq -r '.fh_pct' "$statef" 2>/dev/null)" = "41.2" ] && echo 1 || echo 0)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-state.sh`
Expected: FAIL — `state.json created` fails because `VL_STATE` does nothing yet.

- [ ] **Step 3: Add the state defaults**

In `statusline.sh`, directly after the `VL_NOCOLOR=0` line added in Task 2, add:

```bash
VL_STATE=0                      # 1 = also emit state.json (raw parsed fields, for Spec B)
VL_STATE_FILE="$HOME/.claude/coralline/state.json"
```

- [ ] **Step 4: Add `emit_state()`**

In `statusline.sh`, immediately after the `emit_float()` function added in Task 2, insert:

```bash
# Write the raw parsed fields as JSON atomically (foundation for Spec B).
emit_state() {
  local dir tmp
  dir=$(dirname "$VL_STATE_FILE")
  mkdir -p "$dir"
  tmp="$dir/.state.tmp.$$"
  jq -n \
    --arg ctx_pct "$ctx_pct" --arg fh_pct "$fh_pct" --arg fh_rst "$fh_rst" \
    --arg wd_pct "$wd_pct"   --arg wd_rst "$wd_rst" --arg cost "$cost" \
    --arg model  "$model" \
    '{ctx_pct:$ctx_pct, fh_pct:$fh_pct, fh_rst:$fh_rst,
      wd_pct:$wd_pct, wd_rst:$wd_rst, cost:$cost, model:$model}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$VL_STATE_FILE"
}
```

- [ ] **Step 5: Add the guarded dispatch call**

In `statusline.sh`, directly after the `[ "$VL_FLOAT" = "1" ] && emit_float` line added in Task 2, add:

```bash
[ "$VL_STATE" = "1" ] && emit_state
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash test/test-state.sh`
Expected: `ALL PASS`

- [ ] **Step 7: Commit**

```bash
git add statusline.sh test/test-state.sh
git commit -m "feat(float): emit raw-fields state.json when VL_STATE=1"
```

---

## Task 4: `coralline-float` companion script

**Files:**
- Create: `coralline-float` (repo root)
- Test: `test/test-float-companion.sh` (create)

**Interfaces:**
- Consumes: `float.txt` (path via `CORALLINE_FLOAT_FILE`, default `$HOME/.claude/coralline/float.txt`); env `CORALLINE_FLOAT_INTERVAL` (default `1`), `CORALLINE_FLOAT_STALE` (default `5`), `CORALLINE_FLOAT_TTY` (test override — bypasses the tty guard).
- Produces: writes `\033]1337;SetUserVar=coralline=<base64>\007` to the captured tty; clears the bar (empty value) when `float.txt` is stale/missing. Supports `--once` (single iteration, always emits, no sleep).

- [ ] **Step 1: Write the failing test**

Create `test/test-float-companion.sh`:

```bash
#!/usr/bin/env bash
# Verifies coralline-float emits the correct SetUserVar OSC for a fresh float.txt
# and clears the bar when float.txt is stale.
#   bash test/test-float-companion.sh
# Needs bash + base64.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
COMPANION="$HERE/../coralline-float"
fail=0

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-companion-test.XXXXXX") || exit 1
trap 'rm -rf "$tmpdir"' EXIT
floatf="$tmpdir/float.txt"
out="$tmpdir/tty.out"

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fi; [ "$2" = "1" ] || fail=1; }

# --- Fresh file → emits OSC with base64 of its content ---
printf 'ctx 62%%\n' > "$floatf"   # %% → literal %
b64=$(printf '%s' 'ctx 62%' | base64 | tr -d '\n')
printf '\033]1337;SetUserVar=coralline=%s\007' "$b64" > "$tmpdir/expect.fresh"

CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" \
  CORALLINE_FLOAT_STALE=5 bash "$COMPANION" --once

if cmp -s "$out" "$tmpdir/expect.fresh"; then check "fresh emits correct OSC" 1; else check "fresh emits correct OSC" 0; fi

# --- Stale file → clears the bar (empty value) ---
touch -t 200001010000 "$floatf"   # mtime in the year 2000 → stale
printf '\033]1337;SetUserVar=coralline=%s\007' "" > "$tmpdir/expect.clear"

CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" \
  CORALLINE_FLOAT_STALE=5 bash "$COMPANION" --once

if cmp -s "$out" "$tmpdir/expect.clear"; then check "stale clears the bar" 1; else check "stale clears the bar" 0; fi

# --- Missing file → clears the bar ---
rm -f "$floatf"
CORALLINE_FLOAT_TTY="$out" CORALLINE_FLOAT_FILE="$floatf" bash "$COMPANION" --once
if cmp -s "$out" "$tmpdir/expect.clear"; then check "missing clears the bar" 1; else check "missing clears the bar" 0; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-float-companion.sh`
Expected: FAIL — `coralline-float` does not exist yet (`No such file or directory`).

- [ ] **Step 3: Create the companion script**

Create `coralline-float` (repo root):

```bash
#!/usr/bin/env bash
# coralline-float — transports ~/.claude/coralline/float.txt to iTerm2's top
# status bar via a SetUserVar OSC written to the real session tty.
#
# This exists because Claude Code sanitizes control sequences out of the output
# it captures from statusline.sh, and CC-spawned subprocesses have no usable tty.
# Launch this from your interactive shell (it inherits that shell's tty), e.g.:
#   cf() { "$HOME/.claude/coralline/coralline-float" & local p=$!; claude "$@"; kill "$p" 2>/dev/null; }
#
# It is deliberately dumb: NO formatting logic. statusline.sh is the single
# source of visual truth; this only carries the bytes.
#
# Pure bash + base64. Works on macOS (BSD) and Linux/Git Bash (GNU).
set -u

FLOAT_FILE="${CORALLINE_FLOAT_FILE:-$HOME/.claude/coralline/float.txt}"
INTERVAL="${CORALLINE_FLOAT_INTERVAL:-1}"
STALE="${CORALLINE_FLOAT_STALE:-5}"

# Resolve the target tty. CORALLINE_FLOAT_TTY overrides (used by tests / advanced
# setups); otherwise capture the controlling tty once and require a real device.
if [ -n "${CORALLINE_FLOAT_TTY:-}" ]; then
  TTY="$CORALLINE_FLOAT_TTY"
else
  TTY=$(tty 2>/dev/null) || TTY=""
  case "$TTY" in
    /dev/*) : ;;
    *) printf 'coralline-float: no controlling tty (launch from an interactive shell, not detached)\n' >&2
       exit 1 ;;
  esac
fi

# Write a SetUserVar OSC. $1 = plain value; empty clears the bar. Truncate-write
# so a regular file (tests) holds exactly one OSC; on a tty this is a plain write.
emit() {
  local b64
  b64=$(printf '%s' "$1" | base64 | tr -d '\n')
  printf '\033]1337;SetUserVar=coralline=%s\007' "$b64" > "$TTY"
}

# Portable mtime in epoch seconds (BSD then GNU).
file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

# Compute the value to push: contents if fresh, empty if stale/missing.
current_value() {
  local now mt
  [ -f "$FLOAT_FILE" ] || { printf '%s' ""; return; }
  now=$(date +%s)
  mt=$(file_mtime "$FLOAT_FILE")
  if [ -n "$mt" ] && [ "$((now - mt))" -le "$STALE" ]; then
    cat "$FLOAT_FILE"
  else
    printf '%s' ""
  fi
}

run_once() {
  emit "$(current_value)"
}

# --once: single iteration (for tests / scripted use), always emits.
if [ "${1:-}" = "--once" ]; then
  run_once
  exit 0
fi

# Loop mode: poll, dedupe writes, clear the bar on exit.
trap 'emit ""; exit 0' INT TERM
last=$'\001'   # sentinel that no real value equals, so the first push always fires
while :; do
  val=$(current_value)
  if [ "$val" != "$last" ]; then emit "$val"; last="$val"; fi
  sleep "$INTERVAL"
done
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x coralline-float`

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test-float-companion.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Verify the no-tty guard**

Run: `bash coralline-float --once < /dev/null 2>&1 | head -1` (with no `CORALLINE_FLOAT_TTY` set and stdin not a tty)
Expected: prints `coralline-float: no controlling tty (launch from an interactive shell, not detached)` and exits non-zero. (Confirm with `echo $?` → non-zero.)

- [ ] **Step 7: Commit**

```bash
git add coralline-float test/test-float-companion.sh
git commit -m "feat(float): add coralline-float companion that transports float.txt to iTerm2"
```

---

## Task 5: `configure.sh` integration

**Files:**
- Modify: `configure.sh` (state vars ~line 33; `write_candidate_config` ~line 454; `choose_details_screen` ~line 756 and `draw_details_menu` ~line 804; `write_final_config` ~line 1037; new `print_float_help()`; `install_files` ~line 1050)
- Test: `test/test-configure-float.sh` (create)

**Interfaces:**
- Consumes: `SCRIPT_DIR`, `TARGET_DIR`, existing wizard state vars, `write_assign`, `shell_quote`, `runtime_theme_dir`, `flag_mark`, `draw_option`, `need_file`.
- Produces: persists `VL_FLOAT` / `VL_FLOAT_SEGMENTS` to the generated config via new state vars `float_enabled` / `float_segments`; copies `coralline-float` into `$TARGET_DIR`; prints `print_float_help` when enabled.

- [ ] **Step 1: Write the failing test**

Create `test/test-configure-float.sh`:

```bash
#!/usr/bin/env bash
# Verifies write_candidate_config persists VL_FLOAT / VL_FLOAT_SEGMENTS.
# Extracts the live functions from configure.sh so the test cannot drift.
#   bash test/test-configure-float.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"
fail=0

# Pull the three pure functions out of configure.sh.
eval "$(sed -n '/^shell_quote() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_assign() {/,/^}/p' "$CONF")"
eval "$(sed -n '/^write_candidate_config() {/,/^}/p' "$CONF")"

# Minimal globals write_candidate_config reads.
theme="claude-coral" ; style="pill" ; layout="auto" ; max_lines=3
segments="ctx cost" ; segments2="" ; segments3=""
clock_mode="12h" ; clock_seconds=1 ; name_max=0 ; ascii_mode=0
lean_sep="" ; extra_config=""
float_enabled=1 ; float_segments="ctx limit5h limit7d cost"
runtime_theme_dir() { printf '/tmp/themes'; }

out=$(mktemp "${TMPDIR:-/tmp}/coralline-cfg-test.XXXXXX") || exit 1
trap 'rm -f "$out"' EXIT
write_candidate_config "$out"

check() { if [ "$2" = "1" ]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s\n' "$1"; fail=1; fi; }
grep -q '^VL_FLOAT=1' "$out"            && check "VL_FLOAT=1 written" 1          || check "VL_FLOAT=1 written" 0
grep -q '^VL_FLOAT_SEGMENTS=' "$out"    && check "VL_FLOAT_SEGMENTS written" 1   || check "VL_FLOAT_SEGMENTS written" 0

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/test-configure-float.sh`
Expected: FAIL — `VL_FLOAT=1 written` fails (and likely `write_candidate_config` errors on unbound `float_enabled` under `set -u`, also a fail).

- [ ] **Step 3: Add the wizard state variables**

In `configure.sh`, after the `lean_sep=""` line (currently line 33), add:

```bash
float_enabled=0
float_segments="ctx limit5h limit7d cost"
```

- [ ] **Step 4: Persist the keys in `write_candidate_config`**

In `configure.sh`, after the `write_assign VL_LEAN_SEP "$lean_sep"` line (currently line 454), add:

```bash
    write_assign VL_FLOAT "$float_enabled"
    write_assign VL_FLOAT_SEGMENTS "$float_segments"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bash test/test-configure-float.sh`
Expected: `ALL PASS`

- [ ] **Step 6: Add the Details-menu toggle (interactive wiring)**

In `configure.sh`, in `choose_details_screen` change `local selected=0 key count=6 dirty=1` (line 756) to `count=7`:

```bash
  local selected=0 key count=7 dirty=1
```

In the same function's `space)` case (currently ends at the `5)` name_max block ~line 783), add a new case after the `5)` block, before the closing `esac`:

```bash
          6) [ "$float_enabled" = "1" ] && float_enabled=0 || float_enabled=1; dirty=1 ;;
```

In `draw_details_menu`, after the `name max` block (currently line 804, the `[ "$selected" = "5" ] && draw_option ...` line), add:

```bash
  mark=$(flag_mark "$float_enabled")
  [ "$selected" = "6" ] && draw_option 1 "$mark" "iTerm2 float (VL_FLOAT)" || draw_option 0 "$mark" "iTerm2 float (VL_FLOAT)"
```

- [ ] **Step 7: Add `print_float_help()` and call it after writing config**

In `configure.sh`, add this function immediately before `write_final_config()` (currently line 1022):

```bash
print_float_help() {
  cat <<'EOF'

iTerm2 floating display (VL_FLOAT) is enabled. One-time setup:
  1. iTerm2 -> Settings -> Profiles -> Session -> enable Status bar -> Configure
     Status Bar -> add an "Interpolated String" component, value:  \(user.coralline)
  2. iTerm2 -> Settings -> Appearance -> General -> Status bar location -> Top
  3. Add this to your shell rc (~/.zshrc or ~/.bashrc), then restart your shell:
       cf() { "$HOME/.claude/coralline/coralline-float" & local p=$!; claude "$@"; kill "$p" 2>/dev/null; }
  4. Launch Claude Code sessions with:  cf
     (cf runs the companion that pushes the float to iTerm2's top-right bar)
EOF
}
```

Then in `write_final_config`, after the `printf '%sWrote%s %s\n' ...` line (currently line 1037), add:

```bash
  [ "$float_enabled" = "1" ] && print_float_help
```

- [ ] **Step 8: Copy `coralline-float` during install**

In `configure.sh`, in `install_files()`: after the `need_file "$SCRIPT_DIR/test/sample-input.json"` line (currently line 1044), add:

```bash
  need_file "$SCRIPT_DIR/coralline-float"
```

After the `cp "$SCRIPT_DIR/test/sample-input.json" "$TARGET_DIR/sample-input.json"` line (currently line 1050), add:

```bash
  cp "$SCRIPT_DIR/coralline-float" "$TARGET_DIR/coralline-float"
```

And change the `chmod +x` line (currently line 1059) from:

```bash
  chmod +x "$TARGET_DIR/statusline.sh" "$TARGET_DIR/configure.sh"
```

to:

```bash
  chmod +x "$TARGET_DIR/statusline.sh" "$TARGET_DIR/configure.sh" "$TARGET_DIR/coralline-float"
```

- [ ] **Step 9: Syntax-check configure.sh**

Run: `bash -n configure.sh && echo "configure.sh syntax OK"`
Expected: prints `configure.sh syntax OK`.

- [ ] **Step 10: Verify install copies the companion (local checkout)**

Run:

```bash
rm -rf /tmp/cf-home && CORALLINE_HOME=/tmp/cf-home/coralline \
  CORALLINE_CONFIG=/tmp/cf-home/coralline.conf \
  CLAUDE_SETTINGS=/tmp/cf-home/settings.json \
  bash configure.sh --install-only </dev/null
ls -l /tmp/cf-home/coralline/coralline-float
```

Expected: `coralline-float` exists in `/tmp/cf-home/coralline/` and is executable (`-rwx`).

- [ ] **Step 11: Commit**

```bash
git add configure.sh test/test-configure-float.sh
git commit -m "feat(float): wire VL_FLOAT into configure.sh (persist, toggle, install, help)"
```

---

## Task 6: `install.sh` remote-download path

**Files:**
- Modify: `install.sh` (remote-download block ~line 209)

**Interfaces:**
- Consumes: `BASE_URL`, `WORK_DIR`, `download()`.
- Produces: downloads `coralline-float` into `$WORK_DIR` so `configure.sh install_files` can copy it during a remote (curl) install. (Local-checkout installs already have it in `SCRIPT_DIR`.)

- [ ] **Step 1: Add the download line**

In `install.sh`, after the `download "$BASE_URL/statusline.sh" "$WORK_DIR/statusline.sh"` line (currently line 209), add:

```bash
  download "$BASE_URL/coralline-float" "$WORK_DIR/coralline-float"
```

- [ ] **Step 2: Syntax-check and confirm the line is present**

Run: `bash -n install.sh && grep -q 'coralline-float' install.sh && echo "install.sh OK"`
Expected: prints `install.sh OK`.

- [ ] **Step 3: Verify a local-base-url install pulls the companion**

Run:

```bash
rm -rf /tmp/cf-home2 && CORALLINE_HOME=/tmp/cf-home2/coralline \
  CORALLINE_CONFIG=/tmp/cf-home2/coralline.conf \
  CLAUDE_SETTINGS=/tmp/cf-home2/settings.json \
  bash install.sh --install-only --base-url "file://$PWD" </dev/null
ls -l /tmp/cf-home2/coralline/coralline-float
```

Expected: `coralline-float` exists and is executable. (This exercises the local-checkout path, which is the realistic test without a network; the added line covers the curl path symmetrically.)

- [ ] **Step 4: Commit**

```bash
git add install.sh
git commit -m "feat(float): download coralline-float in the remote install path"
```

---

## Task 7: Documentation (README + INSTALL)

**Files:**
- Modify: `README.md` (add an "iTerm2 floating display" section; add the new keys to the config-keys reference)
- Modify: `INSTALL.md` (note the companion + `cf` snippet in setup)

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add the iTerm2 floating-display section to README.md**

Add a new section to `README.md` (place it after the configuration/segments section, matching the file's existing heading style). Use this content:

````markdown
## iTerm2 floating display (optional)

Show a compact readout — `ctx limit5h limit7d cost` by default — floating in
iTerm2's native **top status bar**, so environment health stays visible without
glancing at Claude Code's bottom statusline.

Claude Code owns and sanitizes its own statusline output, so the data reaches
iTerm2 by a side channel: `statusline.sh` writes a plain-text line to
`~/.claude/coralline/float.txt`, and a tiny companion (`coralline-float`) running
in your interactive shell pushes it to iTerm2 via a `SetUserVar` escape.

**One-time setup**

1. iTerm2 → Settings → Profiles → Session → enable **Status bar** → **Configure
   Status Bar** → add an **Interpolated String** component with value
   `\(user.coralline)`.
2. iTerm2 → Settings → Appearance → General → **Status bar location** → **Top**.
3. Enable the float in `~/.claude/coralline.conf`:

   ```bash
   VL_FLOAT=1
   VL_FLOAT_SEGMENTS="ctx limit5h limit7d cost"
   ```

   (Or pick "iTerm2 float" in `configure.sh`'s Details menu.)
4. Add this to your shell rc (`~/.zshrc` or `~/.bashrc`) and restart your shell:

   ```bash
   cf() { "$HOME/.claude/coralline/coralline-float" & local p=$!; claude "$@"; kill "$p" 2>/dev/null; }
   ```

**Use:** launch Claude Code with `cf` instead of `claude`. The companion starts,
`claude` runs, and the companion is reaped on exit (clearing the bar).

**Config keys**

| Key | Default | Meaning |
|---|---|---|
| `VL_FLOAT` | `0` | `1` = emit `float.txt` each render |
| `VL_FLOAT_SEGMENTS` | `ctx limit5h limit7d cost` | segments rendered into the float line |
| `CORALLINE_FLOAT_INTERVAL` | `1` | companion poll seconds |
| `CORALLINE_FLOAT_STALE` | `5` | seconds before a stale `float.txt` clears the bar |

**Limitations:** iTerm2-only; a single global `float.txt` means concurrent
sessions are last-writer-wins; requires the one-time status-bar setup and using
`cf` to launch.
````

- [ ] **Step 2: Add a short pointer in INSTALL.md**

In `INSTALL.md`, where post-install/optional features are described, add:

```markdown
### iTerm2 floating display (optional)

coralline can float `ctx / 5h / 7d / cost` in iTerm2's top status bar. Enable
`VL_FLOAT=1` (or pick "iTerm2 float" in the Details menu), add an Interpolated
String status-bar component with value `\(user.coralline)`, set the status bar
location to Top, and launch sessions with the `cf` shell function. See the
"iTerm2 floating display" section in the README for the full walkthrough.
```

- [ ] **Step 3: Verify the docs mention the key pieces**

Run:

```bash
grep -q 'user.coralline' README.md \
  && grep -q 'VL_FLOAT' README.md \
  && grep -q 'coralline-float' README.md \
  && grep -q 'VL_FLOAT' INSTALL.md \
  && echo "docs OK"
```

Expected: prints `docs OK`.

- [ ] **Step 4: Commit**

```bash
git add README.md INSTALL.md
git commit -m "docs(float): document the iTerm2 floating display setup and keys"
```

---

## Task 8: Manual end-to-end acceptance

The automated tests cover render, state, and transport in isolation. This task is
the live acceptance the spec calls for. Manual; no test code.

**Files:** none.

- [ ] **Step 1: Install the local build**

Run: `bash install.sh --install-only` (or `--install` to also run setup). Confirm `~/.claude/coralline/coralline-float` exists and is executable.

- [ ] **Step 2: Enable the float and configure iTerm2**

Set `VL_FLOAT=1` in `~/.claude/coralline.conf`, add the `\(user.coralline)` Interpolated String component, and set the status bar location to Top (per Task 7 README).

- [ ] **Step 3: Add the `cf` function and launch**

Add the `cf` snippet to your shell rc, restart the shell, then run `cf` in a project directory to start Claude Code.

- [ ] **Step 4: Observe the live float**

Expected: iTerm2's top-right shows live `ctx / 5h / 7d / cost` updating as the session runs, while Claude Code's bottom statusline renders normally with no corruption.

- [ ] **Step 5: Confirm teardown**

Exit Claude Code. Expected: the companion is reaped and the top bar clears (no stale data lingers).

- [ ] **Step 6: Record the result**

Note PASS/FAIL in the spec's "Testing strategy → Manual iTerm2 acceptance" line.

---

## Self-Review

**1. Spec coverage**

- State/float emitter inside `statusline.sh` (spec §1) → Task 2 (`VL_FLOAT`, `VL_FLOAT_SEGMENTS`, plain-text path via `VL_NOCOLOR`, atomic write).
- `state.json` (spec §1, optional) → Task 3.
- `coralline-float` companion (spec §2) → Task 4 (tty capture, poll, base64 OSC, stale-clear, dumb-by-design).
- `cf` shell function (spec §3) → documented in Task 5 (`print_float_help`) and Task 7 (README), using full path (no PATH assumption).
- iTerm2 status-bar setup (spec §4) → Task 7 README + Task 5 installer print.
- configure.sh integration (spec) → Task 5 (toggle, persist, help print).
- install.sh integration (spec) → Task 5 (local copy) + Task 6 (remote download).
- Validation spike (spec) → Task 1 (pre-build gate).
- Testing strategy: render no-ANSI → Task 2; atomicity → atomic `mv` used throughout (render path tested for single-line integrity in Task 2 Step 1); companion base64/clear → Task 4; manual acceptance → Task 8.
- Edge cases: no-tty guard → Task 4 Step 6; stale/missing clear → Task 4; `base64` BSD/GNU → `base64 | tr -d '\n'`; atomic same-dir temp → `emit_float`/`emit_state`/companion. `VL_ASCII=1` interaction: the float path reuses `seg_*`, so `VL_ASCII` (which blanks Nerd Font glyphs) carries through unchanged — covered behaviorally by Task 2's reuse, called out here as a manual check during Task 8 if `VL_ASCII=1`.

**2. Placeholder scan:** No TBD/TODO/"handle edge cases" placeholders; every code step shows complete code and every test step shows exact assertions and expected output.

**3. Type/name consistency:** `VL_FLOAT`, `VL_FLOAT_SEGMENTS`, `VL_FLOAT_FILE`, `VL_NOCOLOR`, `VL_STATE`, `VL_STATE_FILE` defined in Tasks 2–3 and consumed consistently. `emit_float`/`emit_state`/`strip_ansi` defined and called by the same names. Companion env names `CORALLINE_FLOAT_FILE`/`CORALLINE_FLOAT_INTERVAL`/`CORALLINE_FLOAT_STALE`/`CORALLINE_FLOAT_TTY` consistent between Task 4 script and test. configure state vars `float_enabled`/`float_segments` consistent across Steps 3–7.

---

## Execution Handoff

After saving, choose an execution approach (subagent-driven recommended).
