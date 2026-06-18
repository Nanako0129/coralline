# Spec — `burn` segment (token burn-rate → range-to-empty)

- **Date:** 2026-06-18
- **Status:** Design approved, pending spec review
- **Author:** brainstormed with Claude
- **Relates:** reuses the same "persist parsed state across renders" idea explored in
  the iTerm2 float spec, but with its own minimal append-only sample file.

## Goal

Show, in a compact opt-in statusline segment, **how long until you hit the rate limit
that bites first** — a fuel-gauge "range to empty" for whichever of the 5h / 7d windows
will exhaust soonest, labelled so you know which, e.g. `↗5h ⇢1h58m` or `↗7d ⇢14h`.

The car analogy that seeded this: the dashboard already shows the fuel level and a
clock; what it lacks is *consumption → remaining range*, **and** which tank runs dry
first. That binding range is the one number this feature adds.

The two windows use the lens each one actually needs (see Estimator): the **5h** range
is driven by your **recent** burn (fast window, bursts matter), the **7d** range by the
**multi-day average** (slow window, recent 10-min slope is unmeasurable and irrelevant).
The segment surfaces `min(ETA_5h, ETA_7d)`.

## Background: what the live spike established (load-bearing)

This design followed a live spike against real Claude Code data. The findings are
load-bearing and are recorded here because they killed earlier approaches:

1. **A stateless "average since window start" mode adds zero information _for 5h_.** If
   you compute `rate = used% / elapsed` and project `ETA = elapsed × (100−used%)/used%`,
   every input (`used%`, and `elapsed = 5h − time_to_reset`) is *already on screen* in
   the existing `limit5h` segment. The projection is pure arithmetic on two visible
   numbers — it tells you nothing new for 5h. The only 5h quantity not already visible
   is the **recent slope**, which can diverge sharply from the average (idle for hours,
   then burst). So 5h uses *exclusively* the recent-rate path. **Note the asymmetry:**
   the same average projection is *not* redundant for **7d** — its recent 10-min slope
   is unmeasurable, eyeballing "ahead of pace?" across a week is not trivial, and the
   genuinely new fact is the **cross-limit comparison** ("which of 5h/7d hits first?"),
   which appears nowhere today. So the average lens is dropped for 5h but is the correct,
   information-bearing lens for 7d.

2. **The rate-limit `used_percentage` only exists in Claude Code's statusline input.**
   It is fed to `statusline.sh` on each render; it is not persisted anywhere. To
   measure a slope we must record `(timestamp, used%)` samples ourselves. The sampler
   therefore has to live *inside* `statusline.sh` — the only process that sees the
   value.

3. **`used_percentage` is effectively stepwise in ~1% increments.** It is *typed* as a
   float, but observed values were `6` then `8` with nothing between, and the
   `7.000000000000001` we saw is IEEE float noise, not fine-grained signal. So the
   estimator must treat the data as **1%-quantized** and measure *time between integer
   crossings*, not a fine-grained delta over a fixed window.

4. **The value is account-global**, identical across concurrent sessions. This makes
   the sample file *safe to write from multiple sessions at once* — they all record the
   same truth, just at higher resolution. (Contrast: a per-session transcript
   token-throughput approach would be blind to your other windows and would measure the
   wrong quantity — token throughput, not quota %.)

