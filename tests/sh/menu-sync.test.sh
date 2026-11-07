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

test_english_without_language_file() {
  OMARCHY_LANGUAGE_FILE=$T/none omarchy-mu-menu-sync "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"label":"Add User","when":"omarchy-mu-is-admin"'
  assert_not_contains "$T/menu.jsonc" searchTerms
}

test_writes_labels_in_the_omarchy_language() {
  echo pt-BR >"$T/language"
  OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
  valid_jsonc "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"label":"Adicionar usuário","searchTerms":["Add User"],"when":"omarchy-mu-is-admin"'
  assert_contains "$T/menu.jsonc" '"label":"Trocar de usuário","searchTerms":["Switch User"]'
  # Only the labels change; actions and gates stay as written.
  assert_contains "$T/menu.jsonc" '"action":"omarchy-launch-floating-terminal-with-presentation omarchy-mu-user-add"'
  assert_contains "$T/menu.jsonc" '"label":"Omarchy Setup"'
}

test_follows_a_language_change() {
  echo de >"$T/language"
  OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"label":"Benutzer hinzufügen"'
  echo en >"$T/language"
  OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
  assert_not_contains "$T/menu.jsonc" "Benutzer"
  assert_contains "$T/menu.jsonc" '"label":"Add User"'
}

test_unknown_or_bad_language_is_english() {
  local code
  for code in xx '../../etc' ''; do
    printf '%s\n' "$code" >"$T/language"
    OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
    assert_contains "$T/menu.jsonc" '"label":"Remove User"'
  done
}

# Every language has each labelled entry of the block about accounts, and
# nothing else; with Omarchy installed, its languages are the catalog's plus English.
test_catalog_matches_block_and_omarchy() {
  local locales=${OMU_UPSTREAM_LOCALES:-/usr/share/omarchy/default/i18n/locales.json}
  # shellcheck disable=SC2016  # JavaScript, not shell
  node -e '
    const fs = require("fs")
    const block = JSON.parse(fs.readFileSync(process.argv[1], "utf8").split("\n")
      .filter(l => !/^\s*\/\//.test(l)).join("\n").replace(/,(\s*})/g, "$1"))
    const catalog = JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
    const want = Object.keys(block).filter(id => block[id].label && id !== "setup.omarchy-setup").sort().join(",")
    let bad = []
    for (const [code, labels] of Object.entries(catalog)) {
      if (Object.keys(labels).sort().join(",") !== want) bad.push(code + ": ids differ from " + want)
      for (const [id, label] of Object.entries(labels)) if (!String(label).trim()) bad.push(code + " " + id + ": empty")
    }
    if (fs.existsSync(process.argv[3])) {
      const langs = Object.keys(JSON.parse(fs.readFileSync(process.argv[3], "utf8"))).filter(c => c !== "en").sort()
      if (langs.join(",") !== Object.keys(catalog).sort().join(",")) bad.push("languages differ from Omarchy: " + langs.join(","))
    }
    if (bad.length) { console.error(bad.join("\n")); process.exit(1) }
  ' <(printf '{\n%s\n}\n' "$(cat "$REPO/share/menu-block.jsonc")") "$REPO/share/menu-labels.json" "$locales" || fail "menu-labels.json out of date"
}

# The menu gives a user entry without a label its bare id, so the block's
# overrides of Omarchy's entries are written whole, labelled in the menu's language.
fake_upstream() {
  mkdir -p "$T/i18n/pt-BR"
  cat >"$T/upstream.jsonc" <<'JSON'
{
  "install": {"icon":"I","label":"Install"},
  "update.omarchy": {"icon":"U","iconFont":"omarchy","label":"Omarchy","action":"stock"},
}
JSON
  printf '{"install":{"label":"Instalar"},"update.omarchy":{"label":"Omarchy"}}\n' >"$T/i18n/pt-BR/menu.json"
  export OMU_UPSTREAM_MENU=$T/upstream.jsonc OMU_UPSTREAM_I18N=$T/i18n
}

test_overrides_are_written_whole() {
  fake_upstream
  echo pt-BR >"$T/language"
  OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
  valid_jsonc "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"install": {"icon":"I","label":"Instalar","searchTerms":["Install"],"when":"omarchy-mu-is-admin"},'
  # The block's own fields win; a label the language keeps adds no search term.
  assert_contains "$T/menu.jsonc" '"update.omarchy": {"action":"omarchy-launch-floating-terminal-with-presentation omarchy-mu-update","icon":"U","iconFont":"omarchy","label":"Omarchy"},'
  echo en >"$T/language"
  OMARCHY_LANGUAGE_FILE=$T/language omarchy-mu-menu-sync "$T/menu.jsonc"
  assert_contains "$T/menu.jsonc" '"install": {"icon":"I","label":"Install","when":"omarchy-mu-is-admin"},'
}

# A whole entry the file already has (by hand, or omarchy-setup's overrides)
# would be replaced by a later one with the same id: the block leaves it out.
test_leaves_ids_set_outside_the_block() {
  printf '{\n  "setup.security.fido2": {"label":"Mine","action":"mine"},\n}\n' >"$T/menu.jsonc"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  valid_jsonc "$T/menu.jsonc"
  assert_eq "$(grep -c '"setup.security.fido2"' "$T/menu.jsonc")" 1
  assert_contains "$T/menu.jsonc" '"setup.security.fido2": {"label":"Mine","action":"mine"},'
  assert_contains "$T/menu.jsonc" omarchy-mu-remove-security-fido2
  cp "$T/menu.jsonc" "$T/once"
  omarchy-mu-menu-sync "$T/menu.jsonc"
  cmp -s "$T/once" "$T/menu.jsonc" || fail "second run changed the file"
}

run_tests
