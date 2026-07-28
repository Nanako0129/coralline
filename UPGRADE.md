# coralline — AI Upgrade Playbook

> **You are an AI coding assistant** helping a user update coralline. The installer
> backs up the old `statusline.sh` and never touches `~/.claude/coralline.conf`. It
> only *reports* what is new; you enable the new opt-in features additively, with the
> user's consent.
>
> This playbook updates Bash-based installs. On PowerShell-only Windows, do not run
> `install.sh`; re-run the native archive procedure under
> [Windows without Git Bash](README.md#windows-without-git-bash). It preserves
> `coralline.conf` and keeps `subagentStatusLine` unchanged by default; use
> `-SubagentRows on` or `-SubagentRows off` only for an explicit user choice.

## Overview

"Upgrade" means: re-run the installer in install-only mode, read the
"new since your installed copy" report it prints, and offer to enable the new
segments/options. The renderer (`statusline.sh`) is replaced; `coralline.conf` is
preserved; the prior `statusline.sh` is backed up to
`~/.claude/coralline/statusline.sh.bak.<ts>` (the 3 newest are kept).

## Prerequisites

`jq` and a Nerd Font terminal (or `VL_ASCII=1`). Same as install.

## Fast Path

Re-install the runtime without opening the wizard, capturing its stdout:

    curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash -s -- --install-only

From a local clone instead:

    bash configure.sh --install-only

Keep that output — the report it prints is the source of truth for the next step.

## Read the delta

The report is plain text (no color when piped) shaped as:

    coralline upgrade — new since your installed copy:
      segment  burn
      option   VL_FLOAT=1       1 = also write a plain-text readout to VL_FLOAT_FILE
    ~/.claude/coralline.conf preserved · backup at ~/.claude/coralline/statusline.sh.bak.20260622-100501

Contract: each item line is `  <kind>  <token>  <free-text description>`. `<kind>`
is `segment` or `option`. For `segment`, `<token>` is the segment name. For
`option`, `<token>` is the exact assignment to add (e.g. `VL_FLOAT=1`). Everything
after `<token>` is a human description that may contain spaces and `=` — do not
parse it. An empty report means no new segments or options, not that nothing
changed: the runtime was still replaced. Skip the interview and the config write,
and go straight to **Verification**.

## Enable interview

For each new segment and option, ask the user whether to enable it, briefly
explaining what it does (use the description plus your knowledge of coralline; a
description may be a clipped first sentence). Enable only what the user approves.

## Write Config

First read `~/.claude/coralline.conf`. Find the existing `VL_SEGMENTS`,
`VL_SEGMENTS2`, `VL_SEGMENTS3`, and `VL_LAYOUT` assignments. Layout matters for
where a new segment goes: in `fixed` layout (the default) all three lists render
as separate lines, but in `auto` layout **only `VL_SEGMENTS` is rendered** —
`VL_SEGMENTS2`/`VL_SEGMENTS3` do not display. Then apply only what the user
approved, additively:

- New segment: append it to `VL_SEGMENTS` by default. Only use `VL_SEGMENTS2` or
  `VL_SEGMENTS3` when `VL_LAYOUT` is `fixed` **and** the user already populates
  that line (in `auto` layout a segment added to `2`/`3` would never show). Never
  add a segment already present in **any** of the three, and never reorder or drop
  existing segments.
- New option: append the exact enabling assignment from the report (e.g.
  `VL_FLOAT=1`). Never change a knob the user has already set.

If `coralline.conf` does not exist, do **not** write a bare `VL_SEGMENTS="<new
segment>"` — any `VL_SEGMENTS` assignment replaces the built-in default list, so
that would hide every default segment. Seed the shipped default list first, then
append the approved segments:

    VL_SEGMENTS="dir git model ctx limit5h limit7d cost clock <approved segments>"

followed by one line per approved option.

Before writing an existing `coralline.conf`, show the bounded additive diff and obtain
explicit approval. Leave the file byte-for-byte unchanged when no change was approved.
When a write is approved, create a timestamped byte-exact backup and replace through a
sibling temporary file; never reorder, drop, or rewrite unrelated content.

## Verification

Render once with the bundled sample to confirm it still renders and the new
segments are present:

    cat ~/.claude/coralline/sample-input.json | CORALLINE_NO_SAMPLE=1 bash ~/.claude/coralline/statusline.sh

A newly added segment like `burn` may show a neutral "warming" glyph until real
usage data accrues — that is expected.

Then check the glyphs, which the delta cannot do for you: the gauge and segment
characters are plain Unicode rather than Nerd Font icons, so a font that lacks
them leaves the substitution to the terminal, which may pick one wider than a
cell and push the row out of alignment. Ask the user to look at the rendered
line. If the gauge blocks run together, or the `ctx` / `project` glyph looks too
wide and everything after it is shifted, offer the replacements below — each is
present at exactly one cell in both Meslo and JetBrainsMono Nerd Font. Write only
the ones the user asks for, and never overwrite a value they already set:

    VL_BAR_FILL="▪"     VL_BAR_EMPTY="▫"
    VL_CTX_GLYPH="◔"    VL_PROJECT_GLYPH="▣"

Note these are not upgrade items and will never appear in the delta: `VL_BAR_FILL`
and `VL_BAR_EMPTY` are not new, and the right value for any of the four depends on
the user's font rather than on which version they came from.

Then tell the user to restart Claude Code or open a new session.

## Manual fallback

If the user prefers to do it themselves: rerun the wizard with
`bash ~/.claude/coralline/configure.sh`, or edit `~/.claude/coralline.conf` by
hand. To roll back the renderer, copy a
`~/.claude/coralline/statusline.sh.bak.<ts>` back over `statusline.sh`.
