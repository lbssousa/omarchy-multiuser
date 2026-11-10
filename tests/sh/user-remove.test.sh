#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # literal password hashes
# omarchy-mu-user-remove against a fake tree (see user-stubs.sh).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nsddm:x:900:900::/var/lib/sddm:/usr/bin/nologin\nowner:x:1000:1000::/home/owner:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\ncarol:x:1002:1002::/home/carol:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:bob,carol\ndocker:x:970:\n' >"$T/etc/group"
  # Everyone's password is sekret-pw, what gum answers when it has nothing else.
  {
    echo 'root:!$6$root:1::::::'
    for u in owner bob carol; do echo "$u:$(pw_hash sekret-pw):1::::::"; done
  } >"$T/etc/shadow"
  mkdir -p "$T/home/bob"
}
in_passwd() { grep -q "^$1:" "$T/etc/passwd"; }
# The line number of a call, to compare the order of two.
call_line() { grep -nF -- "$1" "$T/calls" | head -1 | cut -d: -f1; }
assert_nothing_changed() {
  in_passwd bob || fail "bob was removed"
  assert_not_contains "$T/calls" userdel
  assert_not_contains "$T/calls" "usermod -L -e 1 bob"
  assert_not_contains "$T/calls" fprintd-delete
}

test_the_wrong_own_password_keeps_the_account() {
  setup
  printf 'y\nnot-mine\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 && fail "said it removed bob"
  assert_contains "$T/out" "isn't owner's password"
  assert_nothing_changed
}

on_first_console() {
  printf '[{"session":"1","user":"%s","seat":"seat0","class":"user","tty":"tty1"}]\n' "$1" >"$T/sessions"
  mkdir -p "$T/sys/class/tty/tty0"
  echo "$2" >"$T/sys/class/tty/tty0/active"
  echo bob >>"$T/running"
  printf 'y\nsekret-pw\ny\n' >"$T/gum-answers"
}

test_a_desktop_on_the_first_console_leaves_the_login_screen() {
  setup
  on_first_console bob tty3
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "SwitchToGreeter"
  (( $(call_line "loginctl terminate-user bob") < $(call_line SwitchToGreeter) )) || fail "asked before the desktop ended"
  assert_contains "$T/out" "Ctrl+Alt+F3"
  assert_not_contains "$T/out" "didn't come back"
}

test_there_is_no_console_to_come_back_to_from_the_first_one() {
  setup
  on_first_console bob tty1
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "SwitchToGreeter"
  assert_not_contains "$T/out" "Ctrl+Alt"
}

test_a_login_screen_that_cant_come_back_only_warns() {
  setup
  on_first_console bob tty3
  : >"$T/busctl-fails"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/out" "didn't come back"
  assert_contains "$T/out" "Removed bob."
}

test_someone_elses_desktop_on_the_first_console_is_left_alone() {
  setup
  on_first_console carol tty3
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_not_contains "$T/calls" SwitchToGreeter
}

test_removes_account_and_what_it_leaves_behind() {
  setup
  printf 'bob ALL=(ALL) ALL\n' >"$T/etc/sudoers.d/10_bob"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  ! in_passwd bob || fail "bob is still there"
  assert_contains "$T/out" "Removed bob."
  assert_not_contains "$T/out" "mail spool"
  assert_no_file "$T/etc/sudoers.d/10_bob"
  assert_contains "$T/calls" "usermod -L -e 1 bob"
  assert_no_file "$T/var/lib/omarchy-multiuser/password-journal"
  assert_contains "$T/calls" "fprintd-delete bob"
  assert_contains "$T/calls" "loginctl disable-linger bob"
  assert_contains "$T/calls" "omarchy-mu-apply-lock --quiet"
}

test_refuses_system_accounts() {
  setup
  omarchy-mu-user-remove sddm --delete-home 2>"$T/err" && fail "removed a system account"
  assert_contains "$T/err" "sddm is a system account"
  in_passwd sddm || fail "sddm is gone"
  omarchy-mu-user-remove root --delete-home 2>"$T/err" && fail "removed root"
  assert_contains "$T/err" "root is a system account"
  assert_not_contains "$T/calls" userdel
}

test_refuses_itself_a_stranger_and_non_admins() {
  setup
  omarchy-mu-user-remove owner --keep-home 2>"$T/err" && fail "removed itself"
  assert_contains "$T/err" "your own account"
  omarchy-mu-user-remove nobody --keep-home 2>"$T/err" && fail "removed a missing user"
  assert_contains "$T/err" "No such user"
  ME=bob omarchy-mu-user-remove carol --keep-home 2>"$T/err" && fail "a non-admin removed someone"
  assert_contains "$T/err" "Only an administrator"
  assert_not_contains "$T/calls" userdel
}

test_last_administrator_counts_people_who_can_log_in() {
  setup
  printf 'wheel:x:998:bob,sddm\nomarchy-users:x:950:carol\n' >"$T/etc/group"
  # owner's session started while in wheel; of the accounts, only bob is left.
  echo wheel >"$T/session-groups"
  omarchy-mu-user-remove bob --keep-home 2>"$T/err" && fail "removed the last administrator"
  assert_contains "$T/err" "bob is the last administrator"
  in_passwd bob || fail "bob is gone"
}

