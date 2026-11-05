// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const S = require("../../sddm/omarchy-multiuser/Strings.js")

test("language from locale names", () => {
  assert.equal(S.language("pt_BR"), "pt")
  assert.equal(S.language("pt-PT"), "pt")
  assert.equal(S.language("pt_BR.UTF-8"), "pt")
  assert.equal(S.language("en_US"), "en")
  assert.equal(S.language("C"), "en")
  assert.equal(S.language(""), "en")
  assert.equal(S.language("de_DE"), "en")
})

test("translations", () => {
  assert.equal(S.t("pt_BR", "reboot"), "Reiniciar")
  assert.equal(S.t("en_US", "reboot"), "Reboot")
  assert.equal(S.t("C", "cancel"), "Cancel")
  assert.equal(S.t("pt_BR", "missing"), "missing")
})
