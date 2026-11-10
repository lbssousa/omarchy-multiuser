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

test("the greeter logs in by itself only a plain account name", () => {
  assert.equal(P.autoLoginUser("bia"), "bia")
  assert.equal(P.autoLoginUser(""), "")
  assert.equal(P.autoLoginUser(undefined), "")
  assert.equal(P.autoLoginUser("../bia"), "")
  assert.equal(P.autoLoginUser("Bia"), "")
})
