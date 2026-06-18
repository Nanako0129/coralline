# Spec A — iTerm2 right-corner floating display

- **Date:** 2026-06-17
- **Status:** Design approved, pending spec review
- **Author:** brainstormed with Claude
- **Supersedes/relates:** Spec B (threshold engine + conditional segments + notifications) is deferred and will layer on the same `state.json` bridge introduced here.

## Goal

Show a compact coralline readout **floating in the top-right of the iTerm2 window**
(its native top status bar) while a Claude Code session runs — so the
"environment health" (context fill, rate limits, cost) is always visible without
looking down at Claude Code's bottom statusline.

The default float content is `ctx limit5h limit7d cost`.

## Background: what the spike ruled out

This design is the product of a live spike. The findings are load-bearing, so they
are recorded here:

1. **Claude Code owns the screen.** CC calls `statusline.sh`, captures its stdout,
   and renders that string itself in the bottom statusline area. coralline cannot
   tell CC to put it elsewhere.
2. **Escapes through CC's stdout do not reach iTerm2.** Emitting a `SetUserVar`
   OSC sequence from CC-mediated output (tested via `!` bash mode) printed the
   escape as literal text — CC sanitizes control sequences. So the seductive
   "`statusline.sh` writes the OSC directly" approach is **dead**.
3. **CC-spawned subprocesses likely have no controlling tty.** A probe shell
   spawned by CC reported `/dev/tty` not writable and `tty` → "not a tty". So
   `statusline.sh` cannot reliably write to `/dev/tty` either.
4. **The iTerm2 mechanism itself works.** In a plain (non-CC) iTerm2 tab,
   `printf '\033]1337;SetUserVar=coralline=%s\007' "$(printf hello | base64)"`
   correctly updated a top status bar `Interpolated String` component showing
   `\(user.coralline)`.

**Conclusion:** the data must reach iTerm2 by **bypassing CC**, from a process that
holds the real session tty. That process is a small bash **companion** launched
from the user's interactive shell. `SetUserVar` is an OSC sequence — it does not
move the cursor or draw — so injecting it into the session's tty does not disturb
CC's display.

## Non-goals

- Relocating Claude Code's own bottom statusline (impossible; CC controls it).
- Supporting terminals other than iTerm2 in this spec (WezTerm/Kitty/menu-bar
  adapters are possible future specs reusing the same `state.json`).
- The threshold engine / conditional segments / event notifications — deferred to
  Spec B.
- Multi-session correctness beyond "last writer wins" (see Limitations).

## Architecture

```
┌─ Claude Code ────────────────────────────┐
│ calls statusline.sh every refresh         │
│   ├─ prints the bottom line (stdout)       │  ← unchanged
│   └─ if VL_FLOAT=1: also writes a plain-    │
│      text line to ~/.claude/coralline/float.txt
└────────────────────────────────────────────┘
                 │  file write (no tty needed — verified writable)
                 ▼
┌─ coralline-float (companion) ──────────────┐
│  captures `tty` at startup (real session tty)│
│  loop: read float.txt → base64 →            │
│        write SetUserVar OSC to that tty      │
│        clear var if float.txt is stale       │
└──────────────────────────────────────────────┘
                 │  OSC (non-drawing → does not corrupt CC's frame)
                 ▼
        iTerm2 top status bar:  \(user.coralline)
```

Four pieces:

### 1. State/float emitter — inside `statusline.sh`

- New config flag **`VL_FLOAT=0`** (default off; when `1`, emit the float file).
  Keeping it opt-in preserves the current zero-side-effect, fork-free default.
- New config **`VL_FLOAT_SEGMENTS="ctx limit5h limit7d cost"`** — the segment list
  rendered into the float line, independent of `VL_SEGMENTS`.
- Add a **plain-text render path**: a mode where `fg()`/`bg()` become no-ops (emit
  no ANSI), so the existing `seg_*` functions and segment system are reused to
  produce a color-free string. iTerm2's `Interpolated String` component renders
  plain text (it does not interpret ANSI), so the float line must carry no escapes.
- Write the result to `~/.claude/coralline/float.txt` **atomically** (write to a
  temp file in the same dir, then `mv` into place) so the companion never reads a
  half-written line.
- Also (cheap, optional in this spec but recommended) write the already-parsed raw
  fields to `~/.claude/coralline/state.json` for Spec B to consume. If included,
  keep it behind the same `VL_FLOAT` gate or a sibling `VL_STATE` gate.
- Performance: all values are already parsed in the normal render; the float path
  adds one extra segment build + one atomic file write, only when `VL_FLOAT=1`.

### 2. `coralline-float` — the companion (new bash script)

- Captures its controlling tty once at startup (`tty`); exits with a clear message
  if it has none (e.g. launched detached).
- Loop, roughly every 1s (configurable `CORALLINE_FLOAT_INTERVAL`):
  - If `float.txt` exists and is fresh (mtime within `CORALLINE_FLOAT_STALE`,
    default ~5s): read it, base64-encode, write
    `\033]1337;SetUserVar=coralline=<b64>\007` to the captured tty.
  - If stale or missing: write an empty value to clear the bar (no stale data).
