#!/usr/bin/env bash
# End-to-end test for the VL_GIT_CACHE_TTL git-status cache in read_git(): the
# rendered line must be byte-identical with the cache off, cold (miss) and warm
# (hit); a hit must not spawn git; an expired or unwritable cache must degrade
# silently to a normal render.
#
# Entries live in CORALLINE_DIR/git (CLAUDE_CONFIG_DIR/coralline/git here).
#
#   bash test/test-git-cache.sh
#
# Renders run under the bash running this file, so `/bin/bash test/...` checks
# bash 3.2. Exits non-zero if any case fails. Needs bash, jq and git.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"; mkdir -p "$REPO" "$TMP/shim"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
: > "$REPO/untracked"                                  # → "?" mark

# git shim: log every invocation, then run the real git
REAL_GIT=$(command -v git)
printf '#!/bin/bash\necho x >> "%s/calls"\n[ -n "$T_GITFAIL" ] && exit 1\n[ -n "$T_GITPARTIAL" ] && { "%s" "$@" | head -2; exit 1; }\nexec "%s" "$@"\n' "$TMP" "$REAL_GIT" "$REAL_GIT" > "$TMP/shim/git"
chmod +x "$TMP/shim/git"
# rm shim: log only, then run the real one (a successful publish must fork none)
printf '#!/bin/bash\necho x >> "%s/rmcalls"\nexec "%s" "$@"\n' "$TMP" "$(command -v rm)" > "$TMP/shim/rm"
chmod +x "$TMP/shim/rm"

cat > "$TMP/conf" <<'CONF'
VL_CLOCK=off
VL_SEGMENTS="dir git model"
VL_GIT_CACHE_TTL=${T_TTL:-0}
CONF

render() {  # $1=cwd ; env T_TTL / CLAUDE_CONFIG_DIR steer the cache
  printf '{"cwd":"%s","model":{"display_name":"M"}}' "$1" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 PATH="$TMP/shim:$PATH" "$BASH" "$SCRIPT"
}
calls() { [ -f "$TMP/calls" ] && wc -l < "$TMP/calls" | tr -d ' ' || printf 0; }

fail=0
check() {  # $1=expected  $2=label  $3=actual
  if [ "$3" = "$1" ]; then
    printf 'ok    %-34s\n' "$2"
  else
    printf 'FAIL  %-34s want=%q got=%q\n' "$2" "$1" "$3"; fail=1
  fi
}

export CLAUDE_CONFIG_DIR="$TMP/cfg"
export GIT_CEILING_DIRECTORIES="$TMP"   # a non-repo fixture must not find a parent worktree
GDIR="$TMP/cfg/coralline/git"
key() { printf '%s/%s' "$GDIR" "$(printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#_#g')"; }
CFILE=$(key "$REPO")

BASE=$(T_TTL=0 render "$REPO")
case "$BASE" in *main*) ;; *) echo "FAIL  baseline lacks git segment"; fail=1 ;; esac
[ ! -e "$CFILE" ] && echo "ok    ttl=0 writes no cache" || { echo "FAIL  ttl=0 wrote a cache"; fail=1; }

: > "$TMP/calls"
check "$BASE" "ttl=5 cold output"  "$(T_TTL=5 render "$REPO")"
check "1"     "cold run spawned git" "$(calls)"
[ ! -e "$TMP/rmcalls" ] && echo "ok    successful publish forks no rm" || { echo "FAIL  successful publish forked rm"; fail=1; }
[ -f "$CFILE" ] && echo "ok    cache file written" || { echo "FAIL  no cache file"; fail=1; }
check "drwx------" "cache dir is 0700" "$(ls -ld "$GDIR" | cut -c1-10)"
check "$BASE" "ttl=5 warm output"  "$(T_TTL=5 render "$REPO")"
check "1"     "warm run skipped git" "$(calls)"
grep -q untracked "$CFILE" && { echo "FAIL  entry holds a file name"; fail=1; } || echo "ok    entry holds no file names"

# a hit serves the cached state even after the tree changes; ttl=0 sees the change
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
echo x > "$REPO/staged"; git -C "$REPO" add staged
check "$BASE" "warm output is the cached state" "$(T_TTL=5 render "$REPO")"
FRESH=$(T_TTL=0 render "$REPO")
[ "$FRESH" != "$BASE" ] && echo "ok    ttl=0 sees the new state" || { echo "FAIL  ttl=0 stale"; fail=1; }

# expired stamp → miss → refreshed
sed -i.bak '1s/^[0-9]*/1/' "$CFILE"; rm -f "$CFILE.bak"
check "$FRESH" "expired entry refreshes" "$(T_TTL=5 render "$REPO")"

# a stamp in the future (clock stepped back) is a miss, not a hit until it passes
US=$(printf '\037')
printf '%s%s%s%sstale%s%s\n' "$(( $(date +%s) + 600 ))" "$US" "$REPO" "$US" "$US" "$US" >| "$CFILE"
check "$FRESH" "future stamp is a miss" "$(T_TTL=5 render "$REPO")"

