// Pure helpers for the greeter's user list. Loaded by Main.qml and, in the
// tests, by node (module.exports at the bottom), so no QML here.

// What a row shows: the GECOS full name, or the username when it is empty.
function displayName(realName, name) {
  var real = String(realName || "").trim()
  return real.length > 0 ? real : String(name || "")
}

// The username under the full name, only when it adds something.
function secondaryName(realName, name, showUsername) {
  if (!showUsername)
    return ""
  var real = String(realName || "").trim()
  var user = String(name || "")
  return real.length > 0 && real !== user ? user : ""
}

// Rows of the list: one per listed user, then "Other user…" when allowed (or
// when nobody is listed, since the greeter would otherwise have no way in).
function buildEntries(users, allowOther, showUsername) {
  var entries = []
  var list = users || []
  for (var i = 0; i < list.length; i++) {
    var u = list[i]
    if (!u || !u.name)
      continue
    entries.push({
      other: false,
      name: String(u.name),
      label: displayName(u.realName, u.name),
      secondary: secondaryName(u.realName, u.name, showUsername !== false)
    })
  }
  if (allowOther || entries.length === 0)
    entries.push({ other: true, name: "", label: "", secondary: "" })
  return entries
}

// Row selected at startup: SDDM's last user when listed, else the first row.
function initialIndex(entries, lastUser) {
  var list = entries || []
  var last = String(lastUser || "")
  for (var i = 0; i < list.length; i++) {
    if (!list[i].other && list[i].name === last)
      return i
  }
  return 0
}

// Up/Down move one row and wrap around.
function step(index, delta, count) {
  if (count <= 0)
    return 0
  return ((index + delta) % count + count) % count
}

// Username handed to sddm.login(): the selected row's, or what was typed.
function loginUser(entry, typed) {
  if (!entry)
    return ""
  return entry.other ? String(typed || "").trim() : entry.name
}

if (typeof module !== "undefined") {
  module.exports = {
    displayName: displayName,
    secondaryName: secondaryName,
    buildEntries: buildEntries,
    initialIndex: initialIndex,
    step: step,
    loginUser: loginUser
  }
}
