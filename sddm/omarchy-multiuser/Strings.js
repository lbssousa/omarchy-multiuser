// Greeter strings. A plain map instead of .qm catalogs: two languages, and
// node can test it. The greeter's locale comes from /etc/locale.conf.

var catalogs = {
  en: {
    suspend: "Suspend",
    hibernate: "Hibernate",
    reboot: "Reboot",
    powerOff: "Shut down",
    confirmReboot: "Reboot the computer?",
    confirmPowerOff: "Shut down the computer?",
    confirm: "Confirm",
    cancel: "Cancel"
  },
  pt: {
    suspend: "Suspender",
    hibernate: "Hibernar",
    reboot: "Reiniciar",
    powerOff: "Desligar",
    confirmReboot: "Reiniciar o computador?",
    confirmPowerOff: "Desligar o computador?",
    confirm: "Confirmar",
    cancel: "Cancelar"
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
