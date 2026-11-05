#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# omarchy-mu-user-helper, -login-select and -login-match against a fake tree, with a
# real LUKS header in a file: cryptsetup does all of this without root or a device.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

command -v cryptsetup >/dev/null || { echo "# slots.test.sh: cryptsetup not installed; skipped"; exit 0; }

hash_of() { perl -e 'print crypt($ARGV[0], "\$6\$saltsalt\$")' "$1"; }

# Passwords of the fake accounts.
OWNER=owner-pass BOB=bob-pass-1

setup() {
  user_stubs
  export OMU_REFUSAL_DELAY=0 OMU_LUKS_PBKDF="--pbkdf pbkdf2 --pbkdf-force-iterations 1000"
  export OMU_REBUILD_BOOT=$T/stubs/rebuild OMU_LIFECYCLE_DISPATCH=$T/stubs/dispatch OMU_STATE_DIR=$T/state
  mkdir -p "$T/state" "$T/etc/sddm.conf.d"
  setup_sddm_state
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000:Owner:/home/owner:/bin/bash\nbob:x:1001:1001:Bob:/home/bob:/bin/bash\nsddm:x:900:900::/var/lib/sddm:/usr/bin/nologin\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:bob\n' >"$T/etc/group"
  {
    echo 'root:!:1::::::'
    echo "owner:$(hash_of "$OWNER"):1::::::"
    echo 'bob:!:1::::::'
  } >"$T/etc/shadow"
  # Takes the new password's real hash, as chpasswd does, one write for all lines.
  cat >"$T/stubs/chpasswd" <<'STUB'
#!/bin/bash
[[ ! -e $T/chpasswd-fails ]] || exit 1
while IFS=: read -r user password; do
  hash=$(perl -e 'print crypt($ARGV[0], "\$6\$saltsalt\$")' "$password")
  awk -F: -v OFS=: -v u="$user" -v h="$hash" '$1 == u { $2 = h } { print }' "$T/etc/shadow" >"$T/etc/shadow.new"
  mv "$T/etc/shadow.new" "$T/etc/shadow"
done
STUB
  printf '#!/bin/bash\necho rebuild >>"$T/calls"\n' >"$T/stubs/rebuild"
  printf '#!/bin/bash\nexit 3\n' >"$T/stubs/dispatch"
  chmod +x "$T/stubs/chpasswd" "$T/stubs/rebuild" "$T/stubs/dispatch"
  # The real sleep: omarchy-mu-login-match's watchdog would go off at once.
  rm -f "$T/stubs/omarchy-mu-user-helper" "$T/stubs/sleep"
  export SUDO_USER=owner ME=owner
  export OMU_SYSTEM_DRIVE=$T/disk
  truncate -s 32M "$T/disk"
  # shellcheck disable=SC2086  # options, split on purpose
  printf '%s' "$OWNER" | cryptsetup luksFormat -q $OMU_LUKS_PBKDF --key-file - "$T/disk" || fail "no LUKS image"
  UUID=$(cryptsetup luksUUID "$T/disk")
  map=$T/etc/omarchy-multiuser/slots
}

opens() {
  printf '%s' "$1" | LC_ALL=C cryptsetup open --test-passphrase --verbose --token-type passphrase-only --key-file - "$T/disk" 2>&1 |
    grep -o 'Key slot [0-9]*' | grep -o '[0-9]*'
}

helper() {
  printf '%s\n%s\n' "$1" "$2" | omarchy-mu-user-helper "${@:3}"
}

give_bob_a_password() {
  helper "$OWNER" "$BOB" password bob 2>"$T/err" || fail "bob's password: $(cat "$T/err")"
}

test_a_person_gets_a_key_slot_of_their_own() {
  setup
  give_bob_a_password
  assert_eq "$(opens "$BOB")" 1
  assert_eq "$(opens "$OWNER")" 0
  assert_contains "$map" "$UUID 1 1001 bob "
  assert_contains "$map" "$UUID 0 1000 owner "
  [[ $(stat -c %a "$map") == 600 ]] || fail "the map is readable by others"
  assert_no_file "$T/state/password-journal"
  grep -q "^bob:\$6" "$T/etc/shadow" || fail "bob has no password"
}

test_the_boot_image_is_rebuilt_once_for_a_second_person() {
  setup
  give_bob_a_password
  assert_eq "$(grep -c '^rebuild' "$T/calls")" 1
  helper "$BOB" bob-pass-2 password bob 2>/dev/null || true
  helper "$OWNER" bob-pass-3 password bob 2>/dev/null || fail "changing again"
  assert_eq "$(grep -c '^rebuild' "$T/calls")" 1
}

