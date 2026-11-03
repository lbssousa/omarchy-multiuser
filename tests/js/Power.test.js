// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const P = require("../../sddm/omarchy-multiuser/Power.js")

const all = { suspend: true, hibernate: true, reboot: true, powerOff: true }

test("only what the machine can do is offered", () => {
  assert.deepEqual(P.available(all).map((a) => a.id), ["suspend", "hibernate", "reboot", "powerOff"])
  assert.deepEqual(P.available({ ...all, hibernate: false }).map((a) => a.id), ["suspend", "reboot", "powerOff"])
  assert.deepEqual(P.available({ reboot: true }).map((a) => a.id), ["reboot"])
  assert.deepEqual(P.available({}), [])
  assert.deepEqual(P.available(undefined), [])
})

test("an action keeps its F key when another is missing", () => {
  const noHibernate = { ...all, hibernate: false }
  assert.equal(P.forFKey(all, 1).id, "suspend")
  assert.equal(P.forFKey(all, 2).id, "hibernate")
  assert.equal(P.forFKey(all, 3).id, "reboot")
  assert.equal(P.forFKey(all, 4).id, "powerOff")
  assert.equal(P.forFKey(noHibernate, 2), null)
  assert.equal(P.forFKey(noHibernate, 3).id, "reboot")
  assert.equal(P.forFKey(noHibernate, 4).id, "powerOff")
})

test("other keys and a machine that can't do it run nothing", () => {
  assert.equal(P.forFKey(all, 0), null)
  assert.equal(P.forFKey(all, 5), null)
  assert.equal(P.forFKey({}, 4), null)
  assert.equal(P.forFKey(undefined, 4), null)
})
