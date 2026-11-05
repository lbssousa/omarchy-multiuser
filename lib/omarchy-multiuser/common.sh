# shellcheck shell=bash
# Shared by the omarchy-mu-* commands. Every system path goes through
# $OMU_ROOT (empty in production) so the tests can run against a fake tree.

# A helper started as root through sudo/pkexec must not take paths or a PATH
# from its caller (sudo's env_reset already drops them; this is the backstop).
if (( EUID == 0 )) && [[ -n ${SUDO_USER:-}${PKEXEC_UID:-} ]]; then
  unset "${!OMU_@}"
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin
fi

OMU_ROOT=${OMU_ROOT:-}
OMU_SHARE=${OMU_SHARE:-/usr/share/omarchy-multiuser}
OMU_FIDO2_AUTHFILE=${OMU_FIDO2_AUTHFILE:-$OMU_ROOT/etc/fido2/fido2}
OMU_FPRINT_DIR=${OMU_FPRINT_DIR:-$OMU_ROOT/var/lib/fprint}
OMU_PAM_DIR=${OMU_PAM_DIR:-$OMU_ROOT/etc/pam.d}
OMU_SDDM_CONF_DIR=${OMU_SDDM_CONF_DIR:-$OMU_ROOT/etc/sddm.conf.d}
# Where omarchy-mu-login-select named whoever unlocked the disk, up to 0.11.0.
# Removed at every SDDM start, for machines upgraded from then.
OMU_SDDM_AUTOLOGIN=${OMU_SDDM_AUTOLOGIN:-$OMU_SDDM_CONF_DIR/zzz-omarchy-mu-autologin.conf}
# SDDM's own record of the last login, which the greeter reads as lastUser.
OMU_SDDM_STATE=${OMU_SDDM_STATE:-$OMU_ROOT/var/lib/sddm/state.conf}
# The one-time pass omarchy-mu-login-select leaves for whoever unlocked the
# disk, and omarchy-mu-login-once takes at the login screen: "user boot-id
# seconds". Root's alone, in a directory only root writes.
OMU_LOGIN_TICKET=${OMU_LOGIN_TICKET:-$OMU_ROOT/run/omarchy-multiuser/login-once}
OMU_LOGIN_TICKET_TTL=${OMU_LOGIN_TICKET_TTL:-60}
OMU_BOOT_ID=${OMU_BOOT_ID:-$OMU_ROOT/proc/sys/kernel/random/boot_id}
OMU_SDDM_THEMES=${OMU_SDDM_THEMES:-$OMU_ROOT/usr/share/sddm/themes}
OMU_STATE_DIR=${OMU_STATE_DIR:-$OMU_ROOT/var/lib/omarchy-multiuser}
OMU_LOCK_DIR=${OMU_LOCK_DIR:-$OMU_ROOT/run/lock}
OMU_SUDOERS_DIR=${OMU_SUDOERS_DIR:-$OMU_ROOT/etc/sudoers.d}
OMU_HOME_DIR=${OMU_HOME_DIR:-$OMU_ROOT/home}
OMU_LOGIN_DEFS=${OMU_LOGIN_DEFS:-$OMU_ROOT/etc/login.defs}
OMU_SHADOW=${OMU_SHADOW:-$OMU_ROOT/etc/shadow}
OMU_ADMIN_GROUP=${OMU_ADMIN_GROUP:-wheel}
OMU_USERS_GROUP=${OMU_USERS_GROUP:-omarchy-users}
# shellcheck disable=SC2034  # used by the scripts that source this
OMU_THEME=omarchy-multiuser

omu_die() {
  echo -e "\e[31m$*\e[0m" >&2
  exit 1
}

omu_info() {
  echo -e "\e[32m$*\e[0m"
}

