#!/usr/bin/env bash
# read_key / decode_key contract + the issue #23 regression guard.
#
# #23: bash 3.2 returns 1 from `read -t` on timeout, indistinguishable from EOF
# (bash 4+ returns >128). read_key polls with a 1s `-t` so an idle terminal
# resize is still redrawn; the old code treated the timeout's rc=1 as EOF and
# raced every menu forward. The fix rejects a non-tty stdin up front, then treats
# any non-key read result as a timeout (a tty in raw mode has no EOF), so its only
# `return 1` is the entry guard. Re-adding an rc-based EOF return reintroduces #23.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CFG="$HERE/../configure.sh"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; fail=1; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$2"; }

# decode_key: pure key mapping, no tty needed.
eval "$(sed -n '/^decode_key() {/,/^}/p' "$CFG")"
KEY=""; decode_key j;          eq "j -> down"        "$KEY" "down"
KEY=""; decode_key k;          eq "k -> up"          "$KEY" "up"
KEY=""; decode_key '';         eq "empty -> enter"   "$KEY" "enter"
KEY=""; decode_key ' ';        eq "space"            "$KEY" "space"
KEY=""; decode_key q;          eq "q -> quit"        "$KEY" "quit"
KEY=""; decode_key $'\033[A';  eq "up arrow"         "$KEY" "up"
KEY=""; decode_key $'\033[B';  eq "down arrow"       "$KEY" "down"
KEY=""; decode_key x;          eq "passthrough"      "$KEY" "x"

# read_key entry guard: a non-interactive stdin returns 1 immediately (no busy
# loop, no phantom key). This is the ONLY EOF-like exit.
eval "$(sed -n '/^read_key() {/,/^}/p' "$CFG")"
resized=0; last_size=""; KEY=""
read_key </dev/null; rc=$?
eq "non-tty stdin returns 1" "$rc" "1"

# #23 guard: read_key's only `return 1` is the entry guard. An rc-based EOF return
# in the poll loop would fire every idle second on bash 3.2 (timeout rc == EOF rc).
n_ret=$(sed -n '/^read_key() {/,/^}/p' "$CFG" | grep -c 'return 1')
eq "read_key has a single (entry-guard) return 1" "$n_ret" "1"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