- "Dumb" by design: **no formatting logic** — it only transports `float.txt`. All
  rendering stays in `statusline.sh`, so there is a single source of visual truth.
- Pure bash + `base64`; no Python, no daemon framework. Matches coralline's ethos.

### 3. Shell function `cf` — launch ritual

Shipped snippet for the user's shell rc:

```bash
cf() { coralline-float & local p=$!; claude "$@"; kill "$p" 2>/dev/null; }
```

Starts the companion (inheriting the interactive shell's tty), runs `claude`, and
reaps the companion on exit. Explicit and controllable; no shell-rc auto-magic.

### 4. iTerm2 status bar setup (one-time, documented)

- Settings → Profiles → Session → enable Status bar → Configure → add an
  **Interpolated String** component with value `\(user.coralline)`.
- Settings → Appearance → General → Status bar location → **Top**.
- Documented in README + printed by the installer when float is enabled.

### Installer / configure integration

- `configure.sh`: add a toggle to enable `VL_FLOAT`, choose `VL_FLOAT_SEGMENTS`,
  and print the iTerm2 status-bar setup steps + the `cf` snippet.
- `install.sh`: copy `coralline-float` into `~/.claude/coralline/` alongside the
  renderer, and ensure it is on PATH (or document invoking it by full path).

## Data contracts

- **`~/.claude/coralline/float.txt`** — a single line of plain UTF-8 text, no ANSI.
  Overwritten atomically each render. Absence/staleness ⇒ clear the bar.
- **`~/.claude/coralline/state.json`** *(optional here, foundation for Spec B)* —
  the raw parsed fields (`ctx_pct`, `fh_pct`, `fh_rst`, `wd_pct`, `wd_rst`, `cost`,
  …) as JSON.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `VL_FLOAT` | `0` | `1` = emit `float.txt` each render |
| `VL_FLOAT_SEGMENTS` | `ctx limit5h limit7d cost` | segments rendered into the float line |
| `CORALLINE_FLOAT_INTERVAL` | `1` | companion poll seconds |
| `CORALLINE_FLOAT_STALE` | `5` | seconds after which `float.txt` is treated as stale and the bar is cleared |

## Edge cases & error handling

- **Companion has no tty** (launched detached): detect at startup, print a hint,
  exit non-zero.
- **CC not running / session ended**: `float.txt` goes stale → companion clears the
  bar so nothing lingers.
- **Multiple concurrent CC sessions**: `float.txt` is a single global file →
  last-writer-wins; the float reflects whichever session rendered most recently.
  Documented limitation; not solved in Spec A.
- **`VL_ASCII=1`**: the plain-text float path already emits no glyph backgrounds;
  ensure bars/markers still render acceptably without Nerd Font.
- **`base64` flavor differences** (BSD vs GNU): use a form that works on both
  (avoid GNU-only flags); verify on macOS.
- **Atomic write**: temp file must be in the same directory as `float.txt` so `mv`
  is a rename, not a cross-device copy.

## Validation spike (implementation step 1, before building anything)

> **Result — PASSED (2026-06-18).** From a second tab, writing a `SetUserVar` OSC
> to the tty of a tab actively running Claude Code updated the iTerm2 top status
> bar (showed the `spike-ok` payload) with CC's frame staying clean. The
> load-bearing assumption holds; no fallback to the iTerm2 Python API needed.

Confirm the load-bearing assumption: an **external** process writing a `SetUserVar` OSC to
the tty of a session **currently running Claude Code** updates the top status bar
**without corrupting CC's display**.

Minimal test: in a tab running CC, from a second process that holds that session's
tty path, write the OSC; observe the bar updates and CC's frame stays clean. If it
fails, fall back to the iTerm2 Python API delivery (previously evaluated "option
B") before proceeding.

## Testing strategy

- **Render path**: unit-style test that `statusline.sh` with `VL_FLOAT=1` and a
  sample input produces a plain-text `float.txt` containing the expected segments
  and **no ANSI escape bytes**.
- **Atomicity**: concurrent read while writing never yields a partial line.
- **Companion**: with a hand-written `float.txt`, the companion emits the correct
  base64 OSC to a pty and clears it when the file goes stale. Use the existing
  `test/` harness style.
- **Manual iTerm2 acceptance**: the spike test, plus a full `cf` + `claude` run
  showing live `ctx/5h/7d/cost` in the top-right.

## Limitations (recorded, not solved here)

- iTerm2-only.
- Single global `float.txt` ⇒ last-writer-wins across concurrent sessions.
- Requires one-time iTerm2 status-bar configuration and using `cf` to launch.

## Future (Spec B and beyond)

- **Threshold engine**: conditional segments (`show when over X%`) + rate-limit
  threshold notifications, both reading the same `state.json`.
- **Idle/done notifications**: Stop/Notification hook companion.
- **Other carriers**: WezTerm/Kitty status adapters, SwiftBar/xbar menu-bar
  adapter — all reusing `state.json`/`float.txt`.
