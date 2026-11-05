// Pure helpers for the actions at the bottom of the lock screen. Loaded by
// LockView.qml and Service.qml and, in the tests, by node (module.exports at
// the bottom), so no QML here.
//
// `id` is the key in the capabilities from `omarchy-mu-lock-action capabilities`
// and the action handed to that command. The F keys are the greeter's (Power.js),
// so a key does the same on both screens; F2 is the greeter's hibernate. `confirm`
// is the string that asks first: these two end every open session, and the others
// leave them as they are.

var actions = [
  { id: "switchUser", label: "switchUser", fkey: 5, icon: "\u{F0019}" },
  { id: "suspend", label: "suspend", fkey: 1, icon: "\u{F04B2}" },
  { id: "reboot", label: "reboot", fkey: 3, icon: "\u{F0709}", confirm: "confirmReboot" },
  { id: "powerOff", label: "powerOff", fkey: 4, icon: "\u{F0425}", confirm: "confirmPowerOff" }
]

// Unreadable capabilities offer nothing, rather than actions that would fail.
function parseCapabilities(text) {
  try {
    var caps = JSON.parse(String(text || ""))
    return caps && typeof caps === "object" ? caps : {}
  } catch (e) {
    return {}
  }
}

function available(caps) {
  return actions.filter(function (action) {
    return !!caps && caps[action.id] === true
  })
}

// The action F<n> runs among those offered, or null.
function forFKey(offered, n) {
  var list = offered || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].fkey === n)
      return list[i]
  }
  return null
}

// F5 asks for the login screen, which takes a moment to appear. Asking again
// meanwhile would start a second one, which SDDM can't show.
var SWITCH_USER_SETTLE_MS = 5000

function switchUserSettling(now, lastAskedMs) {
  return lastAskedMs > 0 && now - lastAskedMs < SWITCH_USER_SETTLE_MS
}

// The exit status of `omarchy-mu-lock-action session-active` that means the session
// is in the background. Anything else, a command that couldn't run included, must
// not leave someone at their own lock unable to open it.
function isBackgroundAnswer(exitCode) {
  return exitCode === 1
}

// A line from `omarchy-mu-lock-action watch-unlock` meaning logind was told to
// unlock the session it watches. Exactly that line: the rest is gdbus talking.
function isUnlockSignal(line) {
  return /^\/org\/freedesktop\/login1\/session\/[A-Za-z0-9_]+: org\.freedesktop\.login1\.Session\.Unlock \(\)$/.test(String(line))
}

if (typeof module !== "undefined") {
  module.exports = {
    actions: actions,
    parseCapabilities: parseCapabilities,
    available: available,
    forFKey: forFKey,
    switchUserSettling: switchUserSettling,
    isBackgroundAnswer: isBackgroundAnswer,
    isUnlockSignal: isUnlockSignal
  }
}
