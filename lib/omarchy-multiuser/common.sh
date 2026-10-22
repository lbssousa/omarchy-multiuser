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
OMU_SDDM_THEMES=${OMU_SDDM_THEMES:-$OMU_ROOT/usr/share/sddm/themes}
OMU_STATE_DIR=${OMU_STATE_DIR:-$OMU_ROOT/var/lib/omarchy-multiuser}
OMU_LOCK_DIR=${OMU_LOCK_DIR:-$OMU_ROOT/run/lock}
OMU_ADMIN_GROUP=${OMU_ADMIN_GROUP:-wheel}
OMU_USERS_GROUP=${OMU_USERS_GROUP:-omarchy-users}
OMU_THEME=omarchy-multiuser

omu_die() {
  echo -e "\e[31m$*\e[0m" >&2
  exit 1
}

omu_info() {
  echo -e "\e[32m$*\e[0m"
}

# omu_is_admin [user] — member of the admin group (wheel).
omu_is_admin() {
  local user=${1:-$(id -un)}
  id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$OMU_ADMIN_GROUP"
}

# Human accounts SDDM would list: uid 1000..59999 with a login shell.
omu_human_users() {
  getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $7 !~ /(nologin|false)$/ { print $1 }'
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
