# coralline

> 給 Claude Code 用、向 [Powerlevel10k](https://github.com/romkatv/powerlevel10k) 致敬的
> statusline，特色是人類與 AI 共用同一個 installer 入口：你可以直接跑，也可以交給
> Claude 幫你跑完設定。

[English README](./README.md)

![六種 coralline 主題總覽](./assets/hero.png)

## 效果

```text
╭ ~/side-project/coralline  ⬢ coralline  ⎇ main+!  ◆ Fable 5  ψ high  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k  5h ▰▰▱▱▱ 41% ↺2h44m  7d ▰▰▰▰▱ 79% ↺1d11h  +321 −87  $1.23  ✎ Explanatory  ⧖ 47m  ⚑ 1  ⊙ 02:45 pm ╮
```

| 區段 | 顯示內容 |
|---|---|
| `dir` | 目前目錄，過長路徑摺疊為 `~/a/…/z` |
| `project` | repo 名稱（`⬢`），在所有 worktree 都相同；非 git repo 時隱藏 |
| `git` | 分支、已暫存 `+` / 已修改 `!` / 未追蹤 `?`、領先 `⇡` 落後 `⇣` |
| `node` | 目前 Node 版本（Nerd Font `nf-dev-nodejs_small`），來自 `.nvmrc` / `.node-version`（或以 `VL_RUNTIME_PROBE=1` 讀取 `PATH` 上的 `node`）；偵測不到時隱藏；需手動開啟 |
| `python` | 目前 Python 環境（Nerd Font `nf-dev-python`）—— `$VIRTUAL_ENV` / conda（略過 `base`）/ `.python-version`（或以 `VL_RUNTIME_PROBE=1` 讀取 `PATH` 上的 `python3`）；偵測不到時隱藏；需手動開啟 |
| `model` | 目前使用的 Claude 模型 |
| `effort` | 推理強度（`ψ`）—— `low` / `med` / `high` / `xhigh` / `max` |
| `ctx` | context window 量表、輸入/輸出/快取 token 數 |
| `limit5h` / `limit7d` | 用量限額量表與重置倒數 |
| `burn` | 消耗時間預估：根據最近燒耗率推算，何時會達到限額上限（5h 或 7d）100%（`↗`）；把 `burn` 加入 `VL_SEGMENTS` 啟用 |
| `lines` | 本次 session 修改行數 |
| `cost` | 本次 session 花費（USD） |
| `style` | 目前的 output style |
| `duration` | session 經過時間 |
| `stash` | git stash 數量 |
| `clock` | 時鐘，12 或 24 小時制 |

量表會隨用量變色：綠色 → 50% 轉黃 → 75% 轉紅（門檻可調）。

## Subagent 面板

Claude Code 在 subagent 執行時會於 prompt 下方顯示 agent 面板；每列預設為
`name · description · token count`。coralline 可以為其中的 **subagent 列**
套用主題，並加入該 task 的 model、context 用量條與執行時間：

```text
 scout · Explore config sources ◆ gpt-5.6-luna ⬡ ▰▰▱▱▱ 21% 42.0k ⧖ 2m05s
 executor · Apply R2 fixes ◆ Fable 5 ⬡ ▰▰▰▰▱ 77% 155.0k ⧖ 45s
```

![coralline 主狀態列，下方是五列套用主題的 subagent 面板列，涵蓋各種 task 狀態](./assets/subagent-panel.png)

Claude Code v2.1.211 沒有把內部的 `agentType` role 放進
`subagentStatusLine` payload，但本機 Agent task 會在 session transcript
旁留下小型 metadata sidecar。coralline 以 Bash builtin 直接讀取，不會增加
process，因此可恢復 `scout`、`executor` 等 role。列上會同時保留 identity
與 task label：若另有明確的 per-task `name`，會和 role 一起顯示，後面再接
`label` 或 `description`。sidecar 不存在或無法讀取時，payload 原有欄位仍會
正常顯示。

model 直接取自 Claude Code 傳入的 per-task `model` 欄位；coralline 不會從
主 session model 或 agent role 推測。已知的 Claude ID 會縮短顯示
（`claude-haiku-4-5-…` → `Haiku 4.5`），不認得的 ID 或 gateway ID（例如
`gpt-5.6-luna`）則原樣顯示。

可直接使用以下指令啟用或停用：

```bash
bash ~/.claude/coralline/configure.sh --subagent-rows=on
bash ~/.claude/coralline/configure.sh --subagent-rows=off
```

設定 wizard 提供相同的開關。停用時只會移除 `subagentStatusLine`，其他 Claude
設定都會保留。

每個 task 的 `model` 與 `contextWindowSize` 需要 Claude Code **v2.1.205+**。
缺少欄位時會逐一降級：沒有 model 只會隱藏 model segment；沒有
`contextWindowSize` 時，只要有 `tokenCount` 仍會顯示 token 數；其餘列內容
仍由 coralline 套用主題。更新由 panel event 觸發，不是固定每秒輪詢，因此
elapsed time 只會在 Claude Code 重繪面板時變動。

目前 live payload 沒有提供 per-task *effort*。coralline 不會沿用主 session
的 effort，也不會從 role 猜測；只有 Claude Code 未來新增欄位後才能支援。
面板原生的 **main session 列仍會保留**，因為它不屬於
`subagentStatusLine` 協定；coralline 只會取代並美化 subagent 列。

`VL_SUB_SEGMENTS`（預設 `"name model ctx elapsed"`）決定列的內容與順序，
可用的 segment 就是以下四個：

| Segment | 顯示 | 隱藏條件 |
|---|---|---|
| `name` | task identity 加 task label：明確 `name` 與 sidecar `agentType` 同時存在時會組合顯示，後接 payload `label` 或 `description`，最後才以 `type` 退回；顏色由 `VL_FG_SUB_*` 反映狀態——running：一般文字色、completed：ok、failed：hot、缺失／未知：dim | 所有來源皆空或無法取得 |
| `model` | `◆` Claude Code per-task payload 傳入的 model；已知 Claude ID 會縮短，不認得的 ID 或 gateway ID 原樣顯示 | model 尚未 resolve，或 v2.1.205 之前的版本 |
| `ctx` | `⬡` context 用量條 + token 數；無 `contextWindowSize` 時只顯示 token 數 | 沒有 `tokenCount` |
| `elapsed` | `⧖` 自 `startTime` 起的執行時間，精確到秒（epoch 秒／毫秒或 UTC ISO） | `startTime` 缺失或無法解析 |

subagent renderer 與主列共用同一份 config，但只讀取與「單列外觀」有關的參數：
`VL_STYLE` 及各 style 自己的參數——pill 的圓角與分隔（`VL_CAP_L`、`VL_CAP_R`、
`VL_SEP`）、lean/classic 家族（`VL_LEAN_SEP`、`VL_LEAN_BG`、
`VL_LEAN_CAP_L`/`VL_LEAN_CAP_R`、`VL_LEAN_FG`、`VL_BG_BAR`）——`VL_ASCII`、
`VL_NAME_MAX`（建議設定——面板 label 通常很長，列過寬時 Claude Code 從右側裁切，
最先消失的就是 model/ctx）、用量條參數（`VL_BAR_WIDTH`、`VL_BAR_FILL`、
`VL_BAR_EMPTY`、`VL_CTX_GLYPH`、`VL_WARN_PCT`、`VL_HOT_PCT`）、共用色盤（`VL_FG_TEXT`、
`VL_FG_DIM`、`VL_FG_OK`、`VL_FG_WARN`、`VL_FG_HOT`）、列顏色
`VL_BG_SUB_NAME` / `VL_BG_SUB_MODEL` / `VL_BG_SUB_CTX` / `VL_BG_SUB_ELAPSED`
（留空 = 分別退回 `VL_BG_DIR` / `VL_BG_MODEL` / `VL_BG_CTX` /
`VL_BG_DURATION`），以及 name pill 各狀態的文字顏色 `VL_FG_SUB_TEXT` /
`VL_FG_SUB_OK` / `VL_FG_SUB_HOT` / `VL_FG_SUB_DIM`（留空 = 分別退回
`VL_FG_TEXT` / `VL_FG_OK` / `VL_FG_HOT` / `VL_FG_DIM`）。主色盤是為量表區段的深色底
調的，所以內建預設與所有內建主題都用 `VL_BG_SUB_NAME` 讓 name pill 使用同一種深底，
文字沿用主題原本的淺色；不這樣做的話，completed、failed、未知這三種色調在亮色 pill 上
最低只有 1.0:1。對比同時對這個 pill 與 `VL_STYLE="classic"` 改用的整條橫條底色驗證。
把 `VL_BG_SUB_NAME=""` 設空即可換回亮色 pill。其餘參數——`VL_SEGMENTS*`、版面（`VL_LAYOUT`、
`VL_MAX_LINES`、`VL_WRAP_MARGIN`）、clock、cost、lines、float、limit-sync、
burn、git 與 runtime segments——都只作用於主列，在 subagent 模式一律忽略。
想讓面板列使用與主列不同的主題，把註冊的 command 指向獨立 config 即可：
`CORALLINE_CONFIG=~/.claude/coralline-subagent.conf bash ~/.claude/coralline/statusline.sh --subagent`。

## 安裝

在 macOS、Linux，以及具有 Bash 的 Windows 環境中，安裝流程使用 `install.sh`。
僅有 PowerShell 的 Windows 則使用下方[Windows 無 Git Bash](#windows-無-git-bash)
推薦的原生 `install.ps1` 流程。它只需要 Windows PowerShell 5.1，不需要 Bash、
Git、`jq`、WSL 或 archive 解壓工具。

> **Bash 需求：** `jq` 以及 [Nerd Font](https://www.nerdfonts.com/) 終端機字型。
> 沒有 Nerd Font 的話，在設定檔加上 `VL_ASCII=1` 改用無特殊字符的渲染。下方原生
> PowerShell renderer 不需要 `jq`。

### 請 Claude 安裝（推薦）

把這段貼進 Claude Code：

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude 會先判斷環境。可使用 Bash 時，它會執行 `install.sh`、訪談外觀偏好，並可開啟
視覺化 wizard；僅有 PowerShell 的 Windows 則執行 `install.ps1`。原生 installer
會安裝 renderer 與 themes，但不提供 wizard，也不會建立 `coralline.conf`。

如果你的 Claude 對這份 playbook 亮紅旗、想先檢查內容，那是正確的直覺而不是阻礙：
見[信任與安全](#信任與安全)。

### 自己安裝

在 Bash 終端機執行：

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

互動執行時會詢問要裝哪個版本 —— 最新的 release tag（建議）或 `main`（最新開發版）。
想略過詢問就用 `--ref` 直接指定，例如 `... | bash -s -- --ref v0.9.1` 或 `--ref main`。

### 手動安裝

```bash
git clone https://github.com/Nanako0129/coralline ~/.claude/coralline-src
mkdir -p ~/.claude/coralline/themes
cp ~/.claude/coralline-src/statusline.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/configure.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/install.sh ~/.claude/coralline/
cp ~/.claude/coralline-src/themes/claude-coral.conf ~/.claude/coralline/themes/
```

接著在 `~/.claude/settings.json` 加入：

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/coralline/statusline.sh",
    "refreshInterval": 1
  }
}
```

> **注意：** 上面的指令只複製 `claude-coral` 一個主題。「請 Claude 安裝」與一行安裝會帶上全部主題；
> 手動安裝後若要換主題，把 `~/.claude/coralline-src/themes/*.conf` 其餘的也複製進 `~/.claude/coralline/themes/`。

### Windows 無 Git Bash

`statusline.sh` 本身需要 bash，因此只有 Windows PowerShell 5.1、沒有 Git for Windows
或 WSL 的電腦無法執行它。`statusline.ps1` 是原生 Windows PowerShell 5.1 renderer，
不需要 bash 或 `jq`；只有啟用 `git`／`stash`／`project` segments 時才需要 `PATH`
中有 `git.exe`。

它會讀取 bash 版本相同的 `~/.claude/coralline.conf` 與 theme 檔。原生主列與 bash
renderer 支援相同的 segments、`pill`／`lean`／`classic` styles、
`fixed`／`auto` layouts、burn history、limit sync 與 float publication。
只有 `--subagent` 面板列協定仍限定使用 bash；`statusline.ps1 --subagent` 不會輸出內容。

以下是會跟隨開發進度的 **mutable `main`** 一行安裝指令。它先把 `main` 解析成
commit SHA，再以有上限的 `HttpWebRequest` 從該 SHA 下載 `install.ps1`，先解析語法，
最後透過絕對路徑 `$PSHOME\powershell.exe` 啟動，並傳入相同 SHA：

```powershell
& { $ErrorActionPreference='Stop';$repo='Nanako0129/coralline';$ref='main';if($repo -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9._-]{1,100}$' -or $ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Length -gt 200 -or $ref.Contains('..') -or $ref.Contains('//') -or $ref.Contains('@{') -or $ref.EndsWith('/') -or $ref.EndsWith('.') -or $ref -match '(?i)(^|/)[^/]*\.lock($|/)'){throw 'invalid Repo or Ref'};$safe={param([string]$p,[string]$label,[bool]$cmd=$false);if([string]::IsNullOrWhiteSpace($p) -or $p -match '[\x00-\x1f\x7f-\x9f]' -or $p.StartsWith('\\') -or $p.StartsWith('//') -or $p.IndexOf(':',2) -ge 0){throw "$label is not a safe local path"};$full=[IO.Path]::GetFullPath($p).Replace('/','\');$root=[IO.Path]::GetPathRoot($full);if($root -notmatch '^[A-Za-z]:\\$'){throw "$label is not on a local drive"};$drive=New-Object IO.DriveInfo($root);if($drive.DriveType -eq [IO.DriveType]::Network){throw "$label is on a network drive"};if($cmd -and ($full.Contains('"') -or $full.Contains('%') -or $full.Contains('!'))){throw "$label is not cmd-safe"};$current=$root;foreach($part in $full.Substring($root.Length).Split(@([char]'\'),[StringSplitOptions]::RemoveEmptyEntries)){$current=[IO.Path]::Combine($current,$part);$item=Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue;if($null -eq $item){break};if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw "$label contains a reparse point"}};if($full.Length -gt $root.Length){$full=$full.TrimEnd('\')};return $full};$fetch={param([uri]$uri,[long]$cap,[string]$label);if($uri.Scheme -cne 'https' -or ($uri.Host -cne 'api.github.com' -and $uri.Host -cne 'raw.githubusercontent.com') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw "unexpected $label URI"};$request=[Net.HttpWebRequest]::Create($uri);$request.Method='GET';$request.AllowAutoRedirect=$false;$request.Timeout=15000;$request.ReadWriteTimeout=15000;$request.UserAgent='coralline-bootstrap';$response=$null;try{$response=[Net.HttpWebResponse]$request.GetResponse();if($response.StatusCode -ne [Net.HttpStatusCode]::OK -or $response.ResponseUri.AbsoluteUri -cne $uri.AbsoluteUri){throw "$label request failed or redirected"};if($response.ContentLength -gt $cap){throw "$label Content-Length exceeds limit"};$input=$response.GetResponseStream();$memory=New-Object IO.MemoryStream;try{$buffer=New-Object byte[] 8192;$total=0L;while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$read;if($total -gt $cap){throw "$label stream exceeds limit"};$memory.Write($buffer,0,$read)};if($response.ContentLength -ge 0 -and $total -ne $response.ContentLength){throw "$label download was truncated"};return ,$memory.ToArray()}finally{if($null -ne $input){$input.Dispose()};$memory.Dispose()}}finally{if($null -ne $response){$response.Dispose()}}};$old=[Net.ServicePointManager]::SecurityProtocol;$tmp=$null;$made=$false;$code=0;try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$parts=$repo.Split('/');$commit=$ref;if($commit -cnotmatch '^[0-9a-f]{40}$'){$api=[uri]('https://api.github.com/repos/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/commits/'+[uri]::EscapeDataString($ref));$strict=New-Object Text.UTF8Encoding($false,$true);try{$payload=$strict.GetString((& $fetch $api 1MB 'commit resolution'))|ConvertFrom-Json}catch{throw ('commit resolution response is invalid: '+$_.Exception.Message)};if($null -eq $payload -or $payload.PSObject.Properties.Name -notcontains 'sha'){throw 'commit resolution response has no sha'};$commit=[string]$payload.sha;if($commit -cnotmatch '^[0-9a-f]{40}$'){throw 'commit resolution returned an invalid sha'}};$uri=[uri]('https://raw.githubusercontent.com/'+[uri]::EscapeDataString($parts[0])+'/'+[uri]::EscapeDataString($parts[1])+'/'+$commit+'/install.ps1');$bytes=& $fetch $uri 1MB 'installer';$tempRoot=& $safe ([IO.Path]::GetTempPath()) 'TEMP';$tmp=& $safe ([IO.Path]::Combine($tempRoot,('coralline-install-'+[guid]::NewGuid().ToString('N')+'.ps1'))) 'installer temp';$output=[IO.File]::Open($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$made=$true;try{$output.Write($bytes,0,$bytes.Length);$output.Flush($true)}finally{$output.Dispose()};$checked=& $safe $tmp 'downloaded installer';if($checked -cne $tmp){throw 'installer temp identity changed'};$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($tmp,[ref]$tokens,[ref]$errors);if($errors.Count -ne 0){throw ('downloaded installer parse failed: '+$errors[0].Message)};$exe=& $safe ([IO.Path]::Combine($PSHOME,'powershell.exe')) 'PowerShell executable' $true;if(-not [IO.File]::Exists($exe)){throw 'trusted powershell.exe is missing'};$psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$exe;$psi.UseShellExecute=$false;$psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$tmp+'" -Repo "'+$repo+'" -Ref "'+$commit+'"';$process=New-Object Diagnostics.Process;$process.StartInfo=$psi;try{if(-not $process.Start()){throw 'installer child did not start'};$process.WaitForExit();$code=$process.ExitCode}finally{$process.Dispose()}}finally{[Net.ServicePointManager]::SecurityProtocol=$old;if($made -and $null -ne $tmp -and [IO.File]::Exists($tmp)){$checked=& $safe $tmp 'installer cleanup';if($checked -cne $tmp){throw 'refusing unexpected cleanup path'};$item=Get-Item -LiteralPath $tmp -Force;if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'refusing reparse-point cleanup'};[IO.File]::Delete($tmp)}};if($code -ne 0){exit $code} }
```

若要安裝已稽核的 release 或 commit，複製同一行，只把 `$ref='main'` 改成
`$ref='AUDITED_TAG_OR_40_CHARACTER_COMMIT_SHA'`。tag 代表具名 release，但技術上仍可
被移動；只有已稽核的 40 字元 commit SHA 能讓 bootstrap URL 不可變。無論選哪一種，
bootstrap 都會在下載可執行程式碼前先解析可變名稱或 tag，再由 installer 從同一個
commit 下載全部受管理檔案。

`install.ps1` 會安裝 `statusline.ps1` 與全部十個 themes，並只對
`$HOME\.claude\settings.json` 最上層、大小寫完全相符的 `statusLine` 做無損合併。
`$HOME\.claude\coralline.conf` 會逐 byte 保留，而且 installer 永遠不會建立它。
受管理的 runtime 或 settings 確實變更時，舊版本會保留為帶時間戳的同層備份。
Installer 會序列化執行。單檔 runtime rollback 不會覆寫同時發生的編輯，並會保留
被移出的 installer bytes；多檔 rollback 會 fail closed，保留現有檔案與備份供手動
復原。Installer 會在回報成功前重新逐 byte 檢查 11 個檔案。
Atomic settings backup 就是實際被移出的檔案，因此即使 editor 的 open handle 在
replace 後才寫入，內容仍會進入保留的備份，不會遺失。Installer 在 commit 期間
觀察到衝突時會回報失敗，不會覆寫外部內容。

更新時重跑同一行即可。內容完全相同時會是 true no-op：不替換受管理檔案、不重寫
settings、不建立備份，也不改 timestamp。PowerShell-only 安裝不含 wizard；請沿用既有
`coralline.conf`，或自行手動編輯。

若一行 bootstrap 無法執行，請在瀏覽器下載 GitHub source archive、先檢查內容並解壓到
本機，再以零網路的 local mode 執行：

```powershell
& "$PSHOME\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\path\to\coralline\install.ps1 -SourceDirectory C:\path\to\coralline -InstallRoot "$HOME\.claude\coralline" -SettingsPath "$HOME\.claude\settings.json"
```

可以沿用 bash wizard 已寫好的設定，或參考 `themes/` 內任一檔案手動建立
`~/.claude/coralline.conf`。per-process `ExecutionPolicy Bypass` 讓未簽章的本機
renderer 在一般 session 預設為 `Restricted` 時仍能啟動；它不會修改任何持久化 policy，
且強制套用的 Group Policy 仍具有最高優先權。

### 更新

下方兩種 installer 流程用於更新 Bash 安裝。無論哪種，你的 `~/.claude/coralline.conf`
都會被保留，舊的 `statusline.sh` 會備份在 `~/.claude/coralline/` 下（保留最近 3 份）。

#### 僅 PowerShell 的更新方式

重新執行 [Windows 無 Git Bash](#windows-無-git-bash)的原生一行指令，並使用相同的
`Repo` 與 `Ref`。只有受管理檔案 byte 不同時才會個別 atomic replace，只有 managed
settings 值不同時才會合併；變更時保留帶時間戳備份，而且永遠不碰
`~/.claude/coralline.conf`。runtime 目錄下既有的非受管理檔案，包括 burn／limit
history、`float.txt` 與自訂 themes，都會留在原位，不會進入 replacement transaction。

#### 請 Claude 更新（推薦）

把這段貼進 Claude Code：

```text
Please update coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/UPGRADE.md
and follow the playbook in it.
```

Claude 會重跑 installer、讀取「new since your installed copy」報告，並主動問你要不要開啟新出現的 opt-in 功能。

#### 自己更新

重跑 installer —— 有新東西時它會印出一段簡短的「new since your installed copy」報告：

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only
```

## 信任與安全

「請 Claude 安裝」本質上是一份遠端文件，指示 AI 執行 `curl | bash` 並修改
`~/.claude/settings.json`。這個形狀和 prompt-injection 攻擊一模一樣，所以你的 Claude
如果先亮紅旗、要求檢查，那是它運作正常，不是故障。回應這種懷疑的方式是檢驗，不是信任：

- **先讀會執行的東西。** 全部都在這個 repo 裡。Bash 環境使用
  [install.sh](./install.sh)，僅有 PowerShell 的 Windows 使用
  [install.ps1](./install.ps1)，[INSTALL.md](./INSTALL.md) 負責替 AI 判斷路徑。
  PowerShell bootstrap 不是 `irm | iex`：它會限制下載大小、先解析暫存 installer，
  再把它當檔案啟動。
- **釘選版本。** `... | bash -s -- --ref v0.9.1` 安裝打過 tag 的 release 而非 `main`，
  你審過的就是你跑的。互動式安裝本來就預設建議最新 tag。
- **確切會寫入什麼：** Bash 流程會依前述規則寫入 runtime、經你同意的 config 與
  Claude settings。原生 installer 只會在 `~/.claude/coralline` 寫入
  `statusline.ps1` 與十個 themes，並更新 `settings.json` 最上層完全相符的
  `statusLine` 值。它不建立或修改 `coralline.conf`，也不寫
  `subagentStatusLine`。既有 runtime/settings 有變更時會留下同層時間戳備份。
- **裝完之後跑的是什麼：** 每次 prompt 會執行註冊的 Bash 或 PowerShell renderer，
  runtime 都不會發出網路請求。原生命令會引用絕對路徑的可信
  `$PSHOME\powershell.exe` 與 renderer，不會從 workspace 搜尋 `powershell.exe`。
- **INSTALL.md 為什麼對 AI 說話：** 人類走視覺化精靈、AI 走訪談腳本，所以 playbook 對
  「實際執行它的讀者」說話。一份開頭就對你的 AI 下指令的文件本來就該被檢視，這正是它
  引用的每個檔案都放在這個 repo、讓你們倆都能先讀的原因。

### 移除

若環境可使用 Bash，請先移除 subagent 列主題，再刪除工具：

```bash
bash ~/.claude/coralline/configure.sh --subagent-rows=off
rm -rf ~/.claude/coralline ~/.claude/coralline.conf
```

然後把 `~/.claude/settings.json` 裡的 `statusLine` 區塊刪掉（或還原最新的
`settings.json.bak.*`）。若略過第一個指令，也要一併刪除 `subagentStatusLine`。

若是僅有 PowerShell 的原生 archive 安裝，先關閉 Claude Code 並備份設定檔：

```powershell
$settings = Join-Path $HOME '.claude\settings.json'
Copy-Item -LiteralPath $settings -Destination "$settings.bak.$(Get-Date -Format yyyyMMddHHmmss)"
notepad.exe $settings
```

在記事本中刪除 command 指向 `~/.claude/coralline/statusline.ps1` 的 `statusLine`
物件。若 `subagentStatusLine` 的 command 也指向 coralline，請一併刪除，並確認存檔後
仍是有效 JSON。最後移除已安裝的 runtime 與選用設定檔：

```powershell
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline') -Recurse -Force
Remove-Item -LiteralPath (Join-Path $HOME '.claude\coralline.conf') -Force -ErrorAction SilentlyContinue
```

## 設定

兩種 Bash 設定方式都使用同一支 installer。人類不帶模式參數執行時會進入視覺化設定；
Claude 則使用 `--install-only` bootstrap，接著依照 `INSTALL.md` 訪談並寫入設定。
原生 PowerShell installer 沒有 wizard，而且永遠不寫 config；它讀取同一份
`coralline.conf`，可沿用既有 Bash 設定或手動建立。

### 設定模式

| 模式 | 適合情境 |
|---|---|
| 預設 | 想直接使用 coralline 預設外觀 |
| Powerlevel10k import | 已經有 `~/.p10k.zsh`，想帶入 style、時間格式與主要色彩 |
| 視覺化 wizard | 想先預覽 theme、style、segments、折行、時鐘與字型相容性 |

自己直接執行 installer、不帶模式參數時，會開啟互動式設定。除非你明確要求視覺化自訂，
Claude 不需要操作這個人類 TUI。

### 重新設定

兩種 Bash 安裝方式都會把 wizard 複製到 `~/.claude/coralline`，所以有 Bash 的環境可隨時
重跑來重新調整外觀：

```bash
bash ~/.claude/coralline/configure.sh
```

PowerShell-only 安裝不含原生 wizard。請先備份再手動編輯
`$HOME\.claude\coralline.conf`，或沿用在有 Bash 的環境產生的設定。

### 測試 fork

讓 installer 指向同一個 fork：

```bash
curl -fsSL https://raw.githubusercontent.com/YOU/coralline/main/install.sh | bash -s -- --repo YOU/coralline
```

僅有 PowerShell 的 Windows，請同時修改原生 bootstrap 內的 `$repo` 與 `$ref`。
bootstrap 會驗證兩者、在下載 `install.ps1` 前解析可變 Ref，再把得到的 commit SHA
傳給 installer，下載固定的 runtime allowlist。

## 設定檔

所有設定都在 `~/.claude/coralline.conf`（純 bash，由腳本 source 進來）：

| 變數 | 預設值 | 說明 |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`：powerline 膠囊 · `lean`：純色文字 · `classic`：文字鋪在統一深色橫條上(p10k classic) |
| `VL_LAYOUT` | `fixed` | `fixed`：每個 `VL_SEGMENTS*` 變數固定一行 · `auto`：響應式 |
| `VL_MAX_LINES` | `3` | 僅 `auto`——最多折成幾行（`1` = 永不折行） |
| `VL_WRAP_MARGIN` | `4` | 僅 `auto`——右側預留的欄數，避免 segment 貼到視窗邊緣 |
| `VL_SEGMENTS` | `dir git model ctx limit5h limit7d cost clock` | 第一行的區段與順序（`auto` 模式下為完整清單） |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | （空） | 僅 `fixed`——可選的第二、三行 |
| `VL_CLOCK` | `12h` | `12h` / `24h` / `off` |
| `VL_CLOCK_SECONDS` | `1` | 時鐘是否顯示秒數 |
| `VL_BAR_WIDTH` | `5` | 量表寬度（格數） |
| `VL_BAR_FILL` / `VL_BAR_EMPTY` | `▰` / `▱` | 量表字符 |
| `VL_CTX_GLYPH` | `⬡` | `ctx` 區段的字符 |
| `VL_PROJECT_GLYPH` | `⬢` | `project` 區段的字符 |
| `VL_PATH_DEPTH` | `4` | 路徑超過此深度即摺疊 |
| `VL_NAME_MAX` | `0` | `project` / `git` 名稱超過此字數即以 `…` 截斷（`0` = 關閉） |
| `VL_COST_DECIMALS` | `2` | 費用顯示的小數位數 |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | 量表變色門檻 |
| `VL_ASCII` | `0` | 設為 `1` 停用 Nerd Font 字符 |
| `VL_RUNTIME_PROBE` | `0` | `node` / `python`：設為 `1` 時，若無 pin 檔則改用 `PATH` 上的 `node` / `python3` 偵測（每次繪製會 fork） |
| `VL_BG_*` / `VL_FG_*` | 依主題 | 顏色——256 色編號或 `"R,G,B"` |

上述四個字符設定（`VL_BAR_FILL`、`VL_BAR_EMPTY`、`VL_CTX_GLYPH`、`VL_PROJECT_GLYPH`）
屬於一般 Unicode，並非 Nerd Font 圖示，因此 Nerd Fonts 不會補進字型；
若你的字型沒有這些字，替代就交給終端機自己的 fallback 決定。一旦替代字寬於一格，整列
就會被推歪——量表擠成一團，或百分比前面的空格被吃掉。此時請改成終端機字型確實具備的字符。
`▪` / `▫`（量表）與 `◔`（`ctx`）在 Meslo 與 JetBrainsMono Nerd Font 中都存在且剛好一格寬：

```sh
VL_BAR_FILL="▪" ; VL_BAR_EMPTY="▫" ; VL_CTX_GLYPH="◔"
```

### 消耗率區段

![burn 區段在完整狀態列中的樣子，以及各種狀態](./assets/burn-segment.png)

預設關閉。把 `burn` 加入 `VL_SEGMENTS` 即可顯示「到期倒數」—— 根據最近燒耗率推算，
到達限額上限（5h 或 7d）還剩多久，例如 `↗ 5h ⇢ 1h58m`。相關鍵：`CORALLINE_BURN_WINDOW`
（近期斜率回溯長度，預設 600s）、`VL_BURN_GLYPH`（預設 `↗`）、`VL_BG_BURN`（預設用 5h
的背景色）。只要 `burn` 在區段清單裡，coralline 就會寫入樣本到
`~/.claude/coralline/burn-5h.tsv`；從清單移除後便不再寫入任何檔案。

ETA 會依「相對於視窗重置的急迫度」上色，當數字本身已無意義時則收斂成一個符號：

| 你看到 | 代表 |
|---|---|
| `↗ 5h ⇢ 1h58m` **紅** | 會在視窗重置*之前*就耗盡 |
| `↗ 5h ⇢ 1h58m` **黃** | 重置與耗盡時間很接近 |
| `↗ 5h ⇢ 1h58m` **綠** | 能從容趕在重置前，還有餘裕 |
| **亮綠** `↗ ✓` | 照這個速度，就算從全新視窗開始也燒不完一輪——`24d15h` 這種數字純屬噪音 |
| **暗淡** `↗ ✓` | idle：已停止消耗，手上沒有進行中的負載 |
| **暗淡** `↗ …` | 暖機中：冷啟動還沒有樣本（刻意*不用*綠勾，免得全新安裝看起來一切健康） |

標籤會告訴你目前由哪道限額綁定 —— 取 `5h`／`7d` 中最快撞到 100% 的那一個。
`5h` 只有在你燒得夠兇、最近視窗內出現至少兩次整數 % 跨越時才會出現；在輕度或穩定的
步調下沒有可擬合的短期斜率，於是改由 7d 推算綁定，顯示 `↗ 7d`。

### 跨 session 額度同步（選用）

`VL_LIMIT_SYNC=1` 會讓 `limit5h`／`limit7d` 顯示「你任一 session 看過的最新額度值」，而不是只看當前 session 自己的快照。每次 render 會把 `5h`／`7d` 的值寫進一個每台主機共用的 store（`limit-5h.d`、`limit-7d.d` 目錄），區段則顯示當前視窗中記錄到的最大百分比。預設關閉。

之所以需要它，是因為 Claude Code 只在某個 session 有活動時才會重畫它的狀態列，而傳進來的額度數字是該 session 最後一次看到的值。所以閒置的 session 會顯示偏舊、彼此不一致的百分比。開啟同步後，每個 session 在下次重畫時就會收斂到目前已知的最新值。

> **它只在重畫時更新。** 完全沒在重畫的 session 救不了，而且「已知最新」也只到你最近活躍的那個 session 看到的值。coralline 沒有 API 存取，所以它只能縮小 session 之間的落差，沒辦法讓一個完全閒置的 bar 變即時。

單 session 使用者用不到（只有一份快照），所以維持選用。

### 響應式版面

設定 `VL_LAYOUT="auto"` 後，視窗夠寬時整條維持單行，變窄時以貪婪法折行，
最多折成 `VL_MAX_LINES` 行。達到行數上限後，剩餘區段會溢出在最後一行。
`VL_WRAP_MARGIN` 會在右側預留幾欄空間，讓折行後的內容不貼到視窗邊緣——
若你的終端機有額外 padding，可以把它調大。

寬度來自 `$COLUMNS`。Claude Code v2.1.153+ 會在執行 statusline 前把 `COLUMNS`
設成當前終端寬度，所以折行會隨視窗縮放自動反應、開箱即用。在 Claude Code 以外，
腳本會退而用控制終端機的 `stty size`；兩者都拿不到時保持單行。

```text
wide window:    ~/dev/app  ⎇ main  ◆ Fable 5  ⬡ ▰▰▰▱▱ 62%  5h ▰▰▱▱▱ 41%  $1.23  ⊙ 14:45

narrow window:  ~/dev/app  ⎇ main  ◆ Fable 5
                ⬡ ▰▰▰▱▱ 62%  5h ▰▰▱▱▱ 41%  $1.23  ⊙ 14:45
```

偏好完全固定的版面就維持 `VL_LAYOUT="fixed"`，
用 `VL_SEGMENTS` / `VL_SEGMENTS2` / `VL_SEGMENTS3` 釘住每一行。

### Lean 風格

偏好 Powerlevel10k 的 *lean* 簡潔路線——不要背景、只要純色文字？設定
`VL_STYLE="lean"`，每個區段的 `VL_BG_*` 顏色就會變成它的文字強調色：

![Lean 風格與 pill 風格對照](./assets/style-lean.png)

| 變數 | 預設值 | 說明 |
|---|---|---|
| `VL_STYLE` | `pill` | 設為 `lean` 切換成簡潔風格 |
| `VL_LEAN_SEP` | （空） | 區段之間的額外分隔字串，例如 `·` |
| `VL_LEAN_FG` | （空） | 強制指定文字色；留空 = 繼承各區段的強調色 |
| `VL_LEAN_BG` | （空） | 在整列後面鋪一層統一背景——`"R,G,B"` 或 256 色碼。想要完整的 p10k *classic* 外觀，建議直接用下方的 `VL_STYLE="classic"` preset，它會幫你接好這個 |
| `VL_LEAN_CAP_R` | （空） | 收尾字元，用 `VL_LEAN_BG` 的顏色畫出，把橫條尾端斜切收進終端（p10k 的尾端分隔，例如 `$''`）；需搭配 `VL_LEAN_BG` |
| `VL_LEAN_CAP_L` | （空） | 起始截角字元——`VL_LEAN_CAP_R` 在 bar 開頭的左向鏡像（例如 `$''`）；需搭配 `VL_LEAN_BG`。stock p10k *classic* 左端保持平的 |

> **提示：** 本來就是 p10k 使用者？跟 AI 安裝員或視覺化 wizard 說要匯入
> `~/.p10k.zsh`，它會在你同意後帶入風格、配色與時間格式。詳見
> [INSTALL.md 的 AI interview](./INSTALL.md#ai-interview)。

### Classic 風格

想要 Powerlevel10k 原廠的 *classic* 提示列——一條統一的深色橫條、彩色文字、
尾端一個實心截角？設定 `VL_STYLE="classic"`。這是一鍵預設：它以 `lean` 的方式
把文字畫在深色橫條上（p10k 的 `POWERLEVEL9K_BACKGROUND`），並加上尾端的
powerline 截角，不需要其他設定。

![Classic 風格](./assets/style-classic.png)

| 變數 | 預設值 | 說明 |
|---|---|---|
| `VL_STYLE` | `pill` | 設為 `classic` 切換成 p10k 深色橫條外觀 |
| `VL_BG_BAR` | （空 → `238`） | 整列後面那條橫條的顏色——`"R,G,B"` 或 256 色碼。任何主題的配色都會鋪在這條橫條上；灰階配色（例如 `mono`）建議明確設定 `VL_BG_BAR` 以拉開對比 |

底層上 `classic` 就是 `lean` 加上一個 `VL_LEAN_BG`（來自 `VL_BG_BAR`）與一個
`VL_LEAN_CAP_R` 尾端截角，所以你若明確指定 `VL_LEAN_BG` 或截角仍會蓋過預設。
匯入 p10k *classic* 設定時，會帶入你原本的橫條顏色與分隔字元。

## 主題

| | |
|---|---|
| **`claude-coral`** — 鋼藍 · 木槿紫 · Claude 珊瑚紅（預設）<br>![claude-coral 主題預覽](./assets/theme-claude-coral.png) | **`catppuccin-mocha`** — 深底粉彩<br>![catppuccin-mocha 主題預覽](./assets/theme-catppuccin-mocha.png) |
| **`nord`** — 北極冷霜<br>![nord 主題預覽](./assets/theme-nord.png) | **`gruvbox-dark`** — 溫暖復古<br>![gruvbox-dark 主題預覽](./assets/theme-gruvbox-dark.png) |
| **`tokyo-night`** — 深藍霓虹<br>![tokyo-night 主題預覽](./assets/theme-tokyo-night.png) | **`mono`** — 灰階極簡<br>![mono 主題預覽](./assets/theme-mono.png) |
| **`dracula`** — 青 · 粉 · 紫，Dracula 暗炭底<br>![dracula 主題預覽](./assets/theme-dracula.png) | **`lunar-pink`** — 粉 · 青 · 黃，近黑底<br>![lunar-pink 主題預覽](./assets/theme-lunar-pink.png) |
| **`reverie`** — 柔粉彩 · 暖深底配梅紫文字<br>![reverie 主題預覽](./assets/theme-reverie.png) | **`morning-haze`** — 霧霾藍紫 · 鼠尾草 · 砂岩，板岩深底<br>![morning-haze 主題預覽](./assets/theme-morning-haze.png) |

主題就只是一個指定 `VL_BG_*` / `VL_FG_*` 的 `.conf` 檔——複製一份、改顏色、
在 `coralline.conf` 裡改 source 你的版本即可。歡迎發 PR 貢獻新主題。
wizard 會自動掃描 `themes/*.conf` 與 `themes/best-themes/*.conf` 這類巢狀集合，
新增主題檔時不需要修改 `configure.sh`。

> **要貢獻新主題？** 複製一份現有 `.conf`，設好所有 `VL_BG_*` / `VL_FG_*`（含
> `VL_BG_EFFORT`；`VL_BG_BAR` 選用——只有灰階配色需要它來讓 classic 橫條可讀），
> 保留檔尾的 `_VL_SUB_*` 區塊（面板列的候選顏色，加上 `_VL_SUB_FP` 指紋——當某份
> config 在 source 你的主題之後又改動色盤時，靠它安全退回），
> 把名稱加進 [`tools/render-screenshots.py`](./tools/render-screenshots.py)
> 的 `THEMES` 清單，重跑產生 `assets/theme-<名稱>.png`，再到上方表格加一列。請**不要重產
> `hero.png`** —— 它是固定展示最初六個主題的招牌圖、不是完整目錄。

## 平台支援

| 平台 | 狀態 |
|---|---|
| macOS | ✅ 支援（內建 bash 3.2 即可） |
| Linux | ✅ 支援 |
| Windows + Git Bash | ✅ 支援——有裝 Git Bash 時，Claude Code 會用它執行 statusline |
| Windows 無 Git Bash | ✅ 原生 Windows PowerShell 5.1 支援主列 |

> **Windows 提醒：** 原生 PowerShell renderer 不需要 Git Bash 或 `jq`。`git.exe`
> 是選用項目，只用來啟用 `git`、`stash`、`project` segments。互動式 wizard 與套用
> theme 的 `--subagent` 列仍限定使用 bash。

## 為什麼很快

statusline 就是一支本地 shell 腳本：完全不打網路、不呼叫任何 API、不消耗任何 token。
Claude Code 只是把 session 的 JSON 從 stdin 餵給它，再顯示它印出的內容。

它每秒執行一次（`refreshInterval: 1`），所以腳本在 CPU 上必須夠便宜：
單次 `jq` 呼叫一口氣取出所有欄位，單次 `git status --porcelain=v2 --branch`
同時拿到分支、檔案狀態與領先/落後數。不依賴 `bc`，也沒有逐欄位的子程序開銷。
macOS 內建的 bash 3.2 和任何 Linux bash 都能跑。

## 致敬與致謝

coralline 的視覺語言——膠囊化的區段、powerline 轉場、git 的 `⇡⇣` 符號、
隨用量變色的量表——是對 [@romkatv](https://github.com/romkatv) 的
[Powerlevel10k](https://github.com/romkatv/powerlevel10k) 的致敬之作，
它定義了「又快又美的 prompt」應有的樣子。也感謝開創這一切的
[powerline](https://github.com/powerline/powerline) 系譜，以及讓膠囊外型成為可能的
[Nerd Fonts](https://www.nerdfonts.com/)。

至於名稱：珊瑚藻（coralline algae）以一層層纖薄的色彩堆出礁岩——
而 **coral·line** 正是這個專案的本體：一條 Claude 珊瑚色的線。

## 授權

[MIT](./LICENSE)
