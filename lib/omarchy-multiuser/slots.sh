# shellcheck shell=bash
# Every account's password is also its own LUKS key slot on the system disk,
# recorded in the slot map so boot can tell who unlocked it. From Omarchy PR
# #16920 (bin/omarchy-user-functions). Sourced after common.sh, as root.
#
# Passwords live in variables and reach other programs on stdin or through
# process substitution, never argv; never trace them.

OMU_SLOT_DIR=${OMU_SLOT_DIR:-$OMU_ROOT/etc/omarchy-multiuser}
OMU_SLOT_MAP=$OMU_SLOT_DIR/slots
# What omarchy-mu-luks-enroll recorded before each slot had to be the login password.
OMU_SLOT_LEGACY=$OMU_SLOT_DIR/luks-slots
OMU_SLOT_JOURNAL=${OMU_SLOT_JOURNAL:-$OMU_STATE_DIR/password-journal}
OMU_SLOT_RECORD=${OMU_SLOT_RECORD:-$OMU_ROOT/run/omarchy-multiuser/luks-slot}
OMU_RATE_DIR=${OMU_RATE_DIR:-$OMU_ROOT/run/omarchy-multiuser/rate}
OMU_LIFECYCLE_DISPATCH=${OMU_LIFECYCLE_DISPATCH:-/usr/bin/omarchy-lifecycle-dispatch}
OMU_REFUSAL_DELAY=${OMU_REFUSAL_DELAY:-3}
OMU_MIN_PASSWORD=6

omu_say() {
  printf '%s\n' "$*" >&2
}

# --- Passwords ---------------------------------------------------------------

omu_shadow_hash() {
  awk -F: -v user="$1" '$1 == user { print $2; exit }' "$OMU_SHADOW"
}

# The hash travels in the environment, which only root can read for a root
# process, and the password on stdin.
omu_password_matches_hash() {
  local password=$1 hash=$2
  [[ $hash == \$* ]] || return 1
  printf '%s' "$password" | OMU_HASH=$hash perl -e 'local $/; my $p = <STDIN>; my $h = $ENV{OMU_HASH}; exit(crypt($p, $h) eq $h ? 0 : 1)'
}

omu_password_matches() {
  omu_password_matches_hash "$1" "$(omu_shadow_hash "$2")"
}

# The account whose password this is. Accounts share no password, so there is
# at most one.
omu_password_owner() {
  local password=$1 user
  while read -r user; do
    if omu_password_matches "$password" "$user"; then
      echo "$user"
      return 0
    fi
  done < <(omu_human_users)
  return 1
}

# A locked account always has failed logins. Counts as yes when faillock can't say.
omu_has_failed_logins() {
  local tally
  tally=$(faillock --user "$1" 2>/dev/null) || return 0
  [[ -n $(awk 'NR > 2 && NF' <<<"$tally") ]]
}

# Changes whenever the account's shadow password does, without holding it.
omu_fingerprint() {
  omu_shadow_hash "$1" | sha256sum | cut -c1-16
}

# One chpasswd run commits every line in one write of shadow.
omu_set_passwords() {
  local password=$1 user
  shift
  for user in "$@"; do
    printf '%s:%s\n' "$user" "$password"
  done | chpasswd
}

# --- The system disk ---------------------------------------------------------

# The LUKS partition beneath /, or nothing when / is not encrypted. Fails when
# it can't tell.
omu_root_luks_device() {
  local root_source ancestry device
  if [[ -n ${OMU_SYSTEM_DRIVE+set} ]]; then
    printf '%s' "$OMU_SYSTEM_DRIVE"
    return 0
  fi
  root_source=$(findmnt -no SOURCE /) && [[ -n $root_source ]] || return 1
  ancestry=$(lsblk -nsrpo NAME,TYPE,FSTYPE "${root_source%%[*}") || return 1
  device=$(awk '$3 == "crypto_LUKS" { print $1; exit }' <<<"$ancestry")
  if [[ -n $device ]]; then
    readlink -f "$device"
  elif awk '$2 == "crypt" { found = 1 } END { exit !found }' <<<"$ancestry"; then
    return 1
  fi
}

# Sets OMU_DRIVE (empty when / is not encrypted) and OMU_UUID.
omu_load_drive() {
  OMU_DRIVE=$(omu_root_luks_device) || {
    omu_say "Could not tell whether the system disk is encrypted."
    return 1
  }
  OMU_UUID=-
  if [[ -n $OMU_DRIVE ]]; then
    OMU_UUID=$(cryptsetup luksUUID "$OMU_DRIVE") && [[ -n $OMU_UUID ]] || {
      omu_say "Could not read the system disk's UUID."
      return 1
    }
  fi
}