5. **A neighbouring tool (`TokenBar`, same author) exposes no reusable data file.** Its
   only persisted state is a UI-preferences plist; its `tok/min` figure is computed
   live in memory from Claude Code's own transcript JSONL. coralline must therefore not
   depend on it, and the transcript path is the wrong source anyway (see #4).

## Non-goals

- A **recent-slope** estimate for 7d. Over a 7-day window a 10-minute slope is
  unmeasurable at 1% granularity (a single 1% crossing can take hours). 7d is projected
  from its multi-day average instead, which needs no sampling. (A future spec could add
  a recent-slope 7d path if 7d ever reports finer granularity.)
- Replacing or restyling the existing `limit5h` / `limit7d` segments. `burn` is a new,
  independent, opt-in segment.
- A words-based verdict ("you will run out"). The headline is the ETA number; the
  only verdict is encoded subtly in colour (see Colouring).
- Multi-session correctness beyond "all sessions append the same global truth"
  (interleaved timestamps are re-sorted by the reader).

## What it adds vs. the existing `limit5h` / `limit7d`

The existing segments show each window's `used% + reset countdown` side by side; they
never tell you **which wall you hit first** or **when**. `burn` adds exactly that: it
projects both windows to 100% and surfaces the nearer ETA. For 5h that projection uses
the **recent slope** — a number not visible anywhere today, and precisely what warns you
when you have *started* burning hard after a quiet stretch. The motivating gap: **5h can
have plenty of headroom while 7d is about to bind** — the old 5h-only idea would have
shown a reassuring 5h range and let you crash into 7d unwarned.

## Architecture

```
┌─ statusline.sh (every render) ─────────────────────────────┐
│  parse JSON → fh_pct/fh_rst (5h),  wd_pct/wd_rst (7d)        │
│  if VL_BURN=1:                                               │
│     printf '%s\t%s\t%s\n' NOW fh_pct fh_rst  >>  burn-5h.tsv │  ← zero-fork append (5h only)
│                                                             │
│  seg_burn (when 'burn' in VL_SEGMENTS):                     │
│     ETA_5h ← one awk pass over burn-5h.tsv:                 │
│        dedup+sort, detect 1% crossings, recent-slope ETA,   │
│        classify state, rewrite file trimmed to last N rows  │
│     ETA_7d ← stateless: wd_pct / (now − (wd_rst − 7d))      │  ← no sampling
│     binding = the limit with the smaller ETA                │
│     render  ↗<5h|7d> ⇢<ETA>   (or …/— for warming/idle)     │
└─────────────────────────────────────────────────────────────┘
                          │
              ~/.claude/coralline/burn-5h.tsv
              (append-only TSV, 5h samples only; absent unless VL_BURN=1)
```

Three pieces:

### 1. Sampler — inside `statusline.sh`

- Gated by **`VL_BURN=0`** (default off). When off, **nothing is written** — coralline
  keeps its current 100%-stateless, zero-side-effect default.
- When on, append one line per render to `~/.claude/coralline/burn-5h.tsv`:
  `epoch <TAB> fh_pct <TAB> resets_at`.
- **Zero forks**: `printf … >> file` is a bash builtin plus a redirection — no
  subprocess — honouring coralline's fork-frugal ethos.
- Guarded by `[ -n "$fh_pct" ]`, so on plans that don't report a 5h limit the sampler
  is a no-op (and `ETA_5h` stays `∞`; the segment still shows 7d if reported).
- This is exactly the prototype validated during the spike.

### 2. `seg_burn` — the reader/estimator

A single `awk` pass (one fork — the only one the feature adds) that:

- Reads `burn-5h.tsv`, drops empty-`%` rows, dedups by epoch, sorts ascending.
- Detects **1% crossings**: a sample whose integer `%` exceeds the previous integer
  `%`; the crossing's timestamp is the first sample at the new level (an exact 1%
  boundary).
- **Window-reset detection**: if `%` ever *decreases*, discard all samples at/ before
  the drop and restart (the 5h window rolled over).
- Classifies state (state machine below) and computes the rate/ETA.
- **Trims in place**: writes back only the last `N` rows (default 1500 ≈ ~20 min at the
  observed ~1–2 rows/sec), bounding file size without a separate cron/fork. Idle
  renders keep appending identical samples; the trim caps growth.

### 3. Config / installer integration

- `configure.sh`: a toggle to enable `VL_BURN`, plus a reminder that `burn` must also
  be added to `VL_SEGMENTS` to appear.
- No new files to install beyond the segment logic already in `statusline.sh`.

## Estimator

The segment computes a projected time-to-100% for **each** window with the lens that
window needs, then renders the **binding** one (smaller ETA). 5h is the recent-slope
state machine below; 7d is a stateless average; the binding rule ties them together.

### 5h — recent-slope state machine

`CORALLINE_BURN_WINDOW` (default **600s** = the "per 10 minutes" the idea started from)
is the lookback. Evaluate these conditions **top-to-bottom; first match wins** (so the
`0-crossings` overlap between `idle` and `warming` is resolved by history):

| State | Condition (first match wins) | ETA_5h |
|---|---|---|
| `reset` | `%` decreased anywhere in the file | discard history → re-evaluate as `warming` |
| `active` | **≥2** crossings inside the lookback window | finite ETA (below) |
| `idle` | **≥1** crossing exists in history, but **0** inside the lookback window (you were burning, then stopped) | `∞` (not burning → infinite 5h range) |
| `warming` | otherwise (cold start / just reset — not yet two crossings to measure) | `∞` (no estimate yet) |

**Active computation** (quantization-robust — both endpoints are exact 1% crossings):

