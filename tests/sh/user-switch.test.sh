#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/stubs"
  calls=$T/calls
  : >"$calls"
  stub() {
    printf '#!/bin/bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$calls" "${2:-}" >"$T/stubs/$1"
    chmod +x "$T/stubs/$1"
  }
  stub id 'echo ana'
  stub getent 'printf "ana:x:1000:1000:Ana Lima:/home/ana:/bin/bash\nbia:x:1001:1001:Bia Reis,,,:/home/bia:/bin/bash\ncau:x:1002:1002::/home/cau:/bin/bash\nnobody:x:65534:65534::/:/usr/bin/nologin\n" | { [[ $# -gt 1 ]] && grep "^$2:" || cat; }'
  stub omarchy-system-lock
  stub omarchy-hyprland-session-locked 'exit ${NOT_LOCKED:-0}'
  stub sleep
  stub omarchy-notification-send
  stub omarchy-menu-select 'printf "%b" "${CHOICE:-}"; exit ${MENU_STATUS:-0}'
  stub omarchy-shell '[[ $2 == switchUser ]] && echo "${IPC:-ok}"; exit 0'
  stub omarchy-mu-lock-action
  export SESSIONS='[{"session":"2","user":"ana","seat":"seat0","class":"user","tty":"tty2"},{"session":"5","user":"bia","seat":null,"class":"manager","tty":null},{"session":"6","user":"bia","seat":"seat0","class":"user","tty":"tty3"}]'
  stub loginctl '[[ $1 == list-sessions ]] && echo "$SESSIONS"; exit 0'
  export PATH=$T/stubs:$PATH
}

first_console='[{"session":"2","user":"ana","seat":"seat0","class":"user","tty":"tty1"}]'

test_someone_signed_in_is_opened_after_locking() {
  setup
  omarchy-mu-user-switch bia
  assert_contains "$calls" "omarchy-shell lock releaseReader"
  assert_contains "$calls" "loginctl activate 6"
  [[ $(grep -n omarchy-system-lock "$calls" | cut -d: -f1) -lt $(grep -n 'loginctl activate' "$calls" | cut -d: -f1) ]] ||
    fail "activated before locking"
}

test_someone_not_signed_in_gets_the_login_screen_through_the_lock() {
  setup
  omarchy-mu-user-switch cau
  assert_contains "$calls" "omarchy-shell lock switchUser"
  assert_not_contains "$calls" "omarchy-mu-lock-action"
  assert_not_contains "$calls" "loginctl activate"
}

test_omarchys_own_lock_screen_still_reaches_the_login_screen() {
  setup
  IPC=unknown omarchy-mu-user-switch cau
  assert_contains "$calls" "omarchy-mu-lock-action switchUser"
}

test_an_automatic_login_is_offered_a_logout_and_nothing_locks() {
  setup
  SESSIONS=$first_console omarchy-mu-user-switch cau
  assert_contains "$calls" "--exec omarchy-system logout"
  assert_not_contains "$calls" omarchy-system-lock
  assert_not_contains "$calls" switchUser
}

test_an_automatic_login_still_reaches_someone_signed_in() {
  setup
  SESSIONS='[{"session":"2","user":"ana","seat":"seat0","class":"user","tty":"tty1"},{"session":"6","user":"bia","seat":"seat0","class":"user","tty":"tty3"}]' omarchy-mu-user-switch bia
  assert_contains "$calls" "loginctl activate 6"
}

test_a_desktop_that_did_not_lock_switches_nothing() {
  setup
  if NOT_LOCKED=1 omarchy-mu-user-switch bia 2>/dev/null; then fail "switched"; fi
  assert_not_contains "$calls" "loginctl activate"
}

test_only_someone_else_with_an_account() {
  setup
  if omarchy-mu-user-switch ana 2>/dev/null; then fail "switched to myself"; fi
  if omarchy-mu-user-switch nobody 2>/dev/null; then fail "switched to a system account"; fi
  assert_not_contains "$calls" omarchy-system-lock
}

test_the_menu_lists_full_names_and_returns_the_account() {
  setup
  CHOICE='Bia Reis\tbia' omarchy-mu-user-switch
  assert_contains "$calls" "Bia Reis"
  assert_contains "$calls" "loginctl activate 6"
}

test_cancelling_the_menu_does_nothing() {
  setup
  MENU_STATUS=1 omarchy-mu-user-switch || fail "cancelling is no failure"
  CHOICE='' omarchy-mu-user-switch || fail "an empty answer is no failure"
  assert_not_contains "$calls" omarchy-system-lock
}

test_available_only_with_someone_else() {
  setup
  omarchy-mu-user-switch --available || fail "there are others"
  stub getent 'printf "ana:x:1000:1000:Ana:/home/ana:/bin/bash\n"'
  if omarchy-mu-user-switch --available; then fail "nobody else"; fi
}

run_tests
