#!/usr/bin/env bash
# coralline installer. Works from a local clone or via:
#   curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash
# Test a fork with:
#   curl -fsSL https://raw.githubusercontent.com/YOU/coralline/main/install.sh | bash -s -- --repo YOU/coralline

set -u

REPO="${CORALLINE_REPO:-Nanako0129/coralline}"
REF="${CORALLINE_REF:-main}"
BASE_URL="${CORALLINE_BASE_URL:-}"
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

Options:
  --repo owner/repo   Download runtime files from this GitHub repo.
  --ref ref          Download runtime files from this branch, tag, or commit.
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
      shift 2
      ;;
    --ref=*)
      REF="${1#--ref=}"
      shift
      ;;
    --base-url)
      [ "$#" -ge 2 ] || die "--base-url requires a URL"
      BASE_URL="$2"
      shift 2
      ;;
    --base-url=*)
      BASE_URL="${1#--base-url=}"
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

[ -n "$BASE_URL" ] || BASE_URL="https://raw.githubusercontent.com/$REPO/$REF"

cleanup() {
  [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

info "installing coralline"
printf '%s\n' "${DIM}Checking prerequisites...${RESET}"
need_jq

if [ -f "$SCRIPT_DIR/configure.sh" ] \
  && [ -f "$SCRIPT_DIR/statusline.sh" ] \
  && [ -f "$SCRIPT_DIR/test/sample-input.json" ] \
  && [ -d "$SCRIPT_DIR/themes" ]; then
  WORK_DIR="$SCRIPT_DIR"
  printf '%s\n' "${DIM}Using local checkout: $WORK_DIR${RESET}"
else
  need_cmd curl
  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/coralline-install.XXXXXX") || exit 1
  WORK_DIR="$TEMP_DIR"
  mkdir -p "$WORK_DIR/themes" "$WORK_DIR/test"
  printf '%s\n' "${DIM}Downloading runtime files from $BASE_URL${RESET}"
  download "$BASE_URL/configure.sh" "$WORK_DIR/configure.sh"
  download "$BASE_URL/statusline.sh" "$WORK_DIR/statusline.sh"
  download "$BASE_URL/coralline-float" "$WORK_DIR/coralline-float"
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
