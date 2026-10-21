#!/usr/bin/env bash
# End-to-end test for the VL_GIT_CACHE_TTL git-status cache in read_git(): the
# rendered line must be byte-identical with the cache off, cold (miss) and warm
# (hit); a hit must not spawn git; an expired or unwritable cache must degrade
# silently to a normal render.
#
#   bash test/test-git-cache.sh
#
# Exits non-zero if any case fails. Needs bash, jq and git.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"; mkdir -p "$REPO" "$TMP/shim" "$TMP/cache"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
: > "$REPO/untracked"                                  # → "?" mark

# git shim: log every invocation, then run the real git
REAL_GIT=$(command -v git)
printf '#!/bin/bash\necho x >> "%s/calls"\n[ -n "$T_GITFAIL" ] && exit 1\nexec "%s" "$@"\n' "$TMP" "$REAL_GIT" > "$TMP/shim/git"
chmod +x "$TMP/shim/git"

cat > "$TMP/conf" <<'CONF'
VL_CLOCK=off
VL_SEGMENTS="dir git model"
VL_GIT_CACHE_TTL=${T_TTL:-0}
CONF

render() {  # $1=cwd ; env T_TTL / XDG_CACHE_HOME steer the cache
  printf '{"cwd":"%s","model":{"display_name":"M"}}' "$1" |
    CORALLINE_CONFIG="$TMP/conf" COLUMNS=200 PATH="$TMP/shim:$PATH" bash "$SCRIPT"
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

export XDG_CACHE_HOME="$TMP/cache"
CFILE=$(printf '%s/coralline/git/%s' "$TMP/cache" "$(printf '%s' "$REPO" | sed 's#[^A-Za-z0-9._-]#_#g')")

BASE=$(T_TTL=0 render "$REPO")
case "$BASE" in *main*) ;; *) echo "FAIL  baseline lacks git segment"; fail=1 ;; esac
[ ! -e "$CFILE" ] && echo "ok    ttl=0 writes no cache" || { echo "FAIL  ttl=0 wrote a cache"; fail=1; }

: > "$TMP/calls"
check "$BASE" "ttl=5 cold output"  "$(T_TTL=5 render "$REPO")"
check "1"     "cold run spawned git" "$(calls)"
[ -f "$CFILE" ] && echo "ok    cache file written" || { echo "FAIL  no cache file"; fail=1; }
check "drwx------" "cache dir is 0700" "$(ls -ld "$TMP/cache/coralline/git" | cut -c1-10)"
check "$BASE" "ttl=5 warm output"  "$(T_TTL=5 render "$REPO")"
check "1"     "warm run skipped git" "$(calls)"

# a hit serves the cached text even after the tree changes; ttl=0 sees the change
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
echo x > "$REPO/staged"; git -C "$REPO" add staged
check "$BASE" "warm output is the cached state" "$(T_TTL=5 render "$REPO")"
FRESH=$(T_TTL=0 render "$REPO")
[ "$FRESH" != "$BASE" ] && echo "ok    ttl=0 sees the new state" || { echo "FAIL  ttl=0 stale"; fail=1; }

# expired stamp → miss → refreshed
sed -i.bak '1s/^[0-9]*/1/' "$CFILE"; rm -f "$CFILE.bak"
check "$FRESH" "expired entry refreshes" "$(T_TTL=5 render "$REPO")"

# header cwd mismatch (filename collision) → miss
sed -i.bak "1s#.*#$(date +%s) /elsewhere#" "$CFILE"; rm -f "$CFILE.bak"
check "$FRESH" "cwd mismatch is a miss" "$(T_TTL=5 render "$REPO")"

# unwritable cache dir → still renders normally
check "$FRESH" "unwritable cache dir" "$(XDG_CACHE_HOME=/dev/null/x T_TTL=5 render "$REPO")"

