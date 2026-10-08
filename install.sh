#!/usr/bin/env bash
# coralline installer. Works from a local clone or via:
#   curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
# Test a fork with:
#   curl -fsSL https://raw.githubusercontent.com/YOU/coralline/main/install.sh | bash -s -- --repo YOU/coralline

set -u

REPO="${CORALLINE_REPO:-Nanako0129/coralline}"
REF="${CORALLINE_REF:-main}"
BASE_URL="${CORALLINE_BASE_URL:-}"
# Tracks whether the ref/source was pinned explicitly (env or flag). When it is,
# we never prompt or auto-resolve — the caller's choice wins.
REF_SET=0
[ -n "${CORALLINE_REF:-}" ] && REF_SET=1
[ -n "${CORALLINE_BASE_URL:-}" ] && REF_SET=1
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
WORK_DIR=""
TEMP_DIR=""
CONFIGURE_MODE=""

if [ -t 1 ]; then
  BOLD=$(printf '\033[1m')
  DIM=$(printf '\033[2m')
  GREEN=$(printf '\033[32m')
  BLUE=$(printf '\033[34m')
  RESET=$(printf '\033[0m')
else
  BOLD=""
  DIM=""
  GREEN=""
  BLUE=""
  RESET=""
fi

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
coralline installer

Usage:
  bash install.sh [--repo owner/repo] [--ref branch-or-tag]
  curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash

Run interactively (without --ref), it asks whether to install the latest tagged
release or main. Pin one with --ref to skip the prompt.

Options:
  --repo owner/repo   Download runtime files from this GitHub repo.
  --ref ref          Download from this branch, tag, or commit (skips the version prompt).
  --base-url url     Download runtime files from this raw file base URL.
  --install-only     Install runtime files and Claude settings, then exit.
  --default          Install the default coralline config without opening the setup menu.
  --import-p10k      Import ~/.p10k.zsh without opening the setup menu.
  --wizard           Open the visual wizard directly after installing.
  -h, --help         Show this help.
EOF
}

info() {
  printf '%s%s%s %s\n' "$BLUE" "$BOLD" "coralline" "$RESET$*"
}

ok() {
  printf '%s%s%s %s\n' "$GREEN" "$BOLD" "coralline" "$RESET$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need_jq() {
  command -v jq >/dev/null 2>&1 || die "jq is required. Install it first (macOS: brew install jq), then rerun this installer."
}

download() {
  local src="$1" dst="$2"
  case "$src" in
    file://*)
      cp "${src#file://}" "$dst" || die "failed to copy $src"
      ;;
    *)
      curl -fsSL "$src" -o "$dst" || die "failed to download $src"
      ;;
  esac
}

download_theme_archive() {
  local archive extract src rel dst count=0
  need_cmd tar
  archive=$(mktemp "${TMPDIR:-/tmp}/coralline-themes.XXXXXX.tar.gz") || exit 1
  extract=$(mktemp -d "${TMPDIR:-/tmp}/coralline-themes.XXXXXX") || exit 1
  download "https://codeload.github.com/$REPO/tar.gz/$REF" "$archive"
  tar -xzf "$archive" -C "$extract" || die "failed to extract theme archive"
  while IFS= read -r src; do
    rel="${src#"$extract"/}"
    rel="${rel#*/themes/}"
    dst="$WORK_DIR/themes/$rel"
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    count=$((count + 1))
  done <<THEMES
$(find "$extract" -type f -path '*/themes/*.conf' | sort)
THEMES
  rm -rf "$archive" "$extract"
  [ "$count" -gt 0 ] || die "no themes found for $REPO@$REF"
}

download_themes() {
  local paths path dst count=0 local_base
  case "$BASE_URL" in
    file://*)
      local_base="${BASE_URL#file://}"
      paths=$(cd "$local_base" 2>/dev/null && find themes -type f -name '*.conf' | sort || true)
      ;;
    *)
      download_theme_archive
      return 0
      ;;
  esac
  [ -n "$paths" ] || die "no themes found for $REPO@$REF"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    dst="$WORK_DIR/$path"
    mkdir -p "$(dirname "$dst")"
    download "$BASE_URL/$path" "$dst"
    count=$((count + 1))
  done <<THEMES
$paths
THEMES
  [ "$count" -gt 0 ] || die "no themes found"
}

