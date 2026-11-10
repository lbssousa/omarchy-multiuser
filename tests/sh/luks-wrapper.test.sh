#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the fake's code runs in the fake, not in this shell
# The initramfs cryptsetup wrapper, run by busybox ash as the initramfs runs it, in
# front of a fake real cryptsetup; and the hook's mkinitcpio drop-in.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

busybox=/usr/lib/initcpio/busybox
[[ -x $busybox ]] || { echo "# luks-wrapper.test.sh: mkinitcpio's busybox not installed; skipped"; exit 0; }
wrapper=$REPO/initcpio/cryptsetup

setup() {
  export TEST_TMP=$T CRYPTSETUP_REAL=$T/real LUKS_SLOT_RECORD=$T/run/luks-slot
  cat >"$T/real" <<'SH'
#!/bin/sh
echo "$*" >>"$TEST_TMP/calls"
case "$*" in
  "luksUUID /dev/nvme0n1p2") echo uuid-root ;;
  *--verbose*open*)
    password=$(cat)
    [ "$password" = "kidpass" ] || { echo "No key available with this passphrase." >&2; exit 2; }
    echo "No usable token is available."
    echo "Key slot 3 unlocked."
    echo "Command successful."
    echo "Something else cryptsetup said."
    ;;
esac
SH
  chmod +x "$T/real"
}

unlock() {
  printf '%s' "$1" | "$busybox" ash "$wrapper" open --type luks --key-file=- /dev/nvme0n1p2 root '>/dev/null' >"$T/stdout" 2>"$T/stderr"
}

test_a_plymouth_unlock_runs_once_and_records_the_slot() {
  setup
  unlock kidpass || fail "a right password unlocks"
  assert_eq "$(cat "$T/run/luks-slot")" "uuid-root 3"
  assert_contains "$T/calls" 'open --type luks --key-file=- /dev/nvme0n1p2 root >/dev/null'
  assert_eq "$(grep -c open "$T/calls")" 1
  assert_contains "$T/stdout" "Something else cryptsetup said"
  assert_not_contains "$T/stdout" "Key slot"
  assert_not_contains "$T/stdout" "Command successful"
}

test_a_wrong_password_fails_as_it_would_have_and_records_nothing() {
  setup
  status=0
  unlock wrongpass || status=$?
  assert_eq "$status" 2
  assert_no_file "$T/run/luks-slot"
  assert_contains "$T/stderr" "No key available"
}

test_other_calls_go_straight_through() {
  setup
  "$busybox" ash "$wrapper" isLuks /dev/nvme0n1p2
  assert_eq "$(cat "$T/calls")" "isLuks /dev/nvme0n1p2"
  assert_no_file "$T/run/luks-slot"
}

test_the_console_prompt_is_recorded_too() {
  setup
  printf 'kidpass' | "$busybox" ash "$wrapper" open --type luks /dev/nvme0n1p2 root >/dev/null 2>&1 || fail "unlock"
  assert_eq "$(cat "$T/run/luks-slot")" "uuid-root 3"
}

test_nowhere_to_keep_the_record_still_unlocks() {
  setup
  export LUKS_SLOT_RECORD=/proc/no-such-dir/luks-slot
  printf 'kidpass' | "$busybox" ash "$wrapper" open --type luks --key-file=- /dev/nvme0n1p2 root >/dev/null 2>&1 || fail "unlock"
}

test_the_wrapper_parses_and_the_build_step_checks_it() {
  "$busybox" ash -n "$wrapper" || fail "doesn't parse"
  assert_contains "$REPO/initcpio/install/omarchy-mu-luks-slot" 'busybox ash -n "$wrapper"'
  bash -n "$REPO/initcpio/install/omarchy-mu-luks-slot" || fail "the hook doesn't parse"
}

test_the_record_goes_where_login_select_looks() {
  assert_contains "$wrapper" 'record=${LUKS_SLOT_RECORD:-/run/omarchy-multiuser/luks-slot}'
  assert_contains "$REPO/lib/omarchy-multiuser/slots.sh" '$OMU_ROOT/run/omarchy-multiuser/luks-slot'
}

hooks_for() {
  OMU_SLOT_MAP_FILE=$1 OMU_UPSTREAM_BIN=$T/usr/bin bash -uc "
    HOOKS=($2)
    source '$REPO/etc/mkinitcpio.conf.d/zz-omarchy-mu-luks-slot.conf'
    echo \"\${HOOKS[*]}\"
  "
}

test_the_hook_follows_encrypt_only_once_the_map_exists() {
  line="base udev plymouth keyboard block encrypt filesystems fsck"
  assert_eq "$(hooks_for "$T/absent" "$line")" "$line"
  : >"$T/slots"
  assert_eq "$(hooks_for "$T/slots" "$line")" "base udev plymouth keyboard block encrypt omarchy-mu-luks-slot filesystems fsck"
  # A systemd initramfs has no encrypt hook to follow.
  assert_eq "$(hooks_for "$T/slots" "base systemd sd-encrypt filesystems")" "base systemd sd-encrypt filesystems"
}

test_omarchys_own_wrapper_leaves_no_room_for_ours() {
  : >"$T/slots"
  line="base udev block encrypt omarchy-luks-slot filesystems"
  assert_eq "$(hooks_for "$T/slots" "$line")" "$line"
  mkdir -p "$T/usr/bin"
  printf '#!/bin/sh\n' >"$T/usr/bin/omarchy-login-select"; chmod +x "$T/usr/bin/omarchy-login-select"
  line="base udev block encrypt filesystems"
  assert_eq "$(hooks_for "$T/slots" "$line")" "$line"
}

run_tests