omu_encrypted() {
  [[ -n ${OMU_DRIVE:-} ]]
}

# Platforms whose boot checks want every kept key slot recorded (Apple Silicon)
# can't take a slot for another person until their boot package records one.
omu_slot_recorder_present() {
  local out status=0
  out=$("$OMU_LIFECYCLE_DISPATCH" --resolve luks-slots 2>/dev/null) || status=$?
  (( status == 0 )) && [[ -n $out ]]
}

# The slot the password opens. Returns 2 when it opens none. Tokens are tried
# before the key and report their own slot, so allow only a token type no token
# has.
omu_slot_of() {
  local out status=0
  out=$(printf '%s' "$1" | LC_ALL=C cryptsetup open --test-passphrase --verbose --token-type passphrase-only --key-file - "$OMU_DRIVE" 2>&1) || status=$?
  (( status == 0 )) || return "$status"
  grep -o 'Key slot [0-9]* unlocked' <<<"$out" | grep -o '[0-9]*' | head -1
}

# Whether the password opens that one slot. Returns 2 when it doesn't.
omu_slot_opens() {
  printf '%s' "$1" | cryptsetup open --test-passphrase --token-type passphrase-only --key-slot "$2" --key-file - "$OMU_DRIVE" >/dev/null 2>&1
}

omu_drive_slots() {
  local dump
  dump=$(cryptsetup luksDump "$OMU_DRIVE") || return 1
  awk '
    /^[^ \t]/ { keyslots = ($0 == "Keyslots:") }
    keyslots && /^ +[0-9]+: luks2/ { sub(":", "", $1); print $1 }
    /^Key Slot [0-9]+: ENABLED/ { sub(":", "", $3); print $3 }' <<<"$dump" | paste -sd, -
}

# 0 when the slot holds a key, 1 when it doesn't, 2 when the disk can't be read.
omu_slot_enabled() {
  local slots
  slots=$(omu_drive_slots) || return 2
  [[ ,$slots, == *",$1,"* ]]
}

omu_free_slot() {
  local slots slot last=31
  slots=$(omu_drive_slots) || return 1
  cryptsetup isLuks --type luks2 "$OMU_DRIVE" || last=7
  for (( slot = 0; slot <= last; slot++ )); do
    if [[ ,$slots, != *",$slot,"* ]]; then
      echo "$slot"
      return 0
    fi
  done
  return 1
}

# Puts NEW in SLOT, chosen and journaled beforehand so an interrupted run knows
# which slot to take back, authorised by CURRENT, and succeeds once NEW opens it.
omu_add_slot() {
  local slot=$1 current=$2 new=$3 opened
  local -a pbkdf
  # shellcheck disable=SC2206  # the tests' cheap key derivation, as words
  pbkdf=(${OMU_LUKS_PBKDF:---iter-time 2000})
  if [[ -z ${OMU_LUKS_PBKDF:-} ]] && cryptsetup isLuks --type luks2 "$OMU_DRIVE"; then
    pbkdf+=(--pbkdf argon2id)
  fi
  # shellcheck disable=SC2016  # the inner shell's
  printf '%s\n%s' "$current" "$new" |
    bash -c 'IFS= read -r current; drive=$1; shift; exec cryptsetup luksAddKey -q "$@" --key-file <(printf "%s" "$current") "$drive" <(cat)' bash "$OMU_DRIVE" --key-slot "$slot" "${pbkdf[@]}" || return 1
  opened=$(omu_slot_of "$new") || return 1
  [[ $opened == "$slot" ]]
}

# Batch mode needs no remaining key, so an interrupted change can be finished by
# a run that never saw the passwords, and removing an account needs nobody's disk
# password. A disk that can't be read is a failure, never a slot already gone.
omu_kill_slot() {
  local status=0 out
  omu_slot_enabled "$1" || status=$?
  if (( status == 1 )); then
    return 0
  elif (( status != 0 )); then
    return 1
  fi
  # With stdin not a terminal it reads a passphrase from there, batch mode or not,
  # and would wait for good on a pipe nobody closes. An empty one goes through, with
  # a remark about it that means nothing here.
  out=$(cryptsetup luksKillSlot -q "$OMU_DRIVE" "$1" </dev/null 2>&1) || {
    omu_say "$out"
    return 1
  }
}

# --- Durable files -------------------------------------------------------------