# non-repo cwd renders identically with and without the cache
NOREPO="$TMP/plain"; mkdir -p "$NOREPO"
A=$(T_TTL=0 render "$NOREPO"); B=$(T_TTL=5 render "$NOREPO"); C=$(T_TTL=5 render "$NOREPO")
check "$A" "non-repo cold" "$B"
check "$A" "non-repo warm" "$C"
NCFILE=$(printf '%s/coralline/git/%s' "$TMP/cache" "$(printf '%s' "$NOREPO" | sed 's#[^A-Za-z0-9._-]#_#g')")
[ ! -e "$NCFILE" ] && echo "ok    non-repo writes no cache" || { echo "FAIL  non-repo wrote a cache"; fail=1; }

# a failing git is not cached; the next successful render writes the entry
rm -f "$CFILE"
T_GITFAIL=1 T_TTL=5 render "$REPO" >/dev/null
[ ! -e "$CFILE" ] && echo "ok    failing git not cached" || { echo "FAIL  failing git was cached"; fail=1; }
T_TTL=5 render "$REPO" >/dev/null
[ -f "$CFILE" ] && echo "ok    next good render cached" || { echo "FAIL  good render not cached"; fail=1; }

# pre-existing permissive dir: tightened once, marked, then trusted on warm hits
PCACHE="$TMP/pcache"; PDIR="$PCACHE/coralline/git"
mkdir -p "$PDIR"; chmod 755 "$PDIR"
PFILE=$(printf '%s/%s' "$PDIR" "$(printf '%s' "$REPO" | sed 's#[^A-Za-z0-9._-]#_#g')")
: > "$TMP/calls"
check "$FRESH" "pre-existing cold output" "$(XDG_CACHE_HOME="$PCACHE" T_TTL=5 render "$REPO")"
check "1"      "pre-existing cold spawned git" "$(calls)"
check "drwx------" "pre-existing dir tightened" "$(ls -ld "$PDIR" | cut -c1-10)"
[ -f "$PDIR/.private" ] && echo "ok    marker written" || { echo "FAIL  no marker"; fail=1; }
[ -f "$PFILE" ] && echo "ok    pre-existing entry written" || { echo "FAIL  no pre-existing entry"; fail=1; }
check "$FRESH" "pre-existing warm output" "$(XDG_CACHE_HOME="$PCACHE" T_TTL=5 render "$REPO")"
check "1"      "pre-existing warm skipped git" "$(calls)"

# unmarked dir: an existing entry is not served, git is spawned
rm -f "$PDIR/.private"
check "$FRESH" "unmarked output" "$(XDG_CACHE_HOME="$PCACHE" T_TTL=5 render "$REPO")"
check "2"      "unmarked entry not served" "$(calls)"

# symlinked marker planted in a shared-writable dir: never trusted, never written through
LCACHE="$TMP/lcache"; LDIR="$LCACHE/coralline/git"
mkdir -p "$LDIR"; chmod 777 "$LDIR"
echo keep > "$TMP/victim"; ln -s "$TMP/victim" "$LDIR/.private"
LFILE=$(printf '%s/%s' "$LDIR" "$(printf '%s' "$REPO" | sed 's#[^A-Za-z0-9._-]#_#g')")
: > "$TMP/calls"
check "$FRESH" "symlink marker cold output" "$(XDG_CACHE_HOME="$LCACHE" T_TTL=5 render "$REPO")"
check "1"      "symlink marker cold spawned git" "$(calls)"
check "keep"   "symlink target untouched" "$(cat "$TMP/victim")"
[ ! -e "$LFILE" ] && echo "ok    symlink marker writes no entry" || { echo "FAIL  symlink marker wrote an entry"; fail=1; }
check "$FRESH" "symlink marker warm output" "$(XDG_CACHE_HOME="$LCACHE" T_TTL=5 render "$REPO")"
check "2"      "symlink marker warm spawned git" "$(calls)"

# read side: a valid entry whose marker became a symlink is not served
RCACHE="$TMP/rcache"; RDIR="$RCACHE/coralline/git"
XDG_CACHE_HOME="$RCACHE" T_TTL=5 render "$REPO" >/dev/null
rm -f "$RDIR/.private"; ln -s "$TMP/victim" "$RDIR/.private"
: > "$TMP/calls"
check "$FRESH" "symlink marker read output" "$(XDG_CACHE_HOME="$RCACHE" T_TTL=5 render "$REPO")"
check "1"      "symlink marker read spawned git" "$(calls)"

exit "$fail"
