#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-login-once: the one login at the login screen omarchy-mu-login-select
# chose, against a fake tree.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

BOOT=11111111-2222-3333-4444-555555555555

setup() {
  mkdir -p "$T/stubs" "$T/etc" "$T/run/omarchy-multiuser" "$T/proc/sys/kernel/random"
  export PATH="$T/stubs:$PATH"
  echo "$BOOT" >"$T/proc/sys/kernel/random/boot_id"
  printf 'ana:x:1000:1000::/home/ana:/bin/bash\nbia:x:1001:1001::/home/bia:/usr/bin/nologin\n' >"$T/etc/passwd"
  printf '/bin/bash\n/usr/bin/fish\n' >"$T/etc/shells"
  cat >"$T/stubs/getent" <<'STUB'
#!/bin/bash
awk -F: -v k="$2" '$1 == k { print; found = 1 } END { exit !found }' "$T/etc/$1"
STUB
  chmod +x "$T/stubs/getent"
}

ticket() { echo "$T/run/omarchy-multiuser/login-once"; }
give_ticket() { printf '%s %s %s\n' "$1" "${2:-$BOOT}" "${3:-$(date +%s)}" >"$(ticket)"; chmod 600 "$(ticket)"; }
# login-once [args] <user> <password>: the password as pam_exec hands it over,
# its bytes alone.
once() {
  local user=${*: -2:1} password=${*: -1}
  printf '%s' "$password" | PAM_TYPE=auth PAM_USER=$user omarchy-mu-login-once "${@:1:$#-2}"
}

test_the_pass_opens_its_users_login_once() {
  setup
  give_ticket ana
  once ana "" || fail "turned the pass down"
  assert_no_file "$(ticket)"
  if once ana ""; then fail "opened a second login"; fi
}

test_a_typed_password_never_takes_the_pass() {
  setup
  give_ticket ana
  if once ana "ana-pass"; then fail "let a typed password through"; fi
  assert_file "$(ticket)"
  if once --empty ana "ana-pass"; then fail "ended a typed password's attempt"; fi
}

test_the_pass_goes_with_the_first_empty_password_right_or_wrong() {
  setup
  give_ticket ana
  if once bia ""; then fail "opened someone else's login"; fi
  assert_no_file "$(ticket)"
  if once ana ""; then fail "the pass outlived a wrong try"; fi
}

test_an_old_or_other_boots_pass_opens_nothing() {
  setup
  give_ticket ana other-boot
  if once ana ""; then fail "another boot's pass"; fi
  give_ticket ana "$BOOT" $(( $(date +%s) - 120 ))
  if once ana ""; then fail "a pass two minutes old"; fi
  give_ticket ana "$BOOT" $(( $(date +%s) + 120 ))
  if once ana ""; then fail "a pass from the future"; fi
  give_ticket ana "$BOOT" soon
  if once ana ""; then fail "a pass with no time"; fi
}

test_a_link_or_no_pass_opens_nothing() {
  setup
  if once ana ""; then fail "no pass"; fi
  printf 'ana %s %s\n' "$BOOT" "$(date +%s)" >"$T/elsewhere"
  ln -s "$T/elsewhere" "$(ticket)"
  if once ana ""; then fail "followed a link"; fi
}

test_nologin_and_a_shell_outside_etc_shells_stop_it() {
  setup
  give_ticket bia
  if once bia ""; then fail "a nologin shell"; fi
  give_ticket ana
  : >"$T/run/nologin"
  if once ana ""; then fail "with /run/nologin"; fi
}

test_an_empty_password_with_no_pass_ends_the_attempt() {
  setup
  once --empty ana "" || fail "left it to pam_unix and faillock"
}

test_only_an_auth_step_with_a_real_name_counts() {
  setup
  give_ticket ana
  if printf '' | PAM_TYPE=session PAM_USER=ana omarchy-mu-login-once; then fail "another PAM step"; fi
  if printf '' | PAM_TYPE=auth PAM_USER='../ana' omarchy-mu-login-once; then fail "a strange name"; fi
  assert_file "$(ticket)"
}

test_a_password_ending_in_a_nul_is_read_the_same() {
  setup
  give_ticket ana
  if printf 'ana-pass\0' | PAM_TYPE=auth PAM_USER=ana omarchy-mu-login-once; then fail "a typed password"; fi
  printf '\0' | PAM_TYPE=auth PAM_USER=ana omarchy-mu-login-once || fail "an empty one"
}

run_tests
