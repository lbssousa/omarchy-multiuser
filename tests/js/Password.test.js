// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const P = require("../../sddm/omarchy-multiuser/Password.js")

test("passwordChangeUsers as a list or a string", () => {
  assert.deepEqual(P.parseUsers(["surubi", "coruja"]), ["surubi", "coruja"])
  assert.deepEqual(P.parseUsers("surubi"), ["surubi"])
  assert.deepEqual(P.parseUsers("surubi coruja"), ["surubi", "coruja"])
  assert.deepEqual(P.parseUsers("surubi, coruja,,surubi"), ["surubi", "coruja"])
  assert.deepEqual(P.parseUsers(""), [])
  assert.deepEqual(P.parseUsers(undefined), [])
})

test("who needs a new password", () => {
  assert.equal(P.needsChange(["surubi"], "surubi"), true)
  assert.equal(P.needsChange(["surubi"], "abutre"), false)
  assert.equal(P.needsChange(["surubi"], ""), false)
  assert.equal(P.needsChange(undefined, "surubi"), false)
})

test("adding an account reported by PAM", () => {
  const users = ["surubi"]
  assert.deepEqual(P.withUser(users, "coruja"), ["surubi", "coruja"])
  assert.deepEqual(P.withUser(users, "surubi"), ["surubi"])
  assert.notEqual(P.withUser(users, "surubi"), users)
  assert.deepEqual(P.withUser(undefined, ""), [])
})

test("pam_unix's change notices", () => {
  assert.equal(P.isChangeNotice("You are required to change your password immediately (administrator enforced)."), true)
  assert.equal(P.isChangeNotice("You are required to change your password immediately (password expired)."), true)
  assert.equal(P.isChangeNotice("Your password has expired; please change it now"), true)
  assert.equal(P.isChangeNotice("Mude sua senha imediatamente (aplicado pela raiz)."), true)
  assert.equal(P.isChangeNotice("Mude sua senha imediatamente (senha expirada)."), true)
  assert.equal(P.isChangeNotice("Authentication failure"), false)
  assert.equal(P.isChangeNotice("No password has been supplied."), false)
  assert.equal(P.isChangeNotice("Nenhuma senha informada."), false)
  assert.equal(P.isChangeNotice(""), false)
})

test("the two password fields", () => {
  assert.equal(P.check("", ""), "empty")
  assert.equal(P.check("abc", "abd"), "mismatch")
  assert.equal(P.check("abc", ""), "mismatch")
  assert.equal(P.check("abc", "abc"), "")
})
