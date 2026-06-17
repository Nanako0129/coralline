# coralline — AI Installation Playbook

> **You are an AI coding assistant** and a user asked you to install coralline.
> Humans and AI use the same installer entrypoint, but not the same setup UX.
> For AI installs, bootstrap the runtime with `install.sh --install-only`, interview
> the user, write `~/.claude/coralline.conf`, and verify. Do not operate the human TUI
> unless the user explicitly asks to customize visually.

## Overview

coralline is a powerline-style statusline for Claude Code. Installation places the
renderer under `~/.claude/coralline`, writes `~/.claude/coralline.conf`, and merges
the `statusLine` command into `~/.claude/settings.json`.

| Artifact | Destination | Purpose |
|---|---|---|
| `statusline.sh` | `~/.claude/coralline/statusline.sh` | Statusline renderer |
| `configure.sh` | `~/.claude/coralline/configure.sh` | Setup wizard and reconfiguration entrypoint |
| `themes/*.conf` | `~/.claude/coralline/themes/` | Bundled palettes |
| `sample-input.json` | `~/.claude/coralline/sample-input.json` | Local preview and verification sample |
| generated config | `~/.claude/coralline.conf` | User layout, segments, and theme choices |
| `statusLine` entry | `~/.claude/settings.json` | Registers coralline in Claude Code |

## Fast Path

Bootstrap the runtime and Claude settings:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

If the user is testing a fork, keep the downloaded installer and runtime files on the same
repo:

```bash
curl -fsSL https://raw.githubusercontent.com/miyago9267/coralline/main/install.sh | bash -s -- --repo miyago9267/coralline --install-only
```

If you are already inside a local clone, run:

```bash
bash install.sh
```

The installer delegates to `configure.sh --install-only` for AI installs. It will:

1. copy the renderer, wizard, sample input, and bundled themes;
2. merge the Claude Code `statusLine` setting with `jq`;
3. exit without opening the human setup menu or writing theme config.

After bootstrap, do the AI interview below and write `~/.claude/coralline.conf`.

## Prerequisites

Check:

```bash
command -v jq || echo "MISSING: jq"
command -v curl || echo "MISSING: curl"
```

`jq` is required because coralline uses it at runtime and the installer uses it to merge
`settings.json`. If it is missing, help the user install it first:

```bash
brew install jq
```

Use the platform package manager on Linux (`apt`, `dnf`, `pacman`, etc.). `curl` is only
needed for the remote one-line installer; local clone installs can run without it.

`git` is optional. Git segments disappear automatically when unavailable.

## Reconfigure

Rice-focused users can rerun the visual wizard at any time:

```bash
bash ~/.claude/coralline/configure.sh
```

To reinstall files and re-merge Claude settings:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

## AI Guidance

When installing for a user:

1. Ask the user to choose setup mode before installing. Use the runtime's native choice UI
   when available; otherwise show the text menu below and wait for a reply.
2. Run the fast-path installer with `--install-only`.
3. If it fails because `jq` is missing, explain the package-manager command and rerun after
   the user installs it.
4. Follow the selected setup mode.
5. Write `~/.claude/coralline.conf` unless the user chose the visual wizard.
6. Verify with the bundled sample input.
7. After success, tell the user to restart Claude Code or open a new session if the statusline
   does not appear immediately, and mention they can rerun
   `bash ~/.claude/coralline/configure.sh` to customize it later.

Do not manually rewrite `~/.claude/settings.json` unless the installer cannot run. The
installer already performs a merge and creates a backup when a settings file exists.

## Setup Mode

Ask this first:

```text
How do you want to configure coralline?
1. Let Claude configure it for me
2. Import my local ~/.p10k.zsh
3. Use the coralline default
4. Open the visual wizard so I can customize manually
```

Mode behavior:

