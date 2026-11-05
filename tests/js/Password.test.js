// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const P = require("../../sddm/omarchy-multiuser/Password.js")

test("the last account first, then everyone else, once each", () => {
  assert.deepEqual(P.candidates("bia", ["ana", "bia", "cau"]), ["bia", "ana", "cau"])
})

test("no last account, or one SDDM doesn't list any more", () => {
  assert.deepEqual(P.candidates("", ["ana", "bia"]), ["ana", "bia"])
  assert.deepEqual(P.candidates(undefined, ["ana"]), ["ana"])
  assert.deepEqual(P.candidates("velho", ["ana"]), ["velho", "ana"])
})

test("nobody to try", () => {
  assert.deepEqual(P.candidates("", []), [])
  assert.deepEqual(P.candidates("", undefined), [])
  assert.deepEqual(P.candidates("", ["", null]), [])
})
