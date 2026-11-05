#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
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
  stub loginctl '[[ $1 == list-sessions ]] && { echo "${SESSIONS:-[]}"; exit 0; }; [[ $1 == activate ]] && exit ${ACTIVATE_STATUS:-0}; echo "${ACTIVE:-yes}"'
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

# The package's own function, with the system's account list and runuser stood
# in for: the stand-in runs the command as given, on this checkout's script.
removal() {
  setup
  ana=$T/homes/ana sys=$T/homes/sys
  mkdir -p "$ana/.config/omarchy/plugins" "$sys/.config/omarchy"
  ln -s "$OMU_LOCK_PLUGIN" "$ana/.config/omarchy/plugins/lbssousa.lock"
  local enabled='{"plugins":[{"id":"lbssousa.lock"}],"disabledPlugins":["omarchy.lock"],"cloneSourceRestores":["lbssousa.lock"]}'
  echo "$enabled" >"$ana/.config/omarchy/shell.json"
  echo "$enabled" >"$sys/.config/omarchy/shell.json"
  cat >"$T/stubs/getent" <<STUB
#!/bin/bash
echo "root:x:0:0::/root:/bin/bash"
echo "sys:x:999:999::$sys:/bin/bash"
echo "ana:x:1000:1000::$ana:/bin/bash"
echo "gone:x:1001:1001::$T/homes/none:/bin/bash"
echo "svc:x:1002:1002::$sys:/usr/bin/nologin"
echo "nobody:x:65534:65534::$sys:/bin/bash"
STUB
  cat >"$T/stubs/runuser" <<STUB
#!/bin/bash
echo "runuser \$2" >>"$calls"
[[ \$2 != \${FAILS_FOR:-} ]] || exit 1
shift 3
exec "\${@/#\/usr\/bin\//}"
STUB
  chmod +x "$T/stubs/getent" "$T/stubs/runuser"
  # shellcheck source=../../packaging/omarchy-multiuser.install
  source "$REPO/packaging/omarchy-multiuser.install"
}

test_removing_the_package_restores_every_accounts_lock() {
  removal
  _restore_lock_screens 2>"$T/err"
  assert_eq "$(jq -c .disabledPlugins "$ana/.config/omarchy/shell.json")" '[]'
  assert_eq "$(jq -c .plugins "$ana/.config/omarchy/shell.json")" '[]'
  [[ ! -L $ana/.config/omarchy/plugins/lbssousa.lock ]] || fail "link left"
  [[ ! -s $T/err ]] || fail "complained: $(cat "$T/err")"
}

test_removing_the_package_leaves_other_accounts_alone() {
  removal
  _restore_lock_screens 2>/dev/null
  assert_eq "$(grep -c '^runuser' "$calls")" 1
  assert_contains "$calls" "runuser ana"
  assert_contains "$sys/.config/omarchy/shell.json" lbssousa.lock
}