# header cwd mismatch (filename collision) → miss
printf '%s%s/elsewhere%smain%s%s\n' "$(date +%s)" "$US" "$US" "$US" "$US" >| "$CFILE"
: > "$TMP/calls"
check "$FRESH" "cwd mismatch is a miss" "$(T_TTL=5 render "$REPO")"
check "1"      "cwd mismatch spawned git" "$(calls)"

# a line caught mid-write (no newline yet) is a miss
printf '%s%s%s%smain%s' "$(date +%s)" "$US" "$REPO" "$US" "$US" >| "$CFILE"
: > "$TMP/calls"
check "$FRESH" "torn entry is a miss" "$(T_TTL=5 render "$REPO")"
check "1"      "torn entry spawned git" "$(calls)"

# unwritable config dir → still renders normally
check "$FRESH" "unwritable cache dir" "$(CLAUDE_CONFIG_DIR=/dev/null/x T_TTL=5 render "$REPO")"

# non-repo cwd renders identically with and without the cache, and is not cached
NOREPO="$TMP/plain"; mkdir -p "$NOREPO"
A=$(T_TTL=0 render "$NOREPO"); B=$(T_TTL=5 render "$NOREPO"); C=$(T_TTL=5 render "$NOREPO")
check "$A" "non-repo cold" "$B"
check "$A" "non-repo warm" "$C"
[ ! -e "$(key "$NOREPO")" ] && echo "ok    non-repo writes no cache" || { echo "FAIL  non-repo wrote a cache"; fail=1; }

# a failing git is not cached; the next successful render writes the entry
rm -f "$CFILE"
T_GITFAIL=1 T_TTL=5 render "$REPO" >/dev/null
[ ! -e "$CFILE" ] && echo "ok    failing git not cached" || { echo "FAIL  failing git was cached"; fail=1; }
T_GITPARTIAL=1 T_TTL=5 render "$REPO" >/dev/null
[ ! -e "$CFILE" ] && echo "ok    headers-then-failure not cached" || { echo "FAIL  partial status was cached"; fail=1; }
T_TTL=5 render "$REPO" >/dev/null
[ -f "$CFILE" ] && echo "ok    next good render cached" || { echo "FAIL  good render not cached"; fail=1; }

# a symlink under the entry name is never read or written through
rm -f "$CFILE"; echo keep > "$TMP/victim"; ln -s "$TMP/victim" "$CFILE"
: > "$TMP/calls"
check "$FRESH" "symlink entry output" "$(T_TTL=5 render "$REPO")"
check "1"      "symlink entry spawned git" "$(calls)"
check "keep"   "symlink target untouched" "$(cat "$TMP/victim")"
rm -f "$CFILE"

# a symlink planted at this process's temp name is never written through; the
# render falls back to git, and the link is cleared so a later miss can publish
# (a link to a regular file is also refused by noclobber; the FIFO case below is
# the one only the up-front test catches)
VDIR="$TMP/vcfg/coralline/git"; mkdir -p "$VDIR"; echo keep > "$TMP/victim2"
VS='ln -s "$1" "$2/.tmp.$$"; exec "$3" "$4"'
check "$FRESH" "planted temp link output" \
  "$(printf '{"cwd":"%s","model":{"display_name":"M"}}' "$REPO" | CLAUDE_CONFIG_DIR="$TMP/vcfg" T_TTL=5 \
     CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 PATH="$TMP/shim:$PATH" "$BASH" -c "$VS" _ "$TMP/victim2" "$VDIR" "$BASH" "$SCRIPT")"
check "keep" "planted temp link target untouched" "$(cat "$TMP/victim2")"
check "0" "planted temp link removed" "$(ls -A "$VDIR" | grep -c '^\.tmp')"
# a link to a FIFO with no reader must not block the render (noclobber would open it)
# (a blocked writer is released by opening the FIFO, so a regression fails here
# instead of hanging the suite; an alarm did not end the blocked render here)
mkfifo "$TMP/fifo"
printf '{"cwd":"%s","model":{"display_name":"M"}}' "$REPO" | CLAUDE_CONFIG_DIR="$TMP/vcfg" T_TTL=5 \
  CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 PATH="$TMP/shim:$PATH" \
  "$BASH" -c "$VS" _ "$TMP/fifo" "$VDIR" "$BASH" "$SCRIPT" > "$TMP/fout" &
fp=$!; i=0
while kill -0 "$fp" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$fp" 2>/dev/null; then
  : <> "$TMP/fifo"; wait "$fp"   # O_RDWR never blocks, whether or not a writer waits
  echo "FAIL  planted FIFO link blocked the render"; fail=1
else
  wait "$fp"; check "$FRESH" "planted FIFO link does not block" "$(cat "$TMP/fout")"
fi

