pragma ComponentBehavior: Bound

import QtQuick 2.15
import SddmComponents 2.0
import "UserList.js" as UserList
import "Strings.js" as Strings
import "Password.js" as Password

// Omarchy's greeter (upstream/sddm/omarchy/Main.qml) with a user list: every
// account SDDM lists, by full name, plus an optional "Other user…" row that
// reveals a username field. The password row is the stock one, asked twice
// for an account that chooses its password at this login (Password.js).
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
  readonly property bool allowOther: String(config.allowOtherUser || "true") !== "false"
  readonly property bool showUsername: String(config.showUsername || "true") !== "false"
  readonly property int maxVisibleUsers: Math.max(1, parseInt(config.maxVisibleUsers || "6") || 6)
  readonly property string localeName: Qt.locale().name
  readonly property string fontFamily: "JetBrainsMono Nerd Font"

  // Filled from userModel by the Repeater below.
  property var userSlots: ({})
  property var users: []
  readonly property var entries: UserList.buildEntries(users, allowOther, showUsername)
  property int selectedIndex: 0
  // Set once someone moves the selection, so late model rows don't reset it.
  property bool selectionTouched: false
  readonly property var selected: entries.length > 0 ? entries[Math.min(selectedIndex, entries.length - 1)] : null
  readonly property bool otherSelected: selected !== null && selected.other === true

  property bool loginFailed: false
  // Accounts with an empty, expired password, from omarchy-mu-sddm-sync,
  // plus any PAM reports as one; for them the password box takes the new
  // password and a second box confirms it.
  property var changeUsers: Password.parseUsers(config.passwordChangeUsers)
  readonly property string loginName: UserList.loginUser(selected, otherUser.text)
  readonly property bool changeMode: Password.needsChange(changeUsers, loginName)
  // PAM's "change your password" notice comes with a login failure from
  // SDDM while the change goes on: that one failure is skipped.
  property bool changeNoticeSeen: false
  property string lastPamMessage: ""
  // Shown under the boxes: what is wrong with the new password.
  property string message: ""
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

  function addUser(index, name, realName) {
    userSlots[index] = { name: name, realName: realName }
    var list = []
    var keys = Object.keys(userSlots).map(Number).sort(function (a, b) { return a - b })
    for (var i = 0; i < keys.length; i++)
      list.push(userSlots[keys[i]])
    users = list
    if (!selectionTouched)
      selectedIndex = UserList.initialIndex(entries, userModel.lastUser)
    Qt.callLater(focusInput)
  }

  function select(index) {
    selectionTouched = true
    selectedIndex = Math.max(0, Math.min(index, entries.length - 1))
    password.input.text = ""
    confirm.input.text = ""
    loginFailed = false
    message = ""
    focusInput()
  }

  function moveSelection(delta) {
    select(UserList.step(selectedIndex, delta, entries.length))
  }

  // The username field when "Other user…" is selected and still empty,
  // otherwise the password.
  function focusInput() {
    if (otherSelected && otherUser.text.trim().length === 0)
      otherUser.forceActiveFocus()
    else
      password.input.forceActiveFocus()
  }

  function login() {
    var user = loginName
    if (user.length === 0) {
      otherUser.forceActiveFocus()
      return
    }
    if (changeMode) {
      var problem = Password.check(password.input.text, confirm.input.text)
      if (problem !== "") {
        // Clearing a box clears the message, so that goes first.
        confirm.input.text = ""
        message = Strings.t(localeName, problem === "empty" ? "emptyPassword" : "mismatch")
        if (problem === "empty")
          password.input.forceActiveFocus()
        else
          confirm.input.forceActiveFocus()
        return
      }
    }
    message = ""
    lastPamMessage = ""
    changeNoticeSeen = false
    sddm.login(user, password.input.text, root.sessionIndex)
  }

  // Shared by both text fields: list navigation and Escape.
  function handleCommonKey(event) {
    if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Escape) {
      password.input.text = ""
      confirm.input.text = ""
    } else {
      return false
    }
    event.accepted = true
    return true
  }

  Connections {
    target: sddm
    function onInformationMessage(text) {
      root.lastPamMessage = text
      if (Password.isChangeNotice(text)) {
        root.changeNoticeSeen = true
        root.changeUsers = Password.withUser(root.changeUsers, root.loginName)
      }
    }
    function onLoginFailed() {
      if (root.changeNoticeSeen) {
        root.changeNoticeSeen = false
        return
      }
      root.loginFailed = true
      password.input.text = ""
      confirm.input.text = ""
      if (root.changeMode)
        root.message = root.lastPamMessage || Strings.t(root.localeName, "changeFailed")
      password.input.forceActiveFocus()
    }
    function onLoginSucceeded() {
      root.loginFailed = false
    }
  }

  // userModel's roles (name, realName) are only reachable by name from a
  // delegate, so each delegate reports its row to root.users.
  Repeater {
    model: userModel
    delegate: Item {
      required property int index
      required property string name
      required property string realName
      Component.onCompleted: root.addUser(index, name, realName)
    }
  }

  // An image from the stock theme (recolored by Style > Unlock), or the
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
  // text itself is transparent), and a hint while it is empty.
  component SecretField: Item {
    id: field
    property alias input: secret
    property string placeholder: ""
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

    Text {
      text: field.placeholder
      visible: secret.text.length === 0 && text.length > 0
      color: root.textColor
      opacity: 0.4
      font.family: root.fontFamily
      font.pixelSize: 22
      anchors.left: parent.left
      anchors.leftMargin: 20
      anchors.verticalCenter: parent.verticalCenter
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
        root.message = ""
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

    Column {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: 15

      ListView {
        id: userList
        readonly property int rowHeight: root.showUsername ? 52 : 36
        width: password.width
        height: Math.min(count, root.maxVisibleUsers) * rowHeight
        anchors.right: passwordRow.right
        clip: true
        interactive: count > root.maxVisibleUsers
        model: root.entries
        currentIndex: root.selectedIndex
        highlightMoveDuration: 0
        visible: count > 0

        delegate: Item {
          id: row
          required property int index
          required property var modelData
          readonly property bool current: index === root.selectedIndex
          width: userList.width
          height: userList.rowHeight

          Text {
            id: marker
            text: "›"
            color: root.textColor
            visible: row.current
            font.family: root.fontFamily
            font.pixelSize: 22
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: label.verticalCenter
          }

          Text {
            id: label
            text: row.modelData.other ? Strings.t(root.localeName, "otherUser") : row.modelData.label
            color: root.textColor
            opacity: row.current ? 1.0 : 0.55
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: 22
            anchors.left: parent.left
            anchors.leftMargin: 24
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 4
          }

          Text {
            text: row.modelData.secondary
            visible: text.length > 0
            color: root.textColor
            opacity: row.current ? 0.6 : 0.35
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: 14
            anchors.left: label.left
            anchors.right: parent.right
            anchors.top: label.bottom
            anchors.topMargin: 2
          }

          MouseArea {
            anchors.fill: parent
            onClicked: root.select(row.index)
          }
        }
      }

      // Username field, only while "Other user…" is selected.
      Item {
        id: otherRow
        visible: root.otherSelected
        width: passwordRow.width
        height: visible ? otherEntry.height : 0

        ThemeImage {
          id: otherEntry
          assetName: root.loginFailed ? "entry-failed.png" : "entry.png"
          anchors.right: parent.right
        }

        TextInput {
          id: otherUser
          anchors.fill: otherEntry
          anchors.leftMargin: 20
          anchors.rightMargin: 20
          verticalAlignment: TextInput.AlignVCenter
          clip: true
          color: root.textColor
          selectionColor: root.textColor
          selectedTextColor: root.color
          font.family: root.fontFamily
          font.pixelSize: 22
          inputMethodHints: Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText | Qt.ImhPreferLowercase
          enabled: root.otherSelected

          onTextChanged: root.loginFailed = false

          Text {
            text: Strings.t(root.localeName, "username")
            visible: otherUser.text.length === 0
            color: root.textColor
            opacity: 0.4
            font: otherUser.font
            anchors.verticalCenter: parent.verticalCenter
          }

          Keys.onPressed: function (event) {
            if (root.handleCommonKey(event))
              return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                || event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              if (otherUser.text.trim().length > 0)
                password.forceActiveFocus()
              event.accepted = true
            }
          }
        }
      }

      Text {
        width: password.width
        anchors.right: passwordRow.right
        text: Strings.t(root.localeName, "choosePassword")
        visible: root.changeMode
        color: root.textColor
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: 18
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
          placeholder: root.changeMode ? Strings.t(root.localeName, "newPassword") : ""

          onKeyPressed: function (event) {
            if (root.handleCommonKey(event))
              return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.changeMode && password.input.text.length > 0 && confirm.input.text.length === 0)
                confirm.input.forceActiveFocus()
              else
                root.login()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab && root.changeMode) {
              confirm.input.forceActiveFocus()
              event.accepted = true
            } else if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) && root.otherSelected) {
              otherUser.forceActiveFocus()
              event.accepted = true
            }
          }
        }
      }

      // The new password again, only for an account choosing it now.
      Item {
        id: confirmRow
        visible: root.changeMode
        width: passwordRow.width
        height: visible ? confirm.height : 0

        SecretField {
          id: confirm
          anchors.right: parent.right
          placeholder: Strings.t(root.localeName, "confirmPassword")
          input.enabled: root.changeMode

          onKeyPressed: function (event) {
            if (root.handleCommonKey(event))
              return
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.login()
              event.accepted = true
            } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
              password.input.forceActiveFocus()
              event.accepted = true
            }
          }
        }
      }

      Text {
        width: password.width
        anchors.right: passwordRow.right
        text: root.message
        visible: text.length > 0
        color: root.textColor
        wrapMode: Text.WordWrap
        font.family: root.fontFamily
        font.pixelSize: 16
      }
    }
  }

  Component.onCompleted: focusInput()
}
