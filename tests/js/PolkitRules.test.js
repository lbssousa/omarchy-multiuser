// Run with: node --test tests/js/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const RULES = path.join(__dirname, "../../polkit/10-omarchy-multiuser.rules")
const NO = "no"

// polkitd's JavaScript environment, as far as the rules file uses it.
function loadRules() {
  const rules = []
  const polkit = {
    Result: { NO, YES: "yes", AUTH_ADMIN: "auth_admin", NOT_HANDLED: null },
    addRule: (fn) => rules.push(fn),
  }
  vm.runInNewContext(fs.readFileSync(RULES, "utf8"), { polkit })
  return (actionId, details, groups) => {
    const action = { id: actionId, lookup: (k) => details[k] }
    const subject = { isInGroup: (g) => groups.includes(g) }
    for (const rule of rules) {
      const result = rule(action, subject)
      if (result !== undefined && result !== null) return result
    }
    return null
  }
}

const EXEC = "org.freedesktop.policykit.exec"
const BROWSER = { program: "/usr/bin/omarchy-theme-set-browser-policy" }

test("browser policy refused to users outside wheel", () => {
  const decide = loadRules()
  assert.equal(decide(EXEC, BROWSER, ["omarchy-users"]), NO)
  assert.equal(decide(EXEC, BROWSER, []), NO)
})

test("administrators fall through to polkit's own rules", () => {
  const decide = loadRules()
  assert.equal(decide(EXEC, BROWSER, ["wheel", "omarchy-users"]), null)
})

test("other programs and actions are left alone", () => {
  const decide = loadRules()
  assert.equal(decide(EXEC, { program: "/usr/bin/omarchy-theme-set-browser-policy-x" }, []), null)
  assert.equal(decide(EXEC, { program: "/usr/share/omarchy/bin/omarchy-update" }, []), null)
  assert.equal(decide("org.freedesktop.timedate1.set-timezone", BROWSER, []), null)
})

const FIDO2 = "org.omarchy-multiuser.fido2-authfile"

test("FIDO2 authfile action only for wheel and omarchy-users", () => {
  const decide = loadRules()
  assert.equal(decide(FIDO2, {}, []), NO)
  assert.equal(decide(FIDO2, {}, ["users"]), NO)
  assert.equal(decide(FIDO2, {}, ["omarchy-users"]), null)
  assert.equal(decide(FIDO2, {}, ["wheel"]), null)
})
