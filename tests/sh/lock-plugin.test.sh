#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Stand-ins for the shell's IPC and for the system. The action tests log what
# would have run: nothing here can reach a real reboot.
setup() {
  export HOME=$T/home OMU_LOCK_PLUGIN=$T/plugin
  unset XDG_STATE_HOME XDG_CONFIG_HOME XDG_SEAT_PATH XDG_SESSION_ID
  mkdir -p "$HOME/.config/omarchy" "$T/stubs" "$OMU_LOCK_PLUGIN"
  config=$HOME/.config/omarchy/shell.json
  link=$HOME/.config/omarchy/plugins/lbssousa.lock
  state=$HOME/.local/state/omarchy-multiuser/lock-plugin
  calls=$T/calls
  : >"$calls"
  stub() {
    printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$calls" "${2:-}" >"$T/stubs/$1"
    chmod +x "$T/stubs/$1"
  }
  stub omarchy-notification-wait
  stub omarchy-shell '[[ $1 == lock ]] && echo "${LOCKED:-false}"; exit 0'
  stub omarchy-plugin-enable 'exit ${ENABLE_STATUS:-0}'
  stub sleep
  stub systemctl
  stub omarchy-system
  stub omarchy-toggle-enabled 'exit ${SUSPEND_OFF:-1}'
  stub omarchy-sleep-disabled 'exit ${SLEEP_DISABLED:-1}'
  stub loginctl 'echo "${ACTIVE:-yes}"'
  cat >"$T/stubs/busctl" <<STUB
#!/bin/bash
echo "busctl \$*" >>"$calls"
case "\$*" in
  *CanSwitch*) echo "b \${CAN_SWITCH:-true}" ;;
  *CanSuspend*) echo '{"type":"s","data":["'"\${CAN_SUSPEND:-yes}"'"]}' ;;
  *CanReboot*) echo '{"type":"s","data":["'"\${CAN_REBOOT:-yes}"'"]}' ;;
  *CanPowerOff*) echo '{"type":"s","data":["'"\${CAN_POWEROFF:-yes}"'"]}' ;;
esac
STUB
  chmod +x "$T/stubs/busctl"
  export PATH=$T/stubs:$PATH
}

test_first_login_links_and_enables() {
  setup
  omarchy-mu-lock-plugin-sync
  [[ -L $link ]] || fail "no link"
  assert_eq "$(readlink "$link")" "$OMU_LOCK_PLUGIN"
  assert_contains "$calls" "omarchy-plugin-enable lbssousa.lock"
  assert_file "$state"
}

test_a_user_who_turned_it_off_keeps_it_off() {
  setup
  omarchy-mu-lock-plugin-sync
  : >"$calls"
  omarchy-mu-lock-plugin-sync
  assert_not_contains "$calls" omarchy-plugin-enable
}

test_a_locked_session_keeps_its_lock() {
  setup
  LOCKED=true omarchy-mu-lock-plugin-sync
  assert_not_contains "$calls" omarchy-plugin-enable
  assert_no_file "$state"
}

test_an_unknown_lock_state_changes_nothing() {
  setup
  stub omarchy-shell 'exit 1'
  omarchy-mu-lock-plugin-sync
  assert_not_contains "$calls" omarchy-plugin-enable
}

test_someone_elses_replacement_is_left_alone() {
  setup
  echo '{"disabledPlugins":["omarchy.lock"]}' >"$config"
  omarchy-mu-lock-plugin-sync
  assert_not_contains "$calls" omarchy-plugin-enable
  assert_file "$state"
}

test_a_failed_enable_tries_again_at_the_next_login() {
  setup
  if ENABLE_STATUS=1 omarchy-mu-lock-plugin-sync 2>/dev/null; then fail "should fail"; fi
  assert_no_file "$state"
}

test_no_packaged_plugin_does_nothing() {
  setup
  OMU_LOCK_PLUGIN=$T/none omarchy-mu-lock-plugin-sync
  [[ ! -e $link && ! -L $link ]] || fail "linked nothing"
}

test_remove_brings_omarchy_lock_back() {
  setup
  mkdir -p "$(dirname "$link")" "$(dirname "$state")"
  ln -s "$OMU_LOCK_PLUGIN" "$link"
  : >"$state"
  cat >"$config" <<'JSON'
{"plugins":[{"id":"a.b"},{"id":"lbssousa.lock"}],"disabledPlugins":["omarchy.lock","x.y"],"cloneSourceRestores":["lbssousa.lock"],"bar":{"id":"k"}}
JSON
  omarchy-mu-lock-plugin-sync remove
  assert_eq "$(jq -c '.plugins' "$config")" '[{"id":"a.b"}]'
  assert_eq "$(jq -c '.disabledPlugins' "$config")" '["x.y"]'
  assert_eq "$(jq -c 'has("cloneSourceRestores")' "$config")" false
  assert_eq "$(jq -c '.bar' "$config")" '{"id":"k"}'
  [[ ! -L $link ]] || fail "link left"
  assert_no_file "$state"
}

test_remove_keeps_a_source_the_user_disabled() {
  setup
  echo '{"plugins":[{"id":"lbssousa.lock"}],"disabledPlugins":["omarchy.lock"]}' >"$config"
  omarchy-mu-lock-plugin-sync remove
  assert_eq "$(jq -c '.disabledPlugins' "$config")" '["omarchy.lock"]'
}

test_remove_without_config_is_fine() {
  setup
  omarchy-mu-lock-plugin-sync remove
  assert_no_file "$config"
}

test_capabilities_all() {
  setup
  assert_eq "$(omarchy-mu-lock-action capabilities)" '{"switchUser":true,"suspend":true,"reboot":true,"powerOff":true}'
}

test_capabilities_follow_the_machine() {
  setup
  assert_eq "$(CAN_SWITCH=false omarchy-mu-lock-action capabilities | jq -c .switchUser)" false
  assert_eq "$(SUSPEND_OFF=0 omarchy-mu-lock-action capabilities | jq -c .suspend)" false
  assert_eq "$(SLEEP_DISABLED=0 omarchy-mu-lock-action capabilities | jq -c .suspend)" false
  assert_eq "$(CAN_SUSPEND=na omarchy-mu-lock-action capabilities | jq -c .suspend)" false
  # A prompt for a password would open behind the lock.
  assert_eq "$(CAN_REBOOT=challenge omarchy-mu-lock-action capabilities | jq -c .reboot)" false
  assert_eq "$(CAN_POWEROFF=no omarchy-mu-lock-action capabilities | jq -c .powerOff)" false
}

test_actions_run_what_they_should() {
  setup
  omarchy-mu-lock-action switchUser
  assert_contains "$calls" "SwitchToGreeter"
  omarchy-mu-lock-action suspend
  assert_contains "$calls" "systemctl suspend"
  omarchy-mu-lock-action reboot
  assert_contains "$calls" "omarchy-system reboot"
  omarchy-mu-lock-action powerOff
  assert_contains "$calls" "omarchy-system shutdown"
}

test_unknown_action_is_refused() {
  setup
  omarchy-mu-lock-action rm 2>/dev/null
  assert_eq $? 2
  [[ ! -s $calls ]] || fail "ran something"
}

test_only_an_active_session_blanks() {
  setup
  export XDG_SESSION_ID=7
  ACTIVE=yes omarchy-mu-lock-action session-active || fail "active"
  if ACTIVE=no omarchy-mu-lock-action session-active; then fail "background"; fi
  unset XDG_SESSION_ID
  ACTIVE=no omarchy-mu-lock-action session-active || fail "unknown blanks, as before"
}

run_tests
