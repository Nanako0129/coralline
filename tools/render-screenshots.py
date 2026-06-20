#!/usr/bin/env python3
"""Render promotional PNG screenshots for every coralline theme.

Runs the real statusline.sh against canned JSON payloads and a throwaway
demo git repo, parses the ANSI output, and paints terminal-window-style
images. Powerline caps/separators are drawn as vector shapes so the pills
stay pixel-perfect at any size.

Usage:
    python3 tools/render-screenshots.py

Deps: pillow, fonttools, and a "MesloLG* Nerd Font Mono" installed.
Outputs: assets/hero.png and assets/theme-<name>.png
"""

import glob
import json
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "assets"
FAKE_HOME = Path(tempfile.gettempdir()) / "vl-home"
DEMO = FAKE_HOME / "dev" / "coralline"

THEMES = ["claude-coral", "catppuccin-mocha", "nord",
          "gruvbox-dark", "tokyo-night", "mono", "dracula",
          "lunar-pink", "reverie"]

# hero.png is a curated sampler frozen to the original six themes; new themes go
# in the per-theme gallery (theme-<name>.png) only, so the banner doesn't grow.
HERO_THEMES = ["claude-coral", "catppuccin-mocha", "nord",
               "gruvbox-dark", "tokyo-night", "mono"]

# ── Geometry (S = supersampling factor, downscaled at save time) ─────────────
S = 2
FS = 26 * S
CELL_H = 46 * S
PAD = 40 * S
TITLE_H = 62 * S
LABEL_H = 30 * S
ROW_GAP = 22 * S
LINE_GAP = 6 * S

WINDOW_BG = (13, 15, 23)
BORDER = (38, 43, 61)
TITLE_FG = (150, 155, 175)
LABEL_FG = (99, 106, 135)
DEFAULT_FG = (220, 222, 228)

CAP_L, CAP_R, SEP = "", "", ""

# ── Fonts ────────────────────────────────────────────────────────────────────
def find_font(style):
    for pattern in (f"~/Library/Fonts/MesloLG*NerdFontMono-{style}.ttf",
                    f"/Library/Fonts/MesloLG*NerdFontMono-{style}.ttf",
                    f"~/.local/share/fonts/MesloLG*NerdFontMono-{style}.ttf"):
        hits = glob.glob(os.path.expanduser(pattern))
        if hits:
            return hits[0]
    raise SystemExit(f"Meslo Nerd Font Mono ({style}) not found — install from nerdfonts.com")

FONT_PATH = find_font("Regular")
FONT = ImageFont.truetype(FONT_PATH, FS)
FONT_B = ImageFont.truetype(find_font("Bold"), FS)
FONT_TITLE = ImageFont.truetype(FONT_PATH, 20 * S)
FONT_LABEL = ImageFont.truetype(find_font("Bold"), 15 * S)

# Some symbols the script emits are absent from Meslo NF (terminals fall back
# to other fonts; PIL cannot). Substitute with glyphs the font does have.
CMAP = TTFont(FONT_PATH).getBestCmap()

def pick_glyph(candidates, fallback):
    for cp in candidates:
        if cp in CMAP:
            return chr(cp)
    return fallback

GLYPH_FIX = {
    "⎇": pick_glyph([0xE0A0], "Y"),            # ⎇ → powerline branch
    "⬡": pick_glyph([0x2B22, 0x25C7], "#"),    # ⬡ → hexagon/diamond (ctx)
    "⬢": pick_glyph([0x2B22, 0x25CF], "#"),    # ⬢ → filled hexagon/circle (project)
    "⧖": pick_glyph([0xF252, 0xF017, 0x231B], "~"),  # ⧖ → hourglass/clock
}

