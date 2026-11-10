#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck disable=SC2016  # the stubs' code runs in the stubs, not in this shell
# Children (omarchy-child), as in Omarchy PR #16920: the helper's add --child, apps,
# blocked and adult-check, and omarchy-mu-user-apps-apply's ACLs and hidden entries.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=user-stubs.sh
source "$(dirname "$0")/user-stubs.sh"

setup() {
  user_stubs
  printf 'root:x:0:0::/root:/bin/bash\nowner:x:1000:1000::/home/owner:/bin/bash\nemma:x:1001:1001::/home/emma:/bin/bash\n' >"$T/etc/passwd"
  printf 'wheel:x:998:owner\nomarchy-users:x:950:emma\nomarchy-child:x:951:emma\n' >"$T/etc/group"
  printf 'root:!:1::::::\nowner:%s:1::::::\nemma:%s:1::::::\n' "$(pw_hash owner-pass)" "$(pw_hash emma-pass)" >"$T/etc/shadow"
  mkdir -p "$T/home/emma" "$T/usr/bin" "$T/usr/lib/discord" "$T/usr/share/applications"
  # Apps: one with a program of its own, one that runs through the browser.
  printf '#!/bin/sh\n' >"$T/usr/bin/discord"; chmod +x "$T/usr/bin/discord"
  printf '#!/bin/sh\n' >"$T/usr/bin/omarchy-launch-webapp"; chmod +x "$T/usr/bin/omarchy-launch-webapp"
  printf '[Desktop Entry]\nName=Discord\nExec=discord %%U\n' >"$T/usr/share/applications/Discord.desktop"
  printf '[Desktop Entry]\nName=WhatsApp\nExec=omarchy-launch-webapp https://web.whatsapp.com\n' >"$T/usr/share/applications/WhatsApp.desktop"
  printf '[Desktop Entry]\nName=Files\nExec=nautilus\n' >"$T/usr/share/applications/org.gnome.Nautilus.desktop"
  # ACLs as a list of "user path" lines; runuser runs the command, as that user would.
  cat >"$T/stubs/setfacl" <<'STUB'
#!/bin/bash
echo "setfacl $*" >>"$T/calls"
path=${*: -1}
case $1 in
  -m) user=${2#u:}; user=${user%%:*}; echo "$user $path" >>"$T/acl" ;;
  -x) user=${2#u:}; grep -vxF "$user $path" "$T/acl" >"$T/acl.new"; mv "$T/acl.new" "$T/acl" ;;
esac
STUB
  cat >"$T/stubs/runuser" <<'STUB'
#!/bin/bash
echo "runuser $*" >>"$T/calls"
shift 2; [[ $1 == -- ]] && shift
"$@"
STUB
  printf '#!/bin/bash\n' >"$T/stubs/logger"
  chmod +x "$T/stubs/"*
  : >"$T/acl"
  export SUDO_USER=owner
}
denied() { grep -qxF "$1 $T/$2" "$T/acl"; }
apps_dir() { echo "$T/home/emma/.local/share/applications"; }
block() { { echo owner-pass; printf '%s\n' "$@"; } | omarchy-mu-user-helper apps emma; }

test_a_new_child_starts_with_the_shipped_list_blocked() {
  setup
  sed -i '/^emma:/d' "$T/etc/passwd" "$T/etc/shadow"
  sed -i 's/:emma$/:/' "$T/etc/group"
  rm -rf "$T/home/emma"
  printf 'owner-pass\nemma-pass\n' | omarchy-mu-user-helper add --child --full-name "Emma" emma 2>"$T/err" || fail "add: $(cat "$T/err")"
  assert_contains "$T/calls" "--groups omarchy-users,omarchy-child emma"
  assert_contains "$T/var/lib/omarchy-multiuser/blocked-apps/emma" "WhatsApp"
  assert_contains "$T/var/lib/omarchy-multiuser/blocked-apps/emma" "Google Messages"
  assert_file "$(apps_dir)/WhatsApp.desktop"
}