test_removing_the_package_says_whose_lock_it_couldnt_restore() {
  removal
  FAILS_FOR=ana _restore_lock_screens 2>"$T/err"
  assert_contains "$T/err" "Couldn't restore ana's lock screen"
  assert_contains "$ana/.config/omarchy/shell.json" lbssousa.lock
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

test_switching_waits_for_the_first_console() {
  setup
  held='[{"session":"1","user":"ana","seat":"seat0","class":"user","tty":"tty1"}]'
  assert_eq "$(SESSIONS=$held omarchy-mu-lock-action capabilities | jq -c .switchUser)" false
  # Only that entry: the rest of the lock screen stays.
  assert_eq "$(SESSIONS=$held omarchy-mu-lock-action capabilities | jq -c .reboot)" true
  on_its_own='[{"session":"3","user":"ana","seat":"seat0","class":"user","tty":"tty2"},{"session":"c1","user":"sddm","seat":"seat0","class":"greeter","tty":"tty1"},{"session":"4","user":"ana","seat":null,"class":"manager","tty":null}]'
  assert_eq "$(SESSIONS=$on_its_own omarchy-mu-lock-action capabilities | jq -c .switchUser)" true
}

test_switching_is_not_offered_when_the_sessions_cant_be_read() {
  setup
  assert_eq "$(SESSIONS='not json' omarchy-mu-lock-action capabilities | jq -c .switchUser)" false
  stub loginctl 'exit 1'
  assert_eq "$(omarchy-mu-lock-action capabilities | jq -c .switchUser)" false
}

test_a_running_login_screen_is_gone_back_to() {
  setup
  SESSIONS='[{"session":"c1","user":"sddm","seat":"seat0","class":"greeter","tty":"tty1"}]' omarchy-mu-lock-action switchUser
  assert_contains "$calls" "loginctl activate c1"
  assert_not_contains "$calls" SwitchToGreeter
}

test_a_login_screen_that_cant_be_gone_back_to_is_asked_for_again() {
  setup
  ACTIVATE_STATUS=1 SESSIONS='[{"session":"c1","user":"sddm","seat":"seat0","class":"greeter","tty":"tty1"}]' omarchy-mu-lock-action switchUser
  assert_contains "$calls" SwitchToGreeter
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

test_watch_unlock_needs_a_session() {
  setup
  if omarchy-mu-lock-action watch-unlock; then fail "watched nothing"; fi
  [[ ! -s $calls ]] || fail "asked logind about no session"
}

test_watch_unlock_watches_this_session_only() {
  setup
  export XDG_SESSION_ID=7
  cat >"$T/stubs/busctl" <<'STUB'
#!/bin/bash
[[ $* == *"GetSession s 7"* ]] && echo '{"type":"o","data":["/org/freedesktop/login1/session/_37"]}'
STUB
  printf '#!/bin/bash\nshift\nexec "$@"\n' >"$T/stubs/stdbuf"
  printf '#!/bin/bash\necho "$*" >>"%s"\n' "$calls" >"$T/stubs/gdbus"
  chmod +x "$T/stubs/busctl" "$T/stubs/stdbuf" "$T/stubs/gdbus"
  omarchy-mu-lock-action watch-unlock
  assert_contains "$calls" "--object-path /org/freedesktop/login1/session/_37"
}

test_watch_unlock_refuses_a_strange_answer() {
  setup
  export XDG_SESSION_ID=7
  printf '#!/bin/bash\necho %s\n' "'{\"data\":[\"/org/evil\"]}'" >"$T/stubs/busctl"
  chmod +x "$T/stubs/busctl"
  if omarchy-mu-lock-action watch-unlock; then fail "watched /org/evil"; fi
}

test_wait_active_answers_once_the_session_is_back() {
  setup
  export XDG_SESSION_ID=7
  ACTIVE=yes omarchy-mu-lock-action wait-active || fail "active session"
  assert_eq "$(grep -c '^loginctl' "$calls")" 1
  assert_contains "$calls" "sleep 0.3"
}

test_wait_active_waits_for_the_switch() {
  setup
  export XDG_SESSION_ID=7
  # Active on the third look, as when SDDM switches back while this waits.
  stub loginctl '(( $(grep -c ^loginctl '"$calls"') >= 3 )) && echo yes || echo no'
  omarchy-mu-lock-action wait-active || fail "came back"
  assert_eq "$(grep -c '^loginctl' "$calls")" 3
}

test_wait_active_gives_up_and_the_lock_stays() {
  setup
  export XDG_SESSION_ID=7
  if ACTIVE=no omarchy-mu-lock-action wait-active; then fail "never came back"; fi
  assert_eq "$(grep -c '^loginctl' "$calls")" 50
}

test_wait_active_takes_only_a_clear_yes() {
  setup
  export XDG_SESSION_ID=7
  stub loginctl 'exit 1'
  if omarchy-mu-lock-action wait-active; then fail "no answer isn't yes"; fi
  unset XDG_SESSION_ID
  : >"$calls"
  if omarchy-mu-lock-action wait-active; then fail "no session"; fi
  [[ ! -s $calls ]] || fail "asked about no session"
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
