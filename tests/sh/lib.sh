# shellcheck shell=bash
# Minimal test harness: each test_* function runs in a subshell with a fresh
# $T (temp dir) and the repo's bin/ first on PATH. Assertion helpers fail the
# test with a message.
set -uo pipefail
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export PATH="$REPO/bin:$PATH"
export OMU_SHARE=$REPO/share
pass=0 fail=0

fail() { echo "    $*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected [$2], got [$1]${3:+ ($3)}"; }
assert_file() { [[ -f $1 ]] || fail "missing file $1"; }
assert_no_file() { [[ ! -e $1 ]] || fail "unexpected file $1"; }
assert_contains() { grep -qF -- "$2" "$1" || fail "$1 lacks [$2]"; }
assert_not_contains() { ! grep -qF -- "$2" "$1" || fail "$1 has [$2]"; }

run_tests() {
  local t
  for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    if ( T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; export T OMU_ROOT=$T; "$t" ); then
      echo "ok   $t"; pass=$((pass + 1))
    else
      echo "FAIL $t"; fail=$((fail + 1))
    fi
  done
  echo "# $(basename "$0"): $pass passed, $fail failed"
  (( fail == 0 ))
}
