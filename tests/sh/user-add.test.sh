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

test_a_new_account_chooses_its_password_at_the_login_screen() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(shadow_of bob)" ":0"
  assert_contains "$T/calls" "passwd -d -e bob"
  assert_contains "$T/out" "first login"
  assert_contains "$T/usr/share/sddm/themes/omarchy-multiuser/theme.conf.user" "passwordChangeUsers=bob"
}

test_the_account_opens_after_everything_else() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" --luks >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(grep -nE '^(runuser|omarchy-mu-luks-enroll|passwd) ' "$T/calls" | cut -d' ' -f1 | cut -d: -f2 | paste -sd' ')" \
    "runuser omarchy-mu-luks-enroll passwd"
}

test_set_password_asks_for_it_now() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" --set-password >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "passwd bob"
  assert_not_contains "$T/calls" "passwd -d"
  assert_eq "$(shadow_of bob)" "!:20000"
}

test_interactive_answer_keeps_the_old_way() {
  setup
  printf 'n\nn\nn\n' >"$T/gum-answers"
  cat >"$T/stubs/gum" <<'STUB'
#!/bin/bash
if [[ $1 == input ]]; then
  case $* in *username*) echo bob ;; *"Full name"*) echo "Bob B" ;; esac
  exit 0
fi
answer=$(head -1 "$T/gum-answers"); sed -i 1d "$T/gum-answers"
[[ $answer == y ]]
STUB
  omarchy-mu-user-add >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "passwd bob"
  assert_not_contains "$T/calls" "passwd -d"
}

test_english_prompts_fall_back_to_asking_now() {
  setup
  printf 'LANG=en_US.UTF-8\n' >"$T/etc/locale.conf"
  omarchy-mu-user-add bob --full-name "Bob B" >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "this machine's language"
  assert_contains "$T/calls" "passwd bob"
  assert_not_contains "$T/calls" "passwd -d"
  assert_eq "$(shadow_of bob)" "!:20000"
}

test_an_administrator_is_warned_about_first_come() {
  setup
  omarchy-mu-user-add bob --full-name "Bob B" --admin >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "would get root"
  assert_eq "$(shadow_of bob)" ":0"
}

test_first_login_never_replaces_a_password() {
  setup
  omarchy-mu-accounts first-login owner 2>"$T/err" && fail "emptied a password"
  assert_contains "$T/err" "already has a password"
  assert_not_contains "$T/calls" "passwd"
  assert_eq "$(shadow_of owner)" '$6$owner:1'
}

test_first_login_refuses_system_accounts_and_strangers() {
  setup
  omarchy-mu-accounts first-login root 2>"$T/err" && fail "opened root"
  omarchy-mu-accounts first-login nobody 2>"$T/err" && fail "opened an unknown account"
  assert_not_contains "$T/calls" "passwd"
}

test_first_login_without_the_greeter_stays_locked() {
  setup
  printf 'bob:x:1001:1001::/home/bob:/bin/bash\n' >>"$T/etc/passwd"
  printf 'bob:!:20000:0:99999:7:::\n' >>"$T/etc/shadow"
  rm "$T/usr/share/sddm/themes/omarchy-multiuser/Main.qml"
  omarchy-mu-accounts first-login bob 2>"$T/err" && fail "opened it with no greeter to ask"
  assert_contains "$T/err" "isn't installed"
  assert_eq "$(shadow_of bob)" "!:20000"
}

test_first_login_locks_again_when_passwd_goes_wrong() {
  setup
  printf 'bob:x:1001:1001::/home/bob:/bin/bash\n' >>"$T/etc/passwd"
  # Empty but not expired: nothing would ask for a password.
  printf 'bob::20000:0:99999:7:::\n' >>"$T/etc/shadow"
  : >"$T/passwd-fails"
  omarchy-mu-accounts first-login bob 2>"$T/err" && fail "reported success"
  assert_contains "$T/err" "stays locked"
  assert_eq "$(shadow_of bob)" "!:20000"
}

test_first_login_expires_an_empty_password() {
  setup
  printf 'bob:x:1001:1001::/home/bob:/bin/bash\n' >>"$T/etc/passwd"
  printf 'bob::20000:0:99999:7:::\n' >>"$T/etc/shadow"
  omarchy-mu-accounts first-login bob >/dev/null 2>&1 || fail "failed"
  assert_eq "$(shadow_of bob)" ":0"
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
