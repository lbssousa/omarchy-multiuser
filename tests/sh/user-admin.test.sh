#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-user-admin against a fake tree: getent, id, gpasswd and groupadd
# read and edit $T/etc, sudo runs the command as is, and pgrep and gum answer
# from $T/running and $T/gum-answers (see user-stubs.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:owner,bob\ndocker:x:970:\n' >"$T/etc/group"
}
demote_ready() {
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/; s/^omarchy-users:x:950:owner,bob$/omarchy-users:x:950:owner/' "$T/etc/group"
  printf 'root:%s:1::::::\nowner:%s:1::::::\nbob:%s:1::::::\n' "$(pw_hash bob-pass-1)" "$(pw_hash sekret-pw)" "$(pw_hash bob-pass-1)" >"$T/etc/shadow"
  mkdir -p "$T/etc/omarchy-multiuser"
  echo bob >"$T/etc/omarchy-multiuser/root"
}
root_hash() { grep '^root:' "$T/etc/shadow" | cut -d: -f2; }
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
  echo bob >"$T/running"
  echo n >"$T/gum-answers"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?"
  assert_contains "$T/out" "keep sudo until bob logs out"
  assert_not_contains "$T/calls" terminate-user
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  echo y >"$T/gum-answers"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?"
  assert_contains "$T/calls" "loginctl terminate-user bob"
  assert_no_file "$T/still-running"
}

test_demote_says_when_programs_survive_logout() {
  setup
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  echo bob >"$T/running"
  echo bob >"$T/unkillable"
  echo y >"$T/gum-answers"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 && fail "said it logged bob out"
  assert_contains "$T/calls" "pkill -KILL -u bob"
  assert_contains "$T/out" "still running and keep sudo"
}

test_demote_fails_while_something_else_leads_to_root() {
  setup
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/' "$T/etc/group"
  printf 'User bob may run the following commands:\n    (ALL : ALL) ALL\n' >"$T/sudo-l"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 && fail "said the rights were gone"
  assert_contains "$T/out" "still gives bob full sudo"
  assert_not_contains "$T/out" "no longer an administrator"
  assert_eq "$(members wheel)" "owner"
  rm "$T/sudo-l"
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:owner,bob/; s/^docker:x:970:$/docker:x:970:bob/' "$T/etc/group"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 && fail "said the rights were gone with docker"
  assert_contains "$T/out" "docker group"
  assert_not_contains "$T/out" "no longer an administrator"
}

test_rights_and_migration_watcher_go_together() {
  setup
  omarchy-mu-user-admin bob on >/dev/null 2>&1 || fail "exit $?"
  assert_watched bob
  omarchy-mu-user-admin bob off >/dev/null 2>&1 || fail "exit $?"
  assert_not_watched bob
  assert_watched owner
  # Running it on a current administrator repairs a machine that lacks it.
  rm "$(watcher owner)"
  omarchy-mu-user-admin owner on >/dev/null 2>&1 || fail "exit $?"
  assert_watched owner
}

test_last_admin_ignores_accounts_without_a_login() {
  setup
  printf 'svc:x:900:900::/var/lib/svc:/usr/bin/nologin\n' >>"$T/etc/passwd"
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:bob,svc/' "$T/etc/group"
  # owner's session started while in wheel; of the accounts, only bob is left.
  echo wheel >"$T/session-groups"
  omarchy-mu-user-admin bob off 2>"$T/err" && fail "took the last administrator's rights"
  assert_contains "$T/err" "bob is the last administrator"
  assert_eq "$(members wheel)" "bob,svc"
}

test_administrator_through_primary_group_counts() {
  setup
  printf 'carol:x:1002:998::/home/carol:/bin/bash\n' >>"$T/etc/passwd"
  sed -i 's/^wheel:x:998:owner$/wheel:x:998:bob/' "$T/etc/group"
  ME=carol omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(members wheel)" ""
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

test_demoting_roots_holder_hands_root_to_you_first() {
  setup
  demote_ready
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "Root's password is bob's"
  assert_eq "$(cat "$T/etc/omarchy-multiuser/root")" owner
  assert_contains "$T/calls" chpasswd
  assert_eq "$(members wheel)" "owner"
}

test_a_wrong_password_keeps_roots_holder_an_administrator() {
  setup
  demote_ready
  echo not-mine >"$T/gum-answers"
  omarchy-mu-user-admin bob off >"$T/out" 2>&1 && fail "said it worked"
  assert_contains "$T/out" "stays an administrator"
  assert_eq "$(cat "$T/etc/omarchy-multiuser/root")" bob
  assert_eq "$(members wheel)" "owner,bob"
}

test_a_child_is_not_made_an_administrator() {
  setup
  printf 'omarchy-child:x:951:bob\n' >>"$T/etc/group"
  omarchy-mu-user-admin bob on 2>"$T/err" && fail "made a child an administrator"
  assert_contains "$T/err" "child's account"
  assert_eq "$(members wheel)" "owner"
}

run_tests
