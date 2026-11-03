#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-update-log against a fake /tmp, with real open files in /proc.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/tmp"
  log=$T/tmp/omarchy-update.log
  moved=$log.$(id -un)
}

test_a_finished_log_moves_to_its_owner() {
  setup
  echo content >"$log"
  omarchy-mu-update-log || fail "exit $?"
  assert_no_file "$log"
  assert_eq "$(cat "$moved")" content
}

test_replaces_the_owners_previous_log() {
  setup
  echo old >"$moved"
  echo new >"$log"
  omarchy-mu-update-log || fail "exit $?"
  assert_eq "$(cat "$moved")" new
}

test_a_running_update_is_left_alone() {
  setup
  : >"$log"
  # Like script(1), for as long as the update runs.
  sleep 30 9>>"$log" &
  update=$!
  until [[ -e /proc/$update/fd/9 ]]; do sleep 0.02; done
  omarchy-mu-update-log || { kill "$update"; fail "exit $?"; }
  [[ -e $log ]] || { kill "$update"; fail "moved an open log"; }
  kill "$update"
  wait "$update" 2>/dev/null
  omarchy-mu-update-log || fail "exit $?"
  assert_no_file "$log"
  assert_file "$moved"
}

test_nothing_there_is_fine() {
  setup
  omarchy-mu-update-log || fail "exit $?"
}

test_a_planted_link_is_not_followed_or_moved() {
  setup
  echo precious >"$T/target"
  ln -s "$T/target" "$log"
  omarchy-mu-update-log || fail "exit $?"
  [[ -L $log ]] || fail "moved a link"
  assert_eq "$(cat "$T/target")" precious
}

test_a_directory_at_the_destination_stops_it() {
  setup
  mkdir "$moved"
  : >"$log"
  omarchy-mu-update-log 2>/dev/null && fail "moved into a directory"
  assert_file "$log"
  [[ -z $(ls -A "$moved") ]] || fail "wrote into the directory"
}

run_tests