| Mode | What Claude should do |
|---|---|
| Let Claude configure it | Bootstrap with `--install-only`, run the AI interview, write config, verify |
| Import `~/.p10k.zsh` | Ask for confirmation if the file exists, bootstrap with `--install-only`, translate p10k, write config, verify |
| Use default | Bootstrap with `--install-only`, write the default config, verify |
| Visual wizard | Run `curl -fsSL .../install.sh | bash` without `--install-only` and let the user operate the TUI |

If the user says "you decide", choose **Let Claude configure it** and keep the interview short.
Never import `~/.p10k.zsh` unless the user explicitly chooses or confirms that mode.

## AI Interview

Ask concise questions. If the user says "you decide", choose the defaults.

1. **Theme**: `claude-coral` default, `catppuccin-mocha`, `nord`, `gruvbox-dark`,
   `tokyo-night`, `dracula`, or `mono`.
2. **Style**: `pill` default, or `lean`.
3. **Segments**: default is `dir git model ctx limit5h limit7d cost clock`.
   Optional: `project`, `lines`, `style`, `duration`, `effort`, `stash`.
4. **Layout**: responsive default (`VL_LAYOUT="auto"`, `VL_MAX_LINES=3`), single line,
   fixed two lines, or fixed three lines.
5. **Details**: clock `12h` default, `24h`, or `off`; Nerd Font yes/no; if they use git
   worktrees, suggest enabling `project`.

If `~/.p10k.zsh` exists, ask whether the user wants to import its style, clock, and main
colors. Do not import it by default. If the user agrees, read the file and map these values
when present:

| p10k setting | coralline config |
|---|---|
| Wizard options include `lean` | `VL_STYLE="lean"` |
| Wizard options include `classic`, `rainbow`, or `powerline` | `VL_STYLE="pill"` |
| Wizard options or time format indicate 24h | `VL_CLOCK="24h"` |
| `POWERLEVEL9K_DIR_BACKGROUND` or `_FOREGROUND` | `VL_BG_DIR` |
| `POWERLEVEL9K_VCS_CLEAN_*` | `VL_BG_GIT_OK` |
| `POWERLEVEL9K_VCS_MODIFIED_*` / `_UNTRACKED_*` | `VL_BG_GIT_DIRTY` |
| `POWERLEVEL9K_TIME_*` | `VL_BG_CLOCK` |

## Write Config

Create `~/.claude/coralline.conf`:

```bash
# coralline config
. "$HOME/.claude/coralline/themes/claude-coral.conf"

VL_STYLE="pill"
VL_LAYOUT="auto"
VL_MAX_LINES=3
VL_WRAP_MARGIN=4
VL_SEGMENTS="dir git model ctx limit5h limit7d cost clock"
VL_SEGMENTS2=""
VL_SEGMENTS3=""
VL_CLOCK="12h"
VL_CLOCK_SECONDS=1
VL_BAR_WIDTH=5
VL_COST_DECIMALS=2
VL_PATH_DEPTH=4
VL_NAME_MAX=0
VL_ASCII=0
VL_LEAN_SEP=""
```

Adjust the values based on the interview. If the config already exists, preserve the user's
manual edits when possible, or show the change before overwriting.

## Manual Fallback

Use this only if the one-line installer cannot run in the current environment.

```bash
git clone https://github.com/Nanako0129/coralline ~/.claude/coralline-src
cd ~/.claude/coralline-src
bash configure.sh --install
```

If the repository is already available locally, copy from that clone instead of downloading:

```bash
mkdir -p ~/.claude/coralline/themes
cp statusline.sh configure.sh install.sh ~/.claude/coralline/
cp test/sample-input.json ~/.claude/coralline/sample-input.json
cp themes/*.conf ~/.claude/coralline/themes/
chmod +x ~/.claude/coralline/statusline.sh ~/.claude/coralline/configure.sh
bash ~/.claude/coralline/configure.sh --install
```

## Verification

The installer verifies rendering automatically. For a manual check, run:

```bash
bash ~/.claude/coralline/statusline.sh < ~/.claude/coralline/sample-input.json
```

Success means exit code `0`, a rendered statusline on stdout, and no error text on stderr.
