# shellcheck shell=bash
# Classifying Omarchy migrations by the privileges they need. Sourced after
# common.sh by omarchy-mu-migrate and scripts/classify-migrations.
#
#   user    only touches the caller's own files ($HOME, systemctl --user, ...)
#   system  needs root and doesn't touch $HOME (packages, /etc, services)
#   mixed   both
#
# A migration "needs root" when, outside comments, it runs sudo/pkexec/run0
# or an Omarchy command whose header says `omarchy:requires-sudo=true`.
# share/migrations-overrides.tsv ("<name>\t<class>") corrects the guesses.

OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
OMU_MIGRATIONS_DIR=${OMU_MIGRATIONS_DIR:-$OMARCHY_PATH/migrations}
OMU_MIGRATION_OVERRIDES=${OMU_MIGRATION_OVERRIDES:-$OMU_SHARE/migrations-overrides.tsv}
OMU_MIGRATION_REGISTRY=${OMU_MIGRATION_REGISTRY:-$OMU_STATE_DIR/migrations}

declare -gA _omu_requires_sudo=()

# Omarchy commands that declare they need sudo, cached.
_omu_cmd_requires_sudo() {
  local cmd=$1 file
  if [[ -z ${_omu_requires_sudo[$cmd]+x} ]]; then
    file=$OMARCHY_PATH/bin/$cmd
    [[ -f $file ]] || file=$OMU_ROOT/usr/bin/$cmd
    if [[ -f $file ]] && grep -q '^# omarchy:requires-sudo=true' "$file"; then
      _omu_requires_sudo[$cmd]=1
    else
      _omu_requires_sudo[$cmd]=0
    fi
  fi
  [[ ${_omu_requires_sudo[$cmd]} == 1 ]]
}

# omu_migration_class <file>
omu_migration_class() {
  local file=$1 name body privileged=false personal=false cmd override
  name=$(basename "$file")

  if [[ -f $OMU_MIGRATION_OVERRIDES ]]; then
    override=$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$OMU_MIGRATION_OVERRIDES")
    if [[ -n $override ]]; then
      printf '%s\n' "$override"
      return
    fi
  fi

  # Code only: drop comment lines and trailing comments.
  body=$(sed -E -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]+#[^"'\'']*$//' "$file")

  if grep -qE '(^|[^[:alnum:]_-])(sudo|pkexec|run0)([^[:alnum:]_-]|$)' <<<"$body"; then
    privileged=true
  else
    while read -r cmd; do
      if _omu_cmd_requires_sudo "$cmd"; then
        privileged=true
        break
      fi
    done < <(grep -oE '\bomarchy-[a-z0-9-]+' <<<"$body" | sort -u)
  fi

  # shellcheck disable=SC2016  # literal $HOME etc. in the migration's text
  if grep -qE '\$HOME|\$\{HOME|~/|XDG_(CONFIG|DATA|STATE|CACHE)_HOME|systemctl +--user|gsettings|hyprctl|omarchy-(state|toggle|theme|defaults|nvim|done|shell)' <<<"$body"; then
    personal=true
  fi

  if $privileged && $personal; then
    echo mixed
  elif $privileged; then
    echo system
  else
    echo user
  fi
}
