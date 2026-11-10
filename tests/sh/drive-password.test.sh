#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# omarchy-mu-drive-password: the system disk is left out once each person's password
# is their own key to it. omarchy-drive-password is a stub that asks
# omarchy-drive-select, as the real one does with more than one drive.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

setup() {
  mkdir -p "$T/stubs"
  export OMU_SYSTEM_DRIVE=/dev/nvme0n1p2 PATH="$T/stubs:$PATH"
  printf '#!/bin/bash\ncat "$T/drives"\n' >"$T/stubs/lsblk"
  printf '#!/bin/bash\necho "drive-password $*" >>"$T/calls"\nlist=$(awk "{print \\$1}" "$T/drives")\npicked=$(omarchy-drive-select "$list")\necho "picked [$picked]" >>"$T/calls"\n' >"$T/stubs/omarchy-drive-password"
  printf '#!/bin/bash\necho "select [$(paste -sd, <<<"$1")]" >>"$T/calls"\nhead -1 <<<"$1"\n' >"$T/stubs/omarchy-drive-select"
  chmod +x "$T/stubs/"*
  : >"$T/calls"
}
drives() { printf '%s crypto_LUKS\n' "$@" >"$T/drives"; }
managed() { mkdir -p "$T/etc/omarchy-multiuser"; }

test_before_accounts_have_their_own_keys_it_is_omarchys_as_is() {
  setup
  drives /dev/nvme0n1p2 /dev/sda1
  omarchy-mu-drive-password >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "select [/dev/nvme0n1p2,/dev/sda1]"
}

test_the_system_disk_alone_is_refused() {
  setup
  managed
  drives /dev/nvme0n1p2
  omarchy-mu-drive-password >"$T/out" 2>&1 && fail "offered the system disk"
  assert_contains "$T/out" "Setup › Users"
  assert_not_contains "$T/calls" drive-password
}

test_one_data_drive_is_picked_without_asking() {
  setup
  managed
  drives /dev/nvme0n1p2 /dev/sda1
  omarchy-mu-drive-password >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "picked [/dev/sda1]"
  assert_not_contains "$T/calls" "select ["
}

test_several_data_drives_are_offered_without_the_system_disk() {
  setup
  managed
  drives /dev/sda1 /dev/nvme0n1p2 /dev/sdb1
  omarchy-mu-drive-password >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "select [/dev/sda1,/dev/sdb1]"
  assert_contains "$T/calls" "picked [/dev/sda1]"
}

test_an_unencrypted_system_leaves_every_drive() {
  setup
  managed
  export OMU_SYSTEM_DRIVE=''
  drives /dev/sda1 /dev/sdb1
  omarchy-mu-drive-password >"$T/out" 2>&1 || fail "exit $?: $(cat "$T/out")"
  assert_contains "$T/calls" "select [/dev/sda1,/dev/sdb1]"
}

run_tests
