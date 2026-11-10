#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# The commands root runs for someone else without a root password (lib/security.sh):
# they start only as `bash -p` by their shebang, pass no exported function on, and
# as root through sudo, pkexec or PAM ignore the fake tree. fakeroot stands in for
# root: it makes EUID 0 without giving the tests any real power.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

HARDENED=(omarchy-mu-user-helper omarchy-mu-login-match omarchy-mu-fido2-authfile omarchy-mu-apply-lock)

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nbob:x:1001:1001::/home/bob:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:bob\n' >"$T/etc/group"
  printf 'root:!:1::::::\nowner:%s:1::::::\nbob:%s:1::::::\n' "$(pw_hash owner-pass)" "$(pw_hash bob-pass)" >"$T/etc/shadow"
  mkdir -p "$T/etc/omarchy-multiuser"
  echo owner >"$T/etc/omarchy-multiuser/root"
  printf '#!/bin/bash\nprintf "h\\nh\\n"\n' >"$T/stubs/faillock"
  chmod +x "$T/stubs/faillock"
  # The real sleep: omarchy-mu-login-match's watchdog would go off at once.
  rm -f "$T/stubs/sleep"
  export SUDO_USER=owner
}

# What common.sh leaves of the overrides and PATH, under fakeroot with $1 set.
library_sees() {
  fakeroot -- env "$@" OMU_ROOT="$T" OMU_SHADOW="$T/shadow" PATH="$T/evil:$PATH" \
    bash -c 'source "$1/lib/omarchy-multiuser/common.sh"; printf "%s|%s|%s" "$OMU_ROOT" "$OMU_SHADOW" "$PATH"' _ "$REPO"
}

test_started_through_bash_they_refuse() {
  setup
  local cmd
  for cmd in "${HARDENED[@]}"; do
    bash "$REPO/bin/$cmd" --check </dev/null >/dev/null 2>"$T/err" && fail "$cmd ran under plain bash"
    assert_contains "$T/err" "bash -p"
    bash -p "$REPO/bin/$cmd" --check </dev/null >/dev/null 2>"$T/err" && fail "$cmd ran under bash -p by hand"
    assert_contains "$T/err" "bash -p"
  done
}

test_started_by_name_they_run() {
  setup
  assert_eq "$(omarchy-mu-user-helper root-holder 2>"$T/err")" owner "$(cat "$T/err")"
}

test_exported_functions_dont_reach_what_they_run() {
  setup
  # getent (a stub, plain bash) runs awk: an imported awk would leave $T/pwned.
  env 'BASH_FUNC_awk%%=() { : >"$T/pwned"; command awk "$@"; }' BASH_ENV="$T/bash-env" \
    omarchy-mu-user-helper root-holder >"$T/out" 2>"$T/err" || fail "exit $?: $(cat "$T/err")"
  assert_eq "$(cat "$T/out")" owner
  assert_no_file "$T/pwned"
}

test_root_for_someone_else_drops_the_overrides() {
  local who
  for who in SUDO_USER=owner PKEXEC_UID=1000 PAM_TYPE=auth; do
    assert_eq "$(library_sees "$who")" "|/etc/shadow|/usr/local/sbin:/usr/local/bin:/usr/bin" "$who"
  done
}

test_root_on_its_own_keeps_the_overrides() {
  # The FIDO2 tests run that way; so do pacman hooks and services, whose
  # environment is root's own.
  assert_eq "$(library_sees FOO=1)" "$T|$T/shadow|$T/evil:$PATH"
}

test_the_helper_as_root_ignores_the_fake_tree() {
  setup
  out=$(fakeroot -- omarchy-mu-user-helper root-holder 2>/dev/null)
  [[ $out != owner ]] || fail "read root's holder from the fake tree"
}

test_login_match_under_pam_ignores_the_fake_tree() {
  setup
  printf '%s\0' bob-pass | PAM_TYPE=auth PAM_USER=owner omarchy-mu-login-match || fail "no match on the fake tree"
  if printf '%s\0' bob-pass | PAM_TYPE=auth PAM_USER=owner fakeroot -- omarchy-mu-login-match 2>/dev/null; then
    fail "matched a password against the fake tree as root"
  fi
}

run_tests
