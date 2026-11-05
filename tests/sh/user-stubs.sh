# shellcheck shell=bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# The tools the account commands use, against a fake tree: getent, id, gpasswd,
# groupadd, useradd, userdel, usermod and chpasswd read and edit $T/etc; sudo
# runs the command as is. Every change is logged to $T/calls.
#
#   $T/running       accounts with programs running (pgrep); signing them out
#                    empties it, except for those also in $T/unkillable
#   $T/gum-answers   gum's answers, one per call: y, n or c (cancel) to confirm,
#                    the text to input, which is sekret-pw with none left
#   $T/sudo-l        what sudo -l -U prints, instead of "not allowed"
#   $T/userdel-fails account: nothing happens; home: the account goes, its
#                    home stays
user_stubs() {
  mkdir -p "$T/stubs" "$T/etc/sudoers.d" "$T/etc/systemd/system/multi-user.target.wants" "$T/run/lock" "$T/home"
  : >"$T/run/lock/omarchy-mu-accounts.lock"
  : >"$T/run/lock/omarchy-mu-slots.lock"
  : >"$T/etc/shadow"
  : >"$T/calls"
  cat >"$T/stubs/getent" <<'STUB'
#!/bin/bash
db=$T/etc/$1
[[ -f $db ]] || exit 2
if (( $# == 1 )); then cat "$db"; exit 0; fi
awk -F: -v k="$2" '$1 == k || $3 == k { print; found = 1 } END { exit !found }' "$db"
STUB
  cat >"$T/stubs/id" <<'STUB'
#!/bin/bash
case $1 in
  -un) echo "$ME" ;;
  -nG)
    if (( $# == 1 )) && [[ -f $T/session-groups ]]; then cat "$T/session-groups"; exit 0; fi
    u=${2:-$ME}
    grep -q "^$u:" "$T/etc/passwd" || [[ -z ${2:-} ]] || exit 1
    gid=$(awk -F: -v u="$u" '$1 == u { print $4 }' "$T/etc/passwd")
    awk -F: -v u="$u" -v gid="$gid" '
      $3 == gid { print $1; next }
      { n = split($4, m, ","); for (i = 1; i <= n; i++) if (m[i] == u) print $1 }' "$T/etc/group" | paste -sd' '
    ;;
  *) exit 2 ;;
esac
STUB
  cat >"$T/stubs/gpasswd" <<'STUB'
#!/bin/bash
echo "gpasswd $*" >>"$T/calls"
awk -F: -v OFS=: -v op="$1" -v u="$2" -v g="$3" '
  $1 == g {
    n = split($4, m, ","); out = ""
    for (i = 1; i <= n; i++) if (m[i] != u) out = out (out == "" ? "" : ",") m[i]
    if (op == "-a") out = out (out == "" ? "" : ",") u
    $4 = out
  } { print }' "$T/etc/group" >"$T/etc/group.new" && mv "$T/etc/group.new" "$T/etc/group"
STUB
  cat >"$T/stubs/groupadd" <<'STUB'
#!/bin/bash
grep -q "^$2:" "$T/etc/group" || echo "$2:x:950:" >>"$T/etc/group"
STUB
  cat >"$T/stubs/useradd" <<'STUB'
#!/bin/bash
echo "useradd $*" >>"$T/calls"
uid="" groups=""
while (( $# > 1 )); do
  case $1 in
    --uid) uid=$2; shift 2 ;;
    --groups) groups=$2; shift 2 ;;
    --comment|--shell) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s:x:%s:%s::/home/%s:/bin/bash\n' "$1" "$uid" "$uid" "$1" >>"$T/etc/passwd"
printf '%s:!:20000:0:99999:7:::\n' "$1" >>"$T/etc/shadow"
for g in ${groups//,/ }; do "$T/stubs/gpasswd" -a "$1" "$g"; done
STUB
  cat >"$T/stubs/userdel" <<'STUB'
#!/bin/bash
echo "userdel $*" >>"$T/calls"
user=${*: -1}
fails=$(cat "$T/userdel-fails" 2>/dev/null)
if [[ $fails == account ]]; then echo "userdel: user $user is currently used by process 1"; exit 8; fi
sed -i "/^$user:/d" "$T/etc/passwd"
sed -i -E "s/(:|,)$user(,|\$)/\1/; s/,\$//" "$T/etc/group"
if [[ $fails == home ]]; then echo "userdel: error removing directory /home/$user"; exit 12; fi
[[ $* != *--remove* ]] || rm -rf "${T:?}/home/$user"
echo "userdel: $user mail spool (/var/mail/$user) not found"
STUB
  cat >"$T/stubs/usermod" <<'STUB'
#!/bin/bash
echo "usermod $*" >>"$T/calls"
[[ $1 == -L ]] || exit 2
sed -i -E "s/^($2):([^!]?)/\1:!\2/" "$T/etc/shadow"
STUB
  cat >"$T/stubs/chpasswd" <<'STUB'
#!/bin/bash
echo "chpasswd $*" >>"$T/calls"
cat >/dev/null
STUB
  cat >"$T/stubs/sudo" <<'STUB'
#!/bin/bash
[[ $1 != -v ]] || exit 0
[[ $1 != -n ]] || shift
if [[ $1 == -l ]]; then
  if [[ -f $T/sudo-l ]]; then cat "$T/sudo-l"; else echo "User $3 is not allowed to run sudo on this host."; fi
  exit 0
fi
"$@"
STUB
  cat >"$T/stubs/pgrep" <<'STUB'
#!/bin/bash
grep -qx "$2" "$T/running" 2>/dev/null
STUB
  cat >"$T/stubs/pkill" <<'STUB'
#!/bin/bash
echo "pkill $*" >>"$T/calls"
grep -qx "${*: -1}" "$T/unkillable" 2>/dev/null || sed -i "/^${*: -1}$/d" "$T/running"
STUB
  cat >"$T/stubs/loginctl" <<'STUB'
#!/bin/bash
echo "loginctl $*" >>"$T/calls"
if [[ $1 == terminate-user ]] && ! grep -qx "$2" "$T/unkillable" 2>/dev/null; then
  sed -i "/^$2$/d" "$T/running" 2>/dev/null
fi
exit 0
STUB
  # Enabling a watcher is its WantedBy symlink.
  cat >"$T/stubs/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$T/calls"
[[ ! -e $T/systemctl-fails ]] || exit 1
unit=${*: -1}
case $1 in
  enable) ln -s /dev/null "$T/etc/systemd/system/multi-user.target.wants/$unit" ;;
  disable) rm -f "$T/etc/systemd/system/multi-user.target.wants/$unit" ;;
