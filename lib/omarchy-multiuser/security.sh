# shellcheck shell=bash
# For the commands root runs on someone else's behalf without asking for a root
# password: sudo NOPASSWD (omarchy-mu-user-helper, omarchy-mu-apply-lock), sudo
# and pkexec (omarchy-mu-fido2-authfile) and PAM (omarchy-mu-login-match). A port
# of the parts of Omarchy's omarchy-security-functions (PR #16920) that matter
# here. Each of those commands starts with `#!/bin/bash -p`, fixes PATH when it
# is root, sources this file and calls omu_harden "$0" "$@" before anything else.

# shellcheck disable=SC2034  # used by the scripts that source this
OMU_SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/bin

# Started as `/usr/bin/bash -p <script>` (the shebang), and not as `bash script`
# or `bash -p script` by hand: privileged Bash reads no BASH_ENV, imports no
# functions and takes no SHELLOPTS from the environment. The check reads the
# caller's command line from /proc, from a clean Bash.
omu_privileged_bash_startup() {
  [[ $- == *p* ]] || return 1
  # The caller is this check's parent, under the number this /proc gives it.
  # shellcheck disable=SC2016  # the code runs in the clean Bash, not here
  /usr/bin/env -i /usr/bin/bash -p -c '
    stat=$(</proc/self/stat) || exit 1
    read -r _ caller _ <<<"${stat##*) }"
    mapfile -d "" -t argv <"/proc/$caller/cmdline" || exit 1
    executable=$(/usr/bin/readlink -e -- "/proc/$caller/exe") || exit 1
    [[ $executable == "/usr/bin/bash" &&
      ( ${argv[0]:-} == "/bin/bash" || ${argv[0]:-} == "/usr/bin/bash" ) &&
      ${argv[1]:-} == "-p" ]]
  ' omarchy-mu-bash-startup
}

# Privileged Bash ignores exported functions and these variables, but leaves
# them in the environment for the ordinary interpreters it starts later. Starts
# the script again without them when there are any.
omu_sanitize_bash_environment() {
  local script=$1
  shift
  local entry name environment_fd environment_pid
  local -a unsets=()

  exec {environment_fd}< <(/usr/bin/env -0)
  environment_pid=$!
  while IFS= read -r -d '' entry <&"$environment_fd"; do
    name=${entry%%=*}
    case "$name" in
      BASH_ENV|ENV|SHELLOPTS|BASHOPTS|PS4|CDPATH|GLOBIGNORE|IFS|BASH_FUNC_*%%)
        unsets+=(-u "$name")
        ;;
    esac
  done
  exec {environment_fd}<&-
  wait "$environment_pid" || return 1
  if (( ${#unsets[@]} > 0 )); then
    exec /usr/bin/env "${unsets[@]}" /usr/bin/bash -p -- "$script" "$@"
  fi
}

# omu_harden <script> [args...] — refuse an unprivileged start, start again with
# a clean environment if needed, and leave no caller's IFS, CDPATH or PATH.
# The caller sets its own umask. common.sh, sourced next, drops the OMU_*
# overrides when root runs this through sudo, pkexec or PAM.
omu_harden() {
  local script=$1
  shift
  if ! omu_privileged_bash_startup; then
    echo "${script##*/}: run it by its name (it starts with bash -p), not through bash." >&2
    exit 1
  fi
  omu_sanitize_bash_environment "$script" "$@" || exit 1
  unset IFS CDPATH GLOBIGNORE
  if (( EUID == 0 )); then
    export PATH=$OMU_SAFE_PATH
  fi
}
