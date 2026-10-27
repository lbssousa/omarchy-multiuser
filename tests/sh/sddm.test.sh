#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-sddm-sync and omarchy-mu-sddm-guard against a fake tree.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

themes() { echo "$T/usr/share/sddm/themes"; }

setup_themes() {
  mkdir -p "$(themes)/omarchy" "$(themes)/omarchy-multiuser" "$T/etc/sddm.conf.d"
  cp "$REPO/sddm/omarchy-multiuser/fallback/bullet.png" "$(themes)/omarchy/"
  printf 'Rectangle {\n  color: "#123456"\n}\n' >"$(themes)/omarchy/Main.qml"
}

test_sync_writes_colors() {
  setup_themes
  omarchy-mu-sddm-sync >/dev/null
  conf="$(themes)/omarchy-multiuser/theme.conf.user"
  assert_contains "$conf" "background=#123456"
  assert_contains "$conf" "textColor=#C0CAF5"
}

test_sync_follows_recolor() {
  setup_themes
  omarchy-mu-sddm-sync >/dev/null
  magick "$(themes)/omarchy/bullet.png" -fill '#ff0000' -colorize 100 "$(themes)/omarchy/bullet.png"
  sed -i 's/#123456/#abcdef/' "$(themes)/omarchy/Main.qml"
  omarchy-mu-sddm-sync >/dev/null
  conf="$(themes)/omarchy-multiuser/theme.conf.user"
  assert_contains "$conf" "background=#abcdef"
  assert_contains "$conf" "textColor=#FF0000"
}

test_sync_without_stock_theme_removes_override() {
  setup_themes
  omarchy-mu-sddm-sync >/dev/null
  rm -rf "$(themes)/omarchy"
  omarchy-mu-sddm-sync
  assert_no_file "$(themes)/omarchy-multiuser/theme.conf.user"
}

test_sync_lists_first_login_accounts() {
  setup_themes
  # shellcheck disable=SC2016  # a literal shadow hash, not an expansion
  printf '%s\n' 'abutre:$6$hash:20000:0:99999:7:::' 'surubi::0:0:99999:7:::' \
    'coruja::0:0:99999:7:::' 'locked:!:0:0:99999:7:::' 'blank::20000:0:99999:7:::' >"$T/etc/shadow"
  omarchy-mu-sddm-sync >/dev/null
  conf="$(themes)/omarchy-multiuser/theme.conf.user"
  assert_contains "$conf" "passwordChangeUsers=surubi coruja"
}

test_sync_drops_accounts_once_they_chose() {
  setup_themes
  printf '%s\n' 'surubi::0:0:99999:7:::' >"$T/etc/shadow"
  omarchy-mu-sddm-sync >/dev/null
  # shellcheck disable=SC2016  # a literal shadow hash, not an expansion
  printf '%s\n' 'surubi:$6$hash:20000:0:99999:7:::' >"$T/etc/shadow"
  omarchy-mu-sddm-sync >/dev/null
  assert_not_contains "$(themes)/omarchy-multiuser/theme.conf.user" "passwordChangeUsers"
}

test_sync_keeps_first_login_accounts_without_colors() {
  setup_themes
  rm -rf "$(themes)/omarchy"
  printf '%s\n' 'surubi::0:0:99999:7:::' >"$T/etc/shadow"
  omarchy-mu-sddm-sync >/dev/null
  assert_eq "$(cat "$(themes)/omarchy-multiuser/theme.conf.user")" $'[General]\npasswordChangeUsers=surubi'
}

test_guard_removes_autologin() {
  setup_themes
  cp "$REPO/etc/sddm.conf.d/zz-omarchy-multiuser.conf" "$T/etc/sddm.conf.d/"
  printf '[Theme]\nCurrent=omarchy\n' >"$T/etc/sddm.conf.d/99-omarchy-login.conf"
  printf '[Autologin]\nUser=abutre\nSession=omarchy.desktop\n' >"$T/etc/sddm.conf.d/autologin.conf"
  omarchy-mu-sddm-guard --check 2>/dev/null && fail "check passed with autologin.conf"
  omarchy-mu-sddm-guard >/dev/null || fail "guard reported problems after fixing"
  assert_no_file "$T/etc/sddm.conf.d/autologin.conf"
  omarchy-mu-sddm-guard --check || fail "check failed after fixing"
}

test_guard_reports_sddm_conf_autologin() {
  setup_themes
  cp "$REPO/etc/sddm.conf.d/zz-omarchy-multiuser.conf" "$T/etc/sddm.conf.d/"
  printf '[Autologin]\nUser=abutre\n' >"$T/etc/sddm.conf"
  omarchy-mu-sddm-guard 2>/dev/null && fail "missed /etc/sddm.conf autologin"
  true
}

test_guard_reports_wrong_theme() {
  setup_themes
  printf '[Theme]\nCurrent=omarchy\n' >"$T/etc/sddm.conf.d/10-theme.conf"
  omarchy-mu-sddm-guard 2>/dev/null && fail "missed the wrong theme"
  true
}

run_tests
