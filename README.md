# coralline

> A [Powerlevel10k](https://github.com/romkatv/powerlevel10k)-inspired statusline for Claude Code, with native Bash and Windows PowerShell renderers.

[繁體中文說明](./README.zh-TW.md)

![The original six coralline themes rendered side by side](./assets/hero.png)

## What you get

This is the runtime default rendered from the bundled sample in a clean `main` worktree:

```text
 ~/side-project/coralline  ⎇ main  ◆ Fable 5  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k cr:98.7k cw:4.3k  5h ▰▰▱▱▱ 41% ↺2h44m  7d ▰▰▰▰▱ 79% ↺1d11h  $1.23  ⊙ 01:37:35 pm 
```

| Segment | Default | Shows |
|---|---|---|
| `dir` | yes | current directory, with long paths collapsed |
| `project` | no | repository name, stable across worktrees; hidden outside git |
| `git` | yes | branch, staged `+`, modified `!`, untracked `?`, ahead `⇡`, behind `⇣` |
| `node` | no | active Node version from a pin file, or `PATH` with `VL_RUNTIME_PROBE=1`; hidden when undetected |
| `python` | no | active virtualenv, conda, or pinned Python version, or `PATH` with `VL_RUNTIME_PROBE=1`; hidden when undetected |
| `model` | yes | active Claude model |
| `effort` | no | reasoning effort: `low`, `med`, `high`, `xhigh`, or `max` |
| `ctx` | yes | context gauge and input, output, and cache token counts |
| `limit5h` | yes | five-hour rate-limit gauge and reset countdown |
| `limit7d` | yes | seven-day rate-limit gauge and reset countdown |
| `burn` | no | projected time until the binding 5h or 7d limit reaches 100% |
| `lines` | no | lines added and removed in this session |
| `cost` | yes | session cost in USD |
| `style` | no | active output style |
| `duration` | no | session wall-clock duration |
| `stash` | no | git stash count |
| `clock` | yes | 12- or 24-hour clock |

Gauges change from green to yellow at 50% and red at 75%; both thresholds are configurable.

## Install

Bash environments on macOS, Linux, and Windows use `install.sh`. Windows without Git Bash or WSL uses the native Windows PowerShell 5.1 path below. Bash requires `jq` and a [Nerd Font](https://www.nerdfonts.com/); set `VL_ASCII=1` for a glyph-free rendering. Git is optional and only enables git-backed segments.

### Ask Claude

Paste this into Claude Code:

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude routes by environment, asks before changing preferences, and uses the appropriate installer. This fetches a mutable `main/INSTALL.md`; review it first or pin the playbook, installer, and payload to the same audited commit as described under [Trust and security](#trust-and-security).

### Bash

Run the interactive installer:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

It recommends the latest tagged release or lets you choose mutable `main`. Skip the prompt with `--ref v0.14.0` or another ref. If the one-line path cannot run, use the [manual fallback in `INSTALL.md`](./INSTALL.md#manual-fallback).

### Windows without Git Bash

`statusline.ps1` is the native Windows PowerShell 5.1 renderer. It needs no Bash, `jq`, WSL, archive extractor, or Git; `git.exe` is optional and only enables `git`, `stash`, and `project`. It supports the same main segments, styles, layouts, state-backed features, float output, and themed subagent rows as Bash.

The following bootstrap follows mutable `main`, resolves it to a commit before downloading executable installer code, then passes the same commit to `install.ps1`:

```powershell
& { $ErrorActionPreference='Stop';$repo='Nanako0129/coralline';$ref='main';$subagentRows="preserve";if($subagentRows -cnotin @("preserve","on","off")){throw "invalid SubagentRows"};if($repo -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$' -or $ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Length -gt 200 -or $ref.Contains('..') -or $ref.Contains('//') -or $ref.Contains('@{') -or $ref.EndsWith('/') -or $ref.EndsWith('.') -or $ref -match '(?i)(^|/)[^/]*\.lock($|/)'){throw 'invalid Repo or Ref'};$safe={param([string]$p,[string]$label,[bool]$cmd=$false);if([string]::IsNullOrWhiteSpace($p) -or $p -match '[\x00-\x1f\x7f-\x9f]' -or $p.StartsWith('\\') -or $p.StartsWith('//') -or $p.IndexOf(':',2) -ge 0){throw "$label is not a safe local path"};$full=[IO.Path]::GetFullPath($p).Replace('/','\');$root=[IO.Path]::GetPathRoot($full);if($root -notmatch '^[A-Za-z]:\\$'){throw "$label is not on a local drive"};$drive=New-Object IO.DriveInfo($root);if($drive.DriveType -eq [IO.DriveType]::Network){throw "$label is on a network drive"};if($cmd -and ($full.Contains('"') -or $full.Contains('%') -or $full.Contains('!'))){throw "$label is not cmd-safe"};$current=$root;foreach($part in $full.Substring($root.Length).Split(@([char]'\'),[StringSplitOptions]::RemoveEmptyEntries)){$current=[IO.Path]::Combine($current,$part);$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null -eq $item){break};if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$label contains a reparse point"}};if($full.Length -gt $root.Length){$full=$full.TrimEnd('\')};return $full};$fetch={param([uri]$uri,[long]$cap,[string]$label);if($uri.Scheme -cne 'https' -or ($uri.Host -cne 'api.github.com' -and $uri.Host -cne 'raw.githubusercontent.com') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw "unexpected $label URI"};$request=[Net.HttpWebRequest]::Create($uri);$request.Method='GET';$request.AllowAutoRedirect=$false;$request.Timeout=15000;$request.ReadWriteTimeout=15000;$request.UserAgent='coralline-bootstrap';$response=$null;try{$response=[Net.HttpWebResponse]$request.GetResponse();if($response.StatusCode -ne [Net.HttpStatusCode]::OK -or $response.ResponseUri.AbsoluteUri -cne $uri.AbsoluteUri){throw "$label request failed or redirected"};if($response.ContentLength -gt $cap){throw "$label Content-Length exceeds limit"};$input=$response.GetResponseStream();$memory=New-Object IO.MemoryStream;try{$buffer=New-Object byte[] 8192;$total=0L;while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $cap){throw "$label stream exceeds limit"};$memory.Write($buffer,0,$read)};if($response.ContentLength -ge 0 -and $total -ne $response.ContentLength){throw "$label download was truncated"};return ,$memory.ToArray()}finally{if($null -ne $input){$input.Dispose()};$memory.Dispose()}}finally{if($null -ne $response){$response.Dispose()}}};$old=[Net.ServicePointManager]::SecurityProtocol;$tmp=$null;$made=$false;$code=0;try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$parts=$repo.Split('/');$commit=$ref;if($commit -cnotmatch '^[0-9a-f]{40}$'){$api=[uri]('https://api.github.com/repos/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/commits/'+[uri]::EscapeDataString($ref));$strict=New-Object Text.UTF8Encoding($false,$true);try{$payload=$strict.GetString((& $fetch $api 1MB 'commit resolution'))|ConvertFrom-Json}catch{throw ('commit resolution response is invalid: '+$_.Exception.Message)};if($null -eq $payload -or $payload.PSObject.Properties.Name -notcontains 'sha'){throw 'commit resolution response has no sha'};$commit=[string]$payload.sha;if($commit -cnotmatch '^[0-9a-f]{40}$'){throw 'commit resolution returned an invalid sha'}};$uri=[uri]('https://raw.githubusercontent.com/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/'+$commit+'/install.ps1');$bytes=& $fetch $uri 1MB 'installer';$tempRoot=& $safe ([IO.Path]::GetTempPath()) 'TEMP';$tmp=& $safe ([IO.Path]::Combine($tempRoot,('coralline-install-'+[guid]::NewGuid().ToString('N')+'.ps1'))) 'installer temp';$output=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$made=$true;try{$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()};$checked=& $safe $tmp 'downloaded installer';if($checked -cne $tmp){throw 'installer temp identity changed'};$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors);if($errors.Count -ne 0){throw ('downloaded installer parse failed: '+$errors[0].Message)};$exe=& $safe ([IO.Path]::Combine($PSHOME,'powershell.exe')) 'PowerShell executable' $true;if(-not [IO.File]::Exists($exe)){throw 'trusted powershell.exe is missing'};$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.UseShellExecute=$false;$psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$tmp+'" -Repo "'+$repo+'" -Ref "'+$commit+'"';$psi.Arguments+=" -SubagentRows "+[char]34+$subagentRows+[char]34;$process=New-Object Diagnostics.Process;$process.StartInfo=$psi;try{if(-not $process.Start()){throw 'installer child did not start'};$process.WaitForExit();$code=$process.ExitCode}finally{$process.Dispose()}}finally{[Net.ServicePointManager]::SecurityProtocol=$old;if($made -and $null -ne $tmp -and [IO.File]::Exists($tmp)){$checked=& $safe $tmp 'installer cleanup';if($checked -cne $tmp){throw 'refusing unexpected cleanup path'};$item=Get-Item -LiteralPath $tmp -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'refusing reparse-point cleanup'};[IO.File]::Delete($tmp)}};if($code -ne 0){exit $code} }
```

For an audited release or commit, copy the line and replace only `$ref='main'` with the selected tag or 40-character SHA. A branch or tag can move; the bootstrap resolves it before downloading. The native installer manages `statusline.ps1` and the ten shipped themes, precisely merges the top-level `statusLine`, preserves `subagentStatusLine` unless `on` or `off` is explicit, never creates or edits `coralline.conf`, and leaves custom themes, state, and float output outside its replacement set. See the current [`INSTALL.md`](./INSTALL.md) contract and the historical [native installer PR #55](https://github.com/Nanako0129/coralline/pull/55).

### Trust and security

The default `main/INSTALL.md`, `main/UPGRADE.md`, and `main/install.sh` URLs are mutable remote inputs. Read the selected [`INSTALL.md`](./INSTALL.md), [`install.sh`](./install.sh), and [`install.ps1`](./install.ps1) before running them.

Passing `--ref <SHA>` to an installer already downloaded from `main` pins only the files it downloads next. To pin the initial Bash installer and its payload to the same audited commit, replace the placeholder below with one reviewed 40-character SHA:

```bash
SHA=YOUR_AUDITED_40_CHARACTER_COMMIT_SHA
audit_dir=$(mktemp -d "${TMPDIR:-/tmp}/coralline-audit.XXXXXX") || exit 1
(
  set -o pipefail
  trap 'cd / && rm -rf "$audit_dir"' EXIT
  cd "$audit_dir" || exit 1
  curl -fsSL "https://raw.githubusercontent.com/Nanako0129/coralline/$SHA/install.sh" | bash -s -- --ref "$SHA"
)
```

The unique temporary directory prevents stdin-executed Bash from treating a surrounding coralline checkout as its local source. Bash `--install-only` and updates do not edit `coralline.conf`; the wizard or AI changes it only after showing and receiving approval for the proposed change. Bash backs up `settings.json` and performs a semantic `jq` merge, so unrelated settings are retained but original formatting is not promised. The native installer follows the narrower managed/unmanaged boundary described above. Both renderers make no network requests after installation.

## Configuration

Bash reads `~/.claude/coralline.conf`; the native renderer can read the same file. It is sourced shell syntax, usually starting with one bundled theme:

```bash
. "$HOME/.claude/coralline/themes/claude-coral.conf"
```

| Variable | Runtime default | Meaning |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`, `lean`, or `classic` |
| `VL_LAYOUT` | `fixed` | one row per `VL_SEGMENTS*`; `auto` wraps one list responsively |
| `VL_MAX_LINES` / `VL_WRAP_MARGIN` | `3` / `4` | line cap and right margin for `auto` |
| `VL_SEGMENTS` | `dir git model ctx limit5h limit7d cost clock` | first row, and the complete list in `auto` |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | empty | optional fixed second and third rows |
| `VL_CLOCK` / `VL_CLOCK_SECONDS` | `12h` / `1` | `12h`, `24h`, or `off`; seconds toggle |
| `VL_BAR_WIDTH` | `5` | gauge width |
| `VL_BAR_FILL` / `VL_BAR_EMPTY` | `▰` / `▱` | gauge glyphs |
| `VL_CTX_GLYPH` / `VL_PROJECT_GLYPH` | `⬡` / `⬢` | context and project glyphs |
| `VL_PATH_DEPTH` / `VL_NAME_MAX` | `4` / `0` | path collapsing and optional name truncation |
| `VL_COST_DECIMALS` | `2` | cost precision |
| `VL_CTX_ALWAYS_SHOW` / `VL_COST_ALWAYS_SHOW` | `0` / `0` | show valid missing/empty context or cost as zero |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | gauge color thresholds |
| `VL_ASCII` | `0` | disable Nerd Font glyphs when `1` |
| `VL_RUNTIME_PROBE` | `0` | let `node` and `python` probe `PATH` when no pin exists; adds forks per render |
| `VL_BG_*` / `VL_FG_*` | theme | 256-color index or `"R,G,B"` |

### Layout and styles

`VL_LAYOUT="auto"` measures display columns and wraps up to `VL_MAX_LINES`; Claude Code v2.1.153+ supplies `$COLUMNS`, with a terminal fallback outside Claude Code. The display-width implementation and portability rationale live in [PR #10](https://github.com/Nanako0129/coralline/pull/10).

| Style | Result |
|---|---|
| `pill` | powerline pills with per-segment backgrounds |
| `lean` | flat colored text with optional separators, uniform background, and caps |
| `classic` | one-word preset for the p10k uniform dark bar and trailing cap ([PR #40](https://github.com/Nanako0129/coralline/pull/40)) |

The installer can import selected style, color, and clock values from `~/.p10k.zsh`; see the [`INSTALL.md` mapping](./INSTALL.md#ai-interview).

### Themes

Bundled themes: `claude-coral`, `catppuccin-mocha`, `nord`, `gruvbox-dark`, `tokyo-night`, `mono`, `dracula`, `lunar-pink`, `reverie`, and `morning-haze`. A theme is a `.conf` file assigning `VL_BG_*` and `VL_FG_*`; the wizard discovers `.conf` files recursively under [`themes/`](./themes/).

## Optional features

### Subagent panel

![coralline's main statusline above themed subagent panel rows](./assets/subagent-panel.png)

Enable or disable themed subagent rows explicitly:

```bash
bash ~/.claude/coralline/configure.sh --subagent-rows=on
bash ~/.claude/coralline/configure.sh --subagent-rows=off
```

Bash install-only and ordinary updates do not add or remove `subagentStatusLine`; only the wizard choice or explicit commands above change it. The native installer defaults to `-SubagentRows preserve`, and changes the setting only with explicit `on` or `off`.

Per-task model and context fields require Claude Code v2.1.205+. On v2.1.211, coralline recovers a missing local `agentType` role from the task sidecar; without the sidecar it still uses payload names and labels. Missing model or start time hides only the corresponding segment. `ctx` hides only when token count is missing or invalid; without a valid context size, it still shows the glyph and bare token count while omitting only the gauge and percentage. Rows redraw on panel events, not a one-second poll; the native main-session row remains, and per-task effort is not inferred. The design and current fallback behavior are traced in [issue #45](https://github.com/Nanako0129/coralline/issues/45) and [PR #44](https://github.com/Nanako0129/coralline/pull/44).

| `VL_SUB_SEGMENTS` value | Shows |
|---|---|
| `name` | task identity and label, colored by status |
| `model` | per-task model |
| `ctx` | context gauge and token count |
| `elapsed` | elapsed wall-clock time |

The default order is `name model ctx elapsed`.

### Burn-rate segment

Add `burn` to `VL_SEGMENTS` to show the projected time until the binding 5h or 7d limit reaches 100%. It is off by default; while listed, it samples to `~/.claude/coralline/burn-5h.tsv`, and removing it stops writes. `CORALLINE_BURN_WINDOW` defaults to 600 seconds. The motivation and estimator contract are in [issue #17](https://github.com/Nanako0129/coralline/issues/17).

### Cross-session limit sync (optional)

Set `VL_LIMIT_SYNC=1` to let sessions that redraw share the account's open 5h and 7d windows through `limit-5h.d` and `limit-7d.d`. A session's valid reading always wins its own window; the store wins for a strictly newer window or when the session has no reading, using only a still-open stored window. It is off by default, has no API access, and cannot refresh an idle session. The store lives under `~/.claude/coralline`, or under `$CLAUDE_CONFIG_DIR/coralline` when that variable is set, as do the burn samples and the float file, so two Claude config directories keep separate state instead of overwriting each other's windows. See the original redraw-only contract in [PR #24](https://github.com/Nanako0129/coralline/pull/24) and the no-reading fallback in [PR #64](https://github.com/Nanako0129/coralline/pull/64).

### Float readout (optional)

Set `VL_FLOAT=1` to write a plain-text line to `~/.claude/coralline/float.txt` on each render. The default `VL_FLOAT_SEGMENTS` is `model ctx cost`. coralline ships no display carrier; the file is the integration seam, with an unsupported [iTerm2 example](./example/float-display-iterm2/) included. The design boundary is documented in [issue #15](https://github.com/Nanako0129/coralline/issues/15).

## Update, reconfigure, and uninstall

### Updating

Ask Claude to follow the upgrade playbook:

```text
Please update coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/UPGRADE.md
and follow the playbook in it.
```

Or update a Bash install directly from a directory outside any coralline checkout:

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

The URLs above fetch mutable `main` playbook or bootstrap code. Run the direct updater outside a coralline checkout; inside one, the installer intentionally uses that checkout's files instead of downloading a remote payload. Outside a checkout, the Bash installer keeps `main` in non-interactive runs. In an interactive `--install-only` run, it asks which payload ref to install and defaults to the latest tagged release when that tag can be resolved; if release lookup fails, it keeps `main` without prompting. Pass `--ref main` to request the development payload explicitly. A previously pinned install does not make a later unpinned update immutable. For an audited update, fetch `UPGRADE.md` from one reviewed 40-character SHA, then run `install.sh` from that same SHA and a neutral temporary directory as above, passing the same SHA through `--ref`. Re-run the native bootstrap with the same selected ref for PowerShell-only Windows. The installer reports new opt-ins but preserves existing choices unless approved; see [issue #31](https://github.com/Nanako0129/coralline/issues/31) and the current [`UPGRADE.md`](./UPGRADE.md).

### Reconfigure

Bash-capable installs include the visual wizard:

```bash
bash ~/.claude/coralline/configure.sh
```

PowerShell-only installs have no native wizard; back up and edit `coralline.conf` manually or reuse one created on a Bash-capable host.

### Uninstall

The runtime directory can contain custom themes, burn and limit history, `float.txt`, and other unmanaged files. Back up anything you want to keep before deleting it. Also back up the current `~/.claude/settings.json`, then remove `statusLine` or `subagentStatusLine` only if its command still points to coralline; do not restore an old whole-file backup without comparing unrelated changes made since it was created.

For Bash-capable systems, inspect and edit the current settings before removing the runtime:

```bash
settings="$HOME/.claude/settings.json"
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
"${EDITOR:-vi}" "$settings"
rm -rf "$HOME/.claude/coralline"
# Optional: remove your saved preferences too.
rm -f "$HOME/.claude/coralline.conf"
```

For PowerShell-only systems:

```powershell
$settings = Join-Path $HOME '.claude\settings.json'
Copy-Item -LiteralPath $settings -Destination "$settings.bak.$(Get-Date -Format yyyyMMddHHmmss)"
notepad.exe $settings
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline') -Recurse -Force
# Optional: remove your saved preferences too.
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline.conf') -Force -ErrorAction SilentlyContinue
```

## Platform and performance

| Platform | Support |
|---|---|
| macOS | stock Bash 3.2 |
| Linux | Bash 4+ / 5 |
| Windows with Git Bash | Bash renderer |
| Windows without Git Bash | native Windows PowerShell 5.1 renderer |

The renderer is local: no network or API calls and zero token use. The Bash main bar parses its payload with one `jq` call; both renderers use at most one `git status --porcelain=v2 --branch` call per render and no per-field subprocesses. Reproducible measurement guidance is in [BENCHMARK.md](./BENCHMARK.md), introduced in [PR #65](https://github.com/Nanako0129/coralline/pull/65).

## Support, acknowledgements, and license

If coralline improves your daily sessions, you can support its continued maintenance on Patreon.

[![Support coralline on Patreon](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

coralline's visual language is a tribute to [Powerlevel10k](https://github.com/romkatv/powerlevel10k), the [powerline](https://github.com/powerline/powerline) lineage, and [Nerd Fonts](https://www.nerdfonts.com/).

[MIT License](./LICENSE)
