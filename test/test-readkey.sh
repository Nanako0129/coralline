#!/usr/bin/env bash
# read_key contract + the issue #23 regression guard.
#
# #23: bash 3.2 returns 1 from `read -t` on timeout, indistinguishable from EOF,
# so the wizard's 1s `-t` poll made every idle second look like EOF and raced
# the menus forward. The main read must therefore NOT use `-t`; resize comes from
# the SIGWINCH trap flag. The only `read -t` left in read_key are the two ESC
# follow-up reads (lone-Esc disambiguation), where timeout and EOF are both
# handled as "no more bytes" via `|| k=""`, so the 3.2 rc ambiguity is harmless.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CFG="$HERE/../configure.sh"
fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s — %s\n' "$1" "$2"; fail=1; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "want=$3 got=$2"; }

# Guard: read_key has exactly the two ESC-branch `read -t` calls, none on the
# main read. Re-adding `-t` to the main read (3 total) reintroduces #23.
n_t=$(sed -n '/^read_key() {/,/^}/p' "$CFG" | grep -c 'read -rsn1 -t')
eq "read_key main read has no -t timeout" "$n_t" "2"

# Behaviour: pull read_key out and exercise its decode/EOF/resize contract.
eval "$(sed -n '/^read_key() {/,/^}/p' "$CFG")"
resized=0; KEY=""

read_key <<<'j'; eq "j decodes to down" "$KEY" "down"
read_key <<<'k'; eq "k decodes to up"   "$KEY" "up"
KEY=""; read_key </dev/null; rc=$?
eq "EOF returns 1"        "$rc"  "1"
eq "EOF leaves KEY unset" "$KEY" ""
resized=1; read_key </dev/null
eq "resize flag wins"     "$KEY" "resize"
eq "resize flag cleared"  "$resized" "0"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
