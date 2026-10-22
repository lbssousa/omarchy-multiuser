#!/bin/bash
source "$(dirname "$0")/lib.sh"

valid_jsonc() {
  node -e '
    const s = require("fs").readFileSync(process.argv[1], "utf8")
      .split("\n").filter(l => !/^\s*\/\//.test(l)).join("\n").replace(/,(\s*})/g, "$1")
    JSON.parse(s)' "$1" || fail "$1 is not valid JSONC"
}

test_inserts_block_before_closing_brace() {
  printf '{\n  // mine\n  "about": {"label":"Mine"}\n}\n' >"$T/menu.jsonc"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  valid_jsonc "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"about": {"label":"Mine"},'
  assert_contains "$T/menu.jsonc" omarchy-mu-setup-security-fido2
  assert_eq "$(tail -1 "$T/menu.jsonc")" "}"
}

test_idempotent_and_replaces_old_block() {
  printf '{\n  "about": {"label":"Mine"},\n}\n' >"$T/menu.jsonc"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  cp "$T/menu.jsonc" "$T/once"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  cmp -s "$T/once" "$T/menu.jsonc" || fail "second run changed the file"
  sed -i 's/omarchy-mu-update/OLD/' "$T/menu.jsonc"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  cmp -s "$T/once" "$T/menu.jsonc" || fail "old block not replaced"
  assert_eq "$(grep -c '>>> omarchy-multiuser' "$T/menu.jsonc")" 1
}

test_creates_missing_file() {
  omarchy-mu-menu-sync "$T/new/menu.jsonc"
  valid_jsonc "$T/new/menu.jsonc"
}

run_tests
