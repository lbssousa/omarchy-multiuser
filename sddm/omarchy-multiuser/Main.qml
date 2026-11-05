pragma ComponentBehavior: Bound

import QtQuick 2.15
import QtQuick.Window 2.15
import SddmComponents 2.0
import "Strings.js" as Strings
import "Password.js" as Password
import "Power.js" as Power

// Omarchy's greeter (upstream/sddm/omarchy/Main.qml) as Omarchy PR #16920 made it:
// a password alone, as at the disk prompt, tried for the last account and then each
// other one until one logs in (Password.js, omarchy-mu-login-match). The power
// actions SDDM offers sit at the bottom, by click or F key (Power.js).
// As it comes up, it logs in by itself whoever unlocked the disk at this boot, which
// omarchy-mu-login-select chose and omarchy-mu-login-once lets through once: that
// desktop gets a console of its own, so switching users needs no logout.
Rectangle {
  id: root
  width: 640
  height: 480
  color: config.background || "#1a1b26"

  readonly property color textColor: config.textColor || "#c0caf5"
  readonly property string assetDir: {
    var dir = config.assetDir || "/usr/share/sddm/themes/omarchy/"
    return dir.charAt(dir.length - 1) === "/" ? dir : dir + "/"
  }
  readonly property string localeName: Qt.locale().name
  readonly property string fontFamily: "JetBrainsMono Nerd Font"

  // Filled from userModel by the Repeater below.
  property var userSlots: ({})
  property var userNames: []
  property bool loginFailed: false
  property var attemptUsers: []
  property int attempt: 0
  property string pending: ""
  property bool awaiting: false
  property int resends: 0
  // SDDM sends LoginFailed twice for one failure. The second is consumed as such
  // even if it arrives after the next account was sent, so it is never taken for
  // that account's answer.
  property int duplicates: 0
  // The greeter's own try, as it comes up, at the login omarchy-mu-login-select
  // chose (omarchy-mu-login-once), and an Enter pressed meanwhile.
  property bool autoAttempt: false
  property bool loginQueued: false
  readonly property var powerActions: Power.available(powerCaps)
  // All false until the daemon tells SDDM what the machine can do.
  readonly property var powerCaps: ({
    suspend: sddm.canSuspend,
    hibernate: sddm.canHibernate,
    reboot: sddm.canReboot,
    powerOff: sddm.canPowerOff
  })
  // The action waiting for a confirmation, or null.
  property var pendingPower: null
  property int sessionIndex: {
    for (var i = 0; i < sessionModel.rowCount(); i++) {
      var name = (sessionModel.data(sessionModel.index(i, 0), Qt.DisplayRole) || "").toString()
      if (name.indexOf("uwsm") !== -1)
        return i
    }
    return sessionModel.lastIndex
  }

  function asset(name) {
    return "file://" + assetDir + name
  }

  function addUser(index, name) {
    userSlots[index] = name
    userNames = Object.keys(userSlots).map(Number).sort(function (a, b) { return a - b })
      .map(function (key) { return userSlots[key] })
  }

  function login() {
    attemptUsers = Password.candidates(userModel.lastUser, userNames)
    if (attemptUsers.length === 0 || password.input.text.length === 0)
      return
    pending = password.input.text
    attempt = 0
    resends = 0
    send()
  }

  function failLogin() {
    pending = ""
    awaiting = false
    password.input.text = ""
    loginFailed = true
    password.input.forceActiveFocus()
  }

  function send() {
    awaiting = true
    sddm.login(attemptUsers[attempt], pending, root.sessionIndex)
    unanswered.restart()
  }

  // An empty password for SDDM's last user. omarchy-mu-login-select left a pass for
  // it if the disk was unlocked with that user's password at this boot; without one,
  // PAM turns it down at once, and nothing shows.
  function tryAutoLogin() {
    var user = Password.autoLoginUser(userModel.lastUser)
    if (user === "")
      return
    autoAttempt = true
    awaiting = true
    sddm.login(user, "", root.sessionIndex)
    unanswered.restart()
  }

  function endAutoLogin() {
    autoAttempt = false
    awaiting = false
    unanswered.stop()
    if (loginQueued) {
      loginQueued = false
      queuedLogin.start()
    }
  }

  function requestPower(action) {
    if (action.confirm) {
      pendingPower = action
      powerTimeout.restart()
    } else {
      runPower(action)
    }
  }

  // Nothing typed stays in the boxes across a suspend.
  function runPower(action) {
    pendingPower = null
    password.input.text = ""
    sddm[action.id]()
  }

  // Escape and the power keys.
  function handleCommonKey(event) {
    if (pendingPower !== null) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        // Enter still held from before isn't an answer to the question.
        if (!event.isAutoRepeat)
          runPower(pendingPower)
        event.accepted = true
        return true
      }
      if (event.key === Qt.Key_Escape) {
        pendingPower = null
        event.accepted = true
        return true
      }
      // Anything else is someone logging in: it goes on as usual.
      if (event.key < Qt.Key_F1 || event.key > Qt.Key_F4)
        pendingPower = null
    }
    if (event.key === Qt.Key_Escape) {
      password.input.text = ""
    } else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F4) {
      // Held down, the key would run it again as the machine wakes up.
      var action = Power.forFKey(powerCaps, event.key - Qt.Key_F1 + 1)
      if (action !== null && !event.isAutoRepeat)
        requestPower(action)
    } else {
      return false
    }
    event.accepted = true
    return true
  }

  Connections {
    target: sddm
    function onLoginFailed() {
      if (root.duplicates > 0) {
        root.duplicates--
        return
      }
      root.duplicates = 1
      pairWindow.restart()
      if (!root.awaiting)
        return
      root.awaiting = false
      unanswered.stop()
      if (root.autoAttempt) {
        root.endAutoLogin()
        return
      }
      if (root.pending !== "" && root.attempt + 1 < root.attemptUsers.length) {
        root.attempt++
        root.resends = 0
        nextAttempt.start()
        return
      }
      root.failLogin()
    }
    function onLoginSucceeded() {
      root.autoAttempt = false
      root.awaiting = false
      unanswered.stop()
      root.pending = ""
      root.loginFailed = false
    }
  }

  // SDDM reports a failure before its helper has exited, and silently drops a login
  // sent before then, so the next account waits a moment; an attempt still unanswered
  // after pam_unix's failure delay was dropped, and is sent again, a few times at most.
  Timer {
    id: nextAttempt
    interval: 300
    onTriggered: root.send()
  }

  Timer {
    id: unanswered
    interval: 5000
    onTriggered: {
      if (root.autoAttempt) {
        root.endAutoLogin()
        return
      }
      if (root.pending === "")
        return
      if (root.resends >= 3) {
        root.failLogin()
        return
      }
      root.resends++
      root.send()
    }
  }

  // As nextAttempt: SDDM drops a login sent before the last one's helper is gone.
  Timer {
    id: queuedLogin
    interval: 300
    onTriggered: root.login()
  }

  Timer {
    id: pairWindow
    interval: 1000
    onTriggered: root.duplicates = 0
  }

  // userModel's name role is only reachable from a delegate, so each reports its row.
  Repeater {
    model: userModel
    delegate: Item {
      required property int index
      required property string name
      Component.onCompleted: root.addUser(index, name)
    }
  }

  // An image from the stock theme (recolored by Appearance > Unlock), or the
  // packaged copy when the stock one is missing.
  component ThemeImage: Image {
    property string assetName
    property bool useFallback: false
    source: useFallback ? "fallback/" + assetName : root.asset(assetName)
    onStatusChanged: {
      if (status === Image.Error && !useFallback)
        useFallback = true
    }
  }

  // A password box: the stock entry image with a bullet per character (the
  // text itself is transparent).
  component SecretField: Item {
    id: field
    property alias input: secret
    signal keyPressed(var event)
    width: fieldEntry.width
    height: fieldEntry.height

    ThemeImage {
      id: fieldEntry
      assetName: root.loginFailed ? "entry-failed.png" : "entry.png"
      anchors.centerIn: parent
    }

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 20
      anchors.verticalCenter: parent.verticalCenter
      spacing: 5

      Repeater {
        model: Math.min(secret.text.length, 21)

        ThemeImage {
          assetName: "bullet.png"
          width: 7
          height: 7
        }
      }
    }

    TextInput {
      id: secret
      anchors.fill: parent
      anchors.leftMargin: 20
      anchors.rightMargin: 20
      verticalAlignment: TextInput.AlignVCenter
      echoMode: TextInput.Password
      font.family: root.fontFamily
      font.pixelSize: 24
      font.letterSpacing: 5
      passwordCharacter: "•"
      color: "transparent"
      selectionColor: "transparent"
      selectedTextColor: "transparent"
      cursorDelegate: Item {}

      onTextChanged: {
        root.loginFailed = false
      }

      Keys.onPressed: function (event) {
        field.keyPressed(event)
      }
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: 40

    ThemeImage {
      id: logo
      assetName: "logo.png"
      width: Math.min(sourceSize.width, root.width * 0.8)
      height: sourceSize.width > 0 ? Math.round(width * sourceSize.height / sourceSize.width) : 0
      fillMode: Image.PreserveAspectFit
      anchors.horizontalCenter: parent.horizontalCenter
    }

    Row {
      id: passwordRow
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 15

      ThemeImage {
        assetName: root.loginFailed ? "lock-failed.png" : "lock.png"
        width: 34
        height: 38
        fillMode: Image.PreserveAspectFit
        anchors.verticalCenter: parent.verticalCenter
      }

      SecretField {
        id: password

        onKeyPressed: function (event) {
          if (root.handleCommonKey(event))
            return
          if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.pending === "" && !root.awaiting)
              root.login()
            else if (root.autoAttempt)
              root.loginQueued = true
            event.accepted = true
          }
        }
      }
    }
  }

  // Clicks here leave the keyboard focus in the text field.
  component PowerLink: Item {
    id: link
    property string text
    signal clicked()
    width: linkLabel.implicitWidth
    height: linkLabel.implicitHeight

    Text {
      id: linkLabel
      text: link.text
      color: root.textColor
      opacity: linkMouse.containsMouse ? 1.0 : 0.55
      font.family: root.fontFamily
      font.pixelSize: 16
    }

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }
  }

  // A question nobody answered doesn't wait for the next Enter.
  Timer {
    id: powerTimeout
    interval: 10000
    onTriggered: root.pendingPower = null
  }

  Row {
    visible: root.pendingPower === null
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 24
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: 32

    Repeater {
      model: root.powerActions

      delegate: PowerLink {
        required property var modelData
        text: modelData.icon + " " + Strings.t(root.localeName, modelData.label) + " [F" + modelData.fkey + "]"
        onClicked: root.requestPower(modelData)
      }
    }
  }

  Row {
    visible: root.pendingPower !== null
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 24
    anchors.horizontalCenter: parent.horizontalCenter
    spacing: 32

    Text {
      text: root.pendingPower !== null
            ? root.pendingPower.icon + " " + Strings.t(root.localeName, root.pendingPower.confirm) : ""
      color: root.textColor
      font.family: root.fontFamily
      font.pixelSize: 16
    }

    PowerLink {
      text: Strings.t(root.localeName, "confirm") + " [Enter]"
      onClicked: root.runPower(root.pendingPower)
    }

    PowerLink {
      text: Strings.t(root.localeName, "cancel") + " [Esc]"
      onClicked: root.pendingPower = null
    }
  }

  // Going to another console and back takes the keyboard away, and Qt drops the
  // field's focus with it. Nothing gives it back when the keyboard returns, so typing
  // and the F keys went nowhere until the field was clicked.
  function restorePasswordFocus() {
    if (!password.input.activeFocus) password.input.forceActiveFocus()
  }
  Window.onActiveFocusItemChanged: Qt.callLater(restorePasswordFocus)

  Component.onCompleted: {
    password.input.forceActiveFocus()
    tryAutoLogin()
  }
}
