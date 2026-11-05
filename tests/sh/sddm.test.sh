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

test_guard_leaves_the_automatic_login_of_this_boot_alone() {
  setup_themes
  cp "$REPO/etc/sddm.conf.d/zz-omarchy-multiuser.conf" "$T/etc/sddm.conf.d/"
  printf '[Autologin]\nUser=abutre\nSession=omarchy.desktop\nRelogin=false\n' >"$T/etc/sddm.conf.d/zzz-omarchy-mu-autologin.conf"
  omarchy-mu-sddm-guard >/dev/null || fail "took login-select's choice for a problem"
  assert_file "$T/etc/sddm.conf.d/zzz-omarchy-mu-autologin.conf"
}

test_guard_puts_login_match_first_in_the_pam_stack_once() {
  setup_themes
  cp "$REPO/etc/sddm.conf.d/zz-omarchy-multiuser.conf" "$T/etc/sddm.conf.d/"
  mkdir -p "$T/etc/pam.d"
  printf '#%%PAM-1.0\n\nauth        include     system-login\n-auth       optional    pam_kwallet5.so\n\naccount     include     system-login\n' >"$T/etc/pam.d/sddm"
  omarchy-mu-sddm-guard --check 2>/dev/null && fail "check passed without it"
  omarchy-mu-sddm-guard >/dev/null || fail "guard failed"
  assert_eq "$(grep -E '^-?auth' "$T/etc/pam.d/sddm" | head -1)" "auth        [success=die default=ignore] pam_exec.so quiet expose_authtok /usr/bin/omarchy-mu-login-match"
  assert_eq "$(grep -c omarchy-mu-login-match "$T/etc/pam.d/sddm")" 1
  cp "$T/etc/pam.d/sddm" "$T/once"
  omarchy-mu-sddm-guard >/dev/null
  cmp -s "$T/once" "$T/etc/pam.d/sddm" || fail "second run changed the stack"
  omarchy-mu-sddm-guard --check || fail "check failed with it"
}

test_removing_the_package_stops_the_guard_before_cleaning_up() {
  install=$REPO/packaging/omarchy-multiuser.install
  stop=$(grep -n 'disable --now omarchy-mu-sddm-guard.path' "$install" | cut -d: -f1)
  clean=$(grep -n 'rm -f /etc/sddm.conf.d/zzz-omarchy-mu-autologin.conf' "$install" | cut -d: -f1)
  [[ -n $stop && -n $clean && $stop -lt $clean ]] || fail "the guard would put the PAM line back"
}

test_guard_reports_wrong_theme() {
  setup_themes
  printf '[Theme]\nCurrent=omarchy\n' >"$T/etc/sddm.conf.d/10-theme.conf"
  omarchy-mu-sddm-guard 2>/dev/null && fail "missed the wrong theme"
  true
}

run_tests
