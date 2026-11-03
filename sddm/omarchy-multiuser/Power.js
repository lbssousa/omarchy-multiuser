// Pure helpers for the power actions at the bottom of the greeter. Loaded by
// Main.qml and, in the tests, by node (module.exports at the bottom), so no QML
// here.
//
// `id` is both the sddm method to call and the key in `caps`, which Main.qml
// fills from sddm.can*. Each action keeps its F key whatever else is available,
// so F4 doesn't become something else on a machine that can't hibernate. Icons
// are the ones in Omarchy's system menu. `confirm` is the string that asks first:
// these two end every open session, and suspending and hibernating don't.

var actions = [
  { id: "suspend", label: "suspend", fkey: 1, icon: "\u{F04B2}" },
  { id: "hibernate", label: "hibernate", fkey: 2, icon: "\u{F0901}" },
  { id: "reboot", label: "reboot", fkey: 3, icon: "\u{F0709}", confirm: "confirmReboot" },
  { id: "powerOff", label: "powerOff", fkey: 4, icon: "\u{F0425}", confirm: "confirmPowerOff" }
]

function available(caps) {
  return actions.filter(function (action) {
    return !!caps && caps[action.id] === true
  })
}

// The action F<n> runs, or null.
function forFKey(caps, n) {
  var list = available(caps)
  for (var i = 0; i < list.length; i++) {
    if (list[i].fkey === n)
      return list[i]
  }
  return null
}

if (typeof module !== "undefined") {
  module.exports = { available: available, forFKey: forFKey }
}