# Best-effort lookup of the newest published release tag (e.g. v0.6.0). Prints
# the tag, or nothing on any failure (no releases, offline, API rate limit) so
# callers can fall back to main. Uses the curl+jq the installer already requires.
resolve_latest_tag() {
  command -v curl >/dev/null 2>&1 || return 0
  curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' 2>/dev/null
}

# Ask which version to install when running interactively. Skipped when the ref
# is pinned (--ref / env / --base-url), in the no-menu modes, when there is no
# tty, or when no release tag can be resolved — each of those keeps the current
# default (main), so automation and forks are unaffected.
maybe_pick_ref() {
  [ "$REF_SET" = 1 ] && return 0
  case "$CONFIGURE_MODE" in --default|--import-p10k) return 0 ;; esac
  [ -r /dev/tty ] && [ -t 1 ] || return 0
  local latest
  latest=$(resolve_latest_tag)
  [ -n "$latest" ] || return 0
  printf '\n%sInstall which version?%s\n' "$BOLD" "$RESET"
  printf '  1) %s%s%s  %s(latest release, recommended)%s\n' "$BOLD" "$latest" "$RESET" "$DIM" "$RESET"
  printf '  2) main  %s(latest development)%s\n' "$DIM" "$RESET"
  printf 'Choice [1]: '
  local ans=""
  read -r ans < /dev/tty || ans=""
  case "$ans" in
    2|main|M|m) REF="main" ;;
    *) REF="$latest" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires owner/repo"
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --ref)
      [ "$#" -ge 2 ] || die "--ref requires a branch, tag, or commit"
      REF="$2"
      REF_SET=1
      shift 2
      ;;
    --ref=*)
      REF="${1#--ref=}"
      REF_SET=1
      shift
      ;;
    --base-url)
      [ "$#" -ge 2 ] || die "--base-url requires a URL"
      BASE_URL="$2"
      REF_SET=1
      shift 2
      ;;
    --base-url=*)
      BASE_URL="${1#--base-url=}"
      REF_SET=1
      shift
      ;;
    --install-only)
      CONFIGURE_MODE="--install-only"
      shift
      ;;
    --default)
      CONFIGURE_MODE="--default"
      shift
      ;;
    --import-p10k)
      CONFIGURE_MODE="--import-p10k"
      shift
      ;;
    --wizard)
      CONFIGURE_MODE="--wizard"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

cleanup() {
  [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

info "installing coralline"
printf '%s\n' "${DIM}Checking prerequisites...${RESET}"
need_jq

if [ -f "$SCRIPT_DIR/configure.sh" ] \
  && [ -f "$SCRIPT_DIR/statusline.sh" ] \
  && [ -f "$SCRIPT_DIR/statusline-grok.sh" ] \
  && [ -f "$SCRIPT_DIR/test/sample-input.json" ] \
  && [ -d "$SCRIPT_DIR/themes" ]; then
  WORK_DIR="$SCRIPT_DIR"
  printf '%s\n' "${DIM}Using local checkout: $WORK_DIR${RESET}"
else
  need_cmd curl
  maybe_pick_ref
  [ -n "$BASE_URL" ] || BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/coralline-install.XXXXXX") || exit 1
  WORK_DIR="$TEMP_DIR"
  mkdir -p "$WORK_DIR/themes" "$WORK_DIR/test"
  printf '%s\n' "${DIM}Downloading runtime files ($REF) from $BASE_URL${RESET}"
  download "$BASE_URL/configure.sh" "$WORK_DIR/configure.sh"
  download "$BASE_URL/statusline.sh" "$WORK_DIR/statusline.sh"
  download "$BASE_URL/statusline-grok.sh" "$WORK_DIR/statusline-grok.sh"
  download "$BASE_URL/test/sample-input.json" "$WORK_DIR/test/sample-input.json"
  download_themes
fi

if [ "$CONFIGURE_MODE" = "--install-only" ]; then
  ok "installing runtime files"
else
  ok "starting setup"
fi
if [ "$CONFIGURE_MODE" = "--install-only" ]; then
  if [ -r /dev/tty ] && [ -t 1 ]; then
    exec bash "$WORK_DIR/configure.sh" --install-only < /dev/tty
  fi
  exec bash "$WORK_DIR/configure.sh" --install-only
fi
if [ -r /dev/tty ] && [ -t 1 ]; then
  exec bash "$WORK_DIR/configure.sh" --install $CONFIGURE_MODE < /dev/tty
fi
exec bash "$WORK_DIR/configure.sh" --install $CONFIGURE_MODE
