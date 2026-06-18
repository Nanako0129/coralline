# iTerm2 float carrier (example)

This is an **example carrier** for coralline's float readout — not part of the
core install and not guaranteed to be supported. It pushes
`~/.claude/coralline/float.txt` into iTerm2's native **top status bar** so a
glanceable readout stays visible without looking at Claude Code's bottom
statusline.

coralline itself only writes the file (`VL_FLOAT=1`). This `coralline-float`
companion is the missing half: Claude Code sanitizes its own statusline output,
so the readout reaches iTerm2 by a side channel — the companion runs in your
interactive shell, tails `float.txt`, and pushes it via a `SetUserVar` escape.

## Setup

1. iTerm2 → Settings → Profiles → Session → enable **Status bar** → **Configure
   Status Bar** → add an **Interpolated String** component with value
   `\(user.coralline)`.
2. iTerm2 → Settings → Appearance → General → **Status bar location** → **Top**.
3. Enable the float in `~/.claude/coralline.conf`:

   ```bash
   VL_FLOAT=1
   ```

4. Copy this companion next to your coralline install and make it executable:

   ```bash
   cp coralline-float ~/.claude/coralline/coralline-float
   chmod +x ~/.claude/coralline/coralline-float
   ```

5. Add this to your shell rc (`~/.zshrc` or `~/.bashrc`) and restart your shell:

   ```bash
   cf() { "$HOME/.claude/coralline/coralline-float" & local p=$!; claude "$@"; kill "$p" 2>/dev/null; }
   ```

## Use

Launch Claude Code with `cf` instead of `claude`. The companion starts,
`claude` runs, and the companion is reaped on exit (clearing the bar).

## Tuning (env vars)

| Var | Default | Meaning |
|---|---|---|
| `CORALLINE_FLOAT_INTERVAL` | `1` | poll seconds |
| `CORALLINE_FLOAT_STALE` | `5` | seconds before a stale `float.txt` clears the bar |
| `CORALLINE_FLOAT_FILE` | `~/.claude/coralline/float.txt` | file to read |
| `CORALLINE_FLOAT_TTY` | *(auto)* | override the target tty (tests / advanced) |

## Limitation

A single global `float.txt` means concurrent sessions are last-writer-wins.