test_a_blocked_program_is_denied_with_its_own_directory() {
  setup
  block Discord WhatsApp || fail "apps"
  denied emma usr/bin/discord || fail "discord runs"
  denied emma usr/lib/discord || fail "/usr/lib/discord is open"
  # A web app runs through what everyone needs: hidden only.
  ! denied emma usr/bin/omarchy-launch-webapp || fail "denied the web app launcher"
  assert_contains "$(apps_dir)/Discord.desktop" "Hidden=true"
  assert_contains "$(apps_dir)/WhatsApp.desktop" "Hidden=true"
}

test_unblocking_gives_access_and_the_entry_back() {
  setup
  mkdir -p "$(apps_dir)"
  printf '[Desktop Entry]\nName=My WhatsApp\n' >"$(apps_dir)/WhatsApp.desktop"
  block Discord WhatsApp || fail "apps"
  assert_contains "$(apps_dir)/WhatsApp.desktop" "Hidden=true"
  block || fail "emptied"
  ! denied emma usr/bin/discord || fail "discord still denied"
  assert_no_file "$(apps_dir)/Discord.desktop"
  assert_contains "$(apps_dir)/WhatsApp.desktop" "My WhatsApp"
}

test_an_upgrade_that_replaced_a_program_gets_it_denied_again() {
  setup
  block Discord || fail "apps"
  : >"$T/acl"
  omarchy-mu-user-apps-apply || fail "apply"
  denied emma usr/bin/discord || fail "not denied again"
}

test_only_an_administrator_blocks_and_never_for_one() {
  setup
  { echo owner-pass; echo Discord; } | omarchy-mu-user-helper apps owner 2>"$T/err" && fail "blocked an administrator"
  assert_contains "$T/err" "administrator"
  { echo emma-pass; echo Discord; } | SUDO_USER=emma omarchy-mu-user-helper apps emma 2>/dev/null && fail "a child chose"
  { echo owner-pass; echo '../etc/passwd'; } | omarchy-mu-user-helper apps emma 2>/dev/null && fail "took a path"
  assert_no_file "$T/var/lib/omarchy-multiuser/blocked-apps/emma"
}

test_removing_a_child_gives_access_back() {
  setup
  block Discord || fail "apps"
  echo owner-pass | omarchy-mu-user-helper delete emma 2>/dev/null || fail "delete"
  assert_no_file "$T/var/lib/omarchy-multiuser/blocked-apps/emma"
  assert_contains "$T/calls" "setfacl -x u:emma"
}

test_the_list_is_read_back_for_administrators() {
  setup
  block WhatsApp Discord || fail "apps"
  assert_eq "$(omarchy-mu-user-helper blocked emma | paste -sd,)" "Discord,WhatsApp"
  SUDO_USER=emma omarchy-mu-user-helper blocked emma 2>/dev/null && fail "a child read it"
  true
}

# --- adult-check ------------------------------------------------------------------

adult_check() { printf '%s\n' "$1" | SUDO_USER=${2:-emma} omarchy-mu-user-helper adult-check; }

test_an_administrators_password_opens_a_childs_lock() {
  setup
  adult_check owner-pass || fail "refused the owner's password"
  adult_check emma-pass 2>/dev/null && fail "took the child's own"
  adult_check nobodys-pass 2>/dev/null && fail "took a stranger's"
  true
}

test_adult_check_answers_only_for_a_child() {
  setup
  sed -i 's/^omarchy-child:x:951:emma$/omarchy-child:x:951:/' "$T/etc/group"
  adult_check owner-pass 2>"$T/err" && fail "answered for a limited account"
  assert_contains "$T/err" "Only a child's lock screen"
}

test_adult_check_waits_after_five_misses() {
  setup
  for _ in 1 2 3 4 5; do adult_check wrong-pass 2>/dev/null; done
  adult_check owner-pass 2>/dev/null && fail "no lockout after five misses"
  read -r failures until <"$T/run/omarchy-multiuser/rate/adult-check-1001"
  assert_eq "$failures" 5
  (( until > $(date +%s) )) || fail "no wait recorded"
}

test_adult_check_needs_no_lock_and_no_disk() {
  setup
  rm -f "$T/run/lock/omarchy-mu-slots.lock"
  adult_check owner-pass || fail "needed the slots lock"
}

run_tests