test_administrator_through_primary_group_counts() {
  setup
  printf 'wheel:x:998:bob\nomarchy-users:x:950:carol\n' >"$T/etc/group"
  sed -i 's/^carol:x:1002:1002:/carol:x:1002:998:/' "$T/etc/passwd"
  echo y >"$T/gum-answers"
  ME=carol omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  ! in_passwd bob || fail "bob is still there"
}

test_asks_about_the_home_keeping_it_by_default() {
  setup
  printf 'n\ny\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "Delete bob's files in /home/bob too?"
  assert_contains "$T/calls" "--default=false"
  assert_contains "$T/calls" "keeping the home directory"
  assert_not_contains "$T/calls" "userdel --remove"
  [[ -d $T/home/bob ]] || fail "the home went"
}

test_asks_about_the_home_and_deletes_it() {
  setup
  printf 'y\ny\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "DELETE their home directory"
  assert_contains "$T/calls" "userdel --remove bob"
}

test_cancelling_a_question_changes_nothing() {
  setup
  echo c >"$T/gum-answers"
  omarchy-mu-user-remove bob >/dev/null 2>&1 && fail "went on after a cancel"
  assert_nothing_changed
  printf 'n\nn\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob >/dev/null 2>&1 && fail "went on after no"
  assert_nothing_changed
}

test_options_answer_the_home_question() {
  setup
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --delete-home >/dev/null 2>&1 || fail "exit $?"
  assert_not_contains "$T/calls" "too?"
  assert_contains "$T/calls" "userdel --remove bob"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove carol --keep-home >/dev/null 2>&1 || fail "exit $?"
  assert_contains "$T/calls" "userdel carol"
}

test_keeps_a_home_with_an_unfinished_disk_password_change() {
  setup
  mkdir -p "$T/home/bob/.local/state/omarchy"
  : >"$T/home/bob/.local/state/omarchy/drive-password.state"
  omarchy-mu-user-remove bob --delete-home 2>"$T/err" && fail "deleted the note"
  assert_contains "$T/err" "unfinished disk password change"
  assert_nothing_changed
  assert_file "$T/home/bob/.local/state/omarchy/drive-password.state"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >/dev/null 2>&1 || fail "exit $?"
  ! in_passwd bob || fail "bob is still there"
}

test_running_programs_are_ended_before_anything_changes() {
  setup
  echo bob >"$T/running"
  printf 'y\nsekret-pw\ny\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "has programs running"
  terminate=$(call_line "loginctl terminate-user bob")
  luks=$(call_line "usermod -L -e 1 bob")
  [[ -n $terminate && $terminate -lt $luks ]] || fail "the keyslot went before the sign-out"
  (( $(call_line "loginctl disable-linger bob") < terminate )) || fail "linger outlived the sign-out"
}

test_declining_the_sign_out_changes_nothing() {
  setup
  echo bob >"$T/running"
  printf 'y\nsekret-pw\nn\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >/dev/null 2>&1 && fail "went on after no"
  assert_nothing_changed
  assert_not_contains "$T/calls" loginctl
}

test_programs_that_survive_stop_it_before_anything_changes() {
  setup
  echo bob >"$T/running"
  echo bob >"$T/unkillable"
  printf 'y\nsekret-pw\ny\n' >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home 2>"$T/err" >/dev/null && fail "went on with programs running"
  assert_contains "$T/calls" "pkill -KILL -u bob"
  assert_contains "$T/err" "nothing was removed"
  assert_nothing_changed
}

test_userdel_failing_leaves_the_account_to_run_again() {
  setup
  printf 'bob ALL=(ALL) ALL\n' >"$T/etc/sudoers.d/10_bob"
  echo account >"$T/userdel-fails"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 && fail "said it worked"
  assert_contains "$T/out" "Run this again"
  assert_no_file "$T/etc/sudoers.d/10_bob"
  assert_not_contains "$T/calls" apply-lock
  rm "$T/userdel-fails"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "second run: exit $?: $(cat "$T/out")"
  ! in_passwd bob || fail "bob is still there"
}

test_userdel_failing_on_the_home_still_finishes_the_rest() {
  setup
  echo home >"$T/userdel-fails"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --delete-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  ! in_passwd bob || fail "bob is still there"
  assert_contains "$T/out" "couldn't delete their home"
  assert_contains "$T/calls" "omarchy-mu-apply-lock --quiet"
  assert_no_file "$T/var/lib/omarchy-multiuser/password-journal"
}

test_root_passes_to_whoever_removes_its_holder() {
  setup
  mkdir -p "$T/etc/omarchy-multiuser"
  echo bob >"$T/etc/omarchy-multiuser/root"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(cat "$T/etc/omarchy-multiuser/root")" owner
  assert_contains "$T/calls" chpasswd
  (( $(call_line chpasswd) < $(call_line "usermod -L -e 1 bob") )) || fail "root kept bob's password while bob went"
}

test_root_stays_when_it_was_someone_elses() {
  setup
  mkdir -p "$T/etc/omarchy-multiuser"
  echo owner >"$T/etc/omarchy-multiuser/root"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_not_contains "$T/calls" chpasswd
  assert_not_contains "$T/calls" "usermod -L root"
}

test_watcher_goes_with_the_account() {
  setup
  printf 'wheel:x:998:owner,bob\nomarchy-users:x:950:carol\n' >"$T/etc/group"
  ln -s /dev/null "$(watcher bob)"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --keep-home >/dev/null 2>&1 || fail "exit $?"
  assert_not_watched bob
  assert_watched owner
}

run_tests
