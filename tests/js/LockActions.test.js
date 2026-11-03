// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const A = require("../../shell/lock/LockActions.js")

const all = { switchUser: true, suspend: true, reboot: true, powerOff: true }

test("only what the machine can do is offered", () => {
  assert.deepEqual(A.available(all).map((a) => a.id), ["switchUser", "suspend", "reboot", "powerOff"])
  assert.deepEqual(A.available({ ...all, switchUser: false }).map((a) => a.id), ["suspend", "reboot", "powerOff"])
  assert.deepEqual(A.available({}), [])
  assert.deepEqual(A.available(undefined), [])
  assert.deepEqual(A.available({ reboot: "true" }), [])
})

test("capabilities that can't be read offer nothing", () => {
  assert.deepEqual(A.parseCapabilities('{"reboot":true}'), { reboot: true })
  assert.deepEqual(A.parseCapabilities(""), {})
  assert.deepEqual(A.parseCapabilities("not json"), {})
  assert.deepEqual(A.parseCapabilities("null"), {})
  assert.deepEqual(A.available(A.parseCapabilities("not json")), [])
})

test("an action keeps its F key, the greeter's, when another is missing", () => {
  const noSwitch = A.available({ ...all, switchUser: false })
  assert.equal(A.forFKey(noSwitch, 1).id, "suspend")
  assert.equal(A.forFKey(noSwitch, 3).id, "reboot")
  assert.equal(A.forFKey(noSwitch, 4).id, "powerOff")
  assert.equal(A.forFKey(noSwitch, 5), null)
  assert.equal(A.forFKey(A.available(all), 2), null)
  assert.equal(A.forFKey(undefined, 1), null)
})

test("only what ends the sessions asks first", () => {
  const offered = A.available(all)
  assert.equal(A.forFKey(offered, 5).confirm, undefined)
  assert.equal(A.forFKey(offered, 1).confirm, undefined)
  assert.equal(A.forFKey(offered, 3).confirm, "confirmReboot")
  assert.equal(A.forFKey(offered, 4).confirm, "confirmPowerOff")
})

for (const lang of ["en", "pt"]) {
  test(`${lang} has every string the actions use`, () => {
    const file = path.join(__dirname, "../../shell/lock/i18n", `${lang}.json`)
    const catalog = JSON.parse(fs.readFileSync(file, "utf8"))
    for (const action of A.actions) {
      assert.ok(catalog[action.label], action.label)
      if (action.confirm) assert.ok(catalog[action.confirm], action.confirm)
    }
    for (const key of ["confirm", "cancel", "failed"]) assert.ok(catalog[key], key)
  })
}