test_changing_a_password_replaces_the_old_key() {
  setup
  give_bob_a_password
  helper "$OWNER" bob-pass-2 password bob 2>/dev/null || fail "change"
  assert_eq "$(opens bob-pass-2)" 2
  assert_eq "$(opens "$BOB")" ""
  assert_eq "$(grep -c " bob " "$map")" 1
  assert_contains "$map" "$UUID 2 1001 bob "
}

test_a_short_or_taken_password_changes_nothing() {
  setup
  helper "$OWNER" short password bob 2>"$T/err" && fail "took a short password"
  assert_contains "$T/err" "at least 6"
  helper "$OWNER" "$OWNER" password bob 2>"$T/err" && fail "took the owner's password"
  assert_contains "$T/err" "already unlocks this computer"
  assert_eq "$(opens "$BOB")" ""
  grep -q '^bob:!' "$T/etc/shadow" || fail "bob's password changed"
}

test_a_password_left_only_on_the_disk_is_taken_too() {
  setup
  printf '%s\nold-disk-pass' "$OWNER" | bash -c 'IFS= read -r c; exec cryptsetup luksAddKey -q $OMU_LUKS_PBKDF --key-file <(printf "%s" "$c") "$T/disk" <(cat)'
  printf 'old-disk-pass\n' | omarchy-mu-user-helper check-new 2>"$T/err" && fail "took a password the disk knows"
  assert_contains "$T/err" "already unlocks this computer"
  printf 'brand-new-pass\n' | omarchy-mu-user-helper check-new || fail "refused a free password"
}

test_the_wrong_own_password_changes_nothing() {
  setup
  helper not-mine "$BOB" password bob 2>"$T/err" && fail "took a wrong password"
  assert_contains "$T/err" "isn't owner's password"
  assert_eq "$(opens "$BOB")" ""
}

test_a_login_password_the_disk_doesnt_know_says_what_to_do() {
  setup
  awk -F: -v OFS=: -v h="$(hash_of other-login)" '$1 == "owner" { $2 = h } { print }' "$T/etc/shadow" >"$T/s" && mv "$T/s" "$T/etc/shadow"
  helper other-login "$BOB" password bob 2>"$T/err" && fail "added a key with no key"
  assert_contains "$T/err" "omarchy-drive-password"
}

test_only_an_administrator_changes_someone_elses() {
  setup
  export SUDO_USER=bob
  helper "$BOB" other-pass-1 password owner 2>"$T/err" && fail "bob changed the owner's"
  assert_contains "$T/err" "Only an administrator"
  assert_eq "$(opens "$OWNER")" 0
  printf 'x\n' | omarchy-mu-user-helper check-new 2>/dev/null && fail "bob asked whose password"
  omarchy-mu-user-helper forget owner 2>/dev/null && fail "bob took the owner's key"
  assert_eq "$(opens "$OWNER")" 0
}

test_nobody_outside_sudo_gets_anywhere() {
  setup
  unset SUDO_USER
  helper "$OWNER" "$BOB" password bob 2>"$T/err" && fail "ran without a caller"
  assert_contains "$T/err" "through sudo"
}

test_a_limited_account_changes_its_own_three_times_an_hour() {
  setup
  give_bob_a_password
  export SUDO_USER=bob
  helper "$BOB" bob-pass-2 password-self 2>"$T/err" || fail "own password: $(cat "$T/err")"
  assert_eq "$(opens bob-pass-2)" 2
  assert_eq "$(opens "$BOB")" ""
  helper wrong-one bob-pass-3 password-self 2>/dev/null && fail "took a wrong current password"
  helper wrong-two bob-pass-3 password-self 2>/dev/null && fail "took a wrong current password"
  helper bob-pass-2 bob-pass-3 password-self 2>"$T/err" && fail "a fourth try"
  assert_contains "$T/err" "three password changes"
  [[ $(stat -c %a "$T/run/omarchy-multiuser/rate/1001") == 600 ]] || fail "the count is others' to read"
}

test_a_stop_before_the_account_took_it_goes_back() {
  setup
  give_bob_a_password
  : >"$T/chpasswd-fails"
  helper "$OWNER" bob-pass-2 password bob 2>/dev/null && fail "said it changed"
  assert_eq "$(opens bob-pass-2)" ""
  assert_eq "$(opens "$BOB")" 1
  assert_no_file "$T/state/password-journal"
}

