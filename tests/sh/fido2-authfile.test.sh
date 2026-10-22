#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# omarchy-mu-fido2-authfile, under fakeroot (EUID 0, no SUDO_USER) with
# --user, against a fake /etc/fido2. Uses two accounts that exist anywhere:
# root and the user running the tests.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
me=$(id -un)

helper() { fakeroot -- "$REPO/bin/omarchy-mu-fido2-authfile" "$@"; }
authfile() { echo "$T/etc/fido2/fido2"; }

test_add_creates_line() {
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null || fail "add failed"
  assert_eq "$(cat "$(authfile)")" "$me:KH1,PK1,es256,+presence"
  assert_eq "$(stat -c %a "$(authfile)")" 644
}

test_second_user_keeps_first() {
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null
  echo "root:KH9,PK9,es256,+presence" | helper add --user root >/dev/null
  assert_eq "$(wc -l <"$(authfile)")" 2
  assert_contains "$(authfile)" "$me:KH1,PK1,es256,+presence"
  assert_contains "$(authfile)" "root:KH9,PK9,es256,+presence"
}

test_second_key_appends_and_dedupes() {
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null
  echo "$me:KH2,PK2,es256,+presence" | helper add --user "$me" >/dev/null
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null
  assert_eq "$(cat "$(authfile)")" "$me:KH1,PK1,es256,+presence:KH2,PK2,es256,+presence"
}

test_rejects_other_users_line() {
  if echo "root:KH,PK,es256,+presence" | helper add --user "$me" 2>/dev/null; then
    fail "accepted a line for another user"
  fi
  assert_no_file "$(authfile)"
}

test_rejects_multiline_and_junk() {
  printf '%s\n%s\n' "$me:A,B" "root:C,D" | helper add --user "$me" 2>/dev/null && fail "accepted two lines"
  echo "$me:A B;rm -rf /" | helper add --user "$me" 2>/dev/null && fail "accepted junk"
  echo "$me:" | helper add --user "$me" 2>/dev/null && fail "accepted an empty credential"
  assert_no_file "$(authfile)"
}

test_remove_only_own_line_and_report_empty() {
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null
  echo "root:KH9,PK9,es256,+presence" | helper add --user root >/dev/null
  out=$(helper remove --user "$me")
  assert_eq "$(cat "$(authfile)")" "root:KH9,PK9,es256,+presence"
  [[ $out != *empty* ]] || fail "reported empty with a user left"
  out=$(helper remove --user root)
  [[ $out == *empty* ]] || fail "didn't report empty"
  assert_eq "$(cat "$(authfile)")" ""
}

test_has() {
  echo "$me:KH1,PK1,es256,+presence" | helper add --user "$me" >/dev/null
  "$REPO/bin/omarchy-mu-fido2-authfile" has "$me" || fail "has: not found"
  "$REPO/bin/omarchy-mu-fido2-authfile" has root && fail "has: root found"
  true
}

test_refuses_symlinked_authfile() {
  mkdir -p "$T/etc/fido2" "$T/elsewhere"
  ln -s "$T/elsewhere/target" "$(authfile)"
  echo "$me:KH1,PK1" | helper add --user "$me" 2>/dev/null && fail "wrote through a symlink"
  assert_no_file "$T/elsewhere/target"
}

test_add_needs_root() {
  echo "$me:KH1,PK1" | "$REPO/bin/omarchy-mu-fido2-authfile" add 2>/dev/null && fail "ran without root"
  true
}

run_tests
