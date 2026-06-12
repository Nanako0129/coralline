# coralline

> A [Powerlevel10k](https://github.com/romkatv/powerlevel10k)-inspired statusline for Claude
> Code that **installs itself through your AI** — paste one prompt, answer a few questions
> about colors and layout, done.

[繁體中文說明](./README.zh-TW.md)

> **Athena fork** of [Nanako0129/coralline](https://github.com/Nanako0129/coralline) — adds four
> segments tuned for the Athena setup: `ip` (pinned first), `worktree` (beside git), `agent`
> (beside model), and `warn200k` (pinned last). The default `VL_SEGMENTS` ships with all four
> enabled; everything else tracks upstream.

![All six coralline themes rendered side by side](./assets/hero.png)

## Install (the fun way)

Paste this into Claude Code:

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude will ask you to pick a theme (with previews), choose which segments you want, decide
between a one-line or two-line layout, then wire everything up and verify it. No manual
config editing required.

## What you get

```text
╭ ~/side-project/coralline  ⎇ main+!  ◆ Fable 5  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k  5h ▰▰▱▱▱ 41% ↺2h44m  $1.23  ⊙ 02:45 pm ╮
```

| Segment | Shows |
|---|---|
| `ip` | local machine IP, cached for `VL_IP_TTL`s — _Athena fork_ |
| `dir` | current directory, long paths collapsed to `~/a/…/z` |
| `git` | branch, staged `+` / modified `!` / untracked `?`, ahead `⇡` behind `⇣` |
| `worktree` | git worktree name — _Athena fork_ |
| `model` | active Claude model |
| `agent` | active subagent name — _Athena fork_ |
| `ctx` | context-window gauge, input/output/cache token counts |
| `limit5h` / `limit7d` | rate-limit gauges with reset countdown |
| `cost` | session cost in USD |
| `clock` | time, 12h or 24h |
| `lines` | lines added/removed this session |
| `style` | active output style |
| `duration` | session wall-clock duration |
| `stash` | git stash count |
| `warn200k` | 200k-token overflow alert; reuses the theme's hot color — _Athena fork_ |

Gauges change color as they fill: green → yellow at 50% → red at 75% (thresholds configurable).

## Why it's fast

The statusline runs every second (`refreshInterval: 1`), so the script is built to be cheap:
one `jq` invocation extracts every field at once, and one `git status --porcelain=v2 --branch`
call provides branch, dirty state, and ahead/behind together. No `bc`, no per-field subprocess
spam. Works on stock macOS bash 3.2 and any Linux bash.

## Manual install

```bash
git clone https://github.com/Nanako0129/coralline ~/.claude/coralline-src
mkdir -p ~/.claude/coralline/themes
cp ~/.claude/coralline-src/statusline.sh ~/.claude/coralline/
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

> **Note:** requires `jq` and a [Nerd Font](https://www.nerdfonts.com/) terminal.
> No Nerd Font? Set `VL_ASCII=1` in your config for a glyph-free rendering.

## Configuration

Everything lives in `~/.claude/coralline.conf` (plain bash, sourced by the script):

| Variable | Default | Meaning |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`: powerline pills · `lean`: flat colored text, p10k-lean style |
| `VL_LAYOUT` | `fixed` | `fixed`: one line per `VL_SEGMENTS*` var · `auto`: responsive |
| `VL_MAX_LINES` | `2` | `auto` only — wrap into at most this many lines (`1` = never wrap) |
| `VL_SEGMENTS` | `ip dir git worktree model agent ctx limit5h limit7d cost clock warn200k` | segments on line 1, in order (the full list in `auto` mode) |
| `VL_IP_TTL` | `30` | seconds the resolved IP is cached (Athena fork `ip` segment) |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | _(empty)_ | `fixed` only — optional second/third line |
| `VL_CLOCK` | `12h` | `12h` / `24h` / `off` |
| `VL_CLOCK_SECONDS` | `1` | show seconds in the clock |
| `VL_BAR_WIDTH` | `5` | gauge width in cells |
| `VL_PATH_DEPTH` | `4` | collapse paths deeper than this |
| `VL_COST_DECIMALS` | `2` | decimal places for the cost segment |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | gauge color thresholds |
| `VL_ASCII` | `0` | `1` disables Nerd Font glyphs |
| `VL_BG_*` / `VL_FG_*` | theme | colors — `256`-color index or `"R,G,B"` |

### Responsive layout

With `VL_LAYOUT="auto"` the bar stays on a single line while it fits, and greedily wraps into
up to `VL_MAX_LINES` rows when the window gets narrow. Width is read from `$COLUMNS`, falling
back to `stty size` on the controlling terminal; if neither is available the bar stays on one
line. Once the line cap is reached, remaining segments overflow on the last line.

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

> **Tip:** already a p10k user? Tell the AI installer to import your `~/.p10k.zsh` — it will
> carry over your style, colors, and time format. See the
> [Powerlevel10k import step in INSTALL.md](./INSTALL.md#step-25--powerlevel10k-import-optional).

## Themes

| | |
|---|---|
| **`claude-coral`** — steel blue · mauve · Claude coral (default)<br>![claude-coral theme preview](./assets/theme-claude-coral.png) | **`catppuccin-mocha`** — soft pastels on dark<br>![catppuccin-mocha theme preview](./assets/theme-catppuccin-mocha.png) |
| **`nord`** — arctic frost<br>![nord theme preview](./assets/theme-nord.png) | **`gruvbox-dark`** — warm retro<br>![gruvbox-dark theme preview](./assets/theme-gruvbox-dark.png) |
| **`tokyo-night`** — neon on deep navy<br>![tokyo-night theme preview](./assets/theme-tokyo-night.png) | **`mono`** — grayscale minimalism<br>![mono theme preview](./assets/theme-mono.png) |

A theme is just a `.conf` file assigning `VL_BG_*` / `VL_FG_*` — copy one, change the colors,
and source yours from `coralline.conf` instead. PRs with new themes are welcome.

> **Tip:** the preview images are generated from the real script by
> [`tools/render-screenshots.py`](./tools/render-screenshots.py) — after adding a theme, add it
> to the `THEMES` list there and re-run it to get a matching preview.

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
