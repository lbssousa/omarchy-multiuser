#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-apply-lock against a fake tree ($OMU_ROOT), with a fake
# OMARCHY_PATH providing the resume hook and stop-timeout sources.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup_tree() {
  mkdir -p "$T/etc/pam.d" "$T/var/lib/fprint" "$T/omarchy/default/systemd/system-sleep" \
    "$T/omarchy/default/systemd/system/fprintd.service.d"
  echo hook >"$T/omarchy/default/systemd/system-sleep/fprintd-resume"
  echo timeout >"$T/omarchy/default/systemd/system/fprintd.service.d/10-stop-timeout.conf"
  export OMARCHY_PATH=$T/omarchy
}

enroll() { mkdir -p "$T/var/lib/fprint/$1/dev0"; echo print >"$T/var/lib/fprint/$1/dev0/7"; }

test_no_prints_password_only() {
  setup_tree
  omarchy-mu-apply-lock --quiet || fail "failed"
  assert_file "$T/etc/pam.d/omarchy-lock-password"
  assert_no_file "$T/etc/pam.d/omarchy-lock-fingerprint"
}

test_any_user_with_prints_keeps_fingerprint() {
  setup_tree
  mkdir -p "$T/var/lib/fprint/alice"   # enrolled nothing
  enroll bob
  omarchy-mu-apply-lock --quiet
  assert_contains "$T/etc/pam.d/omarchy-lock-fingerprint" pam_fprintd.so
  assert_file "$T/usr/lib/systemd/system-sleep/fprintd-resume"
  assert_file "$T/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf"
}

test_last_prints_removed_drops_fingerprint() {
  setup_tree
  enroll bob
  omarchy-mu-apply-lock --quiet
  rm -rf "$T/var/lib/fprint/bob"
  omarchy-mu-apply-lock --quiet
  assert_no_file "$T/etc/pam.d/omarchy-lock-fingerprint"
  assert_no_file "$T/usr/lib/systemd/system-sleep/fprintd-resume"
  assert_no_file "$T/etc/systemd/system/fprintd.service.d"
}

test_check_mode() {
  setup_tree
  omarchy-mu-apply-lock --check && fail "check: prints reported with none"
  enroll bob
  omarchy-mu-apply-lock --check || fail "check: prints not found"
  assert_no_file "$T/etc/pam.d/omarchy-lock-password"
}

test_unchanged_files_are_not_rewritten() {
  setup_tree
  enroll bob
  omarchy-mu-apply-lock --quiet
  before=$(stat -c %i "$T/etc/pam.d/omarchy-lock-fingerprint")
  omarchy-mu-apply-lock --quiet
  assert_eq "$(stat -c %i "$T/etc/pam.d/omarchy-lock-fingerprint")" "$before" "rewritten (would retrigger the path unit)"
}

# omacom/omarchy#19845: a failed PAM write left the resume hook and the
# stop-timeout drop-in behind with no fingerprint PAM service.
test_failed_pam_write_installs_no_resume_recovery() {
  setup_tree
  enroll bob
  mkdir -p "$T/etc/pam.d/omarchy-lock-fingerprint/busy"   # mv -T can't replace it
  omarchy-mu-apply-lock --quiet 2>/dev/null && fail "succeeded despite the PAM write failing"
  assert_no_file "$T/usr/lib/systemd/system-sleep/fprintd-resume"
  assert_no_file "$T/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf"
}

test_failed_resume_hook_takes_pam_back_out() {
  setup_tree
  enroll bob
  mkdir -p "$T/usr/lib/systemd/system-sleep"
  chmod 555 "$T/usr/lib/systemd/system-sleep"
  omarchy-mu-apply-lock --quiet 2>/dev/null && fail "succeeded despite the hook install failing"
  chmod 755 "$T/usr/lib/systemd/system-sleep"
  assert_no_file "$T/etc/pam.d/omarchy-lock-fingerprint"
  assert_no_file "$T/usr/lib/systemd/system-sleep/fprintd-resume"
  assert_no_file "$T/etc/systemd/system/fprintd.service.d/10-stop-timeout.conf"
}

run_tests
