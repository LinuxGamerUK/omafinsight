import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "com.github.linuxgameruk.omafinsight"
  ipcTarget: "com.github.linuxgameruk.omafinsight"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)

  property bool cursorActive: false

  // Rebound whenever deck values change (a plain array literal in a
  // Repeater would bind once and never refresh).
  readonly property var forecastRows: [
    { label: "END OF MONTH", value: deck.monthEnd },
    { label: "END OF YEAR", value: deck.yearEnd },
    { label: "IN 7 DAYS", value: deck.next7 },
    { label: "IN 30 DAYS", value: deck.next30 }
  ]

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  Service {
    id: deck
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { deck.refresh(); return "ok" }
    function openweb(): string {
      Qt.openUrlExternally(deck.baseUrl)
      return "ok"
    }
    function openapp(): string { deck.openApp(); return "ok" }
    function eyetoggle(): string { deck.toggleHidden(); return deck.hideAmounts ? "hidden" : "visible" }
  }

  function balanceColor(v) {
    if (v !== v) return root.foreground
    if (v < deck.criticalBalance) return root.urgent
    if (v < deck.warnBalance) return Color.accent
    return root.foreground
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(40), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: deck.refresh()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") deck.refresh()
        else if (t === "o" || t === "O") Qt.openUrlExternally(deck.baseUrl)
        else if (t === "a" || t === "A") { root.close(); deck.openApp() }
        else if (t === "h" || t === "H") deck.toggleHidden()
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        // ── Hero ────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(heroCol.implicitHeight, Style.space(40))

          Image {
            id: heroIcon
            source: Qt.resolvedUrl("assets/logo.png")
            sourceSize: Qt.size(34, 34)
            width: 34; height: 34
            fillMode: Image.PreserveAspectFit
            mipmap: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroCol
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: headerButtons.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: "OmaFinSight"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              textFormat: Text.PlainText
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: {
                if (deck.busy) return "REFRESHING\u2026"
                if (deck.authed) {
                  var scope = deck.scope === "all" ? "ALL ACCOUNTS" : "PRIMARY ACCOUNT"
                  return scope + (deck.lastRefreshText !== "" ? " \u00b7 updated " + deck.lastRefreshText : "")
                }
                return "BALANCE FORECAST"
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerButtons
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            CursorSurface {
              id: appButton
              foreground: root.foreground
              implicitWidth: Math.max(appLabel.implicitWidth, Style.space(56))
              implicitHeight: Math.max(appLabel.implicitHeight, Style.space(28))

              Text {
                id: appLabel
                anchors.centerIn: parent
                text: "Open Oma-App"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.close()
                  deck.openApp()
                }
              }
            }

            CursorSurface {
              id: openButton
              foreground: root.foreground
              implicitWidth: Math.max(openLabel.implicitWidth, Style.space(56))
              implicitHeight: Math.max(openLabel.implicitHeight, Style.space(28))

              Text {
                id: openLabel
                anchors.centerIn: parent
                text: "Open web"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                textFormat: Text.PlainText
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Qt.openUrlExternally(deck.baseUrl)
              }
            }
          }
        }

        // ── Error ───────────────────────────────────────────────────
        Text {
          visible: deck.lastError !== ""
          width: parent.width
          text: deck.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }

        // ── Login form (not signed in) ──────────────────────────────
        Column {
          visible: !deck.authed
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: "Sign in to your FinSight instance once — the session is stored in ~/.local/state/omafinsight (0600) and your password is never saved."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }

          TextField {
            id: emailField
            width: parent.width
            placeholderText: "Email address"
            enabled: !deck.busy
            font.family: root.fontFamily
            onAccepted: passwordField.forceActiveFocus()
          }

          TextField {
            id: passwordField
            width: parent.width
            placeholderText: "Password"
            echoMode: TextInput.Password
            enabled: !deck.busy
            font.family: root.fontFamily
            onAccepted: loginButton.clicked()
          }

          Button {
            id: loginButton
            width: parent.width
            text: deck.busy ? "Signing in\u2026" : "Sign in"
            enabled: !deck.busy && emailField.text.trim() !== "" && passwordField.text !== ""
            onClicked: deck.login(emailField.text.trim(), passwordField.text)
          }

          Text {
            width: parent.width
            text: "Base URL (settings): " + deck.baseUrl
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
          }
        }

        // ── Privacy eye (signed in) ─────────────────────────────────
        CursorSurface {
          visible: deck.authed && deck.anyData
          width: parent.width
          implicitHeight: Math.max(privacyLabel.implicitHeight, Style.space(30))
          foreground: root.foreground

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Text {
              id: privacyIcon
              text: deck.hideAmounts ? "\uf070" : "\uf06e"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }

            Text {
              id: privacyLabel
              text: deck.hideAmounts ? "Amounts hidden — click to show" : "Amounts visible — click to hide"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: deck.toggleHidden()
          }
        }

        // ── Forecast cards (signed in) ──────────────────────────────
        Column {
          visible: deck.authed && deck.anyData
          width: parent.width
          spacing: Style.space(10)

          // Today (hero row)
          Column {
            width: parent.width
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: "EXPECTED TODAY"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              textFormat: Text.PlainText
            }

            Text {
              width: parent.width
              text: deck.hideAmounts ? deck.currencySymbol + "**.**" : deck.fmtMoney(deck.expectedToday)
              color: root.balanceColor(deck.expectedToday)
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              font.bold: true
              textFormat: Text.PlainText
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Month / year rows
          Repeater {
            model: root.forecastRows

            // recomputed whenever deck values change
          

            RowLayout {
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }

              Text {
                text: deck.hideAmounts ? deck.currencySymbol + "**.**" : deck.fmtMoney(modelData.value)
                color: root.balanceColor(modelData.value)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                textFormat: Text.PlainText
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Monthly income vs expenses
          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              text: "TYPICAL MONTH"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Text {
              text: deck.hideAmounts ? "+" + deck.currencySymbol + "**.** / -" + deck.currencySymbol + "**.**" : "+" + deck.fmtMoney(deck.monthlyIncome) + " / -" + deck.fmtMoney(deck.monthlyExpenses)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
              Layout.alignment: Qt.AlignVCenter
            }
          }
        }

        // ── Accounts (signed in) ────────────────────────────────────
        Column {
          visible: deck.authed && deck.accounts.length > 0
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            text: "ACCOUNTS"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }

          Repeater {
            model: deck.accounts

            RowLayout {
              required property int index
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                Layout.fillWidth: true
                text: modelData.name + (modelData.isPrimary ? "  \u00b7 primary" : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }

              Text {
                text: deck.hideAmounts ? deck.currencySymbol + "**.**" : (modelData.balanceNow === modelData.balanceNow ? deck.fmtMoney(modelData.balanceNow) : "\u2014")
                color: root.balanceColor(modelData.balanceNow)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                textFormat: Text.PlainText
                Layout.alignment: Qt.AlignVCenter
              }
            }
          }
        }

        // ── Footer (signed in) ──────────────────────────────────────
        Text {
          visible: deck.authed
          width: parent.width
          text: {
            if (deck.busy) return "Refreshing\u2026"
            var t = deck.lastRefreshText === "" ? "" : "Updated " + deck.lastRefreshText + " \u00b7 "
            return t + "refresh every " + deck.refreshIntervalSec + "s \u00b7 R refresh \u00b7 H hide \u00b7 A Oma-App \u00b7 O web"
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
}