test_a_stop_after_the_account_took_it_goes_forward() {
  setup
  give_bob_a_password
  old_fp=$(grep ' bob ' "$map" | cut -d' ' -f5)
  # As a power cut leaves it: the key added, shadow written, the phase not recorded.
  printf '%s\nbob-pass-2' "$OWNER" | bash -c 'IFS= read -r c; exec cryptsetup luksAddKey -q $OMU_LUKS_PBKDF --key-slot 2 --key-file <(printf "%s" "$c") "$T/disk" <(cat)'
  printf 'bob:bob-pass-2\n' | "$T/stubs/chpasswd"
  printf 'user=bob\nuuid=%s\nslot=2\nold_slot=1\nold_fp=%s\nphase=key\n' "$UUID" "$old_fp" >"$T/state/password-journal"
  omarchy-mu-user-helper finish || fail "finish"
  assert_contains "$map" "$UUID 2 1001 bob "
  assert_eq "$(opens "$BOB")" ""
  assert_eq "$(opens bob-pass-2)" 2
  assert_no_file "$T/state/password-journal"
}

test_a_journal_from_another_disk_stops_everything() {
  setup
  printf 'user=bob\nuuid=other-disk\nslot=2\nold_slot=-\nold_fp=x\nphase=key\n' >"$T/state/password-journal"
  helper "$OWNER" "$BOB" password bob 2>"$T/err" && fail "changed over a stranger's journal"
  assert_contains "$T/err" "another disk"
  assert_eq "$(opens "$BOB")" ""
}

test_forgetting_takes_the_key_with_nobodys_password() {
  setup
  give_bob_a_password
  omarchy-mu-user-helper forget bob </dev/null || fail "forget"
  assert_eq "$(opens "$BOB")" ""
  assert_not_contains "$map" " bob "
  assert_eq "$(opens "$OWNER")" 0
}

test_killing_a_slot_doesnt_wait_on_an_open_stdin() {
  setup
  give_bob_a_password
  # A pipe nobody writes to or closes, as when run from another program.
  mkfifo "$T/open"
  exec 8<>"$T/open"
  timeout 20 omarchy-mu-user-helper forget bob <&8 2>"$T/err" || fail "exit $?: $(cat "$T/err")"
  assert_eq "$(opens "$BOB")" ""
  [[ ! -s $T/err ]] || fail "said: $(cat "$T/err")"
}

test_forgetting_refuses_the_disks_last_key() {
  setup
  printf '%s %s %s %s %s\n' "$UUID" 0 1001 bob fp >"$T/map" ; mkdir -p "${map%/*}"; mv "$T/map" "$map"
  omarchy-mu-user-helper forget bob </dev/null 2>"$T/err" && fail "locked the disk for good"
  assert_contains "$T/err" "last one"
  assert_eq "$(opens "$OWNER")" 0
}

test_an_old_recorded_slot_is_replaced_and_forgotten() {
  setup
  printf '%s\nold-bob-disk' "$OWNER" | bash -c 'IFS= read -r c; exec cryptsetup luksAddKey -q $OMU_LUKS_PBKDF --key-file <(printf "%s" "$c") "$T/disk" <(cat)'
  mkdir -p "${map%/*}"
  printf 'bob 1\n' >"$T/etc/omarchy-multiuser/luks-slots"
  give_bob_a_password
  assert_eq "$(opens old-bob-disk)" ""
  assert_eq "$(opens "$BOB")" 2
  assert_not_contains "$T/etc/omarchy-multiuser/luks-slots" bob
}

test_an_unencrypted_machine_only_has_passwords() {
  setup
  export OMU_SYSTEM_DRIVE=
  give_bob_a_password
  grep -q '^bob:\$6' "$T/etc/shadow" || fail "bob has no password"
  assert_no_file "$map"
  assert_not_contains "$T/calls" rebuild
}

test_the_only_account_keeps_root_with_it() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd" "$T/etc/shadow"
  sed -i "s|^root:!:|root:$(hash_of "$OWNER"):|" "$T/etc/shadow"
  helper "$OWNER" new-owner-pass password-self 2>/dev/null || fail "change"
  assert_eq "$(grep '^root:' "$T/etc/shadow" | cut -d: -f2)" "$(hash_of new-owner-pass)"
}

test_a_locked_root_stays_locked() {
  setup
  give_bob_a_password
  grep -q '^root:!' "$T/etc/shadow" || fail "unlocked root"
}

