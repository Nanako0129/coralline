#!/usr/bin/env bash
# coralline installer. Works from a local clone or via:
#   curl -fsSL https://raw.githubusercontent.com/Nanako0129/coralline/main/install.sh | bash

set -u

REF="${CORALLINE_REF:-main}"
BASE_URL="${CORALLINE_BASE_URL:-https://raw.githubusercontent.com/Nanako0129/coralline/$REF}"
THEMES="claude-coral catppuccin-mocha nord gruvbox-dark tokyo-night dracula mono"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)
WORK_DIR=""
TEMP_DIR=""

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
  curl -fsSL "$src" -o "$dst" || die "failed to download $src"
}

cleanup() {
  [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

info "installing statusline"
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
  download "$BASE_URL/test/sample-input.json" "$WORK_DIR/test/sample-input.json"
  for theme in $THEMES; do
    download "$BASE_URL/themes/$theme.conf" "$WORK_DIR/themes/$theme.conf"
  done
fi

ok "starting visual setup"
if [ -r /dev/tty ] && [ -t 1 ]; then
  exec bash "$WORK_DIR/configure.sh" --install "$@" < /dev/tty
fi
exec bash "$WORK_DIR/configure.sh" --install "$@"
