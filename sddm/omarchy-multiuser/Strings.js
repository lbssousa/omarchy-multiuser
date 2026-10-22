// Greeter strings. A plain map instead of .qm catalogs: two languages, and
// node can test it. The greeter's locale comes from /etc/locale.conf.

var catalogs = {
  en: {
    otherUser: "Other user…",
    username: "Username"
  },
  pt: {
    otherUser: "Outro usuário…",
    username: "Nome de usuário"
  }
}

// "pt_BR", "pt-PT", "pt" -> pt; anything unknown (including "C") -> en.
function language(localeName) {
  var lang = String(localeName || "").toLowerCase().split(/[_.@-]/)[0]
  return catalogs.hasOwnProperty(lang) ? lang : "en"
}

function t(localeName, key) {
  var catalog = catalogs[language(localeName)]
  return catalog.hasOwnProperty(key) ? catalog[key] : (catalogs.en[key] || key)
}

if (typeof module !== "undefined") {
  module.exports = { language: language, t: t }
}
