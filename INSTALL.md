# coralline — AI Installation Playbook

> **You are an AI coding assistant** and a user asked you to install coralline.
> Humans and AI use the same entrypoint: the one-line installer. Run it for the
> user, handle missing prerequisites, choose a setup path, and remind them they can
> rerun the visual wizard later if they want to rice the statusline themselves.

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

Run:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

If you are already inside a local clone, run:

```bash
bash install.sh
```

The installer delegates to `configure.sh --install`, so it automatically enters the setup
flow after downloading or locating the runtime files. It will:

1. copy the renderer, wizard, sample input, and bundled themes;
2. merge the Claude Code `statusLine` setting with `jq`;
3. offer setup choices for either the user or the AI assistant:
   - **Default**: install the recommended look immediately;
   - **Import `.p10k.zsh`**: carry over matching Powerlevel10k style and colors when available;
   - **Visual wizard**: choose theme, segments, layout, glyph mode, and clock format with previews;
4. render a sample statusline to verify the final config.

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
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

## AI Guidance

When installing for a user:

1. Run the fast-path installer first.
2. If it fails because `jq` is missing, explain the package-manager command and rerun after
   the user installs it.
3. If `~/.p10k.zsh` exists, prefer the import path unless the user asks for a fresh design.
4. If the user wants detailed visual control, choose the visual wizard path and let them pick.
5. If the user wants you to handle it, choose the default path or the p10k import path yourself.
6. After success, tell the user to restart Claude Code or open a new session if the statusline
   does not appear immediately, and mention they can rerun
   `bash ~/.claude/coralline/configure.sh` to customize it later.

Do not manually rewrite `~/.claude/settings.json` unless the installer cannot run. The wizard
already performs a merge and creates a backup when a settings file exists.

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