esac
STUB
  cat >"$T/stubs/gum" <<'STUB'
#!/bin/bash
echo "gum $*" >>"$T/calls"
answer=$(head -1 "$T/gum-answers"); sed -i 1d "$T/gum-answers"
if [[ $1 == input ]]; then
  echo "${answer:-sekret-pw}"
  exit 0
fi
case $answer in
  y) exit 0 ;;
  c) exit 130 ;;
  *) exit 1 ;;
esac
STUB
  # Reads the passwords like the real one; $T/helper-fails names an action that fails.
  cat >"$T/stubs/omarchy-mu-user-helper" <<'STUB'
#!/bin/bash
echo "omarchy-mu-user-helper $*" >>"$T/calls"
[[ $1 == forget ]] || cat >>"$T/helper-stdin"
[[ $(cat "$T/helper-fails" 2>/dev/null) != "$1" ]]
STUB
  # Nothing to do for the commands that have their own tests, or need hardware.
  local cmd
  for cmd in runuser fprintd-delete omarchy-mu-fido2-authfile omarchy-mu-apply-lock; do
    # shellcheck disable=SC2016  # $* and $T belong to the stub
    printf '#!/bin/bash\necho "%s $*" >>"$T/calls"\n' "$cmd" >"$T/stubs/$cmd"
  done
  printf '#!/bin/bash\n' >"$T/stubs/sleep"
  : >"$T/gum-answers"
  chmod +x "$T/stubs/"*
  export PATH="$T/stubs:$PATH" ME=owner
}

watcher() { echo "$T/etc/systemd/system/multi-user.target.wants/omarchy-mu-migrate-record@$1.path"; }
assert_watched() { [[ -L $(watcher "$1") ]] || fail "no migration watcher for $1"; }
assert_not_watched() { [[ ! -L $(watcher "$1") ]] || fail "a migration watcher for $1"; }
