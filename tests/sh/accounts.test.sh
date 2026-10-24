#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # literal password hashes
# omarchy-mu-accounts, omu_free_uid and omu_hold_lock against a fake tree,
# with getent, usermod and chpasswd stubbed to read and edit $T/etc.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/stubs" "$T/etc/sudoers.d" "$T/home" "$T/run/lock"
  cat >"$T/stubs/getent" <<'STUB'
#!/bin/bash
db=$T/etc/$1
[[ -f $db ]] || exit 2
if (( $# == 1 )); then cat "$db"; exit 0; fi
awk -F: -v k="$2" '$1 == k || $3 == k { print; found = 1 } END { exit !found }' "$db"
STUB
  cat >"$T/stubs/usermod" <<'STUB'
#!/bin/bash
[[ $1 == -L ]] || exit 2
sed -i -E "s/^($2):([^!]?)/\1:!\2/" "$T/etc/shadow"
STUB
  cat >"$T/stubs/chpasswd" <<'STUB'
#!/bin/bash
[[ $1 == -e ]] || exit 2
while IFS=: read -r user hash; do
  awk -F: -v OFS=: -v u="$user" -v h="$hash" '$1 == u { $2 = h } { print }' "$T/etc/shadow" >"$T/etc/shadow.new"
  mv "$T/etc/shadow.new" "$T/etc/shadow"
done
STUB
  chmod +x "$T/stubs/"*
  export PATH="$T/stubs:$PATH"
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\n' >"$T/etc/passwd"
  printf 'root:$6$root:1::::::\nowner:$6$owner:1::::::\n' >"$T/etc/shadow"
  printf 'wheel:x:998:owner\ndocker:x:970:\n' >"$T/etc/group"
}
add_user() { # name uid
  printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$2" "$2" "$1" >>"$T/etc/passwd"
  printf '%s:$6$%s:1::::::\n' "$1" "$1" >>"$T/etc/shadow"
}
shadow_of() { awk -F: -v u="$1" '$1 == u { print $2 }' "$T/etc/shadow"; }
lib() {
  source "$REPO/lib/omarchy-multiuser/common.sh"
  "$@"
}

test_free_uid_skips_accounts_and_kept_homes() {
  setup
  add_user bob 1001
  mkdir "$T/home/gone"   # owned by whoever runs the test, like a kept home
  me=$(id -u)
  expected=1002
  (( me == 1002 )) && expected=1003
  assert_eq "$(lib omu_free_uid)" "$expected"
  printf 'UID_MIN 2000\n' >"$T/etc/login.defs"
  expected=2000
  (( me == 2000 )) && expected=2001
  assert_eq "$(lib omu_free_uid)" "$expected"
}

test_hold_lock_is_exclusive() {
  setup
  ( lib omu_hold_lock accounts ) 2>/dev/null && fail "held a lock whose file doesn't exist"
  : >"$T/run/lock/omarchy-mu-accounts.lock"
  lib omu_hold_lock accounts || fail "couldn't take a free lock"
  ( lib omu_hold_lock accounts ) && fail "took a lock already held"
  ( lib omu_hold_lock update ) 2>/dev/null && fail "held a lock whose file doesn't exist"
  true
}

test_drop_grants() {
  setup
  add_user bob 1001
  printf 'bob ALL=(ALL) ALL\n' >"$T/etc/sudoers.d/10_bob"
  printf '# kept\nbob ALL=(ALL) ALL\nbob ALL=(ALL) NOPASSWD: /usr/bin/true\n' >"$T/etc/sudoers.d/11_bob"
  printf 'bob ALL=(ALL) NOTAFTER=20260101000000Z NOPASSWD: ALL\n' >"$T/etc/sudoers.d/99-omarchy-nopasswd-1001"
  printf 'bob ALL=(ALL) NOPASSWD: ALL\n' >"$T/etc/sudoers.d/99-omarchy-permanent-nopasswd-1001"
  printf 'owner ALL=(ALL) NOPASSWD: ALL\n' >"$T/etc/sudoers.d/99-omarchy-nopasswd-1000"
  printf 'docker:x:970:owner,bob\n' >>"$T/etc/group"
  omarchy-mu-accounts drop-grants bob >"$T/out" 2>&1 || fail "exit $?"
  assert_no_file "$T/etc/sudoers.d/10_bob"
  assert_no_file "$T/etc/sudoers.d/99-omarchy-nopasswd-1001"
  assert_no_file "$T/etc/sudoers.d/99-omarchy-permanent-nopasswd-1001"
  assert_file "$T/etc/sudoers.d/11_bob"
  assert_file "$T/etc/sudoers.d/99-omarchy-nopasswd-1000"
  assert_contains "$T/out" "/etc/sudoers.d/11_bob still names bob"
  assert_contains "$T/out" "bob is in the docker group"
}

test_ensure_wheel_sudo() {
  setup
  omarchy-mu-accounts ensure-wheel-sudo >/dev/null || fail "exit $?"
  assert_eq "$(cat "$T/etc/sudoers.d/00-omarchy-wheel")" "%wheel ALL=(ALL:ALL) ALL"
  assert_eq "$(stat -c %a "$T/etc/sudoers.d/00-omarchy-wheel")" 440
  assert_eq "$(omarchy-mu-accounts ensure-wheel-sudo)" ""
}

test_root_locked_with_two_accounts() {
  setup
  omarchy-mu-accounts root-sync >/dev/null || fail "exit $?"
  assert_eq "$(shadow_of root)" '$6$root'   # one account: left alone
  add_user bob 1001
  omarchy-mu-accounts root-sync >/dev/null || fail "exit $?"
  assert_eq "$(shadow_of root)" '!$6$root'
  omarchy-mu-accounts lock-root >/dev/null || fail "exit $?"
  assert_eq "$(shadow_of root)" '!$6$root'
}

test_root_back_to_the_only_admin() {
  setup
  add_user bob 1001
  omarchy-mu-accounts lock-root >/dev/null
  sed -i '/^bob:/d' "$T/etc/passwd"
  SUDO_USER=someone omarchy-mu-accounts root-sync >/dev/null
  assert_eq "$(shadow_of root)" '!$6$root'   # not the caller's account
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:/' "$T/etc/group"
  SUDO_USER=owner omarchy-mu-accounts root-sync >/dev/null
  assert_eq "$(shadow_of root)" '!$6$root'   # not an administrator
  sed -i 's/^wheel:x:998:$/wheel:x:998:owner/' "$T/etc/group"
  SUDO_USER=owner omarchy-mu-accounts root-sync >/dev/null
  assert_eq "$(shadow_of root)" '$6$owner'
}

run_tests
