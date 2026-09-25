# coralline — AI Installation Playbook

> **You are an AI coding assistant** and a user asked you to install coralline.
> This playbook routes the installation by environment. Use `install.sh` on macOS,
> Linux, or Windows with Bash. On PowerShell-only Windows (no Git Bash or WSL), use
> the native `install.ps1` path under
> [Windows without Git Bash](README.md#windows-without-git-bash). The native path
> needs no Bash, Git, `jq`, WSL, or archive extractor.

> **Before running anything:** tell the user what will be installed and where (the
> Overview table below), and offer the choice between a pinned release (`--ref`, latest
> tag or audited commit SHA) and mutable `main`. If you or the user want to audit
> first, read the selected `install.sh` or `install.ps1` in this repo.
> Skepticism toward a remote document that instructs an AI is correct behavior. The
> answer is reading what it references, not skipping the review. See the README's
> "Trust and security" section for the full accounting of what gets written.

## Environment Routing

Check the actual shell and tools before choosing a path:

- If the user is on Grok Build, follow [Grok Build](#grok-build). Use
  `--register-grok`. Do not merge Claude `settings.json` unless they also use
  Claude Code. Skip the subagent interview.
- If Bash is available, follow the Bash fast path and setup interview below.
- If this is native Windows PowerShell 5.1 without Bash, follow the
  [native one-line installer](README.md#windows-without-git-bash). Do not run
  `install.sh`, do not install `jq`, and do not expect a wizard.

For the native path, explain that `install.ps1` writes only `statusline.ps1` and
the ten shipped themes under `$HOME\.claude\coralline` (plus `statusline.sh` when
it selects the Bash runtime, see below), then losslessly merges
the exact-case top-level `statusLine` value in `$HOME\.claude\settings.json`,
with `refreshInterval: 2` for the native renderer. Claude Code aborts an in-flight statusline render
the moment the next refresh tick fires, and the native renderer takes close
to a second, so `refreshInterval: 1` would abort nearly every render before
it finishes; `2` gives the render room to complete. Rerunning `install.ps1`
replaces the whole `statusLine` value, so an existing `refreshInterval`
becomes `2` for the native renderer and `1` for the Bash renderer.
`install.ps1 -Runtime auto|native|bash` (the bootstrap's `$runtime`) picks the
renderer. The default `auto` selects the Bash renderer (`statusline.sh` through
Git Bash, `refreshInterval: 1`) when Git for Windows is installed for all users
in its standard location (`HKLM\SOFTWARE\GitForWindows` `InstallPath`, else
`%ProgramFiles%\Git`) and that `bash.exe` finds `jq`, and otherwise falls back
to native; it prints the runtime it selected and, after a fallback, why.
`-Runtime native` never probes for Git Bash; `-Runtime bash` fails before
changing anything when Git Bash or `jq` is missing. Per-user and junctioned
(Scoop) Git installs are not detected. Tell the user before running that the
Bash renderer sources `coralline.conf` as shell code (it executes it) while the
native renderer only parses it, so a native install rerun under `auto` on a
machine with Git Bash and `jq` switches to the Bash renderer (the installer
prints this note whenever it selects Bash, under `auto` or `-Runtime bash`); pass
`-Runtime native` (or set `$runtime="native"` in the bootstrap) if they want to
stay native. Switching back to native never deletes `statusline.sh`, and a
`subagentStatusLine` that holds the other runtime's coralline command for this install,
or a Bash command for this install naming a different `bash.exe`, moves
to the selected runtime even under `preserve`.
It never creates or edits `$HOME\.claude\coralline.conf`. Ask whether the user
wants native themed subagent rows: pass `-SubagentRows on` only after yes,
`-SubagentRows off` only for an explicit disable request, and otherwise keep the
default `preserve` so an existing `subagentStatusLine` remains byte-for-byte
untouched. The installer retains timestamped sibling backups when existing
managed content changes. An identical rerun is a true no-op. Renderer state and
custom files remain in place because updates replace only the managed allowlist.
Installer invocations are serialized. Single-file runtime rollback rejects
concurrent edits and retains displaced installer bytes; multi-file rollback fails
closed with current files and backups left for manual recovery. The exact allowlist
and merged settings bytes are rechecked before success. The atomic settings backup
is the actual displaced file, so writes through an already-open editor handle remain
in that backup; conflicts observed during commit fail without overwriting external bytes.

Ask whether the user wants mutable `main`, a named release tag, or an audited
40-character commit SHA. Do not describe a tag as immutable. Run the matching
README one-line after approval. If already inside an audited local checkout, use
the zero-network local mode instead:

```powershell
& "$PSHOME\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\install.ps1 -SourceDirectory (Get-Location).Path -InstallRoot "$HOME\.claude\coralline" -SettingsPath "$HOME\.claude\settings.json" -SubagentRows preserve
```

Pass only drive-absolute local-mode paths (`C:\...` or `C:/...`), never
drive-relative forms such as `C:folder`.

After a native install, do not start the Bash setup interview. Preserve an
existing config byte-for-byte. If no config exists, the renderer's defaults work
without one; offer manual configuration only as a separate, user-approved step.
Verify the installed renderer:

```powershell
$probe = '{"workspace":{"current_dir":"C:\\"},"model":{"display_name":"Claude"}}'
$probe | & "$PSHOME\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$HOME\.claude\coralline\statusline.ps1"
if ($LASTEXITCODE -ne 0) { throw "coralline native verification failed: $LASTEXITCODE" }
```

Success means exit code `0`, a non-empty rendered statusline on stdout, and no
error text on stderr. Tell the user to restart Claude Code or open a new session
if the statusline does not appear immediately.

## Overview

coralline is a powerline-style statusline for Claude Code. The Bash installation path
places the renderer under `~/.claude/coralline`, writes
`~/.claude/coralline.conf`, and merges the `statusLine` command into
`~/.claude/settings.json`.

| Artifact | Destination | Purpose |
|---|---|---|
| `statusline.sh` | `~/.claude/coralline/statusline.sh` | Statusline renderer |
| `configure.sh` | `~/.claude/coralline/configure.sh` | Setup wizard and reconfiguration entrypoint |
| `themes/*.conf` | `~/.claude/coralline/themes/` | Bundled palettes |
| `sample-input.json` | `~/.claude/coralline/sample-input.json` | Local preview and verification sample |
| generated config | `~/.claude/coralline.conf` | User layout, segments, and theme choices |
| `statusLine` entry | `~/.claude/settings.json` | Registers coralline in Claude Code |
| `subagentStatusLine` entry | `~/.claude/settings.json` | Opt-in only — themed agent-panel rows, written when the user says yes (wizard question, `configure.sh --subagent-rows=on`, or native `install.ps1 -SubagentRows on`) |

## Fast Path

Bootstrap the runtime and Claude settings:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

This path is non-interactive, so it installs from `main` and skips the version prompt. To
install a tagged release instead, ask the user which they want and pass `--ref`, e.g.
`--ref v0.18.0` (latest release) or leave it as `main` (latest development).

If the user is testing a fork, keep the downloaded installer and runtime files on the same
repo:

```bash
curl -fsSL https://raw.githubusercontent.com/YOU/coralline/main/install.sh | bash -s -- --repo YOU/coralline --install-only
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

## Grok Build

You are Grok. Claude Code remains the default host and keeps `statusline.sh`.
This path registers `statusline-grok.sh`, which translates Grok's payload and
then calls the Claude renderer. Do not run `--install` or `--install-only`
unless the user also uses Claude Code — those flags merge
`~/.claude/settings.json`. Skip the subagent interview.

From a local checkout:

```bash
bash configure.sh --register-grok
```

If the runtime files are already installed, call that copy instead of depending
on the current directory:

```bash
bash ~/.claude/coralline/configure.sh --register-grok
```

`--register-grok` copies `statusline.sh`, `statusline-grok.sh` and `themes/`
into `~/.grok/coralline/`, writes `~/.grok/coralline.conf` when it is missing,
appends `[ui.status_line]` to `$GROK_HOME/config.toml` (or
`~/.grok/config.toml`), and exits. The adapter resolves its conf and its
limit/burn store from `GROK_HOME` alone, so Grok shares neither with Claude
Code. It never rewrites Claude settings or `~/.claude/coralline.conf`, and it
does not open the wizard.

It refuses to append when `config.toml` mentions `status_line` anywhere, in any
spelling. A second definition of that key makes the whole file invalid TOML, and
nothing in this installer can parse TOML to be certain which spelling is in use,
so it prints the `command` line for the user to set by hand instead.

It touches nothing under `~/.claude`. Everything Grok needs is copied out of the
checkout (or the installed copy you invoked) into `~/.grok/coralline/`, so a
Grok-only machine never gets a Claude Code runtime it has no use for.

Verify with a Grok-shaped stdin probe against the copy Grok actually runs.
`CORALLINE_NO_SAMPLE=1` keeps the probe's values out of the cross-session store:

```bash
printf '%s' '{"cwd":"/tmp","workspace":{"current_dir":"/tmp"},"model":{"display_name":"Grok 4.6"},"context_window":{"used_percentage":25,"context_tokens":12345},"cost":{"total_cost_usd":1.25},"trigger":"state"}' | CORALLINE_NO_SAMPLE=1 bash ~/.grok/coralline/statusline-grok.sh
```

Success means exit code `0` and a non-empty statusline on stdout. Tell the user
to restart Grok if the statusline does not appear immediately.

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

1. Detect whether this is Bash-capable or PowerShell-only Windows. For
   PowerShell-only Windows, complete the native route above and stop before the
   Bash-only setup modes.
2. Ask the user to choose setup mode before installing. Use the runtime's native choice UI
   when available; otherwise show the text menu below and wait for a reply.
3. Run the fast-path installer with `--install-only`.
4. If it fails because `jq` is missing, explain the package-manager command and rerun after
   the user installs it.
5. Follow the selected setup mode.
6. Write `~/.claude/coralline.conf` unless the user chose the visual wizard.
7. Verify with the bundled sample input.
8. After success, tell the user to restart Claude Code or open a new session if the statusline
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

1. **Theme**: inspect `~/.claude/coralline/themes/**/*.conf` and offer the installed theme
   labels. Default to `claude-coral` when unsure. Nested themes use labels like
   `best-themes/github-dark`.
2. **Style**: `pill` default, `lean`, or `classic` (p10k's uniform dark-bar look).
3. **Segments**: default is `dir git model ctx limit5h limit7d cost clock`.
   Optional extras: `project`, `node`, `python`, `effort`, `burn`, `lines`, `style`,
   `duration`, `stash`. `node` shows the active Node version (`.nvmrc` / `.node-version`,
   else `node` on `PATH`) and `python` the active env (`$VIRTUAL_ENV` / conda /
   `.python-version`, else `python3`); each stays hidden until something is detected.
   Write the chosen segments to `VL_SEGMENTS` in this canonical order (keep only the
   ones the user wants): `dir project git node python model effort ctx cache limit5h
   limit7d burn lines cost style duration stash clock`. So opting in `effort` lands it
   right after `model`.
   `cache` (prompt-cache hit ratio plus the countdown to the cache expiring) reads
   `prompt_cache` from the payload, which Claude Code only sends on v2.1.263 and newer;
   on an older build it stays hidden with no other effect.
   `burn` (projected time until a rate limit binds) writes a small sample file to
   `~/.claude/coralline/burn-5h.tsv` while it is in the list, and nothing when it is not.
4. **Layout**: responsive default (`VL_LAYOUT="auto"`, `VL_MAX_LINES=3`), single line,
   fixed two lines, or fixed three lines.
5. **Details**: clock `12h` default, `24h`, or `off`; Nerd Font yes/no; if they use git
   worktrees, suggest enabling `project`. If the user runs many concurrent Claude sessions
   and is bothered by `limit5h` / `limit7d` showing different percentages per session,
   mention `VL_LIMIT_SYNC=1`: a session holding a valid but older window follows a stored
   reading for a newer one (in a `limit-5h.d` / `limit-7d.d` store). Off by default. Your
   own reading always wins your own window; the store is the source a session falls back
   to when it has no reading of its own, which is every session before its first API
   response of the run, so the gauge shows the account's open window instead of nothing.
6. **Subagent panel rows** (optional, needs Claude Code v2.1.205+ for the per-task
   model/context fields): offer to theme only the subagent rows below the prompt — the
   native main-session row remains visible. On Bash-capable installs, if the user says yes, run
   `bash ~/.claude/coralline/configure.sh --subagent-rows=on` after the bootstrap; it
   registers `subagentStatusLine` in `~/.claude/settings.json` (with the same
   backup-then-merge as the installer) and prints a preview. To disable it, run
   `bash ~/.claude/coralline/configure.sh --subagent-rows=off`; this removes only that
   settings entry. On PowerShell-only Windows, rerun the native installer with
   `-SubagentRows on` or `-SubagentRows off`; `preserve` remains the ordinary default.
   Explain that model comes from Claude Code's per-task payload, missing
   fields degrade their own segments (`tokenCount` still shows without a context window),
   and redraws are panel-event-driven rather than a one-second poll. Claude Code v2.1.211
   omits the native `agentType` role from this payload, so coralline recovers it from the
   local task metadata sidecar with Bash builtins and displays it beside the task label;
   explicit `name` values are retained too, and a missing sidecar still shows the payload
   label. Live payloads expose no per-task effort, so never
   copy the main-session effort or infer one from the role. Skip silently if the user's
   Claude Code predates the agent panel.

If `~/.p10k.zsh` exists, ask whether the user wants to import its style, clock, and main
colors. Do not import it by default. If the user agrees, read the file and map these values
when present:

| p10k setting | coralline config |
|---|---|
| Wizard options include `lean` | `VL_STYLE="lean"` |
| Wizard options include `classic` | `VL_STYLE="classic"` (and carry the two rows below) |
| Wizard options include `rainbow` or `powerline` | `VL_STYLE="pill"` |
| `POWERLEVEL9K_BACKGROUND` (classic only) | `VL_LEAN_BG` — the uniform bar color |
| `POWERLEVEL9K_LEFT_SEGMENT_SEPARATOR` (classic only) | `VL_LEAN_CAP_R` — the trailing cap glyph |
| Wizard options or time format indicate 24h | `VL_CLOCK="24h"` |
| `POWERLEVEL9K_DIR_BACKGROUND` or `_FOREGROUND` | `VL_BG_DIR` |
| `POWERLEVEL9K_VCS_CLEAN_*` | `VL_BG_GIT_OK` |
| `POWERLEVEL9K_VCS_MODIFIED_*` / `_UNTRACKED_*` | `VL_BG_GIT_DIRTY` |
| `POWERLEVEL9K_TIME_*` | `VL_BG_CLOCK` |
| `node_version` / `nvm` in prompt elements | add `node` to `VL_SEGMENTS` |
| `virtualenv` / `pyenv` / `anaconda` in prompt elements | add `python` to `VL_SEGMENTS` |

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

Adjust the values based on the interview. Create the config only when it is absent and after
showing the complete proposed file. If it already exists, leave it byte-for-byte unchanged by
default. For any user-approved customization, show a bounded additive diff first, preserve
unrelated assignments and comments, and make a timestamped backup before an atomic replacement.

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
CORALLINE_NO_SAMPLE=1 bash ~/.claude/coralline/statusline.sh < ~/.claude/coralline/sample-input.json
```

`CORALLINE_NO_SAMPLE=1` makes the render read-only, so the sample's preview values are never written to the cross-session limit/burn stores. Without it, `sample-input.json`'s far-future sentinel reset would poison `limit5h`/`limit7d` when `VL_LIMIT_SYNC=1`.

Success means exit code `0`, a rendered statusline on stdout, and no error text on stderr.
