#!/bin/bash
# shellcheck disable=SC2031  # $T is set by run_tests in the subshell each test runs in
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

valid_jsonc() {
  # shellcheck disable=SC2016  # JavaScript, not shell
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
  assert_contains "$T/menu.jsonc" "summon lbssousa.security-key"
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

# An admin gate replaces the entry's own `when`, so it must carry Omarchy's
# condition along, and the entry must still exist upstream.
test_admin_gates_keep_upstream_conditions() {
  local menu=${OMU_UPSTREAM_MENU:-/usr/share/omarchy/default/omarchy/omarchy-menu.jsonc}
  [[ -f $menu ]] || { echo "    (no installed Omarchy menu; skipped)"; return 0; }
  # shellcheck disable=SC2016  # JavaScript, not shell
  node -e '
    const fs = require("fs")
    const parse = f => JSON.parse(fs.readFileSync(f, "utf8").split("\n")
      .filter(l => !/^\s*\/\//.test(l)).join("\n").replace(/,(\s*})/g, "$1"))
    const upstream = parse(process.argv[1])
    const block = parse(process.argv[2])
    let bad = []
    for (const [id, entry] of Object.entries(block)) {
      const m = /^omarchy-mu-is-admin(?: && (.*))?$/.exec(entry.when || "")
      if (!m || entry.label) continue
      if (!upstream[id]) { bad.push(id + ": gone upstream"); continue }
      let want = upstream[id].when, got = m[1]
      if (got && /\|\|/.test(want || "")) got = got.replace(/^\((.*)\)$/, "$1")
      if ((want || undefined) !== got) bad.push(id + ": upstream when is " + JSON.stringify(want))
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1) }
  ' "$menu" <(printf '{\n%s\n}\n' "$(cat "$REPO/share/menu-block.jsonc")") || fail "admin gates out of date"
}

run_tests