# --- omarchy-mu-login-select ------------------------------------------------------

old_autologin_file() { echo "$T/etc/sddm.conf.d/zzz-omarchy-mu-autologin.conf"; }
ticket() { echo "$T/run/omarchy-multiuser/login-once"; }
state() { echo "$T/var/lib/sddm/state.conf"; }
# A pass for $1 at this boot, and $1 as SDDM's last user.
assert_logged_in() {
  assert_file "$(ticket)"
  read -r user boot when <"$(ticket)"
  assert_eq "$user" "$1" "ticket's user"
  assert_eq "$boot" "$(<"$T/proc/sys/kernel/random/boot_id")" "ticket's boot"
  [[ $when =~ ^[0-9]+$ ]] || fail "ticket's time: $when"
  assert_eq "$(stat -c %a "$(ticket)")" 600 "ticket's mode"
  assert_contains "$(state)" "User=$1"
  assert_no_file "$(old_autologin_file)"
}
assert_login_screen() { assert_no_file "$(ticket)"; assert_no_file "$(old_autologin_file)"; }
setup_sddm_state() {
  mkdir -p "$T/proc/sys/kernel/random" "$T/var/lib/sddm"
  echo 11111111-2222-3333-4444-555555555555 >"$T/proc/sys/kernel/random/boot_id"
}
record() { mkdir -p "$T/run/omarchy-multiuser"; printf '%s %s\n' "$1" "$2" >"$T/run/omarchy-multiuser/luks-slot"; }
select_login() { omarchy-mu-login-select --clear && omarchy-mu-login-select; }

test_the_slot_that_opened_the_disk_opens_its_owners_desktop() {
  setup
  give_bob_a_password
  record "$UUID" 1
  select_login || fail "select"
  assert_logged_in bob
}

test_the_record_is_used_once() {
  setup
  give_bob_a_password
  record "$UUID" 1
  select_login
  assert_logged_in bob
  select_login || fail "second start"
  assert_login_screen
}

test_anything_unsure_shows_the_login_screen() {
  setup
  give_bob_a_password
  for bad in "$UUID 9" "other-disk 1" "$UUID x"; do
    read -r a b <<<"$bad"; record "$a" "$b"
    select_login
    assert_login_screen
  done
  rm -f "$T/run/omarchy-multiuser/luks-slot"
  select_login
  assert_login_screen
}

test_a_password_changed_with_passwd_shows_the_login_screen() {
  setup
  give_bob_a_password
  printf 'bob:changed-elsewhere\n' | "$T/stubs/chpasswd"
  record "$UUID" 1
  select_login
  assert_login_screen
}

test_an_unfinished_change_shows_the_login_screen() {
  setup
  give_bob_a_password
  printf 'user=bob\nuuid=%s\nphase=key\n' "$UUID" >"$T/state/password-journal"
  record "$UUID" 1
  select_login
  assert_login_screen
}

test_a_broken_map_shows_the_login_screen() {
  setup
  give_bob_a_password
  printf '%s 0 1000 bob fp\n' "$UUID" >>"$map"
  record "$UUID" 1
  select_login
  assert_login_screen
}

test_one_account_on_an_encrypted_disk_is_logged_in() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd"
  select_login
  assert_logged_in owner
}

# What systemd-cryptenroll writes, without a TPM behind it.
TPM2_TOKEN='{"type":"systemd-tpm2","keyslots":["0"],"tpm2-blob":"","tpm2-pcrs":[7],"tpm2-pcr-bank":"sha256","tpm2-primary-alg":"ecc","tpm2-policy-hash":""}'

test_one_account_on_a_disk_a_token_opens_gets_the_login_screen() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd"
  for token in "$TPM2_TOKEN" '{"type":"clevis","keyslots":["0"],"jwe":{}}'; do
    cryptsetup token remove --token-id 0 "$T/disk" 2>/dev/null
    printf '%s' "$token" | cryptsetup token import --token-id 0 "$T/disk" >/dev/null || fail "no token"
    select_login
    assert_login_screen
  done
}

test_a_token_leaves_the_slot_on_record_to_choose() {
  setup
  give_bob_a_password
  printf '%s' "$TPM2_TOKEN" | cryptsetup token import "$T/disk" >/dev/null || fail "no token"
  record "$UUID" 1
  select_login || fail "select"
  assert_logged_in bob
}

