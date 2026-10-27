#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-user-admin against a fake tree: getent, id, gpasswd and groupadd
# read and edit $T/etc, sudo runs the command as is, and loginctl and gum
# answer from $LOGGED_IN and $GUM_ANSWERS.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/stubs" "$T/etc/sudoers.d" "$T/run/lock"
  : >"$T/run/lock/omarchy-mu-accounts.lock"
  cat >"$T/stubs/getent" <<'STUB'
#!/bin/bash
db=$T/etc/$1
[[ -f $db ]] || exit 2
if (( $# == 1 )); then cat "$db"; exit 0; fi
awk -F: -v k="$2" '$1 == k || $3 == k { print; found = 1 } END { exit !found }' "$db"
STUB
  cat >"$T/stubs/id" <<'STUB'
#!/bin/bash
case $1 in
  -un) echo "$ME" ;;
  -nG) awk -F: -v u="${2:-$ME}" '{ n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' "$T/etc/group" | paste -sd' ' ;;
  *) exit 2 ;;
esac
STUB
  cat >"$T/stubs/gpasswd" <<'STUB'
#!/bin/bash
echo "gpasswd $*" >>"$T/calls"
awk -F: -v OFS=: -v op="$1" -v u="$2" -v g="$3" '
  $1 == g {
    n = split($4, m, ","); out = ""
    for (i = 1; i <= n; i++) if (m[i] != u) out = out (out == "" ? "" : ",") m[i]
    if (op == "-a") out = out (out == "" ? "" : ",") u
    $4 = out
  } { print }' "$T/etc/group" >"$T/etc/group.new" && mv "$T/etc/group.new" "$T/etc/group"
STUB
  cat >"$T/stubs/groupadd" <<'STUB'
#!/bin/bash
grep -q "^$2:" "$T/etc/group" || echo "$2:x:950:" >>"$T/etc/group"
STUB
  cat >"$T/stubs/sudo" <<'STUB'
#!/bin/bash
"$@"
STUB
  cat >"$T/stubs/loginctl" <<'STUB'
#!/bin/bash
echo "loginctl $*" >>"$T/calls"
[[ $1 == show-user && " ${LOGGED_IN:-} " == *" $2 "* ]] || [[ $1 == terminate-user ]]
STUB
  # One answer per call: y or n.
  cat >"$T/stubs/gum" <<'STUB'
#!/bin/bash
echo "gum $*" >>"$T/calls"
answer=$(head -1 "$T/gum-answers"); sed -i 1d "$T/gum-answers"
[[ $answer == y ]]
STUB
  : >"$T/gum-answers"
  chmod +x "$T/stubs/"*
  export PATH="$T/stubs:$PATH" ME=owner
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
}
members() { awk -F: -v g="$1" '$1 == g { print $4 }' "$T/etc/group"; }

test_promote() {
  setup
  omarchy-mu-user-admin bob on >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(members wheel)" "owner,bob"
  assert_eq "$(cat "$T/etc/sudoers.d/00-omarchy-wheel")" "%wheel ALL=(ALL:ALL) ALL"
  assert_contains "$T/out" "bob is now an administrator"
  omarchy-mu-user-admin bob on >"$T/out" 2>&1 || fail "second run: exit $?"
  assert_contains "$T/out" "already an administrator"
  assert_eq "$(members wheel)" "owner,bob"
}

test_demote_drops_grants_first() {
  setup
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/; s/^omarchy-users:x:950:owner,bob$/omarchy-users:x:950:owner/' "$T/etc/group"
  printf 'bob ALL=(ALL) ALL\n' >"$T/etc/sudoers.d/10_bob"
  printf 'bob ALL=(ALL) NOPASSWD: ALL\n' >"$T/etc/sudoers.d/99-omarchy-nopasswd-1001"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(members wheel)" "owner"
  assert_eq "$(members omarchy-users)" "owner,bob"
  assert_no_file "$T/etc/sudoers.d/10_bob"
  assert_no_file "$T/etc/sudoers.d/99-omarchy-nopasswd-1001"
  assert_contains "$T/out" "bob is no longer an administrator"
  assert_not_contains "$T/calls" terminate-user
}

test_demote_offers_to_log_out() {
  setup
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  echo n >"$T/gum-answers"
  LOGGED_IN=bob omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?"
  assert_contains "$T/out" "keep sudo until they log out"
  assert_not_contains "$T/calls" terminate-user
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  echo y >"$T/gum-answers"
  LOGGED_IN=bob omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?"
  assert_contains "$T/calls" "loginctl terminate-user bob"
}

test_refusals() {
  setup
  ME=bob omarchy-mu-user-admin owner off 2>/dev/null && fail "a non-admin changed rights"
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  omarchy-mu-user-admin owner off 2>"$T/err" && fail "took away own rights"
  assert_contains "$T/err" "your own"
  sed -i 's/^wheel:x:998:owner,bob$/wheel:x:998:owner/' "$T/etc/group"
  ME=other omarchy-mu-user-admin owner off 2>/dev/null && fail "a non-admin took the last admin's rights"
  # Already outside wheel: nothing to do, and nothing done.
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:carol/' "$T/etc/group"
  ME=carol omarchy-mu-user-admin owner off >"$T/out" 2>&1 || fail "exit $?"
  assert_contains "$T/out" "owner isn't an administrator"
  assert_not_contains "$T/calls" gpasswd
  sed -i 's/^wheel:x:998:carol$/wheel:x:998:owner/' "$T/etc/group"
  omarchy-mu-user-admin root on 2>"$T/err" && fail "changed a system account"
  assert_contains "$T/err" "system account"
  omarchy-mu-user-admin nobody on 2>"$T/err" && fail "changed a missing user"
  assert_contains "$T/err" "No such user"
  assert_eq "$(members wheel)" "owner"
}

test_last_admin_and_primary_group() {
  setup
  printf 'wheel:x:998:owner,bob\nomarchy-users:x:950:owner,bob\n' >"$T/etc/group"
  sed -i 's/^bob:x:1001:1001:/bob:x:1001:998:/' "$T/etc/passwd"
  omarchy-mu-user-admin bob off 2>"$T/err" && fail "dropped a primary group"
  assert_contains "$T/err" "primary group"
  assert_eq "$(members wheel)" "owner,bob"
  ME=bob omarchy-mu-user-admin owner off >/dev/null 2>&1 || fail "couldn't demote owner with bob left"
  printf 'wheel:x:998:bob\n' >"$T/etc/group"
  sed -i 's/^bob:x:1001:998:/bob:x:1001:1001:/' "$T/etc/passwd"
  ME=bob omarchy-mu-user-admin bob off 2>"$T/err" && fail "took own rights"
  true
}

test_asks_when_not_told() {
  setup
  printf 'y\n' >"$T/gum-answers"
  # gum choose answers through stdout in real life; give the name instead.
  omarchy-mu-user-admin bob >/dev/null 2>&1 || fail "exit $?"
  assert_contains "$T/calls" "Make bob an administrator?"
  assert_eq "$(members wheel)" "owner,bob"
  printf 'n\n' >"$T/gum-answers"
  omarchy-mu-user-admin bob >/dev/null 2>&1 && fail "went on after no"
  assert_eq "$(members wheel)" "owner,bob"
}

run_tests