# omu_is_admin [user] — member of the admin group (wheel). With a user, the
# account as configured; without one, this session's groups, which are what
# sudo goes by: a change to wheel takes effect at the next login for both.
omu_is_admin() {
  if (( $# )); then
    id -nG "$1" 2>/dev/null
  else
    id -nG
  fi | tr ' ' '\n' | grep -qx "$OMU_ADMIN_GROUP"
}

# Human accounts SDDM would list: uid 1000..59999 with a login shell.
omu_human_users() {
  getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1 }'
}

# The human accounts that are administrators, one per line. A wheel member
# with no login doesn't count as someone left to administer the machine.
omu_admins() {
  local user
  while read -r user; do
    if omu_is_admin "$user"; then
      echo "$user"
    fi
  done < <(omu_human_users)
}

# omu_has_programs <user> — anything running as them, in a session or not
# (cron, su, a lingering user manager). userdel refuses while there is.
omu_has_programs() {
  pgrep -u "$1" >/dev/null
}

_omu_programs_end() {
  local _
  for _ in {1..10}; do
    omu_has_programs "$1" || return 0
    sleep 0.5
  done
  return 1
}

# Whether loginctl lists a session matching the jq filter on the first console.
_omu_first_console_has() {
  local sessions
  sessions=$(loginctl list-sessions --json=short 2>/dev/null) || return 1
  jq -e --arg user "${2:-}" "any(.[]; .tty == \"tty1\" and ($1))" <<<"$sessions" >/dev/null 2>&1
}

# SDDM takes the end of a desktop it logged in automatically, when it is forced,
# for a crash and shows nothing more on the first console until it is asked.
# Asking also switches to that console, and that stays: a greeter whose console is
# taken back before its compositor has set up the screen stays dark for good, and
# how long that takes depends on the graphics card.
_omu_login_screen_back() {
  local active="" _
  [[ ! -r $OMU_ROOT/sys/class/tty/tty0/active ]] || active=$(<"$OMU_ROOT/sys/class/tty/tty0/active")
  for _ in {1..10}; do
    _omu_first_console_has '.class != "greeter"' || break
    sleep 0.5
  done
  sudo busctl call org.freedesktop.DisplayManager /org/freedesktop/DisplayManager/Seat0 \
    org.freedesktop.DisplayManager.Seat SwitchToGreeter >/dev/null 2>&1 || return 1
  [[ $active != tty[0-9]* || $active == tty1 ]] ||
    echo "The login screen takes over the screen. To come back here: Ctrl+Alt+F${active#tty}."
  for _ in {1..20}; do
    _omu_first_console_has '.class == "greeter"' && return 0
    sleep 0.5
  done
  return 1
}

# omu_sign_out <user> — end their sessions, then whatever outlives them, and bring
# back the login screen if their desktop was on the first console. Fails when
# something is still running.
omu_sign_out() {
  local on_first_console=false status=0
  # shellcheck disable=SC2016  # $user is jq's
  _omu_first_console_has '.user == $user' "$1" && on_first_console=true
  sudo loginctl terminate-user "$1" 2>/dev/null || true
  if ! _omu_programs_end "$1"; then
    sudo pkill -KILL -u "$1" || true
    _omu_programs_end "$1" || status=$?
  fi
  if $on_first_console && ! _omu_login_screen_back; then
    echo "Warning: the login screen didn't come back on the first console. Reboot, or run: sudo systemctl restart sddm (it ends every open desktop)." >&2
  fi
  return "$status"
}

# SDDM 0.21 starts a new greeter on the first console. An automatic login's
# desktop holds that console, so the greeter fails there and leaves the desktop
# dark with no way back. A normal login's desktop has a console of its own, and
# an earlier greeter on the first one can be gone back to. Not knowing counts as
# held: the cost of a wrong yes is a dark screen, of a wrong no a missing entry.
omu_first_console_free() {
  local sessions
  sessions=$(loginctl list-sessions --json=short 2>/dev/null) || return 1
  jq -e 'all(.[]; .tty != "tty1" or .class == "greeter")' <<<"$sessions" >/dev/null 2>&1
}

# omu_fixed_autologin — /etc/sddm.conf, which outranks every drop-in, names
# someone to log in automatically: the login screen would never show.
omu_fixed_autologin() {
  [[ -f $OMU_ROOT/etc/sddm.conf ]] || return 1
  awk '/^\[/ { section = $0 }
    section == "[Autologin]" && /^[ \t]*User[ \t]*=[ \t]*[^ \t]/ { found = 1 }
    END { exit !found }' "$OMU_ROOT/etc/sddm.conf"
}

# omu_ask_new_password <header> — prints the password, asked twice until both match.
omu_ask_new_password() {
  local first second
  while :; do
    first=$(gum input --password --header "$1") || return 1
    second=$(gum input --password --header "$1, again") || return 1
    [[ $first != "$second" ]] || break
    echo "The passwords don't match." >&2
  done
  printf '%s' "$first"
}

# omu_atomic_write <dest> <mode> — stdin to a sibling temp file, then rename,
# so readers never see a half-written file and a symlink at <dest> is
# replaced rather than followed.
omu_atomic_write() {
  local dest=$1 mode=$2 tmp
  tmp=$(mktemp "$dest.new.XXXXXX")
  if ! cat >"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod "$mode" "$tmp"
  mv -Tf -- "$tmp" "$dest"
}

# omu_with_lock <name> <command...> — serialize writers of a shared file.
omu_with_lock() {
  local name=$1
  shift
  mkdir -p "$OMU_LOCK_DIR"
  (
    flock -w 30 9 || omu_die "Timed out waiting for the $name lock."
    "$@"
  ) 9>"$OMU_LOCK_DIR/omarchy-mu-$name.lock"
}

# omu_hold_lock <name> — hold a machine-wide lock until this process ends,
# or fail at once when someone else holds it. The files come from tmpfiles.d
# (root:wheel 0640), so only administrators can open them, and opening them
# read-only means one administrator can't create them under their own name
# and keep the others out. Children inherit the descriptor (sudo closes it);
# close it ({OMU_LOCK_FD}<&-) for anything that may outlive the command.
omu_hold_lock() {
  local file=$OMU_LOCK_DIR/omarchy-mu-$1.lock
  [[ -f $file ]] || omu_die "Missing $file; run: sudo systemd-tmpfiles --create omarchy-multiuser.conf"
  exec {OMU_LOCK_FD}<"$file" || omu_die "Can't open $file (administrators only)."
  flock -n "$OMU_LOCK_FD"
}

_omu_login_def() {
  local value
  value=$(awk -v k="$1" '$1 == k { print $2 }' "$OMU_LOGIN_DEFS" 2>/dev/null | tail -1)
  echo "${value:-$2}"
}

# The lowest UID in UID_MIN..UID_MAX that no account has and that owns
# nothing directly under /home, so a home kept by `userdel` (--keep-home)
# never passes to the next account created.
omu_free_uid() {
  local min max uid
  min=$(_omu_login_def UID_MIN 1000)
  max=$(_omu_login_def UID_MAX 60000)
  declare -A taken=()
  while read -r uid; do taken[$uid]=1; done < <(
    getent passwd | cut -d: -f3
    find "$OMU_HOME_DIR" -mindepth 1 -maxdepth 1 -printf '%U\n' 2>/dev/null
  )
  for ((uid = min; uid <= max; uid++)); do
    [[ -n ${taken[$uid]:-} ]] || { echo "$uid"; return 0; }
  done
  return 1
}

# omu_group_members <group> — its listed members, one per line.
omu_group_members() {
  getent group "$1" | cut -d: -f4 | tr ',' '\n' | grep . || true
}

# omu_in_group <user> <group> — a listed member, or through the primary group.
omu_in_group() {
  local group gid
  omu_group_members "$2" | grep -x -- "$1" >/dev/null && return 0
  group=$(getent group "$2") || return 1
  gid=$(getent passwd "$1" | cut -d: -f4)
  [[ -n $gid && $gid == "$(cut -d: -f3 <<<"$group")" ]]
}
