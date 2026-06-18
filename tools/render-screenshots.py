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

def run_bar(theme, segments, payload_json, extra_conf="", cols=None):
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
    out = subprocess.run(["bash", str(REPO / "statusline.sh")],
                         input=payload_json, env=env, check=True,
                         capture_output=True, text=True)
    return [parse_ansi(l) for l in out.stdout.splitlines() if l.strip()]

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
    ASSETS.mkdir(exist_ok=True)
    setup_demo_repo()
    render_image("coralline — pick your vibe", hero_blocks(), ASSETS / "hero.png")
    render_image("coralline · lean style", lean_blocks(), ASSETS / "style-lean.png")
    render_image("coralline · responsive wrap", wrap_blocks(), ASSETS / "wrap-demo.png")
    for theme in THEMES:
        render_image(f"coralline · {theme}", theme_blocks(theme),
                     ASSETS / f"theme-{theme}.png")

if __name__ == "__main__":
    main()
