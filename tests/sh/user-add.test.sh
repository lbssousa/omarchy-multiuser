#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # literal password hashes
# omarchy-mu-user-add against a fake tree (see user-stubs.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\n' >"$T/etc/passwd"
  printf 'root:$6$root:1::::::\nowner:$6$owner:1::::::\n' >"$T/etc/shadow"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:\n' >"$T/etc/group"
  mkdir -p "$T/usr/share/sddm/themes/omarchy-multiuser"
  : >"$T/usr/share/sddm/themes/omarchy-multiuser/Main.qml"
  printf 'LANG=pt_BR.UTF-8\n' >"$T/etc/locale.conf"
}

shadow_of() { awk -F: -v u="$1" '$1 == u { print $2 ":" $3 }' "$T/etc/shadow"; }

test_the_password_goes_in_after_everything_else() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(grep -E '^(useradd|runuser|omarchy-mu-user-helper) ' "$T/calls" | cut -d' ' -f1,2 | paste -sd,)" \
    "omarchy-mu-user-helper check-new,useradd --create-home,runuser -u,omarchy-mu-user-helper password"
  assert_contains "$T/calls" "omarchy-mu-user-helper password bob"
  # check-new's one password, then the caller's and the new one.
  assert_eq "$(cat "$T/helper-stdin")" $'sekret-pw\nsekret-pw\nsekret-pw'
}

test_a_password_someone_else_has_stops_before_anything_changes() {
  setup
  echo check-new >"$T/helper-fails"
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 && fail "added bob"
  assert_not_contains "$T/calls" useradd
  assert_not_contains "$T/calls" usermod
}

test_passwords_are_asked_until_they_match() {
  setup
  printf 'one-pass\ntwo-pass\ngood-pass\ngood-pass\nmine-pass\n' >"$T/gum-answers"
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "don't match"
  assert_eq "$(cat "$T/helper-stdin")" $'good-pass\nmine-pass\ngood-pass'
}

test_a_password_that_fails_last_says_how_to_finish() {
  setup
  echo password >"$T/helper-fails"
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 && fail "said it worked"
  assert_contains "$T/out" "omarchy-mu-user-password bob"
}

test_interactive_asks_for_everything() {
  setup
  printf 'bob\nBob B\n\nn\n' >"$T/gum-answers"
  omarchy-mu-user-add >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "omarchy-mu-user-helper password bob"
}

test_an_account_can_no_longer_wait_to_choose() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" --set-password 2>"$T/err" && fail "took an option that is gone"
  omarchy-mu-accounts first-login bob 2>"$T/err" && fail "first-login is gone"
  true
}

test_adds_an_account() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/etc/passwd" "bob:x:"
  assert_contains "$T/out" "Created bob"
  assert_not_watched bob
  assert_contains "$T/etc/group" "omarchy-users:x:950:bob"
}

test_a_new_administrator_records_migrations() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" --admin >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_watched bob
  assert_watched owner
}

test_the_baseline_includes_what_first_setup_marks() {
  setup
  mkdir -p "$T/var/lib/omarchy-multiuser/migrations"
  touch "$T/var/lib/omarchy-multiuser/migrations/100.sh"
  # Like omarchy-provision-user --first-install.
  cat >"$T/stubs/runuser" <<'STUB'
#!/bin/bash
mkdir -p "$T/home/bob/.local/state/omarchy/migrations"
touch "$T/home/bob/.local/state/omarchy/migrations/200.sh"
STUB
  omarchy-mu-user-add bob --full-name "Bob B" --admin >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/var/lib/omarchy-multiuser/migration-baselines/bob" "200.sh"
}

test_a_watcher_that_fails_only_warns() {
  setup
  : >"$T/systemctl-fails"
  omarchy-mu-user-add bob --full-name "Bob B" --admin >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "sync-migration-watchers"
  assert_contains "$T/etc/passwd" "bob:x:"
}

test_refuses_while_sddm_conf_logs_someone_in() {
  setup
  printf '[Autologin]\nUser=owner\n' >"$T/etc/sddm.conf"
  omarchy-mu-user-add bob --full-name "Bob B" 2>"$T/err" && fail "added a second person to an automatic login"
  assert_contains "$T/err" "logs someone in automatically"
  assert_not_contains "$T/calls" useradd
}

test_an_sddm_conf_without_automatic_login_is_fine() {
  setup
  printf '[Autologin]\nUser=\n\n[Other]\nUser=owner\n' >"$T/etc/sddm.conf"
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" useradd
}

test_refuses_a_kept_home() {
  setup
  mkdir "$T/home/bob"
  omarchy-mu-user-add bob --full-name "Bob B" 2>"$T/err" && fail "reused a kept home"
  assert_contains "$T/err" "already exists; move it aside first"
  assert_not_contains "$T/calls" useradd
  assert_not_contains "$T/calls" usermod
}

test_refuses_a_group_of_that_name() {
  setup
  printf 'bob:x:1500:\n' >>"$T/etc/group"
  omarchy-mu-user-add bob --full-name "Bob B" 2>"$T/err" && fail "went on with the group there"
  assert_contains "$T/err" "A group named bob already exists"
  assert_not_contains "$T/calls" useradd
  # Nothing protective was changed for an add that can't go ahead.
  assert_not_contains "$T/calls" usermod
}

test_refuses_a_taken_name_and_non_admins() {
  setup
  omarchy-mu-user-add owner --full-name "O" 2>"$T/err" && fail "added a taken name"
  assert_contains "$T/err" "already exists"
  ME=bob omarchy-mu-user-add carol --full-name "C" 2>"$T/err" && fail "a non-admin added someone"
  assert_contains "$T/err" "Only an administrator"
  assert_not_contains "$T/calls" useradd
}

run_tests
