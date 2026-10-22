// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const L = require("../../sddm/omarchy-multiuser/UserList.js")

const users = [
  { name: "abutre", realName: "Laércio de Sousa" },
  { name: "fulana", realName: "" },
  { name: "beltrano", realName: "  Beltrano  " }
]

test("displayName falls back to the username", () => {
  assert.equal(L.displayName("Laércio de Sousa", "abutre"), "Laércio de Sousa")
  assert.equal(L.displayName("", "fulana"), "fulana")
  assert.equal(L.displayName("   ", "fulana"), "fulana")
  assert.equal(L.displayName(undefined, "fulana"), "fulana")
  assert.equal(L.displayName(" Beltrano ", "beltrano"), "Beltrano")
})

test("secondaryName only when it adds something", () => {
  assert.equal(L.secondaryName("Laércio de Sousa", "abutre", true), "abutre")
  assert.equal(L.secondaryName("", "fulana", true), "")
  assert.equal(L.secondaryName("fulana", "fulana", true), "")
  assert.equal(L.secondaryName("Laércio de Sousa", "abutre", false), "")
})

test("buildEntries lists users, then Other user", () => {
  const e = L.buildEntries(users, true, true)
  assert.equal(e.length, 4)
  assert.deepEqual(e.map(x => x.label), ["Laércio de Sousa", "fulana", "Beltrano", ""])
  assert.equal(e[3].other, true)
  assert.equal(e.slice(0, 3).every(x => x.other === false), true)
})

test("buildEntries without Other user", () => {
  const e = L.buildEntries(users, false, true)
  assert.equal(e.length, 3)
  assert.equal(e.some(x => x.other), false)
})

test("buildEntries always offers Other user when nobody is listed", () => {
  assert.deepEqual(L.buildEntries([], false, true), [{ other: true, name: "", label: "", secondary: "" }])
  assert.equal(L.buildEntries(undefined, false, true).length, 1)
  assert.equal(L.buildEntries([{ name: "" }, null], false, true).length, 1)
})

test("initialIndex picks the last user, else the first row", () => {
  const e = L.buildEntries(users, true, true)
  assert.equal(L.initialIndex(e, "beltrano"), 2)
  assert.equal(L.initialIndex(e, "nobody"), 0)
  assert.equal(L.initialIndex(e, ""), 0)
  assert.equal(L.initialIndex([], "abutre"), 0)
})

test("step wraps around", () => {
  assert.equal(L.step(0, -1, 4), 3)
  assert.equal(L.step(3, 1, 4), 0)
  assert.equal(L.step(1, 1, 4), 2)
  assert.equal(L.step(0, 1, 0), 0)
})

test("loginUser uses the row or the typed name", () => {
  const e = L.buildEntries(users, true, true)
  assert.equal(L.loginUser(e[0], "ignored"), "abutre")
  assert.equal(L.loginUser(e[3], "  ciclano "), "ciclano")
  assert.equal(L.loginUser(e[3], ""), "")
  assert.equal(L.loginUser(null, "x"), "")
})
