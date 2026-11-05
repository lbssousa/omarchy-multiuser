// Pure helper for the login screen, which asks for a password alone. Loaded by
// Main.qml and, in the tests, by node (module.exports at the bottom), so no QML here.

// The accounts to try the password for, in order: the last one to log in, then
// everyone else SDDM lists. omarchy-mu-login-match ends an attempt on the wrong
// one at once, so only a password that is nobody's counts as a failed login.
function candidates(lastUser, names) {
  var list = []
  var all = [lastUser].concat(names || [])
  for (var i = 0; i < all.length; i++) {
    var name = String(all[i] || "")
    if (name.length > 0 && list.indexOf(name) === -1)
      list.push(name)
  }
  return list
}

// The account the greeter logs in by itself as it comes up: SDDM's last user,
// which omarchy-mu-login-select sets to whoever unlocked the disk. Only a plain
// account name; anything else, nobody.
function autoLoginUser(lastUser) {
  var name = String(lastUser || "")
  return /^[a-z_][a-z0-9_-]{0,31}$/.test(name) ? name : ""
}

if (typeof module !== "undefined") {
  module.exports = { candidates: candidates, autoLoginUser: autoLoginUser }
}
