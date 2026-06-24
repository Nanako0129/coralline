#!/usr/bin/env bash
# Unit test for to_epoch() — the ISO 8601 / epoch parser behind the limit5h and
# limit7d countdowns. Extracts the live function from statusline.sh so this test
# can never drift from the implementation it checks.
#
#   bash test/test-epoch.sh
#
# The fork-free path is checked for byte-equality against the system `date`,
# the reference it replaced. Needs only bash and date (no jq, no git).
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../statusline.sh"

# Pull just the to_epoch function body out of the real script and define it here.
eval "$(sed -n '/^to_epoch() {/,/^}/p' "$SCRIPT")"

# Reference epoch via the system date (GNU first, BSD fallback) — what the old
# implementation produced. The fork-free parser must match it exactly.
ref_epoch() {
  local r s
  r=$(date -u -d "$1" +%s 2>/dev/null) && { echo "$r"; return; }
  s="${1%%[.+]*}"; s="${s%Z}"
  date -ju -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null
}

fail=0
iso() {  # $1=ISO timestamp — assert to_epoch matches the system date
  to_epoch "$1"; local got="$_EP" want; want=$(ref_epoch "$1")
  if [ "$got" = "$want" ]; then
    printf 'ok    %-30s %s\n' "$1" "$got"
  else
    printf 'FAIL  %-30s want=%s got=%s\n' "$1" "$want" "$got"; fail=1
  fi
}

# Spread: epoch boundary, leap years, century non-leap, month edges, far future,
# the 32-bit boundary, fractional seconds, and an explicit +00:00 offset.
iso 1970-01-01T00:00:00Z
iso 1999-12-31T23:59:59Z
iso 2000-01-01T00:00:00Z
iso 2000-02-29T12:00:00Z
iso 2004-02-29T00:00:00Z
iso 2024-02-29T23:59:59Z
iso 2026-03-01T00:00:00Z
iso 2026-06-24T15:20:00Z
iso 2026-12-31T23:59:59Z
iso 2030-01-01T09:30:00Z
iso 2038-01-19T03:14:07Z
iso 2099-12-31T23:59:59Z
iso 2100-03-01T00:00:00Z
iso 2026-06-24T15:20:00.123456Z
iso 2026-06-24T15:20:00+00:00

chk() { [ "$2" = "$3" ] && printf 'ok    %s\n' "$1" || { printf 'FAIL  %s want=%s got=%s\n' "$1" "$3" "$2"; fail=1; }; }

# Epoch-int passthrough (callers that already hold epoch stay fork-free)
to_epoch 1893490200;   chk "epoch-int passthrough" "$_EP" 1893490200
to_epoch 1893490200.5; chk "epoch-float trims"     "$_EP" 1893490200
# Empty input is rejected
to_epoch ""; chk "empty returns non-zero" "$?" 1

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
