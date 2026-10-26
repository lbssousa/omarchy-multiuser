#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # migration bodies are literal shell code
# omarchy-mu-migrate as a non-admin (OMU_FORCE_NON_ADMIN), with fake
# migrations, a fake HOME and a fake machine registry.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  export OMU_FORCE_NON_ADMIN=1 HOME=$T/home OMARCHY_PATH=$T/omarchy
  export OMU_MIGRATIONS_DIR=$T/omarchy/migrations OMU_MIGRATION_OVERRIDES=$T/overrides.tsv
  mkdir -p "$OMU_MIGRATIONS_DIR" "$HOME" "$T/omarchy/bin" "$T/var/lib/omarchy-multiuser/migrations"
  : >"$OMU_MIGRATION_OVERRIDES"
  # A command that declares it needs sudo, like omarchy-pkg-add.
  printf '#!/bin/bash\n# omarchy:requires-sudo=true\nsudo pacman -S "$@"\n' >"$T/omarchy/bin/omarchy-pkg-add"
  chmod +x "$T/omarchy/bin/omarchy-pkg-add"
  export PATH="$T/omarchy/bin:$PATH"
}
migration() { printf '%s\n' "$2" >"$OMU_MIGRATIONS_DIR/$1.sh"; }
register() { touch "$T/var/lib/omarchy-multiuser/migrations/$1.sh"; }
marker() { echo "$HOME/.local/state/omarchy/migrations/$1.sh"; }
classify() {
  source "$REPO/lib/omarchy-multiuser/common.sh"
  source "$REPO/lib/omarchy-multiuser/migrations.sh"
  omu_migration_class "$OMU_MIGRATIONS_DIR/$1.sh"
}

test_classification() {
  setup
  migration 100 'touch "$HOME/.config/x"'
  migration 101 'sudo systemctl enable foo.service'
  migration 102 'omarchy-pkg-add foo'
  migration 103 'sudo pacman -S foo; touch ~/.config/foo'
  migration 104 '# sudo is only mentioned here
echo hi'
  migration 105 '/usr/bin/sudo true'
  assert_eq "$(classify 100)" user
  assert_eq "$(classify 101)" system
  assert_eq "$(classify 102)" system
  assert_eq "$(classify 103)" mixed
  assert_eq "$(classify 104)" user
  assert_eq "$(classify 105)" system
  printf '104.sh\tsystem\n' >"$OMU_MIGRATION_OVERRIDES"
  assert_eq "$(classify 104)" system
}

test_user_migration_runs() {
  setup
  migration 100 'touch "$HOME/ran-100"'
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$HOME/ran-100"
  assert_file "$(marker 100)"
}

test_system_migration_waits_for_admin_then_marks() {
  setup
  migration 100 'sudo touch /should-not-run'
  migration 101 'touch "$HOME/ran-101"'
  omarchy-mu-migrate --quiet
  assert_eq $? 3
  assert_no_file "$(marker 100)"
  assert_no_file "$HOME/ran-101"   # order is kept: 101 waits behind 100
  register 100
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$(marker 100)"
  assert_file "$HOME/ran-101"
}

test_mixed_runs_user_part_after_admin() {
  setup
  migration 100 'sudo pacman -S foo
touch "$HOME/ran-100"'
  omarchy-mu-migrate --quiet
  assert_eq $? 3
  assert_no_file "$HOME/ran-100"
  register 100
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$HOME/ran-100"
  assert_contains "$HOME/.local/state/omarchy-multiuser/migrate.log" "skipped (done by an admin): sudo pacman -S foo"
}

test_mixed_sudo_tee_keeps_the_pipe_open() {
  setup
  # More than a pipe buffer: a stub that doesn't read would break the writer.
  migration 100 'head -c 300000 /dev/zero | sudo tee /etc/x >/dev/null
touch "$HOME/ran-100"'
  register 100
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$HOME/ran-100"
}

test_mixed_step_about_this_account_waits_for_admin() {
  setup
  migration 100 'sudo gpasswd -d "$USER" input
touch "$HOME/ran-100"'
  register 100
  omarchy-mu-migrate --quiet 2>/dev/null
  assert_eq $? 3
  assert_no_file "$(marker 100)"
  assert_no_file "$HOME/ran-100"
  assert_contains "$HOME/.local/state/omarchy-multiuser/migrate.log" "waiting for an admin: 100.sh (mixed, for this account: sudo gpasswd -d $(id -un) input)"
}

test_mixed_step_naming_this_account_in_other_forms() {
  setup
  local me; me=$(id -un)
  migration 100 "sudo chown $me:$me /x"
  migration 101 "sudo chown root:$me /x"
  migration 102 'sudo rm -f "$HOME/.config/x"'
  migration 103 "sudo cat /etc/usbguard/IPCAccessControl.d/$me"
  local n
  for n in 100 101 102 103; do
    printf '%s.sh\tmixed\n' "$n" >"$OMU_MIGRATION_OVERRIDES"
    register "$n"
    omarchy-mu-migrate --quiet 2>/dev/null
    assert_eq $? 3 "migration $n"
    rm -f "$OMU_MIGRATIONS_DIR/$n.sh"
  done
}

test_mixed_step_only_sharing_a_name_is_skipped() {
  setup
  local me; me=$(id -un)
  # The program (and sudo's own -u value) aren't the account's arguments.
  migration 100 "sudo -u root /usr/bin/$me --flag
sudo -- $me
touch \"\$HOME/ran-100\""
  register 100
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$HOME/ran-100"
}

test_mixed_failing_check_about_this_account_still_completes() {
  setup
  # A sudo check whose failure the migration handles itself.
  migration 100 '[[ $(sudo cat "/etc/usbguard/IPCAccessControl.d/$USER" 2>/dev/null) == x ]] || true
sudo systemctl disable --now foo
touch "$HOME/ran-100"'
  register 100
  omarchy-mu-migrate --quiet || fail "exit $?"
  assert_file "$HOME/ran-100"
  assert_file "$(marker 100)"
}

test_misclassified_user_migration_fails_loudly() {
  setup
  printf '100.sh\tuser\n' >"$OMU_MIGRATION_OVERRIDES"
  migration 100 'sudo touch /x'
  omarchy-mu-migrate --quiet 2>/dev/null
  assert_eq $? 1
  assert_no_file "$(marker 100)"
  assert_contains "$HOME/.local/state/omarchy-multiuser/migrate.log" "FAILED 100.sh"
}

test_pending_lists_unmarked() {
  setup
  migration 100 'true'
  migration 101 'true'
  mkdir -p "$(dirname "$(marker 100)")"; touch "$(marker 100)"
  assert_eq "$(omarchy-mu-migrate --pending)" "101.sh"
}

run_tests
