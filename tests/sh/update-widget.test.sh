#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# Stand-ins for the shell's IPC: they log the call and, like the shell, move
# the widget in the user's shell.json, starting it from Omarchy's.
setup() {
  export HOME=$T/home OMARCHY_PATH=$T/omarchy
  unset XDG_STATE_HOME XDG_CONFIG_HOME
  mkdir -p "$HOME/.config/omarchy" "$T/stubs" "$OMARCHY_PATH/config/omarchy"
  config=$HOME/.config/omarchy/shell.json
  state=$HOME/.local/state/omarchy-multiuser/update-widget
  calls=$T/calls
  cat >"$T/stubs/omarchy-notification-wait" <<'EOF'
#!/bin/bash
[[ -z ${SHELL_DOWN:-} ]]
EOF
  cat >"$T/stubs/omarchy-plugin-disable" <<EOF
#!/bin/bash
echo "disable \$*" >>"$calls"
[[ -f $config ]] || cp "$OMARCHY_PATH/config/omarchy/shell.json" "$config"
jq --arg id "\$1" '.bar.layout |= map_values(map(select(.id != \$id)))' "$config" >"$config.new" && mv "$config.new" "$config"
EOF
  cat >"$T/stubs/omarchy-plugin-enable" <<EOF
#!/bin/bash
echo "enable \$*" >>"$calls"
[[ -f $config ]] || cp "$OMARCHY_PATH/config/omarchy/shell.json" "$config"
jq --arg id "\$1" --arg s "\$3" --argjson i "\$5" '.bar.layout[\$s] |= .[:\$i] + [{id: \$id}] + .[\$i:]' "$config" >"$config.new" && mv "$config.new" "$config"
EOF
  chmod +x "$T/stubs"/*
  export PATH="$T/stubs:$PATH"
  bar '[{"id":"omarchy.weather"},{"id":"omarchy.system-update"}]'
}

bar() {
  printf '{"bar":{"layout":{"left":[{"id":"omarchy.menu"}],"centerEnd":%s}}}\n' "$1" >"$config"
}

as_admin() { OMU_ADMIN_GROUP=$(id -gn) omarchy-mu-update-widget-sync; }
as_user() { OMU_ADMIN_GROUP=omu-no-such-group omarchy-mu-update-widget-sync; }

in_bar() { jq -e '[.bar.layout[][] | select(.id == "omarchy.system-update")] | length > 0' "$config" >/dev/null; }

test_user_loses_widget_once() {
  setup
  as_user
  in_bar && fail "widget still in the bar"
  assert_eq "$(cat "$state")" "centerEnd 1"
  assert_eq "$(cat "$calls")" "disable omarchy.system-update"
  # Put back by hand: it stays.
  bar '[{"id":"omarchy.system-update"}]'
  as_user
  in_bar || fail "removed the widget the user put back"
  assert_eq "$(wc -l <"$calls")" 1
}

test_user_without_widget_is_left_alone() {
  setup
  bar '[{"id":"omarchy.weather"}]'
  as_user
  assert_no_file "$calls"
  assert_file "$state"
  assert_eq "$(cat "$state")" ""
}

test_admin_without_record_is_left_alone() {
  setup
  as_admin
  in_bar || fail "admin lost the widget"
  assert_no_file "$calls"
  assert_no_file "$state"
}

test_promotion_puts_widget_back_in_place() {
  setup
  as_user
  as_admin
  assert_eq "$(jq -c '[.bar.layout.centerEnd[].id]' "$config")" '["omarchy.weather","omarchy.system-update"]'
  assert_contains "$calls" "enable omarchy.system-update --section centerEnd --index 1"
  assert_no_file "$state"
  # Demoted again: off again.
  as_user
  in_bar && fail "widget kept after the second demotion"
  true
}

test_promotion_skips_widget_already_back() {
  setup
  as_user
  bar '[{"id":"omarchy.system-update"}]'
  as_admin
  assert_not_contains "$calls" enable
  assert_no_file "$state"
}

test_default_config_when_user_has_none() {
  setup
  mv "$config" "$OMARCHY_PATH/config/omarchy/shell.json"
  as_user
  assert_eq "$(cat "$state")" "centerEnd 1"
  assert_contains "$calls" "disable omarchy.system-update"
  in_bar && fail "widget still in the bar"
  true
}

test_shell_down_leaves_no_record() {
  setup
  SHELL_DOWN=1 as_user 2>/dev/null && fail "succeeded without the shell"
  assert_no_file "$state"
  in_bar || fail "widget removed without the shell"
}

run_tests