# ── xterm-256 → RGB ──────────────────────────────────────────────────────────
BASE16 = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
          (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
          (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
          (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]

def xterm256(n):
    if n < 16:
        return BASE16[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return (steps[n // 36], steps[(n // 6) % 6], steps[n % 6])
    g = 8 + 10 * (n - 232)
    return (g, g, g)

# ── ANSI parsing ─────────────────────────────────────────────────────────────
def parse_ansi(line):
    """Return a list of (char, fg, bg, bold) cells."""
    cells, fg, bg, bold = [], None, None, False
    i = 0
    while i < len(line):
        if line[i] == "\x1b" and i + 1 < len(line) and line[i + 1] == "[":
            j = line.index("m", i)
            params = [int(p) if p else 0 for p in line[i + 2:j].split(";")]
            k = 0
            while k < len(params):
                p = params[k]
                if p == 0:
                    fg, bg, bold = None, None, False
                elif p == 1:
                    bold = True
                elif p == 22:
                    bold = False
                elif p in (38, 48):
                    if params[k + 1] == 5:
                        color = xterm256(params[k + 2]); k += 2
                    else:
                        color = tuple(params[k + 2:k + 5]); k += 4
                    if p == 38:
                        fg = color
                    else:
                        bg = color
                elif p == 39:
                    fg = None
                elif p == 49:
                    bg = None
                k += 1
            i = j + 1
        else:
            cells.append((line[i], fg, bg, bold))
            i += 1
    return cells

# ── Drawing ──────────────────────────────────────────────────────────────────
def draw_cells(draw, cells, x0, y0):
    """Draw one statusline row; pass draw=None to measure. Returns width."""
    x = float(x0)
    half = CELL_H / 2
    for ch, fg, bg, bold in cells:
        ch = GLYPH_FIX.get(ch, ch)
        color = fg or DEFAULT_FG
        if ch == CAP_L:
            if draw:
                draw.pieslice([round(x), y0, round(x + CELL_H), y0 + CELL_H],
                              90, 270, fill=color)
            x += half
        elif ch == CAP_R:
            if draw:
                draw.pieslice([round(x - half), y0, round(x + half), y0 + CELL_H],
                              -90, 90, fill=color)
            x += half
        elif ch == SEP:
            if draw:
                if bg:
                    draw.rectangle([round(x), y0, round(x + half), y0 + CELL_H], fill=bg)
                draw.polygon([(round(x), y0), (round(x + half), y0 + CELL_H / 2),
                              (round(x), y0 + CELL_H)], fill=color)
            x += half
        else:
            font = FONT_B if bold else FONT
            w = font.getlength(ch)
            if draw:
                if bg:
                    draw.rectangle([round(x), y0, round(x + w) + 1, y0 + CELL_H], fill=bg)
                draw.text((round(x), y0 + CELL_H / 2 + S), ch,
                          font=font, fill=color, anchor="lm")
            x += w
    return x - x0

def render_image(title, blocks, out_path):
    """blocks: list of (label, [cells, ...]) — each block is a label plus
    one or more statusline rows."""
    content_w = max(draw_cells(None, cells, 0, 0)
                    for _, rows in blocks for cells in rows)
    width = int(content_w) + 2 * PAD
    height = TITLE_H + PAD // 2
    for _, rows in blocks:
        height += LABEL_H + len(rows) * CELL_H + (len(rows) - 1) * LINE_GAP + ROW_GAP
    height += PAD - ROW_GAP

    img = Image.new("RGB", (width, height), WINDOW_BG)
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle([0, 0, width - 1, height - 1], radius=14 * S,
                           outline=BORDER, width=S)
    for idx, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        cx = (28 + idx * 24) * S
        r = 7 * S
        draw.ellipse([cx - r, TITLE_H // 2 - r, cx + r, TITLE_H // 2 + r], fill=color)
    draw.text((width / 2, TITLE_H / 2 + S), title,
              font=FONT_TITLE, fill=TITLE_FG, anchor="mm")
    draw.line([PAD // 2, TITLE_H, width - PAD // 2, TITLE_H], fill=BORDER, width=S)

    y = TITLE_H + PAD // 2
    for label, rows in blocks:
        draw.text((PAD, y + LABEL_H // 2), label.upper(),
                  font=FONT_LABEL, fill=LABEL_FG, anchor="lm")
        y += LABEL_H
        for cells in rows:
            draw_cells(draw, cells, PAD, y)
            y += CELL_H + LINE_GAP
        y += ROW_GAP - LINE_GAP

    img = img.resize((width // S, height // S), Image.LANCZOS)
    img.save(out_path)
    print(f"wrote {out_path}  ({width // S}x{height // S})")

# ── Demo data ────────────────────────────────────────────────────────────────
def setup_demo_repo():
    shutil.rmtree(FAKE_HOME, ignore_errors=True)
    DEMO.mkdir(parents=True)
    g = ["git", "-C", str(DEMO)]
    run = lambda *a: subprocess.run([*g, *a], check=True, capture_output=True)
    subprocess.run(["git", "-c", "init.defaultBranch=main", "-C", str(DEMO),
                    "init", "-q"], check=True)
    run("config", "user.email", "demo@example.com")
    run("config", "user.name", "Demo")
    (DEMO / "app.py").write_text("print('hi')\n")
    run("add", "."); run("commit", "-qm", "init")
    (DEMO / "app.py").write_text("print('hi')\nprint('stash me')\n")
    run("stash", "push", "-q")                       # stash count: 1
    (DEMO / "feature.py").write_text("pass\n"); run("add", "feature.py")  # staged +
    with open(DEMO / "app.py", "a") as f: f.write("print('more')\n")     # modified !
    (DEMO / "notes.txt").write_text("todo\n")                            # untracked ?

def payload(ctx, tin, tout, cr, cw, fh, fh_s, wd, wd_s, cost,
            ladd=0, ldel=0, dur_ms=0):
    now = int(time.time())
    return json.dumps({
        "cwd": str(DEMO),
        "workspace": {"current_dir": str(DEMO)},
        "model": {"display_name": "Claude Fable 5"},
        "output_style": {"name": "Explanatory"},
        "effort": {"level": "high"},
        "context_window": {
            "used_percentage": ctx,
            "total_input_tokens": tin, "total_output_tokens": tout,
            "current_usage": {"cache_read_input_tokens": cr,
                              "cache_creation_input_tokens": cw},
        },
        "rate_limits": {
            "five_hour": {"used_percentage": fh, "resets_at": now + fh_s},
            "seven_day": {"used_percentage": wd, "resets_at": now + wd_s},
        },
        "cost": {"total_cost_usd": cost, "total_lines_added": ladd,
                 "total_lines_removed": ldel, "total_duration_ms": dur_ms},
    })

LOW  = payload(23, 234500, 12300, 198000, 8400, 12, 6420, 34, 2 * 86400 + 5 * 3600 + 600, 0.87)
MID  = payload(62, 891234, 45600, 623000, 12800, 41, 9840, 79, 86400 + 11 * 3600 + 300, 1.23)
HIGH = payload(87, 1934000, 98400, 1620000, 45200, 91, 2820, 68, 3 * 86400 + 11 * 3600 + 300, 4.52,
               ladd=321, ldel=87, dur_ms=2820000)

def run_bar(theme, segments, payload_json, extra_conf="", cols=None, env_extra=None):
    conf = FAKE_HOME / "render.conf"
    conf.write_text(
        f'. {REPO}/themes/{theme}.conf\n'
        f'VL_SEGMENTS="{segments}"\nVL_SEGMENTS2=""\n'
        f'VL_CLOCK="24h"\nVL_CLOCK_SECONDS=0\n{extra_conf}'
    )
    env = dict(os.environ, HOME=str(FAKE_HOME), CORALLINE_CONFIG=str(conf))
    if cols is not None:
        env["COLUMNS"] = str(cols)
    else:
        env.pop("COLUMNS", None)
    if env_extra:
        env.update(env_extra)
    out = subprocess.run(["bash", str(REPO / "statusline.sh")],
                         input=payload_json, env=env, check=True,
                         capture_output=True, text=True)
    return [parse_ansi(l) for l in out.stdout.splitlines() if l.strip()]


# ── Authoring custom statusline demos ─────────────────────────────────────────
# The whole tool is built from three reusable primitives, so a new demo is just
# a *_blocks() function plus one line in main():
#
#   run_bar(theme, segments, payload_json, extra_conf="", cols=None, env_extra=None)
#       Runs the real statusline.sh and returns parsed rows. Everything is
#       overridable: any theme, any space-separated segment list, any Claude
#       payload JSON, extra conf lines (e.g. 'VL_STYLE="lean"\n'), a fixed
#       COLUMNS for wrap demos, and extra env vars.
#   make_payload(**over)   Build a Claude statusline payload; pass nested dicts
#                          to override just the fields a scene cares about.
#   render_image(title, blocks, out_path)
#       blocks = [(label, rows), ...]; rows = one or more parsed statuslines.
#
# Scenes that need a rolling sample file (like burn) seed it and point
# statusline.sh at it via env_extra — see run_burn below as the template.

def make_payload(**over):
    """A Claude statusline payload with sensible demo defaults. Override any
    top-level key; dict values are shallow-merged so a scene can set just
    e.g. rate_limits without restating the rest."""
    base = {
        "cwd": str(DEMO), "workspace": {"current_dir": str(DEMO)},
        "model": {"display_name": "Claude Fable 5"},
        "context_window": {"used_percentage": 47,
                           "total_input_tokens": 234500, "total_output_tokens": 12300,
                           "current_usage": {"cache_read_input_tokens": 198000,
                                             "cache_creation_input_tokens": 8400}},
        "cost": {"total_cost_usd": 1.23},
    }
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k] = {**base[k], **v}
        else:
            base[k] = v
    return json.dumps(base)

# ── Burn scene ────────────────────────────────────────────────────────────────
# The 5h estimator is crossing-based: it needs >=2 integer-percent crossings
# within CORALLINE_BURN_WINDOW (600s). We seed a sample file so the live
# statusline.sh produces a real recent-slope ETA — no faked output.
def run_burn(theme, segments, climb, fh_pct, fh_reset_s,
             wd_pct=40, wd_reset_s=6 * 86400):
    """climb: list of (seconds_ago, integer_pct) seeding the recent slope, or
    None for the cold-start 'warming' state. wd_pct=None omits the 7d limit
    entirely (so a no-samples render shows the true '↗ …', not a 7d fallback)."""
    now = int(time.time())
    burn_file = FAKE_HOME / "burn-demo.tsv"
    burn_file.write_text(
        "".join(f"{now - ago}\t{pct}\t{now + fh_reset_s}\n" for ago, pct in climb)
        if climb else ""
    )
    rl = {"five_hour": {"used_percentage": fh_pct, "resets_at": now + fh_reset_s}}
    if wd_pct is not None:
        rl["seven_day"] = {"used_percentage": wd_pct, "resets_at": now + wd_reset_s}
    return run_bar(theme, segments, make_payload(rate_limits=rl),
                   env_extra={"CORALLINE_BURN_FILE": str(burn_file),
                              "CORALLINE_BURN_WINDOW": "600"})

# A medium recent slope → eta ~2h23m; the colour is set by how soon the 5h
# window resets relative to that eta (shown by the ↺ countdown beside it).
CLIMB_MED = [(500, 27), (375, 28), (250, 29), (125, 30)]
# Two crossings spread far apart → eta beyond the whole 5h window → bright ✓.
CLIMB_SLOW = [(560, 29), (500, 30)]
# Crossings exist but all older than the 600s window → idle → dim ✓.
CLIMB_IDLE = [(1400, 30), (1300, 31)]

# The complete canonical layout, with burn in its documented slot (after
# limit7d) — i.e. what a fully-configured coralline looks like in Claude Code.
FULL = "dir git model effort ctx limit5h limit7d burn cost clock"

def burn_blocks():
    return [
        ("the full statusline, burn included",     run_burn("claude-coral",
            FULL, CLIMB_MED, 31, 7800)),
        ("empties before the 5h window resets",    run_burn("claude-coral",
            "limit5h burn", CLIMB_MED, 31, 10800)),
        ("reset and empty are neck-and-neck",      run_burn("claude-coral",
            "limit5h burn", CLIMB_MED, 31, 7800)),
        ("window resets with room to spare",       run_burn("claude-coral",
            "limit5h burn", CLIMB_MED, 31, 3600)),
        ("✓  slow enough to never run dry",        run_burn("claude-coral",
            "burn", CLIMB_SLOW, 31, 10800)),
        ("✓  idle · nothing in flight",            run_burn("claude-coral",
            "burn", CLIMB_IDLE, 31, 10800, wd_pct=None)),
        ("…  warming up · no samples yet",         run_burn("claude-coral",
            "burn", None, 31, 10800, wd_pct=None)),
    ]

# ── Scenes ───────────────────────────────────────────────────────────────────
def theme_blocks(theme):
    return [
        ("daily drive",        run_bar(theme, "dir git model clock", LOW)),
        ("context · low",      run_bar(theme, "ctx", LOW)),
        ("limits & cost · low", run_bar(theme, "limit5h limit7d cost", LOW)),
        ("context · running hot", run_bar(theme, "ctx", HIGH)),
        ("limits & cost · running hot", run_bar(theme, "limit5h limit7d cost", HIGH)),
        ("extras",             run_bar(theme, "effort lines style duration stash", HIGH)),
    ]

def hero_blocks():
    return [(theme, run_bar(theme, "dir git model clock", MID)
                    + run_bar(theme, "ctx limit5h cost", MID))
            for theme in HERO_THEMES]

def lean_blocks():
    lean = 'VL_STYLE="lean"\n'
    return [
        ("daily drive",       run_bar("claude-coral", "dir git model clock", LOW, lean)),
        ("context & limits",  run_bar("claude-coral", "ctx limit5h limit7d cost", MID, lean)),
        ("running hot",       run_bar("claude-coral", "ctx limit5h limit7d cost", HIGH, lean)),
        ("extras",            run_bar("claude-coral", "effort lines style duration stash", HIGH, lean)),
        ("same data, pill style", run_bar("claude-coral", "dir git model clock", LOW)),
    ]

def wrap_blocks():
    SEGS = "dir git model ctx limit5h limit7d cost clock"
    auto = lambda n: f'VL_LAYOUT="auto"\nVL_MAX_LINES={n}\n'
    return [
        ("VL_MAX_LINES=1  ·  always one line", run_bar("claude-coral", SEGS, MID, auto(1), cols=120)),
        ("VL_MAX_LINES=2  ·  COLUMNS=38",      run_bar("claude-coral", SEGS, MID, auto(2), cols=38)),
        ("VL_MAX_LINES=5  ·  same window",     run_bar("claude-coral", SEGS, MID, auto(5), cols=38)),
    ]

def main():
    import sys
    ASSETS.mkdir(exist_ok=True)
    setup_demo_repo()
    only = sys.argv[1] if len(sys.argv) > 1 else None
    if only in (None, "burn"):
        render_image("coralline · burn-rate segment", burn_blocks(),
                     ASSETS / "burn-segment.png")
    if only == "burn":
        return
    render_image("coralline — pick your vibe", hero_blocks(), ASSETS / "hero.png")
    render_image("coralline · lean style", lean_blocks(), ASSETS / "style-lean.png")
    render_image("coralline · responsive wrap", wrap_blocks(), ASSETS / "wrap-demo.png")
    for theme in THEMES:
        render_image(f"coralline · {theme}", theme_blocks(theme),
                     ASSETS / f"theme-{theme}.png")

if __name__ == "__main__":
    main()
