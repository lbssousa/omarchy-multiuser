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
  omarchy-mu-accounts drop-grants bob >"$T/out" 2>&1 || fail "exit $?"
  assert_no_file "$T/etc/sudoers.d/10_bob"
  assert_no_file "$T/etc/sudoers.d/99-omarchy-nopasswd-1001"
  assert_no_file "$T/etc/sudoers.d/99-omarchy-permanent-nopasswd-1001"
  assert_file "$T/etc/sudoers.d/11_bob"
  assert_file "$T/etc/sudoers.d/99-omarchy-nopasswd-1000"
  assert_contains "$T/out" "/etc/sudoers.d/11_bob still names bob"
}

sudo_says() {
  printf '#!/bin/bash\necho "User bob may run the following commands on host:"\ncat <<LIST\n%s\nLIST\n' "$1" >"$T/stubs/sudo"
  chmod +x "$T/stubs/sudo"
}

test_check_root_sees_rules_that_dont_name_the_user() {
  setup
  add_user bob 1001
  local rule
  for rule in '    (ALL : ALL) ALL' '    (ALL) ALL' '    (root) NOPASSWD: ALL' '    (root : root) SETENV: NOPASSWD: ALL' \
    '    (bob, root) ALL' '    (ALL) ALL, !/usr/bin/su'; do
    sudo_says "$rule"
    omarchy-mu-accounts check-root bob >"$T/out" 2>&1 && fail "missed [$rule]"
    assert_contains "$T/out" "still gives bob full sudo"
  done
}

test_check_root_passes_lesser_rules() {
  setup
  add_user bob 1001
  local rule
  for rule in '    (root) /usr/bin/omarchy-mu-fido2-authfile add' '    (root) NOPASSWD: /usr/bin/true' \
    '    (bob) ALL' 'User bob is not allowed to run sudo on host.'; do
    sudo_says "$rule"
    omarchy-mu-accounts check-root bob >"$T/out" 2>&1 || fail "flagged [$rule]: $(cat "$T/out")"
  done
}

test_check_root_says_when_sudo_gives_no_answer() {
  setup
  add_user bob 1001
  printf '#!/bin/bash\nexit 1\n' >"$T/stubs/sudo"
  chmod +x "$T/stubs/sudo"
  omarchy-mu-accounts check-root bob >"$T/out" 2>&1 && fail "took no answer as fine"
  assert_contains "$T/out" "couldn't ask sudo"
}

test_check_root_sees_docker_listed_or_primary() {
  setup
  add_user bob 1001
  sudo_says 'User bob is not allowed to run sudo on host.'
  sed -i 's/^docker:x:970:$/docker:x:970:bob/' "$T/etc/group"
  omarchy-mu-accounts check-root bob >"$T/out" 2>&1 && fail "missed a listed member"
  assert_contains "$T/out" "bob is in the docker group"
  sed -i 's/^docker:x:970:bob$/docker:x:970:/; s/^bob:x:1001:1001:/bob:x:1001:970:/' "$T/etc/group" "$T/etc/passwd"
  omarchy-mu-accounts check-root bob >"$T/out" 2>&1 && fail "missed the primary group"
  assert_contains "$T/out" "bob is in the docker group"
}

