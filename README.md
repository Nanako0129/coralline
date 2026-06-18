# coralline

> A [Powerlevel10k](https://github.com/romkatv/powerlevel10k)-inspired statusline for Claude
> Code with one installer entrypoint for humans and AI: run it directly, or ask Claude to run
> it and handle the setup for you.

[繁體中文說明](./README.zh-TW.md)

![All six coralline themes rendered side by side](./assets/hero.png)

## What you get

```text
╭ ~/side-project/coralline  ⬢ coralline  ⎇ main+!  ◆ Fable 5  ψ high  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k  5h ▰▰▱▱▱ 41% ↺2h44m  7d ▰▰▰▰▱ 79% ↺1d11h  +321 −87  $1.23  ✎ Explanatory  ⧖ 47m  ⚑ 1  ⊙ 02:45 pm ╮
```

| Segment | Shows |
|---|---|
| `dir` | current directory, long paths collapsed to `~/a/…/z` |
| `project` | repo name (`⬢`), stable across every worktree; hidden outside a git repo |
| `git` | branch, staged `+` / modified `!` / untracked `?`, ahead `⇡` behind `⇣` |
| `model` | active Claude model |
| `effort` | reasoning effort level (`ψ`) — `low` / `med` / `high` / `xhigh` / `max` |
| `ctx` | context-window gauge, input/output/cache token counts |
| `limit5h` / `limit7d` | rate-limit gauges with reset countdown |
| `lines` | lines added/removed this session |
| `cost` | session cost in USD |
| `style` | active output style |
| `duration` | session wall-clock duration |
| `stash` | git stash count |
| `clock` | time, 12h or 24h |

Gauges change color as they fill: green → yellow at 50% → red at 75% (thresholds configurable).

## Install

Three ways to install, all driven by the same `install.sh`. Each one copies the renderer **and
the setup wizard** into `~/.claude/coralline` and registers the status line in Claude Code, so
you can re-run the wizard later no matter which way you installed.

> **Requirements:** `jq` and a [Nerd Font](https://www.nerdfonts.com/) terminal. No Nerd Font?
> Set `VL_ASCII=1` in your config for a glyph-free rendering.

### Ask Claude (recommended)

Paste this into Claude Code:

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude will read the playbook, use the same installer to bootstrap the runtime, interview you
about the look, write the config, verify it, and remind you that you can rerun the visual
wizard if the first result doesn't match your taste.

### Install it yourself

Run the installer in your terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

### Manual

```bash
git clone https://github.com/Nanako0129/coralline ~/.claude/coralline-src
mkdir -p ~/.claude/coralline/themes
cp ~/.claude/coralline-src/statusline.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/configure.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/install.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/themes/claude-coral.conf ~/.claude/coralline/themes/
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/coralline/statusline.sh",
    "refreshInterval": 1
  }
}
```

> **Note:** the commands above copy only the `claude-coral` theme. The Ask-Claude and one-line
> installers bundle every theme; after a manual install, copy the rest of
> `~/.claude/coralline-src/themes/*.conf` into `~/.claude/coralline/themes/` to switch themes.

## Setup

Both paths use the same installer. Humans run it with no mode and get the visual setup. Claude
uses it with `--install-only`, then follows `INSTALL.md` to interview you and write config.

### Setup modes

| Mode | Use when |
|---|---|
| Default | You want the coralline default immediately |
| Powerlevel10k import | You already have `~/.p10k.zsh` and want to carry over its style, time format, and main colors |
| Visual wizard | You want to preview themes, style, segments, wrapping, clock, and font compatibility before writing config |

Running the installer yourself with no mode opens the interactive setup. Claude should not
operate that TUI unless you explicitly ask for visual customization.

### Reconfigure

Every install path copies the wizard into `~/.claude/coralline`, so you can rerun it anytime to
restyle:

```bash
bash ~/.claude/coralline/configure.sh
```

### Testing a fork

Point the installer at the same fork:

```bash
curl -fsSL https://raw.githubusercontent.com/YOU/coralline/main/install.sh | bash -s -- --repo YOU/coralline
```

## Configuration

Everything lives in `~/.claude/coralline.conf` (plain bash, sourced by the script):

| Variable | Default | Meaning |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`: powerline pills · `lean`: flat colored text, p10k-lean style |
| `VL_LAYOUT` | `fixed` | `fixed`: one line per `VL_SEGMENTS*` var · `auto`: responsive |
| `VL_MAX_LINES` | `3` | `auto` only — wrap into at most this many lines (`1` = never wrap) |
| `VL_WRAP_MARGIN` | `4` | `auto` only — columns kept free on the right so segments never touch the edge |
| `VL_SEGMENTS` | `dir git model ctx limit5h limit7d cost clock` | segments on line 1, in order (the full list in `auto` mode) |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | _(empty)_ | `fixed` only — optional second/third line |
| `VL_CLOCK` | `12h` | `12h` / `24h` / `off` |
| `VL_CLOCK_SECONDS` | `1` | show seconds in the clock |
| `VL_BAR_WIDTH` | `5` | gauge width in cells |
| `VL_PATH_DEPTH` | `4` | collapse paths deeper than this |
| `VL_NAME_MAX` | `0` | max chars for the `project` / `git` names before `…` truncation (`0` = off) |
| `VL_COST_DECIMALS` | `2` | decimal places for the cost segment |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | gauge color thresholds |
| `VL_ASCII` | `0` | `1` disables Nerd Font glyphs |
| `VL_BG_*` / `VL_FG_*` | theme | colors — `256`-color index or `"R,G,B"` |

### Responsive layout

With `VL_LAYOUT="auto"` the bar stays on a single line while it fits, and greedily wraps into
up to `VL_MAX_LINES` rows when the window gets narrow. Once the line cap is reached, remaining
segments overflow on the last line. `VL_WRAP_MARGIN` keeps a few columns free on the right so
wrapped lines never butt against the window edge — raise it if your terminal adds padding.

Width comes from `$COLUMNS`. Claude Code v2.1.153+ sets `COLUMNS` to the current terminal width
before running the status line, so wrapping responds to window resizing out of the box. Outside
Claude Code the script falls back to `stty size` on the controlling terminal; if neither is
available it stays on one line.

```text
wide window:    ~/dev/app  ⎇ main  ◆ Fable 5  ⬡ ▰▰▰▱▱ 62%  5h ▰▰▱▱▱ 41%  $1.23  ⊙ 14:45

narrow window:  ~/dev/app  ⎇ main  ◆ Fable 5
                ⬡ ▰▰▰▱▱ 62%  5h ▰▰▱▱▱ 41%  $1.23  ⊙ 14:45
```

Prefer a layout that never moves? Keep `VL_LAYOUT="fixed"` and pin rows with
`VL_SEGMENTS` / `VL_SEGMENTS2` / `VL_SEGMENTS3`.

### Lean style

Prefer Powerlevel10k's *lean* look — no backgrounds, just colored text? Set
`VL_STYLE="lean"` and each segment's `VL_BG_*` color becomes its text accent instead:

![Lean style compared with pill style](./assets/style-lean.png)

| Variable | Default | Meaning |
|---|---|---|
| `VL_STYLE` | `pill` | set to `lean` for the flat look |
| `VL_LEAN_SEP` | _(empty)_ | extra text between segments, e.g. `·` |
| `VL_LEAN_FG` | _(empty)_ | force a text color; empty = inherit each segment's accent |

> **Tip:** already a p10k user? Tell the AI installer or the visual wizard to import your
> `~/.p10k.zsh` — it will carry over your style, colors, and time format after you opt in.
> See the [AI interview notes in INSTALL.md](./INSTALL.md#ai-interview).

## iTerm2 floating display (optional)

Show a compact readout — `model ctx cost clock` by default — floating in
iTerm2's native **top status bar**, so a glanceable readout stays visible without
looking at Claude Code's bottom statusline.

The float line is **plain text** — iTerm2's `Interpolated String` component does
not interpret ANSI, so it carries no color. The default therefore favors
stable, glance-friendly segments and leaves the color-driven limit warnings
(`limit5h` / `limit7d`) in the bottom statusline, where threshold colors work.
You can still add them to `VL_FLOAT_SEGMENTS` if you want the numbers up top.

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
   VL_FLOAT_SEGMENTS="model ctx cost clock"
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
| `VL_FLOAT_SEGMENTS` | `model ctx cost clock` | segments rendered into the float line (plain text, no color) |
| `CORALLINE_FLOAT_INTERVAL` | `1` | companion poll seconds |
| `CORALLINE_FLOAT_STALE` | `5` | seconds before a stale `float.txt` clears the bar |

**Limitations:** iTerm2-only; a single global `float.txt` means concurrent
sessions are last-writer-wins; requires the one-time status-bar setup and using
`cf` to launch.

## Themes

| | |
|---|---|
| **`claude-coral`** — steel blue · mauve · Claude coral (default)<br>![claude-coral theme preview](./assets/theme-claude-coral.png) | **`catppuccin-mocha`** — soft pastels on dark<br>![catppuccin-mocha theme preview](./assets/theme-catppuccin-mocha.png) |
| **`nord`** — arctic frost<br>![nord theme preview](./assets/theme-nord.png) | **`gruvbox-dark`** — warm retro<br>![gruvbox-dark theme preview](./assets/theme-gruvbox-dark.png) |
| **`tokyo-night`** — neon on deep navy<br>![tokyo-night theme preview](./assets/theme-tokyo-night.png) | **`mono`** — grayscale minimalism<br>![mono theme preview](./assets/theme-mono.png) |
| **`dracula`** — cyan · pink · purple on charcoal<br>![dracula theme preview](./assets/theme-dracula.png) | **`lunar-pink`** — pink · cyan · yellow on near-black<br>![lunar-pink theme preview](./assets/theme-lunar-pink.png) |
| **`reverie`** — soft pastels · plum text on warm-dark<br>![reverie theme preview](./assets/theme-reverie.png) | |

A theme is just a `.conf` file assigning `VL_BG_*` / `VL_FG_*` — copy one, change the colors,
and source yours from `coralline.conf` instead. PRs with new themes are welcome.
The wizard discovers themes automatically from `themes/*.conf` and nested collections such as
`themes/best-themes/*.conf`, so adding a theme file does not require editing `configure.sh`.

> **Adding a theme?** Copy an existing `.conf`, set every `VL_BG_*` / `VL_FG_*`
> (including `VL_BG_EFFORT`), add its name to the `THEMES` list in
> [`tools/render-screenshots.py`](./tools/render-screenshots.py), re-run it to generate
> `assets/theme-<name>.png`, and add a row to the table above. Please **don't regenerate
> `hero.png`** — it's a fixed sampler of the original six themes, not a full catalog.

## Platform support

| Platform | Status |
|---|---|
| macOS | ✅ supported (works on the stock bash 3.2) |
| Linux | ✅ supported |
| Windows + Git Bash | ✅ supported — Claude Code runs the status line through Git Bash when it's installed |
| Windows without Git Bash | ❌ not yet — Claude Code falls back to PowerShell, which can't run the bash script ([roadmap](https://github.com/Nanako0129/coralline/issues)) |

> **Windows note:** install [Git for Windows](https://git-scm.com/download/win) (which bundles
> Git Bash) and `jq`, and coralline runs natively. A native PowerShell port for the no-Git-Bash
> case is on the roadmap. The render path is built to stay cheap under Git Bash's emulated
> `fork()` — one `jq`, one `git`, and no per-field subprocess spawning.

## Why it's fast

The statusline is just a local shell script: it makes no network or API calls and uses zero
tokens. Claude Code pipes the session JSON to it on stdin and renders whatever it prints.

It runs every second (`refreshInterval: 1`), so the script is built to be cheap on CPU: one
`jq` invocation extracts every field at once, and one `git status --porcelain=v2 --branch`
call provides branch, dirty state, and ahead/behind together. No `bc`, no per-field subprocess
spam. Works on stock macOS bash 3.2 and any Linux bash.

## Acknowledgements

The visual language of coralline — segmented pills, powerline transitions, the `⇡⇣` git
glyphs, gauges that shift color as they fill — is a loving tribute to
[Powerlevel10k](https://github.com/romkatv/powerlevel10k) by
[@romkatv](https://github.com/romkatv), which set the bar for what a fast, beautiful prompt
can be. Thanks also to the wider [powerline](https://github.com/powerline/powerline) lineage
that started it all, and to [Nerd Fonts](https://www.nerdfonts.com/) for the glyphs that make
the pill shapes possible.

As for the name: coralline algae build reefs one thin, colorful layer at a time —
and **coral·line** is exactly what this is: a line, in Claude's coral.

## License

[MIT](./LICENSE)
