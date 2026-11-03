pragma ComponentBehavior: Bound

import QtQuick 2.15
import SddmComponents 2.0
import "UserList.js" as UserList
import "Strings.js" as Strings
import "Password.js" as Password
import "Power.js" as Power

// Omarchy's greeter (upstream/sddm/omarchy/Main.qml) with a user list: every
// account SDDM lists, by full name, plus an optional "Other user…" row that
// reveals a username field. The password row is the stock one, asked twice
// for an account that chooses its password at this login (Password.js). What
// that account also needs hangs below the password row, so the logo and the
// boxes stay put between users. The power actions SDDM offers sit at the
// bottom, by click or F key (Power.js).
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
    pendingPower = null
    focusInput()
  }

  function moveSelection(delta) {
    select(UserList.step(selectedIndex, delta, entries.length))
  }

  // The wheel stops at the ends, where it must not clear the password either.
  function scrollSelection(delta) {
    var next = UserList.clampedStep(selectedIndex, delta, entries.length)
    if (next !== selectedIndex)
      select(next)
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
    confirm.input.text = ""
    sddm[action.id]()
  }

  // Shared by the text fields: list navigation, Escape and the power keys.
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
    if (event.key === Qt.Key_Up) {
      moveSelection(-1)
    } else if (event.key === Qt.Key_Down) {
      moveSelection(1)
    } else if (event.key === Qt.Key_Escape) {
      password.input.text = ""
      confirm.input.text = ""
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
    // Centered, or higher when what hangs below the password row wouldn't
    // clear the power actions. Counted for every user, so it never moves.
    readonly property real centeredY: (root.height - height) / 2
    readonly property real clearY: root.height - height - belowPassword.reservedHeight - 64
    anchors.horizontalCenter: parent.horizontalCenter
    y: Math.round(Math.max(0, Math.min(centeredY, clearY)))
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
        boundsBehavior: Flickable.StopAtBounds
        snapMode: ListView.SnapToItem
        model: root.entries
        currentIndex: root.selectedIndex
        // A row stays visible on each side of the selected one, when it fits.
        readonly property int contextHeight: root.maxVisibleUsers >= 3 ? rowHeight : 0
        highlightRangeMode: ListView.ApplyRange
        preferredHighlightBegin: contextHeight
        preferredHighlightEnd: height - contextHeight
        // Slides once someone moves; the last user starts in place.
        highlightMoveVelocity: -1
        highlightMoveDuration: root.selectionTouched ? 150 : 0
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
            anchors.topMargin: 2
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

      // Over the list, so the wheel selects instead of scrolling past the
      // selection. Clicks and drags go through to the rows below.
      MouseArea {
        property real pending: 0
        parent: userList
        anchors.fill: parent
        z: 1
        acceptedButtons: Qt.NoButton
        onWheel: function (event) {
          pending += event.angleDelta.y
          var notches = pending > 0 ? Math.floor(pending / 120) : Math.ceil(pending / 120)
          if (notches !== 0) {
            pending -= notches * 120
            root.scrollSelection(-notches)
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
                password.input.forceActiveFocus()
              event.accepted = true
            }
          }
        }
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

      // Hangs from this row, so none of it moves what is above. One pixel tall:
      // a Column skips an item with no height, and what is inside it.
      Item {
        width: passwordRow.width
        height: 1

        Column {
          id: belowPassword
          // The box and the notice, plus a line for a message. Not its height,
          // which changes with the user.
          readonly property real reservedHeight: confirm.height + notice.height + 24 + 2 * spacing
          width: password.width
          anchors.right: parent.right
          spacing: 15

          // The new password again, only for an account choosing it now.
          SecretField {
            id: confirm
            visible: root.changeMode
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

          Text {
            id: notice
            width: parent.width
            text: Strings.t(root.localeName, "choosePassword")
            visible: root.changeMode
            color: root.textColor
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: 18
          }

          Text {
            width: parent.width
            text: root.message
            visible: text.length > 0
            color: root.textColor
            wrapMode: Text.WordWrap
            font.family: root.fontFamily
            font.pixelSize: 16
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

  Component.onCompleted: focusInput()
}
