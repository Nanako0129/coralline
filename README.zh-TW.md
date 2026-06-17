# coralline

> 給 Claude Code 用、向 [Powerlevel10k](https://github.com/romkatv/powerlevel10k) 致敬的
> statusline，特色是人類與 AI 共用同一個 installer 入口：你可以直接跑，也可以交給
> Claude 幫你跑完設定。

[English README](./README.md)

![六種 coralline 主題總覽](./assets/hero.png)

## 請 Claude 安裝

把這段貼進 Claude Code：

```text
Please install coralline for me:
fetch https://raw.githubusercontent.com/Nanako0129/coralline/main/INSTALL.md
and follow the playbook in it.
```

Claude 會先讀 playbook，再用同一支 installer bootstrap runtime、訪談你的外觀偏好、
寫入設定並驗證，最後提醒你如果不滿意可以自己重新開啟視覺化 wizard。

## 自己安裝

在終端機執行：

```bash
curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
```

## 設定選項

兩種方式都使用同一支 installer。人類不帶模式參數執行時會進入視覺化設定；
Claude 則使用 `--install-only` bootstrap，接著依照 `INSTALL.md` 訪談並寫入設定。

| 模式 | 適合情境 |
|---|---|
| 預設 | 想直接使用 coralline 預設外觀 |
| Powerlevel10k import | 已經有 `~/.p10k.zsh`，想帶入 style、時間格式與主要色彩 |
| 視覺化 wizard | 想先預覽 theme、style、segments、折行、時鐘與字型相容性 |

自己直接執行 installer、不帶模式參數時，會開啟互動式設定。除非你明確要求視覺化自訂，
Claude 不需要操作這個人類 TUI。

之後要重新調整外觀可以跑：

```bash
bash ~/.claude/coralline/configure.sh
```

測試 fork 時，可以讓 installer 指向同一個 fork：

```bash
curl -fsSL https://raw.githubusercontent.com/miyago9267/coralline/main/install.sh | bash -s -- --repo miyago9267/coralline
```

## 效果

```text
╭ ~/side-project/coralline  ⎇ main+!  ◆ Fable 5  ψ high  ⬡ ▰▰▰▱▱ 62% ↑1.2M ↓45.6k  5h ▰▰▱▱▱ 41% ↺2h44m  $1.23  ⊙ 02:45 pm ╮
```

| 區段 | 顯示內容 |
|---|---|
| `dir` | 目前目錄，過長路徑摺疊為 `~/a/…/z` |
| `project` | repo 名稱（`⬢`），在所有 worktree 都相同；非 git repo 時隱藏 |
| `git` | 分支、已暫存 `+` / 已修改 `!` / 未追蹤 `?`、領先 `⇡` 落後 `⇣` |
| `model` | 目前使用的 Claude 模型 |
| `ctx` | context window 量表、輸入/輸出/快取 token 數 |
| `limit5h` / `limit7d` | 用量限額量表與重置倒數 |
| `cost` | 本次 session 花費（USD） |
| `clock` | 時鐘，12 或 24 小時制 |
| `lines` | 本次 session 修改行數 |
| `style` | 目前的 output style |
| `duration` | session 經過時間 |
| `effort` | 推理強度（`ψ`）—— `low` / `med` / `high` / `xhigh` / `max` |
| `stash` | git stash 數量 |

量表會隨用量變色：綠色 → 50% 轉黃 → 75% 轉紅（門檻可調）。

## 為什麼很快

statusline 就是一支本地 shell 腳本：完全不打網路、不呼叫任何 API、不消耗任何 token。
Claude Code 只是把 session 的 JSON 從 stdin 餵給它，再顯示它印出的內容。

它每秒執行一次（`refreshInterval: 1`），所以腳本在 CPU 上必須夠便宜：
單次 `jq` 呼叫一口氣取出所有欄位，單次 `git status --porcelain=v2 --branch`
同時拿到分支、檔案狀態與領先/落後數。不依賴 `bc`，也沒有逐欄位的子程序開銷。
macOS 內建的 bash 3.2 和任何 Linux bash 都能跑。

## 手動安裝

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

> **注意：** 需要 `jq` 以及 [Nerd Font](https://www.nerdfonts.com/) 終端機字型。
> 沒有 Nerd Font 的話，在設定檔加上 `VL_ASCII=1` 改用無特殊字符的渲染。

### 平台支援

| 平台 | 狀態 |
|---|---|
| macOS | ✅ 支援（內建 bash 3.2 即可） |
| Linux | ✅ 支援 |
| Windows + Git Bash | ✅ 支援——有裝 Git Bash 時，Claude Code 會用它執行 statusline |
| Windows 無 Git Bash | ❌ 暫不支援——Claude Code 會退回 PowerShell，跑不了 bash 腳本（[roadmap](https://github.com/Nanako0129/coralline/issues)） |

> **Windows 提醒：** 裝 [Git for Windows](https://git-scm.com/download/win)（內含 Git Bash）和 `jq`，
> coralline 即可原生運作。給「無 Git Bash」情境的原生 PowerShell 版本列在 roadmap 上。渲染流程
> 特意設計成在 Git Bash 模擬的 `fork()` 下仍便宜——一個 `jq`、一個 `git`，沒有逐欄位的子程序開銷。

## 設定

所有設定都在 `~/.claude/coralline.conf`（純 bash，由腳本 source 進來）：

| 變數 | 預設值 | 說明 |
|---|---|---|
| `VL_STYLE` | `pill` | `pill`：powerline 膠囊 · `lean`：p10k lean 的純色文字風格 |
| `VL_LAYOUT` | `fixed` | `fixed`：每個 `VL_SEGMENTS*` 變數固定一行 · `auto`：響應式 |
| `VL_MAX_LINES` | `3` | 僅 `auto`——最多折成幾行（`1` = 永不折行） |
| `VL_WRAP_MARGIN` | `4` | 僅 `auto`——右側預留的欄數，避免 segment 貼到視窗邊緣 |
| `VL_SEGMENTS` | `dir git model ctx limit5h limit7d cost clock` | 第一行的區段與順序（`auto` 模式下為完整清單） |
| `VL_SEGMENTS2` / `VL_SEGMENTS3` | （空） | 僅 `fixed`——可選的第二、三行 |
| `VL_CLOCK` | `12h` | `12h` / `24h` / `off` |
| `VL_CLOCK_SECONDS` | `1` | 時鐘是否顯示秒數 |
| `VL_BAR_WIDTH` | `5` | 量表寬度（格數） |
| `VL_PATH_DEPTH` | `4` | 路徑超過此深度即摺疊 |
| `VL_NAME_MAX` | `0` | `project` / `git` 名稱超過此字數即以 `…` 截斷（`0` = 關閉） |
| `VL_COST_DECIMALS` | `2` | 費用顯示的小數位數 |
| `VL_WARN_PCT` / `VL_HOT_PCT` | `50` / `75` | 量表變色門檻 |
| `VL_ASCII` | `0` | 設為 `1` 停用 Nerd Font 字符 |
| `VL_BG_*` / `VL_FG_*` | 依主題 | 顏色——256 色編號或 `"R,G,B"` |

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

> **提示：** 本來就是 p10k 使用者？跟 AI 安裝員或視覺化 wizard 說要匯入
> `~/.p10k.zsh`，它會在你同意後帶入風格、配色與時間格式。詳見
> [INSTALL.md 的 AI interview](./INSTALL.md#ai-interview)。

## 主題

| | |
|---|---|
| **`claude-coral`** — 鋼藍 · 木槿紫 · Claude 珊瑚紅（預設）<br>![claude-coral 主題預覽](./assets/theme-claude-coral.png) | **`catppuccin-mocha`** — 深底粉彩<br>![catppuccin-mocha 主題預覽](./assets/theme-catppuccin-mocha.png) |
| **`nord`** — 北極冷霜<br>![nord 主題預覽](./assets/theme-nord.png) | **`gruvbox-dark`** — 溫暖復古<br>![gruvbox-dark 主題預覽](./assets/theme-gruvbox-dark.png) |
| **`tokyo-night`** — 深藍霓虹<br>![tokyo-night 主題預覽](./assets/theme-tokyo-night.png) | **`mono`** — 灰階極簡<br>![mono 主題預覽](./assets/theme-mono.png) |
| **`dracula`** — 青 · 粉 · 紫，Dracula 暗炭底<br>![dracula 主題預覽](./assets/theme-dracula.png) | **`lunar-pink`** — 粉 · 青 · 黃，近黑底<br>![lunar-pink 主題預覽](./assets/theme-lunar-pink.png) |

主題就只是一個指定 `VL_BG_*` / `VL_FG_*` 的 `.conf` 檔——複製一份、改顏色、
在 `coralline.conf` 裡改 source 你的版本即可。歡迎發 PR 貢獻新主題。

> **要貢獻新主題？** 複製一份現有 `.conf`，設好所有 `VL_BG_*` / `VL_FG_*`（含
> `VL_BG_EFFORT`），把名稱加進 [`tools/render-screenshots.py`](./tools/render-screenshots.py)
> 的 `THEMES` 清單，重跑產生 `assets/theme-<名稱>.png`，再到上方表格加一列。請**不要重產
> `hero.png`** —— 它是固定展示最初六個主題的招牌圖、不是完整目錄。

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