test_session_groups_decide_without_a_user() {
  setup
  add_user bob 1001
  # In wheel now, but this session started before that.
  cat >"$T/stubs/id" <<'STUB'
#!/bin/bash
[[ $1 == -nG ]] || { echo bob; exit 0; }
if (( $# == 1 )); then echo "bob users"; else echo "bob users wheel"; fi
STUB
  chmod +x "$T/stubs/id"
  ( lib omu_is_admin ) && fail "omu_is_admin went by the account"
  ( lib omu_is_admin bob ) || fail "omu_is_admin bob went by the session"
  omarchy-mu-is-admin && fail "omarchy-mu-is-admin went by the account"
  omarchy-mu-is-admin bob || fail "omarchy-mu-is-admin bob went by the session"
  cat >"$T/stubs/id" <<'STUB'
#!/bin/bash
[[ $1 == -nG ]] || { echo bob; exit 0; }
if (( $# == 1 )); then echo "bob wheel"; else echo "bob users"; fi
STUB
  ( lib omu_is_admin ) || fail "omu_is_admin went by the account"
  omarchy-mu-is-admin || fail "omarchy-mu-is-admin went by the account"
}

watchers_setup() {
  mkdir -p "$T/etc/systemd/system/multi-user.target.wants"
  wants=$T/etc/systemd/system/multi-user.target.wants
  cat >"$T/stubs/id" <<'STUB'
#!/bin/bash
awk -F: -v u="$2" '{ n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' "$T/etc/group"
grep -q "^$2:" "$T/etc/passwd"
STUB
  cat >"$T/stubs/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$T/calls"
[[ ! -e $T/systemctl-fails ]] || exit 1
case $1 in
  enable) ln -s /dev/null "$T/etc/systemd/system/multi-user.target.wants/${*: -1}" ;;
  disable) rm -f "$T/etc/systemd/system/multi-user.target.wants/${*: -1}" ;;
esac
STUB
  chmod +x "$T/stubs/id" "$T/stubs/systemctl"
  : >"$T/calls"
}

test_watchers_follow_the_administrators() {
  setup
  watchers_setup
  add_user bob 1001
  add_user carol 1002
  add_user svc 1003
  sed -i 's/^svc:.*/svc:x:1003:1003::\/var\/lib\/svc:\/usr\/bin\/nologin/' "$T/etc/passwd"
  printf 'wheel:x:998:owner,carol,svc\ndocker:x:970:\n' >"$T/etc/group"
  # A former administrator, and one whose account is gone.
  ln -s /dev/null "$wants/omarchy-mu-migrate-record@bob.path"
  ln -s /dev/null "$wants/omarchy-mu-migrate-record@gone.path"
  ln -s /dev/null "$wants/omarchy-mu-migrate-record@carol.path"
  omarchy-mu-accounts sync-migration-watchers || fail "exit $?"
  assert_eq "$(ls "$wants")" "omarchy-mu-migrate-record@carol.path
omarchy-mu-migrate-record@owner.path"
  assert_contains "$T/calls" "systemctl enable --now --quiet omarchy-mu-migrate-record@owner.path"
  assert_contains "$T/calls" "systemctl disable --now --quiet omarchy-mu-migrate-record@bob.path"
  # carol's was there already, and a second run changes nothing.
  assert_not_contains "$T/calls" "enable --now --quiet omarchy-mu-migrate-record@carol.path"
  : >"$T/calls"
  omarchy-mu-accounts sync-migration-watchers || fail "second run: exit $?"
  assert_eq "$(cat "$T/calls")" ""
}

assert_watched_here() { [[ -L $wants/omarchy-mu-migrate-record@$1.path ]] || fail "no watcher for $1"; }
marked() { # user migrations...
  local user=$1
  shift
  mkdir -p "$T/home/$user/.local/state/omarchy/migrations"
  for name in "$@"; do touch "$T/home/$user/.local/state/omarchy/migrations/$name.sh"; done
}
record() { # user
  OMU_MIGRATIONS_DIR=$T/migrations omarchy-mu-migrate-record "$1"
}
recorded() { find "$T/var/lib/omarchy-multiuser/migrations" -type f -printf '%f\n' 2>/dev/null | sort | paste -sd' '; }
record_setup() {
  setup
  watchers_setup
  mkdir -p "$T/migrations"
  touch "$T/migrations/100.sh" "$T/migrations/200.sh" "$T/migrations/300.sh"
  add_user bob 1001
  printf 'wheel:x:998:owner\ndocker:x:970:\n' >"$T/etc/group"
}

test_first_administrator_vouches_for_the_machines_history() {
  record_setup
  marked owner 100 200
  omarchy-mu-accounts sync-migration-watchers || fail "exit $?"
  assert_no_file "$T/var/lib/omarchy-multiuser/migration-baselines/owner"
  record owner || fail "exit $?"
  assert_eq "$(recorded)" "100.sh 200.sh"
}

test_a_later_administrators_first_markers_dont_count() {
  record_setup
  marked owner 100
  omarchy-mu-accounts sync-migration-watchers
  record owner
  # bob's first setup marked everything; nobody has run 200.
  marked bob 100 200
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers || fail "exit $?"
  assert_watched_here bob
  record bob || fail "exit $?"
  assert_eq "$(recorded)" "100.sh"
  # What bob runs from now on does count.
  marked bob 300
  record bob || fail "exit $?"
  assert_eq "$(recorded)" "100.sh 300.sh"
  # And the owner's run of 200 still reaches the machine.
  marked owner 200
  record owner || fail "exit $?"
  assert_eq "$(recorded)" "100.sh 200.sh 300.sh"
}

test_the_baseline_stands_when_a_watcher_is_only_retried() {
  record_setup
  marked owner 100
  omarchy-mu-accounts sync-migration-watchers
  marked bob 200
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  : >"$T/systemctl-fails"
  omarchy-mu-accounts sync-migration-watchers && fail "hid the failure"
  rm "$T/systemctl-fails"
  marked bob 300
  omarchy-mu-accounts sync-migration-watchers || fail "exit $?"
  assert_eq "$(cat "$T/var/lib/omarchy-multiuser/migration-baselines/bob")" "200.sh"
}

test_becoming_an_administrator_again_sets_aside_the_time_in_between() {
  record_setup
  marked owner 100
  omarchy-mu-accounts sync-migration-watchers
  marked bob 100
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers
  printf 'wheel:x:998:owner\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers
  assert_no_file "$T/var/lib/omarchy-multiuser/migration-baselines/bob"
  # Outside wheel, its privileged parts were skipped.
  marked bob 200
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers
  record bob || fail "exit $?"
  assert_eq "$(recorded)" ""
}

test_a_baseline_goes_with_the_account() {
  record_setup
  marked owner 100
  omarchy-mu-accounts sync-migration-watchers
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers
  assert_file "$T/var/lib/omarchy-multiuser/migration-baselines/bob"
  sed -i '/^bob:/d' "$T/etc/passwd"
  printf 'wheel:x:998:owner\ndocker:x:970:\n' >"$T/etc/group"
  omarchy-mu-accounts sync-migration-watchers
  assert_no_file "$T/var/lib/omarchy-multiuser/migration-baselines/bob"
}

test_no_watcher_without_its_baseline() {
  record_setup
  marked owner 100
  omarchy-mu-accounts sync-migration-watchers
  printf 'wheel:x:998:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
  # A file where the directory goes.
  mkdir -p "$T/var/lib/omarchy-multiuser"
  : >"$T/var/lib/omarchy-multiuser/migration-baselines"
  omarchy-mu-accounts sync-migration-watchers 2>/dev/null && fail "hid the failure"
  [[ ! -L $wants/omarchy-mu-migrate-record@bob.path ]] || fail "enabled without a baseline"
}

test_watchers_report_a_failure_after_trying_all() {
  setup
  watchers_setup
  add_user bob 1001
  printf 'wheel:x:998:owner,bob\n' >"$T/etc/group"
  : >"$T/systemctl-fails"
  omarchy-mu-accounts sync-migration-watchers && fail "hid the failure"
  assert_contains "$T/calls" "record@owner.path"
  assert_contains "$T/calls" "record@bob.path"
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
