// Greeter strings. A plain map instead of .qm catalogs: two languages, and
// node can test it. The greeter's locale comes from /etc/locale.conf.

var catalogs = {
  en: {
    otherUser: "Other user…",
    username: "Username",
    choosePassword: "First login: choose your password",
    newPassword: "New password",
    confirmPassword: "Repeat the password",
    emptyPassword: "Type a password",
    mismatch: "The passwords don't match",
    changeFailed: "The password wasn't changed"
  },
  pt: {
    otherUser: "Outro usuário…",
    username: "Nome de usuário",
    choosePassword: "Primeiro acesso: escolha sua senha",
    newPassword: "Nova senha",
    confirmPassword: "Repita a senha",
    emptyPassword: "Digite uma senha",
    mismatch: "As senhas não coincidem",
    changeFailed: "A senha não foi alterada"
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
