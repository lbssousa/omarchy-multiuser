#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-migrate-notify, with the notification tools and omarchy-migrate
# stubbed, and real flocks on the update locks.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/stubs" "$T/run/lock" "$T/xdg"
  export XDG_RUNTIME_DIR=$T/xdg
  : >"$T/run/lock/omarchy-mu-update.lock"
  : >"$T/calls"
  cat >"$T/stubs/omarchy-migrate" <<'STUB'
#!/bin/bash
[[ -s $T/pending ]] || exit 1
cat "$T/pending"
STUB
  cat >"$T/stubs/omarchy-i18n" <<'STUB'
#!/bin/bash
echo "i18n:$*"
STUB
  cat >"$T/stubs/omarchy-notification-wait" <<'STUB'
#!/bin/bash
echo "wait" >>"$T/calls"
[[ ! -e $T/start-update-during-wait ]] || "$T/start-update-during-wait"
STUB
  cat >"$T/stubs/omarchy-notification-send" <<'STUB'
#!/bin/bash
echo "send $*" >>"$T/calls"
[[ ! -e $T/send-fails ]]
STUB
  cat >"$T/stubs/omarchy-mu-migrate" <<'STUB'
#!/bin/bash
echo "omarchy-mu-migrate $*" >>"$T/calls"
exit "${MIGRATE_STATUS:-0}"
STUB
  printf '#!/bin/bash\nexit %s\n' "${ADMIN_STATUS:-0}" >"$T/stubs/omarchy-mu-is-admin"
  chmod +x "$T/stubs/"*
  export PATH="$T/stubs:$PATH"
}
# Holds a lock file until $T/release appears, and says when it has it. Gives
# up after a while, so a failed test doesn't leave it running.
hold() { # file
  (
    exec 9<"$1"
    flock 9
    : >"$T/held"
    for _ in {1..200}; do
      [[ -e $T/release ]] && break
      sleep 0.05
    done
  ) &
  holder=$!
  until [[ -e $T/held ]]; do sleep 0.05; done
}

test_admin_click_runs_migrations_under_the_lock() {
  setup
  printf '100.sh\n101.sh\n' >"$T/pending"
  omarchy-mu-migrate-notify || fail "exit $?"
  assert_contains "$T/calls" "omarchy-launch-floating-terminal-with-presentation omarchy-mu-migrate"
  assert_not_contains "$T/calls" "presentation omarchy-migrate"
  assert_contains "$T/calls" "i18n:--count 2 migrate.clickToRun 2"
  assert_not_contains "$T/calls" "omarchy-mu-migrate --quiet"
}

test_admin_with_nothing_pending_hears_nothing() {
  setup
  omarchy-mu-migrate-notify || fail "exit $?"
  assert_not_contains "$T/calls" send
}

waits_for() { # lock file
  printf '100.sh\n' >"$T/pending"
  : >"$1"
  hold "$1"
  omarchy-mu-migrate-notify &
  notifier=$!
  sleep 0.4
  assert_not_contains "$T/calls" send
  kill -0 "$notifier" 2>/dev/null || fail "it didn't wait for the update"
  # The update applied them.
  : >"$T/release"
  wait "$holder"
  wait "$notifier" || fail "exit $?"
  assert_contains "$T/calls" send
}

test_admin_waits_for_the_machine_wide_lock() {
  setup
  waits_for "$T/run/lock/omarchy-mu-update.lock"
}

test_admin_waits_for_an_update_started_from_the_bar() {
  setup
  waits_for "$XDG_RUNTIME_DIR/omarchy-update.lock"
}

test_admin_counts_again_after_an_update_in_the_meantime() {
  setup
  printf '100.sh\n' >"$T/pending"
  cat >"$T/start-update-during-wait" <<'EOF2'
#!/bin/bash
rm "$T/start-update-during-wait"
(
  exec 9<"$T/run/lock/omarchy-mu-update.lock"
  flock 9
  : >"$T/held"
  sleep 0.3
  : >"$T/pending"
) &
until [[ -e $T/held ]]; do sleep 0.02; done
EOF2
  chmod +x "$T/start-update-during-wait"
  omarchy-mu-migrate-notify || fail "exit $?"
  assert_not_contains "$T/calls" send
}

test_admin_unreadable_lock_is_not_waited_for() {
  setup
  rm "$T/run/lock/omarchy-mu-update.lock"
  printf '100.sh\n' >"$T/pending"
  omarchy-mu-migrate-notify || fail "exit $?"
  assert_contains "$T/calls" send
}

test_admin_told_in_the_log_when_the_notice_fails() {
  setup
  printf '100.sh\n' >"$T/pending"
  : >"$T/send-fails"
  omarchy-mu-migrate-notify 2>"$T/err" || fail "exit $?"
  assert_contains "$T/err" "  100.sh"
}

test_others_apply_their_own_quietly() {
  ADMIN_STATUS=1 setup
  omarchy-mu-migrate-notify || fail "exit $?"
  assert_contains "$T/calls" "omarchy-mu-migrate --quiet"
  assert_not_contains "$T/calls" send
}

test_others_hear_about_a_failure() {
  ADMIN_STATUS=1 setup
  MIGRATE_STATUS=1 omarchy-mu-migrate-notify || fail "exit $?"
  assert_contains "$T/calls" "A migration failed for your account"
}

run_tests
