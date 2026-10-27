// Pure helpers for the first-login password. Loaded by Main.qml and, in the
// tests, by node (module.exports at the bottom), so no QML here.
//
// SDDM answers every PAM prompt with what was typed in the greeter, so for an
// account with an empty, expired password (`passwd -d`, `chage -d 0`) the
// typed text becomes "New password" and "Retype new password" at once. The
// greeter asks for it twice instead, for the accounts omarchy-mu-sddm-sync
// lists in theme.conf.user (passwordChangeUsers).

// passwordChangeUsers as SDDM hands it over: a space-separated string (a
// list, from "a,b", only when the theme.conf default has one; SDDM drops
// lists from theme.conf.user).
function parseUsers(value) {
  var list = Array.isArray(value) ? value : String(value || "").split(/[,\s]+/)
  var users = []
  for (var i = 0; i < list.length; i++) {
    var name = String(list[i] || "").trim()
    if (name.length > 0 && users.indexOf(name) === -1)
      users.push(name)
  }
  return users
}

function needsChange(users, user) {
  return String(user || "").length > 0 && (users || []).indexOf(String(user)) !== -1
}

// The list with one more account, for one PAM reports after the list was
// written (a new array, so QML bindings see the change).
function withUser(users, user) {
  var list = (users || []).slice()
  if (String(user || "").length > 0 && list.indexOf(String(user)) === -1)
    list.push(String(user))
  return list
}

// pam_unix's notice before it asks for the new password ("You are required
// to change your password immediately (...)", "Your password has expired;
// ...") and its Portuguese translations ("Mude sua senha imediatamente"). SDDM relays it as an error and reports the
// login as failed while the change still goes on.
function isChangeNotice(message) {
  return /(required to change your password|password has expired|(mude|mudar|altere|alterar|troque|trocar) (a |sua )?senha|senha (expirou|expirada))/i
    .test(String(message || ""))
}

// "" when the two fields can go to sddm.login(), else what is wrong with them.
function check(password, confirmation) {
  if (String(password || "").length === 0)
    return "empty"
  if (password !== confirmation)
    return "mismatch"
  return ""
}

if (typeof module !== "undefined") {
  module.exports = {
    parseUsers: parseUsers,
    needsChange: needsChange,
    withUser: withUser,
    isChangeNotice: isChangeNotice,
    check: check
  }
}