```
rate = (pct_last_crossing − pct_first_crossing) / (t_last_crossing − t_first_crossing)
ETA_5h = (100 − pct_now) / rate          # seconds
```

Rules:

- **Never freeze a stale ETA.** When state leaves `active` (idle/reset), `ETA_5h`
  reverts to `∞` for the binding comparison; it must not keep the last computed value.
- A single crossing is **not** enough — it stays `warming` until the second crossing
  gives a measurable interval. (Matches the spike: the value sat at 7% for ~6 minutes
  with no second crossing.)
- A slow burn (<1% per lookback) is indistinguishable from idle until a crossing lands;
  `ETA_5h` stays `∞` (no fabricated number) — and 7d will usually be the binding one then.
- Guard `t_last − t_first > 0` and `rate > 0`; otherwise `ETA_5h = ∞`.

Non-`active` 5h states yield `ETA_5h = ∞` rather than a rendered string, because the
**binding selection** decides what is actually shown — when 5h has no recent signal, 7d
naturally wins the `min()`.

### 7d — stateless average

No sampling. A pure function of the 7d fields already in the statusline input:

```
elapsed_7d = now − (wd_rst − 7·86400)    # seconds since the 7d window opened
rate_7d    = wd_pct / elapsed_7d
ETA_7d     = (100 − wd_pct) / rate_7d     # = elapsed_7d × (100 − wd_pct) / wd_pct
```

`ETA_7d = ∞` when `wd_pct` is empty (7d not reported) or `0` (nothing used yet, guard the
divide). This is the "average since the tank was filled" lens — correct for a slow,
cumulative weekly window where 10-minute bursts are noise.

### Binding selection

```
ETA_binding = min(ETA_5h, ETA_7d)
label       = "5h" or "7d", whichever owns ETA_binding
```

- If **both** are `∞` (5h idle/warming **and** 7d unused/unreported), **and at least one
  limit is reported** → the segment is in `warming`/`idle` and renders `↗ ⇢…` / `↗ ⇢—`
  with no label. If neither limit is reported (`fh_pct` and `wd_pct` both empty), the
  segment renders nothing entirely (see Edge cases).
- Ties (both finite and equal) resolve to **5h** (the tighter, faster-moving window).
- Colour uses the **binding limit's own** `time_to_reset` (see Colouring).

### Known resolution limit

At 1% granularity, light 5h use yields sparse crossings, so an `active` `ETA_5h` is
coarse and lags. This is acceptable because the feature's value is greatest under *heavy*
burn — where crossings are dense and the estimate is both responsive and most needed. 7d,
by contrast, is smooth by construction (average over days).

## Display & colouring

- **Headline = binding ETA + which limit** (range to empty): `↗5h ⇢1h58m` /
  `↗7d ⇢14h`. The `5h`/`7d` tag is the binding label; warming/idle drop it (`↗ ⇢…`).
- `VL_BURN_SHOWRATE=1` additionally renders the binding limit's rate: for 5h the recent
  slope `↗5h 4.8%/10m ⇢1h58m`; for 7d the average `↗7d 11%/d ⇢14h`.
- Glyph configurable (`VL_BURN_GLYPH`, default **`↗`** U+2197). Chosen to match
  coralline's plain-Unicode convention (the segment glyphs are geometric Unicode, not
  Nerd-Font PUA) and to sit in the existing arrow family (`↑ ↓ ↺`): a half-width,
  universally-rendered "consumption trending up" mark. `VL_ASCII` falls back to a plain
  ASCII token per existing segment conventions.

**Colouring — "ratio" rule (chosen over an absolute-ETA threshold).** The existing
gauges colour purely by fill % (50/75 thresholds) and know nothing about rate or
reset. An absolute-ETA threshold for `burn` would "cry wolf" (ETA 40m flagged red even
when reset is 5m away). Instead colour by **`time_to_reset ÷ ETA`** — using the
**binding limit's own** `time_to_reset` (the 5h reset if 5h binds, the 7d reset if 7d
binds) — keeping the codebase's threshold idiom while encoding the only thing that
matters: *will you hit this wall before this window resets*:

| `time_to_reset / ETA` | meaning | colour var |
|---|---|---|
| `< 0.8` | reset well before you run dry — safe | `VL_FG_OK` |
| `0.8 – 1.0` | closing in, not yet crossing | `VL_FG_WARN` |
| `≥ 1.0` | ETA ≤ time-to-reset → you hit 100% before reset | `VL_FG_HOT` |

