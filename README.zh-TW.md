# coralline

> 給 Claude Code 用、向 [Powerlevel10k](https://github.com/romkatv/powerlevel10k) 致敬的 statusline，同時提供原生 Bash 與 Windows PowerShell renderer。

[English README](./README.md)

![並排顯示 coralline 最初六個主題](./assets/hero.png)

## 效果

這是以乾淨的 `main` worktree 與內建 sample 實際 render 出來的 runtime 預設值：

```text
 ~/side-project/coralline  ⎇ main  ◆ Fable 5  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k cr:98.7k cw:4.3k  5h ▰▰▱▱▱ 41% ↺2h44m  7d ▰▰▰▰▱ 79% ↺1d11h  $1.23  ⊙ 01:37:35 pm 
```

| 區段 | 預設啟用 | 顯示內容 |
|---|---|---|
| `dir` | 是 | 目前目錄，過長路徑會摺疊 |
| `project` | 否 | repo 名稱，在所有 worktree 都相同；非 git repo 時隱藏 |
| `git` | 是 | 分支、已暫存 `+`、已修改 `!`、未追蹤 `?`、領先 `⇡`、落後 `⇣` |
| `node` | 否 | pin 檔指定的 Node 版本，或以 `VL_RUNTIME_PROBE=1` 偵測 `PATH`；偵測不到時隱藏 |
| `python` | 否 | 目前 virtualenv、conda 或 pin 檔指定的 Python 版本，或以 `VL_RUNTIME_PROBE=1` 偵測 `PATH`；偵測不到時隱藏 |
| `model` | 是 | 目前使用的 Claude model |
| `effort` | 否 | 推理強度：`low`、`med`、`high`、`xhigh` 或 `max` |
| `ctx` | 是 | context 用量條與輸入、輸出、快取 token 數 |
| `limit5h` | 是 | 五小時額度量表與重置倒數 |
| `limit7d` | 是 | 七天額度量表與重置倒數 |
| `burn` | 否 | 綁定中的 5h 或 7d 額度到達 100% 的預估時間 |
| `lines` | 否 | 本次 session 新增與刪除的行數 |
| `cost` | 是 | 本次 session 花費（USD） |
| `style` | 否 | 目前 output style |
| `duration` | 否 | session 經過時間 |
| `stash` | 否 | git stash 數量 |
| `clock` | 是 | 12 或 24 小時制時鐘 |

量表會從綠色變成 50% 的黃色與 75% 的紅色；兩個門檻都能自訂。

## 安裝

macOS、Linux 與有 Bash 的 Windows 使用 `install.sh`；沒有 Git Bash 或 WSL 的 Windows 使用下方原生 Windows PowerShell 5.1 流程。Bash 需要 `jq` 與 [Nerd Font](https://www.nerdfonts.com/)；設定 `VL_ASCII=1` 可改用無特殊字符的渲染。Git 是選用項目，只用來啟用 git 相關區段。

### 請 Claude 安裝

把這段貼進 Claude Code：

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude 會依環境選擇路徑、在更改偏好前詢問，並使用對應 installer。這會抓取可變的 `main/INSTALL.md`；請先檢閱，或依[信任與安全](#信任與安全)把 playbook、installer 與 payload 釘到同一個已稽核 commit。

### Bash

執行互動式 installer：

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

它會建議最新 release tag，也能選擇可變的 `main`。使用 `--ref v0.13.0` 或其他 ref 可略過詢問。若一行安裝無法執行，使用 [`INSTALL.md` 的 manual fallback](./INSTALL.md#manual-fallback)。

### Windows 無 Git Bash

`statusline.ps1` 是原生 Windows PowerShell 5.1 renderer。它不需要 Bash、`jq`、WSL、archive 解壓工具或 Git；`git.exe` 是選用項目，只用來啟用 `git`、`stash` 與 `project`。它支援和 Bash 相同的主列區段、風格、版面、state-backed 功能、float 輸出與套用主題的 subagent 列。

以下 bootstrap 會跟隨可變的 `main`，在下載可執行 installer 前先解析成 commit，再把同一個 commit 傳給 `install.ps1`：

```powershell
& { $ErrorActionPreference='Stop';$repo='Nanako0129/coralline';$ref='main';$subagentRows="preserve";if($subagentRows -cnotin @("preserve","on","off")){throw "invalid SubagentRows"};if($repo -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$' -or $ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Length -gt 200 -or $ref.Contains('..') -or $ref.Contains('//') -or $ref.Contains('@{') -or $ref.EndsWith('/') -or $ref.EndsWith('.') -or $ref -match '(?i)(^|/)[^/]*\.lock($|/)'){throw 'invalid Repo or Ref'};$safe={param([string]$p,[string]$label,[bool]$cmd=$false);if([string]::IsNullOrWhiteSpace($p) -or $p -match '[\x00-\x1f\x7f-\x9f]' -or $p.StartsWith('\\') -or $p.StartsWith('//') -or $p.IndexOf(':',2) -ge 0){throw "$label is not a safe local path"};$full=[IO.Path]::GetFullPath($p).Replace('/','\');$root=[IO.Path]::GetPathRoot($full);if($root -notmatch '^[A-Za-z]:\\$'){throw "$label is not on a local drive"};$drive=New-Object IO.DriveInfo($root);if($drive.DriveType -eq [IO.DriveType]::Network){throw "$label is on a network drive"};if($cmd -and ($full.Contains('"') -or $full.Contains('%') -or $full.Contains('!'))){throw "$label is not cmd-safe"};$current=$root;foreach($part in $full.Substring($root.Length).Split(@([char]'\'),[StringSplitOptions]::RemoveEmptyEntries)){$current=[IO.Path]::Combine($current,$part);$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null -eq $item){break};if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$label contains a reparse point"}};if($full.Length -gt $root.Length){$full=$full.TrimEnd('\')};return $full};$fetch={param([uri]$uri,[long]$cap,[string]$label);if($uri.Scheme -cne 'https' -or ($uri.Host -cne 'api.github.com' -and $uri.Host -cne 'raw.githubusercontent.com') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw "unexpected $label URI"};$request=[Net.HttpWebRequest]::Create($uri);$request.Method='GET';$request.AllowAutoRedirect=$false;$request.Timeout=15000;$request.ReadWriteTimeout=15000;$request.UserAgent='coralline-bootstrap';$response=$null;try{$response=[Net.HttpWebResponse]$request.GetResponse();if($response.StatusCode -ne [Net.HttpStatusCode]::OK -or $response.ResponseUri.AbsoluteUri -cne $uri.AbsoluteUri){throw "$label request failed or redirected"};if($response.ContentLength -gt $cap){throw "$label Content-Length exceeds limit"};$input=$response.GetResponseStream();$memory=New-Object IO.MemoryStream;try{$buffer=New-Object byte[] 8192;$total=0L;while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $cap){throw "$label stream exceeds limit"};$memory.Write($buffer,0,$read)};if($response.ContentLength -ge 0 -and $total -ne $response.ContentLength){throw "$label download was truncated"};return ,$memory.ToArray()}finally{if($null -ne $input){$input.Dispose()};$memory.Dispose()}}finally{if($null -ne $response){$response.Dispose()}}};$old=[Net.ServicePointManager]::SecurityProtocol;$tmp=$null;$made=$false;$code=0;try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$parts=$repo.Split('/');$commit=$ref;if($commit -cnotmatch '^[0-9a-f]{40}$'){$api=[uri]('https://api.github.com/repos/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/commits/'+[uri]::EscapeDataString($ref));$strict=New-Object Text.UTF8Encoding($false,$true);try{$payload=$strict.GetString((& $fetch $api 1MB 'commit resolution'))|ConvertFrom-Json}catch{throw ('commit resolution response is invalid: '+$_.Exception.Message)};if($null -eq $payload -or $payload.PSObject.Properties.Name -notcontains 'sha'){throw 'commit resolution response has no sha'};$commit=[string]$payload.sha;if($commit -cnotmatch '^[0-9a-f]{40}$'){throw 'commit resolution returned an invalid sha'}};$uri=[uri]('https://raw.githubusercontent.com/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/'+$commit+'/install.ps1');$bytes=& $fetch $uri 1MB 'installer';$tempRoot=& $safe ([IO.Path]::GetTempPath()) 'TEMP';$tmp=& $safe ([IO.Path]::Combine($tempRoot,('coralline-install-'+[guid]::NewGuid().ToString('N')+'.ps1'))) 'installer temp';$output=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$made=$true;try{$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()};$checked=& $safe $tmp 'downloaded installer';if($checked -cne $tmp){throw 'installer temp identity changed'};$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors);if($errors.Count -ne 0){throw ('downloaded installer parse failed: '+$errors[0].Message)};$exe=& $safe ([IO.Path]::Combine($PSHOME,'powershell.exe')) 'PowerShell executable' $true;if(-not [IO.File]::Exists($exe)){throw 'trusted powershell.exe is missing'};$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.UseShellExecute=$false;$psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$tmp+'" -Repo "'+$repo+'" -Ref "'+$commit+'"';$psi.Arguments+=" -SubagentRows "+[char]34+$subagentRows+[char]34;$process=New-Object Diagnostics.Process;$process.StartInfo=$psi;try{if(-not $process.Start()){throw 'installer child did not start'};$process.WaitForExit();$code=$process.ExitCode}finally{$process.Dispose()}}finally{[Net.ServicePointManager]::SecurityProtocol=$old;if($made -and $null -ne $tmp -and [IO.File]::Exists($tmp)){$checked=& $safe $tmp 'installer cleanup';if($checked -cne $tmp){throw 'refusing unexpected cleanup path'};$item=Get-Item -LiteralPath $tmp -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'refusing reparse-point cleanup'};[IO.File]::Delete($tmp)}};if($code -ne 0){exit $code} }
```

要安裝已稽核的 release 或 commit，請複製同一行，只把 `$ref='main'` 換成選定的 tag 或 40 字元 SHA。branch 或 tag 都可能移動；bootstrap 會先解析再下載。原生 installer 管理 `statusline.ps1` 與十個 shipped themes、精確合併最上層 `statusLine`、除非明確指定 `on` 或 `off` 否則保留 `subagentStatusLine`、永不建立或修改 `coralline.conf`，且不會把 custom themes、state 與 float 輸出納入替換。現行契約見 [`INSTALL.md`](./INSTALL.md)，歷史設計見[原生 installer PR #55](https://github.com/Nanako0129/coralline/pull/55)。

### 信任與安全

預設的 `main/INSTALL.md`、`main/UPGRADE.md` 與 `main/install.sh` URL 都是可變的遠端輸入。執行前請讀取選定的 [`INSTALL.md`](./INSTALL.md)、[`install.sh`](./install.sh) 與 [`install.ps1`](./install.ps1)。

把 `--ref <SHA>` 傳給已經從 `main` 下載並開始執行的 installer，只會釘選它接著下載的檔案。要把最初的 Bash installer 與 payload 都釘到同一個已稽核 commit，請以一個已檢閱的 40 字元 SHA 取代下方 placeholder：

```bash
SHA=YOUR_AUDITED_40_CHARACTER_COMMIT_SHA
curl -fsSL "https://raw.githubusercontent.com/Nanako0129/coralline/$SHA/install.sh" | bash -s -- --ref "$SHA"
```

Bash `--install-only` 與更新不會修改 `coralline.conf`；wizard 或 AI 只會在顯示變更並取得同意後修改。Bash 會先備份 `settings.json`，再以 `jq` 做語意合併，因此會保留無關設定，但不承諾原始格式不變。原生 installer 則遵守上方更窄的 managed／unmanaged 邊界。兩種 renderer 在安裝後都不會發出網路請求。

## 設定檔

Bash 讀取 `~/.claude/coralline.conf`，原生 renderer 也能讀同一個檔案。它是會被 source 的 shell 語法，通常從一個內建主題開始：

```bash
. "$HOME/.claude/coralline/themes/claude-coral.conf"
```

| 變數 | Runtime 預設值 | 說明 |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`、`lean` 或 `classic` |
| `VL_LAYOUT` | `fixed` | 每個 `VL_SEGMENTS*` 固定一列；`auto` 會響應式折行單一清單 |
| `VL_MAX_LINES` / `VL_WRAP_MARGIN` | `3` / `4` | `auto` 的行數上限與右側留白 |
| `VL_SEGMENTS` | `dir git model ctx limit5h limit7d cost clock` | 第一列，亦是 `auto` 模式的完整清單 |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | 空 | 選用的固定第二、三列 |
| `VL_CLOCK` / `VL_CLOCK_SECONDS` | `12h` / `1` | `12h`、`24h` 或 `off`；秒數開關 |
| `VL_BAR_WIDTH` | `5` | 量表寬度 |
| `VL_BAR_FILL` / `VL_BAR_EMPTY` | `▰` / `▱` | 量表字符 |
| `VL_CTX_GLYPH` / `VL_PROJECT_GLYPH` | `⬡` / `⬢` | context 與 project 字符 |
| `VL_PATH_DEPTH` / `VL_NAME_MAX` | `4` / `0` | 路徑摺疊與選用的名稱截斷 |
| `VL_COST_DECIMALS` | `2` | 費用顯示精度 |
| `VL_CTX_ALWAYS_SHOW` / `VL_COST_ALWAYS_SHOW` | `0` / `0` | 把有效但缺失／空白的 context 或 cost 顯示為零 |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | 量表變色門檻 |
| `VL_ASCII` | `0` | 設為 `1` 停用 Nerd Font 字符 |
| `VL_RUNTIME_PROBE` | `0` | 無 pin 時讓 `node` 與 `python` 偵測 `PATH`；每次 render 會增加 fork |
| `VL_BG_*` / `VL_FG_*` | 依主題 | 256 色編號或 `"R,G,B"` |

### 版面與風格

`VL_LAYOUT="auto"` 會量測顯示欄寬並折成最多 `VL_MAX_LINES` 行；Claude Code v2.1.153+ 會提供 `$COLUMNS`，Claude Code 外則退回終端寬度。顯示寬度的實作與可攜性理由見 [PR #10](https://github.com/Nanako0129/coralline/pull/10)。

| 風格 | 結果 |
|---|---|
| `pill` | 每個區段有獨立背景的 powerline 膠囊 |
| `lean` | 純色文字，可選分隔、統一背景與端點 |
| `classic` | p10k 統一深色橫條與尾端截角的一字 preset（[PR #40](https://github.com/Nanako0129/coralline/pull/40)） |

Installer 可以從 `~/.p10k.zsh` 匯入選定的風格、色彩與時鐘設定；詳見 [`INSTALL.md` mapping](./INSTALL.md#ai-interview)。

### 主題

內建主題：`claude-coral`、`catppuccin-mocha`、`nord`、`gruvbox-dark`、`tokyo-night`、`mono`、`dracula`、`lunar-pink`、`reverie` 與 `morning-haze`。主題就是指定 `VL_BG_*` 與 `VL_FG_*` 的 `.conf` 檔；wizard 會遞迴掃描 [`themes/`](./themes/) 下的 `.conf`。

## 選用功能

### Subagent 面板

![coralline 主狀態列與套用主題的 subagent 面板列](./assets/subagent-panel.png)

明確啟用或停用套用主題的 subagent 列：

```bash
bash ~/.claude/coralline/configure.sh --subagent-rows=on
bash ~/.claude/coralline/configure.sh --subagent-rows=off
```

Bash install-only 與一般更新不會自行新增或刪除 `subagentStatusLine`；只有 wizard 選擇或上方明確指令才會改動。原生 installer 預設使用 `-SubagentRows preserve`，只有明確指定 `on` 或 `off` 才改設定。

每個 task 的 model 與 context 欄位需要 Claude Code v2.1.205+。在 v2.1.211，coralline 會從 task sidecar 恢復 payload 缺少的本機 `agentType` role；沒有 sidecar 時仍會使用 payload 的 name 與 label。缺少 model、context size、token count 或 start time 時只隱藏受影響的區段。列由 panel event 觸發重繪，不是固定每秒輪詢；原生 main-session 列會保留，也不推測 per-task effort。設計與現行 fallback 行為可追溯到 [issue #45](https://github.com/Nanako0129/coralline/issues/45) 與 [PR #44](https://github.com/Nanako0129/coralline/pull/44)。

| `VL_SUB_SEGMENTS` 值 | 顯示內容 |
|---|---|
| `name` | task identity 與 label，依狀態上色 |
| `model` | per-task model |
| `ctx` | context 用量條與 token 數 |
| `elapsed` | 經過的 wall-clock 時間 |

預設順序是 `name model ctx elapsed`。

### 消耗率區段

把 `burn` 加入 `VL_SEGMENTS`，即可顯示綁定中的 5h 或 7d 額度到達 100% 的預估時間。它預設關閉；列在清單中時會把樣本寫入 `~/.claude/coralline/burn-5h.tsv`，移除後停止寫入。`CORALLINE_BURN_WINDOW` 預設為 600 秒。動機與 estimator 契約見 [issue #17](https://github.com/Nanako0129/coralline/issues/17)。

### 跨 session 額度同步（選用）

設定 `VL_LIMIT_SYNC=1`，讓會重繪的 session 透過 `limit-5h.d` 與 `limit-7d.d` 共用帳號仍開放的 5h 與 7d 視窗。session 自己的有效讀數永遠贏自己的視窗；只有 store 握有嚴格較新的視窗，或 session 完全沒有讀數時，才使用仍開放的 stored window。它預設關閉、沒有 API 存取，也無法刷新完全閒置的 session。原始 redraw-only 契約見 [PR #24](https://github.com/Nanako0129/coralline/pull/24)，無讀數 fallback 見 [PR #64](https://github.com/Nanako0129/coralline/pull/64)。

### Float readout（選用）

設定 `VL_FLOAT=1`，每次 render 都會把純文字一行寫入 `~/.claude/coralline/float.txt`。`VL_FLOAT_SEGMENTS` 預設為 `model ctx cost`。coralline 不提供 display carrier；這個檔案就是 integration seam，repo 另附一個不受支援的 [iTerm2 範例](./example/float-display-iterm2/)。設計邊界記錄在 [issue #15](https://github.com/Nanako0129/coralline/issues/15)。

## 更新、重新設定與移除

### 更新

請 Claude 依照 upgrade playbook 更新：

```text
Please update coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/UPGRADE.md
and follow the playbook in it.
```

或直接更新 Bash 安裝：

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

兩個預設路徑都使用可變的 `main`。先前釘選的安裝，不會讓之後未釘選的更新自動變成 immutable。要做 audited update，請從同一個已檢閱的 40 字元 SHA 抓取 `UPGRADE.md` 與 `install.sh`，並把相同 SHA 傳給 `--ref`。僅有 PowerShell 的 Windows 則以同一個選定 ref 重跑原生 bootstrap。Installer 會報告新的 opt-in，但除非取得同意，否則保留既有選擇；見 [issue #31](https://github.com/Nanako0129/coralline/issues/31) 與現行 [`UPGRADE.md`](./UPGRADE.md)。

### 重新設定

有 Bash 的安裝包含視覺化 wizard：

```bash
bash ~/.claude/coralline/configure.sh
```

PowerShell-only 安裝沒有原生 wizard；請先備份再手動編輯 `coralline.conf`，或沿用有 Bash 的主機所建立的設定。

### 移除

Runtime 目錄可能包含 custom themes、burn／limit history、`float.txt` 與其他非受管理檔案。刪除前請先備份要保留的內容。也請先備份目前的 `~/.claude/settings.json`，並且只有在 command 仍指向 coralline 時才移除 `statusLine` 或 `subagentStatusLine`；未比較建立後的其他變更前，不要直接還原整份舊 backup。

有 Bash 的系統先檢查並編輯目前 settings，再移除 runtime：

```bash
settings="$HOME/.claude/settings.json"
cp "$settings" "$settings.bak.$(date +%Y%m%d%H%M%S)"
"${EDITOR:-vi}" "$settings"
rm -rf "$HOME/.claude/coralline"
# Optional: remove your saved preferences too.
rm -f "$HOME/.claude/coralline.conf"
```

PowerShell-only 系統：

```powershell
$settings = Join-Path $HOME '.claude\settings.json'
Copy-Item -LiteralPath $settings -Destination "$settings.bak.$(Get-Date -Format yyyyMMddHHmmss)"
notepad.exe $settings
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline') -Recurse -Force
# Optional: remove your saved preferences too.
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline.conf') -Force -ErrorAction SilentlyContinue
```

## 平台與效能

| 平台 | 支援方式 |
|---|---|
| macOS | 內建 Bash 3.2 |
| Linux | Bash 4+ / 5 |
| Windows with Git Bash | Bash renderer |
| Windows without Git Bash | 原生 Windows PowerShell 5.1 renderer |

Renderer 全程在本機執行：不呼叫網路或 API，也不使用 token。Bash 主列只用一次 `jq` 解析 payload；兩種 renderer 每次 render 最多呼叫一次 `git status --porcelain=v2 --branch`，不會為每個欄位啟動 process。可重現的量測方法見 [BENCHMARK.zh-TW.md](./BENCHMARK.zh-TW.md)，來源是 [PR #65](https://github.com/Nanako0129/coralline/pull/65)。

## 支持、致謝與授權

如果 coralline 讓你的日常 session 更清楚，歡迎在 Patreon 支持後續維護。

[![在 Patreon 支持 coralline](https://img.shields.io/badge/Support_on_Patreon-FF424D?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/Nanako0129/membership)

coralline 的視覺語言致敬 [Powerlevel10k](https://github.com/romkatv/powerlevel10k)、[powerline](https://github.com/powerline/powerline) 系譜與 [Nerd Fonts](https://www.nerdfonts.com/)。

[MIT License](./LICENSE)
