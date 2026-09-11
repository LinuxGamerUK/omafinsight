import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "com.github.linuxgameruk.finsightbar"

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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    var v = deck.expectedToday
    if (deck.barShows === "month-end") v = deck.monthEnd
    else if (deck.barShows === "year-end") v = deck.yearEnd
    else if (deck.barShows === "none") return ""
    if (v !== v) return ""
    return deck.fmtMoneyNoDp(v)
  }

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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText !== "" ? ("\ue933 " + root.barText) : "\ue933"
    fontSize: root.barText !== "" ? Style.font.bodySmall : Style.bar.iconFont
    horizontalMargin: root.barText !== "" ? 8.5 : 0
    tooltipText: {
      if (!deck.authed) return "FinSightBar \u00b7 Not signed in"
      if (deck.busy) return "FinSightBar \u00b7 Refreshing\u2026"
      if (!deck.anyData) return "FinSightBar \u00b7 No data"
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
}