# Written whole, synced, then renamed and the directory synced, so a power cut
# leaves the old file or the new one, never a LUKS change without the record that
# explains it.
omu_durable_write() {
  local target=$1 tmp
  mkdir -p "${target%/*}" || return 1
  tmp=$(mktemp "${target%/*}/.${target##*/}.XXXXXX") || return 1
  if cat >"$tmp" && chmod 600 "$tmp" && sync "$tmp" && mv -f "$tmp" "$target"; then
    sync "${target%/*}"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --- The slot map --------------------------------------------------------------

# One line per account: <LUKS UUID> <slot> <uid> <user> <shadow fingerprint>.

omu_map_lines() {
  [[ -f $OMU_SLOT_MAP ]] && cat "$OMU_SLOT_MAP"
  true
}

omu_map_field() {
  omu_map_lines | awk -v user="$1" -v field="$2" '$4 == user { print $field; exit }'
}

omu_map_slot() {
  omu_map_field "$1" 2
}

omu_map_user_for_slot() {
  omu_map_lines | awk -v uuid="$1" -v slot="$2" '$1 == uuid && $2 == slot { print $4; exit }'
}

omu_map_set() {
  local user=$1 slot=$2 uid
  uid=$(getent passwd "$user" | cut -d: -f3)
  [[ -n $uid ]] || return 1
  { omu_map_lines | awk -v user="$user" '$4 != user'
    printf '%s %s %s %s %s\n' "$OMU_UUID" "$slot" "$uid" "$user" "$(omu_fingerprint "$user")"
  } | omu_durable_write "$OMU_SLOT_MAP"
}

omu_map_remove() {
  [[ -n $(omu_map_slot "$1") ]] || return 0
  omu_map_lines | awk -v user="$1" '$4 != user' | omu_durable_write "$OMU_SLOT_MAP"
}

omu_legacy_slot() {
  [[ -f $OMU_SLOT_LEGACY ]] || return 0
  awk -v user="$1" '$1 == user { slot = $2 } END { if (slot != "") print slot }' "$OMU_SLOT_LEGACY"
}

omu_legacy_owner() {
  [[ -f $OMU_SLOT_LEGACY ]] || return 0
  awk -v slot="$1" '$2 == slot { print $1; exit }' "$OMU_SLOT_LEGACY"
}

omu_legacy_remove() {
  [[ -n $(omu_legacy_slot "$1") ]] || return 0
  awk -v user="$1" '$1 != user' "$OMU_SLOT_LEGACY" | omu_durable_write "$OMU_SLOT_LEGACY"
}

# The map is trusted only whole: every line for this disk, no slot or account
# twice, every account still there under its uid.
omu_map_valid() {
  local uuid slot uid user fp
  local -A slots=() names=()
  while read -r uuid slot uid user fp; do
    [[ $uuid == "$OMU_UUID" && $slot =~ ^[0-9]+$ && -n $fp ]] || return 1
    [[ -z ${slots[$slot]:-} && -z ${names[$user]:-} ]] || return 1
    [[ $(getent passwd "$user" | cut -d: -f3) == "$uid" ]] || return 1
    slots[$slot]=1
    names[$user]=1
  done < <(omu_map_lines)
}

# A password changed with plain passwd no longer selects the account at boot:
# drift costs the convenience, never the boundary.
omu_in_sync() {
  [[ -n $(omu_map_slot "$1") && $(omu_map_field "$1" 5) == "$(omu_fingerprint "$1")" ]]
}

# --- The journal ---------------------------------------------------------------

# The account, the disk, slot numbers, a fingerprint of the account's password
# before the change, and the phase; never key material.

omu_journal_get() {
  [[ -f $OMU_SLOT_JOURNAL ]] || return 1
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' "$OMU_SLOT_JOURNAL"
}

omu_journal_put() {
  local key value
  local -A updates=()
  while (( $# )); do
    updates[$1]=$2
    shift 2
  done
  { if [[ -f $OMU_SLOT_JOURNAL ]]; then
      while IFS='=' read -r key value; do
        [[ -n ${updates[$key]+set} ]] || printf '%s=%s\n' "$key" "$value"
      done <"$OMU_SLOT_JOURNAL"
    fi
    for key in "${!updates[@]}"; do
      printf '%s=%s\n' "$key" "${updates[$key]}"
    done
  } | omu_durable_write "$OMU_SLOT_JOURNAL"
}

omu_journal_clear() {
  # shellcheck disable=SC2015  # a failed sync doesn't matter once the file is gone
  rm -f "$OMU_SLOT_JOURNAL" && sync "${OMU_SLOT_JOURNAL%/*}" 2>/dev/null || [[ ! -e $OMU_SLOT_JOURNAL ]]
}

omu_journal_pending() {
  [[ -f $OMU_SLOT_JOURNAL ]]
}

# --- Rules ---------------------------------------------------------------------

# Saying a password is taken says it is somebody's. The disk prompt says as much
# at every boot, so the delay only keeps this from being any cheaper.
omu_refuse_taken() {
  sleep "$OMU_REFUSAL_DELAY"
  omu_say "That password already unlocks this computer. Choose a different one."
}

# Every password is a disk key and picks its account, so it must be long enough
# and nobody else's: no other account's login password, and no key slot at all
# on the disk. An old password left in a slot no longer matches any hash but
# still opens it.
omu_check_new_password() {
  local password=$1 except_user=$2 user status=0
  if [[ $password == *$'\n'* ]]; then
    omu_say "A password can't contain a line break."
    return 1
  elif (( ${#password} < OMU_MIN_PASSWORD )); then
    omu_say "The password must be at least $OMU_MIN_PASSWORD characters."
    return 1
  fi
  while read -r user; do
    [[ $user != "$except_user" ]] || continue
    if omu_password_matches "$password" "$user"; then
      omu_refuse_taken
      return 1
    fi
  done < <(omu_human_users)
  if omu_encrypted; then
    omu_slot_of "$password" >/dev/null || status=$?
    if (( status == 0 )); then
      omu_refuse_taken
      return 1
    elif (( status != 2 )); then
      omu_say "Could not check the password against the system disk."
      return 1
    fi
  fi
}

# The caller's own password, proving they are who sudo says, and the key that
# lets a new slot be added. Once the map knows them, the password that opens
# their own slot proves it, which is also how someone whose login password was
# changed with plain passwd gets back in step. The first time, it must be their
# login password and open a slot nobody else holds, which then becomes theirs.
omu_authenticate() {
  local caller=$1 password=$2 mapped slot status=0 holder
  if ! omu_encrypted; then
    omu_password_matches "$password" "$caller" && return 0
    sleep "$OMU_REFUSAL_DELAY"
    omu_say "That isn't $caller's password."
    return 1
  fi

  mapped=$(omu_map_slot "$caller")
  if [[ -n $mapped ]]; then
    omu_slot_opens "$password" "$mapped" || status=$?
    if (( status == 0 )); then
      return 0
    elif (( status == 2 )); then
      sleep "$OMU_REFUSAL_DELAY"
      omu_say "That isn't the password that unlocks this computer for $caller."
    else
      omu_say "Could not check the password against the system disk."
    fi
    return 1
  fi

  if ! omu_password_matches "$password" "$caller"; then
    sleep "$OMU_REFUSAL_DELAY"
    omu_say "That isn't $caller's password."
    return 1
  fi
  slot=$(omu_slot_of "$password") || status=$?
  if (( status == 2 )); then
    omu_say "$caller's password doesn't open the system disk. Make them the same first, with omarchy-drive-password."
    return 1
  elif (( status != 0 )); then
    omu_say "Could not check the password against the system disk."
    return 1
  fi
  holder=$(omu_map_user_for_slot "$OMU_UUID" "$slot")
  [[ -n $holder ]] || holder=$(omu_legacy_owner "$slot")
  if [[ -n $holder && $holder != "$caller" ]]; then
    omu_say "$caller's password opens $holder's key slot."
    return 1
  fi
  omu_map_set "$caller" "$slot" && omu_legacy_remove "$caller"
}

# --- Operations ----------------------------------------------------------------

# Journals its phase before every step that changes something, keeping old access
# until its replacement is proven, so omu_slots_finish can roll an interrupted one
# back (before the account took the new password) or forward (after). Whether the
# account took it is read from shadow itself, by its fingerprint, not the phase.
omu_slots_change_password() {
  local caller=$1 name=$2 password=$3 caller_password=$4 slot=- old_slot=-
  local -a accounts=("$name") people
  omu_authenticate "$caller" "$caller_password" || return 1
  if omu_password_matches "$password" "$name"; then
    omu_say "That's already $name's password."
    return 1
  fi
  omu_check_new_password "$password" "$name" || return 1
  mapfile -t people < <(omu_human_users)
  if omu_encrypted; then
    if (( ${#people[@]} > 1 )) && omu_slot_recorder_present; then
      omu_say "This machine's boot checks can't take a second person's disk password yet."
      return 1
    fi
    old_slot=$(omu_map_slot "$name")
    [[ -n $old_slot ]] || old_slot=$(omu_legacy_slot "$name")
    old_slot=${old_slot:--}
    slot=$(omu_free_slot) || { omu_say "The system disk has no free key slot."; return 1; }
  fi
  # With one account root keeps its password, as the installer set it up.
  if (( ${#people[@]} == 1 )) && [[ $(omu_shadow_hash root) == \$* ]]; then
    accounts+=(root)
  fi

  omu_journal_put user "$name" uuid "$OMU_UUID" slot "$slot" old_slot "$old_slot" old_fp "$(omu_fingerprint "$name")" phase key || return 1
  if [[ $slot != "-" ]] && ! omu_add_slot "$slot" "$caller_password" "$password"; then
    omu_say "Could not add the new password to the system disk."
    omu_slots_finish
    return 1
  fi
  omu_set_passwords "$password" "${accounts[@]}" || { omu_slots_finish; return 1; }
  omu_journal_put phase shadow || return 1
  omu_slots_finish || return 1
  omu_boot_records_slot
}

# Takes the account's key off the disk and out of the records. Key first: a stop
# in between is finished by running this again, which still knows whose slot it is.
omu_slots_forget() {
  local user=$1 slot enabled status=0
  slot=$(omu_map_slot "$user")
  [[ -n $slot ]] || slot=$(omu_legacy_slot "$user")
  if [[ -z $slot ]] || ! omu_encrypted; then
    omu_map_remove "$user" && omu_legacy_remove "$user"
    return
  fi
  omu_slot_enabled "$slot" || status=$?
  if (( status == 0 )); then
    enabled=$(omu_drive_slots) || return 1
    if [[ $enabled == "$slot" ]]; then
      omu_say "Key slot $slot is the disk's last one; refusing to lock the disk for good."
      return 1
    fi
  fi
  omu_kill_slot "$slot" || return 1
  omu_map_remove "$user" && omu_legacy_remove "$user"
}

# Finishes whatever the journal says was under way, and succeeds once nothing is.
omu_slots_finish() {
  local user slot old_slot phase uuid
  omu_journal_pending || return 0
  user=$(omu_journal_get user)
  slot=$(omu_journal_get slot)
  old_slot=$(omu_journal_get old_slot)
  phase=$(omu_journal_get phase)
  uuid=$(omu_journal_get uuid)

  if [[ $uuid != "$OMU_UUID" ]]; then
    omu_say "The password journal records a change on another disk ($uuid); remove $OMU_SLOT_JOURNAL once you've checked that disk."
    return 1
  fi

  case $phase in
    key)
      if [[ -n $(omu_shadow_hash "$user") && $(omu_fingerprint "$user") != "$(omu_journal_get old_fp)" ]]; then
        omu_journal_put phase shadow && omu_slots_finish
        return
      fi
      # The new password may have reached the disk but not the account: back to
      # the old one everywhere.
      if [[ $slot != "-" ]]; then
        omu_kill_slot "$slot" || return 1
      fi
      omu_journal_clear
      ;;
    shadow)
      if [[ $slot != "-" ]]; then
        omu_map_set "$user" "$slot" || return 1
        if [[ $old_slot != "-" ]]; then
          omu_kill_slot "$old_slot" || return 1
        fi
        omu_legacy_remove "$user" || return 1
      fi
      omu_journal_clear
      ;;
    *)
      omu_say "The password journal records an unknown change ($phase)."
      return 1
      ;;
  esac
}

# --- Boot ------------------------------------------------------------------------

# The boot image picks up the hook that records which slot unlocked the disk once
# the map exists (zz-omarchy-mu-luks-slot.conf), so it is rebuilt the first time
# there is more than one person. Until it is, every boot shows the login screen,
# which is safe.
omu_boot_records_slot() {
  local marker=$OMU_SLOT_DIR/boot-records-slot rebuild=${OMU_REBUILD_BOOT:-limine-mkinitcpio}
  local -a people
  omu_encrypted && [[ ! -f $marker ]] || return 0
  mapfile -t people < <(omu_human_users)
  (( ${#people[@]} > 1 )) || return 0
  command -v "$rebuild" >/dev/null || rebuild="mkinitcpio -P"
  omu_say "Updating the boot image so the computer knows whose password unlocked it..."
  # shellcheck disable=SC2086  # a command and its option
  if $rebuild >/dev/null 2>&1; then
    : | omu_durable_write "$marker"
  else
    omu_say "Could not update the boot image, so the computer shows the login screen after the disk prompt. Run: sudo limine-mkinitcpio"
  fi
}
