#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# Stepping aside once Omarchy ships its own Setup › Users (PR #16920): omarchy-mu-handoff,
# and what login-select, sddm-guard, the helper and the account commands do then.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:bob\n' >"$T/etc/group"
  printf 'root:%s:1::::::\nowner:%s:1::::::\nbob:%s:1::::::\n' "$(pw_hash sekret-pw)" "$(pw_hash sekret-pw)" "$(pw_hash bob-pass-1)" >"$T/etc/shadow"
  mkdir -p "$T/etc/omarchy-multiuser" "$T/etc/sddm.conf.d"
  printf 'uuid-1 0 1000 owner fp0\nuuid-1 1 1001 bob fp1\n' >"$T/etc/omarchy-multiuser/slots"
  echo owner >"$T/etc/omarchy-multiuser/root"
  printf '#!/bin/bash\necho rebuild >>"$T/calls"\n' >"$T/stubs/rebuild"
  chmod +x "$T/stubs/rebuild"
  export OMU_REBUILD_BOOT=$T/stubs/rebuild SUDO_USER=owner
}

# Omarchy's own commands, which only say they ran.
omarchy_ships_it() {
  mkdir -p "$T/usr/bin"
  local cmd
  for cmd in omarchy-user-helper omarchy-login-select omarchy-user-password omarchy-user-add omarchy-user-delete; do
    printf '#!/bin/bash\necho "%s $*" >>"$T/calls"\n' "$cmd" >"$T/usr/bin/$cmd"
    chmod +x "$T/usr/bin/$cmd"
  done
}

up() { echo "$T/etc/omarchy/users/$1"; }

test_nothing_happens_before_omarchy_ships_it() {
  setup
  omarchy-mu-handoff >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_no_file "$T/etc/omarchy/users"
  omarchy-mu-handoff --check >"$T/out" || fail "--check failed with nothing to hand over"
}

test_the_records_go_to_omarchy_once() {
  setup
  omarchy_ships_it
  omarchy-mu-handoff --check 2>/dev/null && fail "--check saw nothing to do"
  omarchy-mu-handoff >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_eq "$(cat "$(up slots)")" "$(cat "$T/etc/omarchy-multiuser/slots")"
  assert_eq "$(cat "$(up root)")" owner
  [[ $(stat -c %a "$(up slots)") == 600 ]] || fail "the map is readable by others"
  [[ $(stat -c %a "$T/etc/omarchy/users") == 755 ]] || fail "Omarchy's users dir is private"
  assert_file "$T/var/lib/omarchy-multiuser/handed-over"
  omarchy-mu-handoff --check >/dev/null || fail "--check after the hand-over"
  echo 'uuid-1 2 1002 carol fp2' >>"$T/etc/omarchy-multiuser/slots"
  omarchy-mu-handoff >/dev/null 2>&1 || fail "second run"
  assert_not_contains "$(up slots)" carol
}

test_omarchys_own_records_are_never_overwritten() {
  setup
  omarchy_ships_it
  mkdir -p "$T/etc/omarchy/users"
  echo 'uuid-1 0 1000 owner theirs' >"$(up slots)"
  echo bob >"$(up root)"
  omarchy-mu-handoff >/dev/null 2>&1 || fail "exit $?"
  assert_eq "$(cat "$(up slots)")" 'uuid-1 0 1000 owner theirs'
  assert_eq "$(cat "$(up root)")" bob
}

test_an_unfinished_change_is_finished_first() {
  setup
  omarchy_ships_it
  mkdir -p "$T/var/lib/omarchy-multiuser"
  printf 'op=add\nuser=ghost\nuuid=-\nslot=-\nphase=account\n' >"$T/var/lib/omarchy-multiuser/password-journal"
  omarchy-mu-handoff >/dev/null 2>&1 || fail "exit $?"
  assert_no_file "$T/var/lib/omarchy-multiuser/password-journal"
}

test_the_boot_image_trades_our_wrapper_for_omarchys() {
  setup
  omarchy_ships_it
  : >"$T/etc/omarchy-multiuser/boot-records-slot"
  omarchy-mu-handoff >/dev/null 2>&1 || fail "exit $?"
  assert_contains "$T/calls" rebuild
  assert_no_file "$T/etc/omarchy-multiuser/boot-records-slot"
  assert_file "$(up boot-records-slot)"
}

test_our_helper_changes_nothing_once_omarchy_ships_it() {
  setup
  omarchy_ships_it
  printf 'sekret-pw\nnew-pass-1\n' | omarchy-mu-user-helper password-self 2>"$T/err" && fail "changed a password"
  assert_contains "$T/err" "use Setup › Users"
  printf 'sekret-pw\n' | omarchy-mu-user-helper delete bob 2>/dev/null && fail "deleted bob"
  assert_contains "$T/etc/passwd" "bob:"
  omarchy-mu-user-helper finish </dev/null || fail "finishing our own journal is still ours"
}

test_the_account_commands_hand_over_to_omarchys() {
  setup
  omarchy_ships_it
  omarchy-mu-user-password bob >/dev/null 2>&1 || fail "password"
  assert_contains "$T/calls" "omarchy-user-password bob"
  omarchy-mu-user-add >/dev/null 2>&1 || fail "add"
  assert_contains "$T/calls" "omarchy-user-add"
  echo y >"$T/gum-answers"
  omarchy-mu-user-remove bob --delete-home >"$T/out" 2>&1 || fail "remove: $(cat "$T/out")"
  assert_contains "$T/calls" "omarchy-user-delete bob --delete-home"
  assert_contains "$T/calls" "fprintd-delete bob"
  assert_not_contains "$T/calls" "gum input --password"
}

test_login_select_leaves_the_choice_to_omarchy() {
  setup
  omarchy_ships_it
  export OMU_SYSTEM_DRIVE=''
  managed=$T/etc/sddm.conf.d/zzz-omarchy-mu-autologin.conf
  printf '[Autologin]\nUser=owner\n' >"$managed"
  printf '[Autologin]\nUser=\n' >"$T/etc/sddm.conf.d/zz-omarchy-autologin.conf"
  omarchy-mu-login-select --clear || fail "clear"
  assert_no_file "$managed"
  assert_file "$T/etc/sddm.conf.d/zz-omarchy-autologin.conf"
  omarchy-mu-login-select || fail "select"
  assert_no_file "$managed"
}

test_sddm_guard_takes_our_pam_line_out_next_to_omarchys() {
  setup
  omarchy_ships_it
  mkdir -p "$T/etc/pam.d"
  printf 'auth [success=die default=ignore] pam_exec.so quiet expose_authtok /usr/bin/omarchy-login-match\nauth [success=die default=ignore] pam_exec.so quiet expose_authtok /usr/bin/omarchy-mu-login-match\nauth include system-login\n' >"$T/etc/pam.d/sddm"
  omarchy-mu-sddm-guard >/dev/null 2>&1
  assert_not_contains "$T/etc/pam.d/sddm" omarchy-mu-login-match
  assert_contains "$T/etc/pam.d/sddm" /usr/bin/omarchy-login-match
}

run_tests