`warming` / `idle` (both ETAs `∞`) render in `VL_FG_DIM`.

**Theme portability (free).** Every theme overrides the *semantic* colour vars
(`VL_FG_OK/WARN/HOT/DIM`), not literal codes. As long as `burn` colours via those vars
and never hardcodes a colour, all 8 themes' palettes apply automatically. The segment
background defaults to **`VL_BG_BURN="${VL_BG_5H}"`** so it inherits the 5h family's
per-theme background without editing any theme file.

## Data contracts

- **`~/.claude/coralline/burn-5h.tsv`** — append-only TSV, one row per render:
  `epoch <TAB> used_percentage(raw) <TAB> resets_at`, **5h only**. Absent entirely
  unless `VL_BURN=1`. Reader dedups by epoch, sorts ascending, and trims to the last `N`
  rows. A decreasing `%` marks a window reset.
- **7d needs no persistence.** `ETA_7d` is computed each render from the live `wd_pct` /
  `wd_rst` input fields — there is no `burn-7d.tsv`.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `VL_BURN` | `0` | `1` = sampler writes `burn-5h.tsv` and `seg_burn` is enabled |
| `CORALLINE_BURN_WINDOW` | `600` | recent-slope lookback, seconds |
| `VL_BURN_SHOWRATE` | `0` | also render the `%/10m` rate beside the ETA |
| `VL_BURN_GLYPH` | `↗` (U+2197) | segment glyph — plain-Unicode, arrow family (with `VL_ASCII` fallback) |
| `VL_BG_BURN` | `${VL_BG_5H}` | segment background; inherits the 5h family colour |
| `VL_BURN_TRIM` | `1500` | max rows kept in `burn-5h.tsv` |

(`burn` must also be added to `VL_SEGMENTS` to appear.)

## Edge cases & error handling

- **5h not reported** (`fh_pct` empty): sampler no-ops, `ETA_5h = ∞`; segment still
  shows 7d if `wd_pct` is present.
- **7d not reported** (`wd_pct` empty): `ETA_7d = ∞`; segment shows 5h if active.
- **Neither reported**: segment renders nothing.
- **Binding handoff**: when 5h goes idle, `ETA_5h → ∞` and the label/colour flip to 7d
  on the next render (and vice-versa as 5h bursts). The label always names the shown ETA.
- **Both have room**: still shows the nearer ETA (informative), coloured by *its* reset
  ratio — usually `VL_FG_OK`.
- **Window reset** (5h `%` drops): discard pre-drop samples, return to `warming`.
- **Clock skew / `NOW` going backwards**: guard `Δt > 0` (both estimators); skip the bad
  pair / treat as `∞`.
- **Concurrent sessions**: harmless — all append the same global `%`; reader re-sorts.
- **Idle growth**: bounded by the in-place trim to `VL_BURN_TRIM` rows.
- **First enable**: `warming` until two 5h crossings accumulate; 7d average available
  immediately if `wd_pct > 0`.

## Testing

`seg_burn` is a pure function of the `burn-5h.tsv` fixture **plus** the live
`wd_pct`/`wd_rst` inputs. Tests (in the existing `test/`) feed both and assert the
rendered output:

- steady 5h burn → `active`, `↗5h ⇢<ETA>` within tolerance, correct colour band;
- burst-after-idle → recent slope (shorter ETA) distinct from the whole-file average;
- **5h roomy, 7d binding** (the motivating case) → label flips to `↗7d`, coloured by the
  7d reset ratio;
- **binding handoff** → start 5h-active/binding, let 5h go idle → next render shows 7d;
- 5h idle **and** 7d unused → `↗ ⇢—`, dim (both `∞`);
- warming (one or zero 5h crossings) with 7d unused → `↗ ⇢…`, dim;
- 7d-only (5h not reported, `wd_pct` present) → shows `↗7d` from the first render;
- window reset (5h `%` drops mid-file) → history discarded, back to `warming`;
- `time_to_reset/ETA` boundaries (0.8, 1.0) on the **binding** limit → OK/WARN/HOT;
- `VL_BURN=0` → no file written, segment absent.

## Implementation note (prototype cleanup)

During the spike an **un-gated** sampler line was injected into the live
`~/.claude/coralline/statusline.sh` (backed up as `statusline.sh.bak-burnrate-prototype`).
The real implementation replaces it with the `VL_BURN`-gated version; the live file must
be restored from that backup (or re-installed) so no unguarded write remains.
