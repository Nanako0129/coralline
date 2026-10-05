#!/usr/bin/env bash
# Going back from the Layout screen (the left arrow) after a fixed two- or
# three-row layout split the list: Segments edits the first row only, so the
# rows are recombined on the way back and re-split the same way on the way
# forward. Without that, a segment parked on row 2/3 looks disabled, and
# toggling it writes it into two rows. Extracts the live functions from
# configure.sh so the test cannot drift.
#   bash test/test-configure-layout-back.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
CONF="$HERE/../configure.sh"

for f in known_segment normalize_segments has_segment toggle_segment split_segments \
         recombine_segment_rows apply_layout_index layout_selected_index \
         shell_quote write_assign write_candidate_config; do
  eval "$(sed -n "/^$f() {/,/^}/p" "$CONF")"
done
# The real fallback list, as configure.sh declares it.
eval "$(grep '^SEGMENT_CHOICES=' "$CONF")"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s  (%s)\n' "$1" "$2"; fail=1; }

# Globals the functions read.
layout="auto" ; max_lines=3 ; layout_rows=""
segments="" ; segments2="" ; segments3=""
theme="claude-coral" ; style="pill" ; clock_mode="12h" ; clock_seconds=1
name_max=0 ; ascii_mode=0 ; lean_sep="" ; extra_config=""
float_enabled=0 ; float_segments="model ctx cost"
runtime_theme_dir() { printf '/tmp/themes'; }

ALL="dir git model ctx cost clock"

# Names that appear more than once across the three rows (empty = none).
dupes() {
  printf '%s\n' $segments $segments2 $segments3 | sort | uniq -d | tr '\n' ' '
}
rows() { printf '[%s|%s|%s]' "$segments" "$segments2" "$segments3"; }

for n in 2 3; do
  segments="$ALL" ; segments2="" ; segments3="" ; layout="auto" ; layout_rows=""
  apply_layout_index "$n"
  [ -n "$segments2" ] && ok "$n rows: list is split" || bad "$n rows: list is split" "$(rows)"

  # The left arrow from Layout.
  recombine_segment_rows
  [ "$segments" = "$ALL" ] && [ -z "$segments2" ] && [ -z "$segments3" ] \
    && ok "$n rows: recombine puts all six on row 1" || bad "$n rows: recombine puts all six on row 1" "$(rows)"
  [ "$(layout_selected_index)" = "$n" ] \
    && ok "$n rows: layout_selected_index still $n" || bad "$n rows: layout_selected_index still $n" "$(layout_selected_index)"

  # ctx sat on row 2 before; on Segments it is enabled and toggles cleanly.
  toggle_segment ctx
  has_segment ctx && bad "$n rows: toggle removes ctx" "$(rows)" || ok "$n rows: toggle removes ctx"
  toggle_segment ctx
  [ "$(printf '%s\n' $segments | grep -c '^ctx$')" = 1 ] \
    && ok "$n rows: toggle adds ctx back once" || bad "$n rows: toggle adds ctx back once" "$(rows)"

  # Forward to Layout again: the same choice is re-split, nothing doubled.
  apply_layout_index "$(layout_selected_index)"
  [ -n "$segments2" ] && [ -z "$(dupes)" ] \
    && ok "$n rows: re-split with no duplicates" || bad "$n rows: re-split with no duplicates" "$(rows)"
  if [ "$n" = 3 ]; then
    [ -n "$segments3" ] && ok "3 rows: third row restored" || bad "3 rows: third row restored" "$(rows)"
  else
    [ -z "$segments3" ] && ok "2 rows: stays two rows" || bad "2 rows: stays two rows" "$(rows)"
  fi

  # The written config lists every segment in exactly one VL_SEGMENTS* line.
  out=$(mktemp "${TMPDIR:-/tmp}/coralline-layout-back.XXXXXX") || exit 1
  write_candidate_config "$out"
  good=1
  for s in $ALL; do
    c=$(grep '^VL_SEGMENTS[23]*=' "$out" | sed 's/^VL_SEGMENTS[23]*=//; s/\\ / /g; s/'"'"'//g' \
      | tr ' ' '\n' | grep -c "^$s\$")
    [ "$c" = 1 ] || { good=0; bad "$n rows: $s in exactly one VL_SEGMENTS* line" "count=$c"; }
  done
  [ "$good" = 1 ] && ok "$n rows: config lists every segment once"
  rm -f "$out"
done

# Accepted, later back: Layout accepted with two rows, the user moves on, then
# comes back through Layout with the left arrow and edits Segments.
segments="$ALL" ; segments2="" ; segments3="" ; layout="auto" ; layout_rows=""
apply_layout_index 2          # Enter on "fixed two lines"
apply_layout_index "$(layout_selected_index)"   # Layout drawn again on the way back
recombine_segment_rows        # the left arrow from Layout
toggle_segment cost           # cost was on row 2
toggle_segment cost
apply_layout_index "$(layout_selected_index)"   # forward through Layout again
[ "$layout_rows" = 2 ] && [ -z "$segments3" ] && [ -z "$(dupes)" ] \
  && [ "$(printf '%s\n' $segments $segments2 | sort | tr '\n' ' ')" = "$(printf '%s\n' $ALL | sort | tr '\n' ' ')" ] \
  && ok "accepted, later back: two rows, every segment once" || bad "accepted, later back: two rows, every segment once" "$(rows)"

# Callers that set rows directly (p10k import, the plain prompt) still map.
layout="fixed" ; layout_rows="" ; segments="dir" ; segments2="git" ; segments3=""
[ "$(layout_selected_index)" = 2 ] && ok "fallback: rows set directly still read as two" || bad "fallback: rows set directly still read as two" "$(layout_selected_index)"
( unset layout_rows; [ "$(layout_selected_index)" = 2 ] ) \
  && ok "fallback: unset layout_rows is tolerated" || bad "fallback: unset layout_rows is tolerated" "set -u"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
