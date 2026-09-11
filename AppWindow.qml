// OmaFinSight desktop app — native window with the full FinSight picture:
// forecast chart, in/out bars, forecast rows, per-account balances and a
// month calendar strip. Reads exclusively from the user's FinSight instance
// using the same 0600 session store as the bar widget.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

ApplicationWindow {
  id: appWindow

  readonly property string baseUrl: {
    var u = String(Quickshell.env("OMAFIN_URL") || "").trim()
    if (u === "") return "https://finsight.cresta.digital"
    if (u.indexOf("http") !== 0) u = "https://" + u
    while (u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    return u
  }
  readonly property string sessionFile: sessionSvc.sessionPath()

  Service {
    id: sessionSvc
  }

  property var dash: null           // parsed /api/dashboard payload
  property var series: []           // [{date, balance, in, out}]
  property bool busy: false
  property string lastError: ""
  property string scope: "primary"  // "primary" | "all"
  property int chartDays: 30
  property string currencySymbol: "£"
  readonly property color fg: "#f4dbfa"
  readonly property color dim: "#a5adcb"
  readonly property color accent: "#8caaee"
  readonly property color card: "#1a1f33"
  readonly property color border: "#414559"
  readonly property color red: "#ee99a0"
  readonly property color orange: "#f5a97f"
  readonly property color green: "#a6da95"

  title: "OmaFinSight"
  color: "#11131c"
  width: 1100
  height: 720
  visible: true
  readonly property string fontFamily: "JetBrainsMono Nerd Font Propo"

  onClosing: Qt.quit()

  Component.onCompleted: refresh()

  // ── helpers ──────────────────────────────────────────────────────────
  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function _group(intPart) {
    var s = String(intPart)
    var out = ""
    var count = 0
    for (var i = s.length - 1; i >= 0; i--) {
      out = s.charAt(i) + out
      count++
      if (count % 3 === 0 && i > 0) out = "," + out
    }
    return out
  }

  function fmtMoney(n, dp) {
    if (n === null || n === undefined || n !== n) return "—"
    if (dp === undefined) dp = 2
    var neg = n < 0
    var fixed = Math.abs(n).toFixed(dp)
    var parts = fixed.split(".")
    return (neg ? "-" : "") + currencySymbol + _group(parts[0]) + (dp > 0 ? "." + parts[1] : "")
  }

  function fmtDateUK(iso) {
    var p = String(iso || "").split("-")
    return p.length === 3 ? p[2] + "/" + p[1] + "/" + p[0] : iso
  }

  function scopeParam() {
    return scope === "primary" ? "" : "?account=" + scope
  }

  // ── data loading (hardened: timeout + capped) ───────────────────────
  function refresh() {
    if (busy) return
    busy = true
    lastError = ""
    _outstanding = 2
    dashProc.url = baseUrl + "/api/dashboard" + scopeParam()
    chartProc.url = baseUrl + "/api/chart?days=" + chartDays + "&back=30" + (scope === "primary" ? "" : "&account=" + scope)
    dashProc.running = true
    chartProc.running = true
    dashWatchdog.restart()
    chartWatchdog.restart()
  }

  property int _outstanding: 0
  function _finish(ok, errMsg) {
    _outstanding = _outstanding - 1
    if (_outstanding <= 0) {
      _outstanding = 0
      busy = false
      if (!ok && lastError === "" && errMsg) lastError = errMsg
    }
  }

  function valueColor(v) {
    if (v !== v) return appWindow.dim
    if (v < 200) return appWindow.red
    if (v < 500) return appWindow.orange
    return appWindow.fg
  }

  function applyDashboard(raw) {
    try {
      var d = JSON.parse(raw)
      if (d.onboarded === false) {
        lastError = "Finish setup in the FinSight web app first"
        return
      }
      if (d.needsAccount === true) {
        lastError = "Account migration pending — open the web app once"
        return
      }
      dash = d
      var u = d.user || {}
      if (u.currency) {
        var c = String(u.currency)
        currencySymbol = (c === "USD") ? "$" : (c === "EUR") ? "€" : (c === "JPY" || c === "CNY") ? "¥"
          : (c === "INR") ? "₹" : (c === "AUD") ? "A$" : (c === "CAD") ? "C$" : (c === "CHF") ? "Fr"
          : (c === "BRL") ? "R$" : "£"
      }
    } catch (e) {
      lastError = "Unexpected response (not JSON)"
    }
  }

  function applyChart(raw) {
    try {
      var d = JSON.parse(raw)
      var s = []
      var arr = d.series || []
      for (var i = 0; i < arr.length && i < 500; i++) {
        var p = arr[i]
        s.push({
          date: String(p.date || ""),
          balance: typeof p.balance === "number" ? p.balance : NaN,
          in: typeof p.in === "number" ? p.in : 0,
          out: typeof p.out === "number" ? p.out : 0
        })
      }
      series = s
    } catch (e) { /* keep old series */ }
  }

  Process {
    id: dashProc
    running: false
    property string url: ""
    property string buffer: ""
    command: ["timeout", "-k", "2", "12", "bash", "-c",
      "set -o pipefail; curl -sS -b '" + appWindow.sessionFile + "' " +
      "--connect-timeout 5 --max-time 10 '" + dashProc.url + "' 2>&1 | head -c 400000"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (dashProc.buffer.length + s.length <= 400000) dashProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      dashWatchdog.stop()
      dashProc.running = false
      var buf = dashProc.buffer
      dashProc.buffer = ""
      if (exitCode === 0 && buf.trim().indexOf("{") >= 0) {
        appWindow.applyDashboard(buf.substring(buf.indexOf("{")))
        appWindow._finish(true, "")
      } else {
        appWindow._finish(false, exitCode === 124 ? "Timed out" : "Dashboard fetch failed (exit " + exitCode + ")")
      }
    }
  }

  Timer {
    id: dashWatchdog
    interval: 18000
    onTriggered: {
      if (dashProc.running) dashProc.running = false
      appWindow._finish(false, "Dashboard fetch timed out")
    }
  }

  Process {
    id: chartProc
    running: false
    property string url: ""
    property string buffer: ""
    command: ["timeout", "-k", "2", "12", "bash", "-c",
      "set -o pipefail; curl -sS -b '" + appWindow.sessionFile + "' " +
      "--connect-timeout 5 --max-time 10 '" + chartProc.url + "' 2>&1 | head -c 400000"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (chartProc.buffer.length + s.length <= 400000) chartProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      chartWatchdog.stop()
      chartProc.running = false
      var buf = chartProc.buffer
      chartProc.buffer = ""
      if (exitCode === 0 && buf.trim().indexOf("{") >= 0) {
        appWindow.applyChart(buf.substring(buf.indexOf("{")))
        appWindow._finish(true, "")
      } else {
        appWindow._finish(false, exitCode === 124 ? "Timed out" : "Chart fetch failed (exit " + exitCode + ")")
      }
    }
  }

  Timer {
    id: chartWatchdog
    interval: 18000
    onTriggered: {
      if (chartProc.running) chartProc.running = false
      appWindow._finish(false, "Chart fetch timed out")
    }
  }

  // ── layout ──────────────────────────────────────────────────────────
  Column {
    anchors.fill: parent
    anchors.margins: 16
    spacing: 12

    // header
    Item {
      width: parent.width
      height: 44

      Row {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        Text {
          text: "\ue933"
          color: "#8caaee"
          font.family: appWindow.fontFamily
          font.pixelSize: 24
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: "OmaFinSight"
          color: "#f4dbfa"
          font.family: appWindow.fontFamily
          font.pixelSize: 20
          font.bold: true
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          text: {
            if (!appWindow.dash) return ""
            var s = appWindow.dash.scope
            if (s === "all") return "\u00b7 all accounts"
            var prim = null
            var arr = appWindow.dash.accounts || []
            for (var i = 0; i < arr.length; i++) {
              if (arr[i] && arr[i].isPrimary === true) { prim = arr[i]; break }
            }
            return "\u00b7 " + sanitize((prim && prim.name) || "primary")
          }
          color: "#f4dbfa"
          opacity: 0.5
          font.family: appWindow.fontFamily
          font.pixelSize: 13
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        ComboBox {
          id: scopeBox
          width: 180
          model: ["Primary account", "All accounts"]
          onActivated: function(idx) {
            var s = idx === 0 ? "primary" : "all"
            if (s !== appWindow.scope) {
              appWindow.scope = s
              appWindow.refresh()
            }
          }
          currentIndex: appWindow.scope === "all" ? 1 : 0
        }

        ComboBox {
          id: rangeBox
          width: 150
          model: ["Next 30 days", "Next 90 days", "Next 12 months"]
          onActivated: function(idx) {
            appWindow.chartDays = [30, 90, 365][idx]
            appWindow.refresh()
          }
        }

        Button {
          text: appWindow.busy ? "…" : "Refresh"
          onClicked: appWindow.refresh()
        }

        Button {
          text: "Open web"
          onClicked: Qt.openUrlExternally(appWindow.baseUrl)
        }
      }
    }

    Text {
      visible: appWindow.lastError !== ""
      text: appWindow.lastError
      color: "#ee99a0"
      font.family: appWindow.fontFamily
      font.pixelSize: 13
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      width: parent.width
    }

    // summary strip
    Row {
      width: parent.width
      spacing: 12
      visible: appWindow.dash !== null

      Repeater {
        model: appWindow.dash ? [
          { label: "EXPECTED TODAY", value: appWindow.dash.summary.expectedToday, hero: true },
          { label: "END OF MONTH", value: appWindow.dash.summary.monthEnd },
          { label: "END OF YEAR", value: appWindow.dash.summary.yearEnd },
          { label: "IN 30 DAYS", value: appWindow.dash.summary.next30 }
        ] : []

        Rectangle {
          required property var modelData
          width: (parent.width - 36) / 4
          height: 74
          radius: 10
          color: modelData.hero ? "#232a45" : "#1a1f33"
          border.color: modelData.hero ? "#8caaee" : "#414559"

          Column {
            anchors.fill: parent
            anchors.margins: 12
            spacing: 4

            Text {
              text: modelData.label
              color: "#a5adcb"
              font.family: appWindow.fontFamily
              font.pixelSize: 10
              font.letterSpacing: 1.2
              font.bold: true
              textFormat: Text.PlainText
            }
            Text {
              text: appWindow.fmtMoney(modelData.value)
              color: appWindow.valueColor(modelData.value)
              font.family: appWindow.fontFamily
              font.pixelSize: modelData.hero ? 24 : 19
              font.bold: true
              textFormat: Text.PlainText
            }
          }
        }
      }
    }

    // balance chart
    Rectangle {
      width: parent.width
      height: 250
      radius: 12
      color: "#1a1f33"
      border.color: "#414559"

      Column {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 6

        Text {
          text: "BALANCE FORECAST (" + appWindow.chartDays + " DAYS)"
          color: "#a5adcb"
          font.family: appWindow.fontFamily
          font.pixelSize: 11
          font.bold: true
          font.letterSpacing: 1.2
          textFormat: Text.PlainText
        }

        ChartCanvas {
          id: balanceChart
          width: parent.width
          height: parent.height - 30
          series: appWindow.series
          mode: "balance"
          symbol: appWindow.currencySymbol
        }
      }
    }

    // in/out chart
    Rectangle {
      width: parent.width
      height: 170
      radius: 12
      color: "#1a1f33"
      border.color: "#414559"

      Column {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 6

        Text {
          text: "MONEY IN VS OUT (LAST 30 DAYS + FORECAST)"
          color: "#a5adcb"
          font.family: appWindow.fontFamily
          font.pixelSize: 11
          font.bold: true
          font.letterSpacing: 1.2
          textFormat: Text.PlainText
        }

        ChartCanvas {
          width: parent.width
          height: parent.height - 30
          series: appWindow.series
          mode: "inout"
          symbol: appWindow.currencySymbol
        }
      }
    }

    // accounts + upcoming
    Row {
      width: parent.width
      spacing: 12

      // accounts
      Rectangle {
        width: (parent.width - 12) / 2
        height: 190
        radius: 12
        color: "#1a1f33"
        border.color: "#414559"

        Column {
          anchors.fill: parent
          anchors.margins: 14
          spacing: 8

          Text {
            text: "ACCOUNTS"
            color: "#a5adcb"
            font.family: appWindow.fontFamily
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }

          Repeater {
            model: appWindow.dash ? (appWindow.dash.accounts || []) : []

            Row {
              required property var modelData
              width: parent.width
              spacing: 8

              Text {
                width: parent.width - 130
                text: modelData.name + (modelData.isPrimary ? "  \u00b7 primary" : "")
                color: "#f4dbfa"
                font.family: appWindow.fontFamily
                font.pixelSize: 13
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                text: appWindow.fmtMoney(modelData.balanceNow)
                color: {
                  var v = modelData.balanceNow
                  if (v !== v) return appWindow.dim
                  if (v < 0) return appWindow.red
                  if (v < 500) return appWindow.orange
                  return appWindow.fg
                }
                font.family: appWindow.fontFamily
                font.pixelSize: 13
                font.bold: true
                textFormat: Text.PlainText
              }
            }
          }
        }
      }

      // upcoming
      Rectangle {
        width: (parent.width - 12) / 2
        height: 190
        radius: 12
        color: "#1a1f33"
        border.color: "#414559"

        Column {
          anchors.fill: parent
          anchors.margins: 14
          spacing: 6

          Text {
            text: "UPCOMING (NEXT 6)"
            color: "#a5adcb"
            font.family: appWindow.fontFamily
            font.pixelSize: 11
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }

          Repeater {
            model: appWindow.dash ? (appWindow.dash.upcoming || []).slice(0, 6) : []

            Row {
              required property var modelData
              width: parent.width
              spacing: 8

              Text {
                width: 70
                text: appWindow.fmtDateUK(modelData.date)
                color: "#a5adcb"
                font.family: appWindow.fontFamily
                font.pixelSize: 12
                textFormat: Text.PlainText
              }

              Text {
                width: parent.width - 70 - 90 - 16
                text: sanitize(modelData.label)
                color: "#f4dbfa"
                font.family: appWindow.fontFamily
                font.pixelSize: 12
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }

              Text {
                width: 90
                text: (modelData.amount >= 0 ? "+" : "-") + appWindow.currencySymbol + Math.abs(modelData.amount).toFixed(2)
                color: modelData.amount >= 0 ? "#a6da95" : "#ee99a0"
                font.family: appWindow.fontFamily
                font.pixelSize: 12
                font.bold: true
                textFormat: Text.PlainText
              }
            }
          }
        }
      }
    }
  }

  // ── chart painter (Canvas, pure QML) ────────────────────────────────
  component ChartCanvas: Canvas {
    id: canvas
    property var series: []
    property string mode: "balance"
    property string symbol: "£"
    property real padL: 56
    property real padR: 8
    property real padT: 8
    property real padB: 18

    onSeriesChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var pts = []
      for (var i = 0; i < series.length; i++) {
        if (mode === "balance" && series[i].balance === series[i].balance) pts.push(series[i])
      }
      if (mode === "balance" && pts.length < 2) return

      var W = width - padL - padR
      var H = height - padT - padB

      if (mode === "balance") {
        var min = 0, max = -Infinity
        for (var j = 0; j < pts.length; j++) {
          if (pts[j].balance < min) min = pts[j].balance
          if (pts[j].balance > max) max = pts[j].balance
        }
        if (max === min) max = min + 1
        var pad = (max - min) * 0.08
        max += pad

        var x = function(i) { return padL + (i / (pts.length - 1)) * W }
        var y = function(v) { return padT + (1 - (v - min) / (max - min)) * H }

        // grid
        ctx.strokeStyle = "#414559"
        ctx.lineWidth = 1
        ctx.fillStyle = "#a5adcb"
        ctx.font = "10px sans-serif"
        for (var g = 0; g <= 4; g++) {
          var gv = min + ((max - min) * g) / 4
          var gy = y(gv)
          ctx.beginPath()
          ctx.moveTo(padL, gy)
          ctx.lineTo(width - padR, gy)
          ctx.stroke()
          ctx.fillText(symbol + Math.round(gv).toLocaleString("en-GB"), 4, gy + 4)
        }

        // zero line if in range
        if (min < 0) {
          ctx.strokeStyle = "#ee99a0"
          ctx.beginPath()
          ctx.moveTo(padL, y(0))
          ctx.lineTo(width - padR, y(0))
          ctx.stroke()
        }

        // area fill
        ctx.beginPath()
        ctx.moveTo(x(0), y(pts[0].balance))
        for (var k = 1; k < pts.length; k++) ctx.lineTo(x(k), y(pts[k].balance))
        ctx.lineTo(x(pts.length - 1), y(Math.max(min, 0)))
        ctx.lineTo(x(0), y(Math.max(min, 0)))
        ctx.closePath()
        ctx.fillStyle = "rgba(140, 170, 238, 0.15)"
        ctx.fill()

        // line
        ctx.beginPath()
        ctx.moveTo(x(0), y(pts[0].balance))
        for (var m = 1; m < pts.length; m++) ctx.lineTo(x(m), y(pts[m].balance))
        ctx.strokeStyle = "#8caaee"
        ctx.lineWidth = 2
        ctx.stroke()

        // month labels
        ctx.fillStyle = "#a5adcb"
        var lastMonth = ""
        var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        for (var t = 0; t < pts.length; t++) {
          var mo = pts[t].date.substring(5, 7)
          if (mo !== lastMonth) {
            lastMonth = mo
            ctx.fillText(MONTHS[parseInt(mo, 10) - 1], x(t) - 10, height - 4)
          }
        }
        return
      }

      // in/out bars
      var maxBar = 1
      for (var b = 0; b < series.length; b++) {
        if (series[b].in > maxBar) maxBar = series[b].in
        if (series[b].out > maxBar) maxBar = series[b].out
      }
      maxBar *= 1.05
      var bw = Math.max(2, W / series.length - 1)
      var yBase = height - padB
      for (var c = 0; c < series.length; c++) {
        var bx = padL + (c * W) / series.length
        if (series[c].in > 0) {
          ctx.fillStyle = "rgba(166, 218, 149, 0.8)"
          ctx.fillRect(bx, yBase - (series[c].in / maxBar) * H, bw, (series[c].in / maxBar) * H)
        }
        if (series[c].out > 0) {
          ctx.fillStyle = "rgba(238, 153, 160, 0.6)"
          ctx.fillRect(bx, yBase - (series[c].out / maxBar) * H, bw, (series[c].out / maxBar) * H)
        }
      }
      ctx.strokeStyle = "#414559"
      ctx.beginPath()
      ctx.moveTo(padL, yBase)
      ctx.lineTo(width - padR, yBase)
      ctx.stroke()
      ctx.fillStyle = "#a5adcb"
      ctx.fillText(symbol + Math.round(maxBar), 4, padT + 4)
      ctx.fillText(symbol + Math.round(maxBar / 2), 4, padT + H / 2 + 4)
    }
  }
}