test_an_unencrypted_machine_is_never_logged_in() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd"
  export OMU_SYSTEM_DRIVE=
  select_login
  assert_login_screen
}

test_clear_takes_every_automatic_login_away() {
  setup
  printf '[Autologin]\nUser=owner\n' >"$T/etc/sddm.conf.d/autologin.conf"
  printf '[Autologin]\nUser=owner\n' >"$(old_autologin_file)"
  mkdir -p "$T/run/omarchy-multiuser"; echo "owner x 1" >"$(ticket)"
  omarchy-mu-login-select --clear || fail "clear"
  assert_no_file "$T/etc/sddm.conf.d/autologin.conf"
  assert_login_screen
}

test_sddm_conf_naming_someone_stops_sddm_with_two_people_only() {
  setup
  printf '[Autologin]\nUser=owner\n' >"$T/etc/sddm.conf"
  omarchy-mu-login-select --clear 2>/dev/null && fail "started SDDM into someone's desktop"
  sed -i '/^bob:/d' "$T/etc/passwd"
  omarchy-mu-login-select --clear || fail "stopped SDDM on a one-person machine"
}

test_the_last_user_is_set_and_the_rest_of_sddms_state_kept() {
  setup
  give_bob_a_password
  printf '[Last]\n# The last user\nUser=owner\nSession=/usr/share/wayland-sessions/hyprland.desktop\n\n[Other]\nUser=keep\n' >"$(state)"
  chmod 640 "$(state)"
  record "$UUID" 1
  select_login || fail "select"
  assert_logged_in bob
  assert_eq "$(grep -c '^User=' "$(state)")" 2
  assert_contains "$(state)" "Session=/usr/share/wayland-sessions/hyprland.desktop"
  assert_contains "$(state)" "User=keep"
  assert_not_contains "$(state)" "User=owner"
  assert_eq "$(stat -c %a "$(state)")" 640 "state.conf's mode"
}

test_a_state_without_a_last_section_gets_one() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd"
  printf '[Other]\nKey=1\n' >"$(state)"
  select_login
  assert_logged_in owner
  assert_contains "$(state)" "[Last]"
  assert_contains "$(state)" "Key=1"
}

test_without_a_boot_id_or_sddms_state_dir_it_shows_the_login_screen() {
  setup
  sed -i '/^bob:/d' "$T/etc/passwd"
  rm "$T/proc/sys/kernel/random/boot_id"
  select_login
  assert_login_screen
  setup_sddm_state
  rm -rf "$T/var/lib/sddm"
  select_login
  assert_login_screen
}

# --- omarchy-mu-login-match -------------------------------------------------------

match_for() { printf '%s\0' "$2" | PAM_TYPE=auth PAM_USER=$1 omarchy-mu-login-match; }

test_another_accounts_password_ends_the_attempt() {
  setup
  give_bob_a_password
  printf '#!/bin/bash\nprintf "h\\nh\\n"\n' >"$T/stubs/faillock"; chmod +x "$T/stubs/faillock"
  match_for owner "$BOB" || fail "tried bob's password as the owner"
}

test_the_accounts_own_or_nobodys_password_goes_on_to_the_stack() {
  setup
  give_bob_a_password
  printf '#!/bin/bash\nprintf "h\\nh\\n"\n' >"$T/stubs/faillock"; chmod +x "$T/stubs/faillock"
  if match_for bob "$BOB"; then fail "ended bob's own login"; fi
  if match_for bob nobodys-pass; then fail "ended a wrong password early"; fi
}

test_a_locked_owners_password_takes_the_slow_refusal() {
  setup
  give_bob_a_password
  printf '#!/bin/bash\nprintf "h\\nh\\nWhen Type Source Valid\\n"\n' >"$T/stubs/faillock"; chmod +x "$T/stubs/faillock"
  if match_for owner "$BOB"; then fail "a fast refusal told a guesser about the lockout"; fi
  printf '#!/bin/bash\nexit 1\n' >"$T/stubs/faillock"
  if match_for owner "$BOB"; then fail "counted a faillock that can't say as no failures"; fi
}

test_only_an_auth_step_with_a_real_name_counts() {
  setup
  give_bob_a_password
  if printf '%s\0' "$BOB" | PAM_TYPE=session PAM_USER=owner omarchy-mu-login-match; then fail "another PAM step"; fi
  if printf '%s\0' "$BOB" | PAM_TYPE=auth PAM_USER='../owner' omarchy-mu-login-match; then fail "a strange name"; fi
}

run_tests