# the store holds TOKS_KEEP (32) entries: the 32nd evicts nothing, the 33rd the oldest
rm -f "$GDIR"/*; for i in $(seq 1 31); do : > "$GDIR/old$i"; done
touch -t 202001010000 "$GDIR/old1"
T_TTL=5 render "$REPO" >/dev/null
[ -e "$GDIR/old1" ] && echo "ok    32nd entry evicts nothing" || { echo "FAIL  32nd entry evicted"; fail=1; }
check "32" "store holds 32" "$(ls "$GDIR" | wc -l | tr -d ' ')"
rm -f "$CFILE"; : > "$GDIR/old32"
touch -t 202001010000 "$GDIR/old1"
T_TTL=5 render "$REPO" >/dev/null
[ ! -e "$GDIR/old1" ] && echo "ok    oldest entry evicted" || { echo "FAIL  oldest entry kept"; fail=1; }
[ -f "$CFILE" ] && echo "ok    new entry written" || { echo "FAIL  new entry missing"; fail=1; }

# CORALLINE_NO_SAMPLE (wizard preview) reads but never writes or evicts
NCFG="$TMP/ncfg"
CORALLINE_NO_SAMPLE=1 CLAUDE_CONFIG_DIR="$NCFG" T_TTL=5 render "$REPO" >/dev/null
[ ! -e "$NCFG/coralline/git" ] && echo "ok    no-sample writes nothing" || { echo "FAIL  no-sample wrote"; fail=1; }

# an entry with an empty branch is a miss
printf '%s%s%s%s%s%s\n' "$(date +%s)" "$US" "$REPO" "$US" "$US" "$US" >| "$CFILE"
: > "$TMP/calls"
check "$FRESH" "empty branch is a miss" "$(T_TTL=5 render "$REPO")"
check "1"      "empty branch spawned git" "$(calls)"

# a read-only dir holding 32 entries stays as it is when a new cwd misses
ROC="$TMP/rocfg/coralline/git"; mkdir -p "$ROC"; for i in $(seq 1 32); do : > "$ROC/e$i"; done
touch -t 202001010000 "$ROC/e1"; chmod 500 "$ROC"
OTHER="$TMP/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q -b main
CLAUDE_CONFIG_DIR="$TMP/rocfg" T_TTL=5 render "$OTHER" >/dev/null
check "dr-x------" "read-only dir left read-only" "$(ls -ld "$ROC" | cut -c1-10)"
chmod 700 "$ROC"
[ -e "$ROC/e1" ] && echo "ok    read-only dir evicts nothing" || { echo "FAIL  read-only dir evicted e1"; fail=1; }
check "32" "read-only dir gains no entry" "$(ls "$ROC" | wc -l | tr -d ' ')"

# a non-ASCII cwd gets an ASCII entry name on every bash (3.2 ranges follow collation)
UC="$TMP/caf\303\251"; UC=$(printf "$UC"); mkdir -p "$UC"; git -C "$UC" init -q -b main
LC_ALL=en_US.UTF-8 T_TTL=5 render "$UC" >/dev/null
check "0" "entry names are ASCII" "$(ls "$GDIR" | LC_ALL=C grep -c '[^ -~]')"
ls "$GDIR" | grep -q 'caf__*$' && echo "ok    non-ASCII cwd cached" || { echo "FAIL  non-ASCII cwd not cached"; fail=1; }

# a cwd whose entry name is just under NAME_MAX is still cached (the temp name
# must not inherit its length)
NEAR="$TMP/n"; while [ "${#NEAR}" -lt 254 ]; do NEAR="${NEAR}n"; done
mkdir -p "$NEAR"; git -C "$NEAR" init -q -b main
T_TTL=5 render "$NEAR" >/dev/null
[ -f "$(key "$NEAR")" ] && echo "ok    near-NAME_MAX cwd cached" || { echo "FAIL  near-NAME_MAX cwd not cached"; fail=1; }
check "0" "no temp file left" "$(ls -A "$GDIR" | grep -c '^\.tmp')"

# a cwd whose entry name passes NAME_MAX is never cached and never evicts
LONG="$TMP/$(printf 'd%.0s' $(seq 1 250))"; mkdir -p "$LONG"; git -C "$LONG" init -q -b main
N0=$(ls "$GDIR" | wc -l | tr -d ' ')
check "$(T_TTL=0 render "$LONG")" "long cwd output" "$(T_TTL=5 render "$LONG")"
check "$N0" "long cwd evicts nothing" "$(ls "$GDIR" | wc -l | tr -d ' ')"

# a symlinked cache dir is never used, and nothing is written through it
SCFG="$TMP/scfg"; mkdir -p "$SCFG/coralline" "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$SCFG/coralline/git"
: > "$TMP/calls"
check "$FRESH" "symlinked dir output" "$(CLAUDE_CONFIG_DIR="$SCFG" T_TTL=5 render "$REPO")"
check "$FRESH" "symlinked dir warm output" "$(CLAUDE_CONFIG_DIR="$SCFG" T_TTL=5 render "$REPO")"
check "2"      "symlinked dir spawned git" "$(calls)"
check "0"      "nothing written through it" "$(ls "$TMP/elsewhere" | wc -l | tr -d ' ')"

exit "$fail"
