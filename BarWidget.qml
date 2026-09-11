import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "com.github.linuxgameruk.omafinsight"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Shape contract for shell.summon/hide/toggle routing
  // (Bar.findPanelWidget requires open/close/opened on the bar-widget root).
  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function refresh() {
    deck.refresh()
  }

  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Service {
    id: deck
    settings: root.settings
  }

  readonly property color barIconColor: {
    if (!deck.authed)
      return bar ? Qt.darker(bar.barForeground, 2.0) : Qt.darker(Color.foreground, 2.0)
    if (deck.alerting) return bar ? bar.urgent : Color.urgent
    if (deck.warning) return Color.accent
    return bar ? bar.barForeground : Color.foreground
  }

  // Bar text: the selected balance figure, comma-grouped without decimals
  // so the chip stays compact.
  readonly property string barText: {
    if (!deck.authed || !deck.anyData || deck.busy) return ""
    if (deck.hideAmounts) return deck.currencySymbol + "**.**"
    var v = deck.expectedToday
    if (deck.barShows === "month-end") v = deck.monthEnd
    else if (deck.barShows === "year-end") v = deck.yearEnd
    else if (deck.barShows === "none") return ""
    if (v !== v) return ""
    return deck.fmtMoneyNoDp(v)
  }

  // Eye glyph: closed eye when amounts hidden, open eye when visible.
  // A separate small button so the balance chip itself stays clickable.
  readonly property string eyeGlyph: deck.hideAmounts ? "\uf070" : "\uf06e"

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: 2

    WidgetButton {
      id: button
      bar: root.bar
      text: root.barText !== "" ? ("\uf0114 " + root.barText) : "\uf0114"
      fontSize: root.barText !== "" ? Style.font.bodySmall : Style.bar.iconFont
      horizontalMargin: root.barText !== "" ? 8.5 : 0
      tooltipText: {
        if (!deck.authed) return "OmaFinSight \u00b7 Not signed in"
        if (deck.busy) return "OmaFinSight \u00b7 Refreshing\u2026"
        if (!deck.anyData) return "OmaFinSight \u00b7 No data"
        if (deck.hideAmounts) return "OmaFinSight \u00b7 amounts hidden (eye to show)"
        var line = "Today " + deck.fmtMoney(deck.expectedToday)
        if (deck.monthEnd === deck.monthEnd)
          line += " \u00b7 Month-end " + deck.fmtMoney(deck.monthEnd)
        if (deck.alerting || deck.warning)
          line += " \u00b7 low balance"
        return line
      }

      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton) root.toggle()
        else if (buttonCode === Qt.RightButton) deck.refresh()
      }
    }

    WidgetButton {
      id: eyeButton
      visible: deck.authed && deck.anyData
      bar: root.bar
      text: deck.hideAmounts ? "\uf070" : "\uf06e"
      fontSize: Style.font.bodySmall
      horizontalMargin: 6
      tooltipText: deck.hideAmounts ? "Show amounts" : "Hide amounts (streaming-safe)"
      onPressed: function(buttonCode) {
        if (buttonCode === Qt.LeftButton) deck.toggleHidden()
      }
    }
  }
}