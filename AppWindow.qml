// OmaFinSight desktop app — native window with the full FinSight experience:
// forecast chart, in/out bars, per-account balances, and full transaction
// management (add/edit/delete ad-hoc items, repeats, transfers and recurring
// transfers) plus register + first-run onboarding. Reads and writes only to
// the user's FinSight instance using the same 0600 session store as the bar
// widget; passwords travel over stdin and are never persisted.
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
  readonly property string sessionFile: sessionSvc.sessionFileFor(baseUrl)

  Service {
    id: sessionSvc
  }

  // ── auth state ─────────────────────────────────────────────────────
  // view: "auth" | "onboard" | "main"
  property string view: "auth"
  // Re-assert field focus once the view mounts (Loader mounts async — a
  // focus set during Component.onCompleted can be stolen by the window).
  Timer {
    interval: 400
    repeat: false
    running: appWindow.view === "onboard"
    onTriggered: {
      var f = onboardFocusHelper()
      if (f) f.forceActiveFocus()
    }
    function onboardFocusHelper() {
      function walk(item) {
        if (!item) return null
        if (item.objectName === "obBalanceField") return item
        for (var i = 0; i < item.children.length; i++) {
          var r = walk(item.children[i])
          if (r) return r
        }
        return null
      }
      return walk(appWindow.contentItem)
    }
  }
  property bool authed: false
  property string userEmail: ""
  property bool authBusy: false
  property string authError: ""
  property bool regMode: false

  // ── onboarding state ───────────────────────────────────────────────
  property string obName: ""
  property string obEmail: ""
  property string obPassword: ""
  property string obCurrency: "GBP"
  property real obOpening: 0
  property string obAccountName: "Main Account"
  property string obOpeningDate: ""
  property bool obSubmitting: false
  property string obError: ""

  // ── data state ─────────────────────────────────────────────────────
  property var dash: null           // parsed /api/dashboard payload
  property var series: []           // [{date, balance, in, out}]
  property var adhocs: []           // [{id, categoryId, category, label, amount, direction, date}]
  property var repeats: []          // [{id, categoryId, category, categoryKind, label, amount, direction, frequency, subType, startDate, endDate, neverExpires, nextDate}]
  property var transfers: []        // [{id, fromAccountId, fromName, toAccountId, toName, amount, label, date}]
  property var transferRepeats: []  // [{id, fromAccountId, fromName, toAccountId, toName, label, amount, frequency, subType, startDate, endDate, neverExpires}]
  property var categories: []       // [{id, name, kind, isDefault}]
  property var accounts: []         // [{id, name, kind, isPrimary}]
  property bool busy: false
  property string lastError: ""
  property string notice: ""        // transient success message
  property int tab: 0               // 0 overview, 1 transactions, 2 recurring
  property int chartDays: 30
  property string currencySymbol: "£"
  property int mutationBusy: 0      // in-flight mutation count
  readonly property bool mutationsBusy: mutationBusy > 0

  // Catppuccin Mocha palette (matches the house theme)
  readonly property color fg: "#f4dbfa"
  readonly property color dim: "#a5adcb"
  readonly property color accent: "#8caaee"
  readonly property color card: "#1a1f33"
  readonly property color border: "#414559"
  readonly property color red: "#ee99a0"
  readonly property color orange: "#f5a97f"
  readonly property color green: "#a6da95"
  readonly property color inputBg: "#11131c"

  title: "OmaFinSight"
  color: "#11131c"
  width: 1160
  height: 760
  visible: true
  readonly property string fontFamily: "JetBrainsMono Nerd Font Propo"

  onClosing: Qt.quit()

  Component.onCompleted: authCheckStart()


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

  function todayISO() {
    var d = new Date()
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
  }

  function currencySymbolFor(code) {
    var c = String(code || "GBP")
    if (c === "USD") return "$"
    if (c === "EUR") return "€"
    if (c === "JPY" || c === "CNY") return "¥"
    if (c === "INR") return "₹"
    if (c === "AUD") return "A$"
    if (c === "CAD") return "C$"
    if (c === "CHF") return "Fr"
    if (c === "BRL") return "R$"
    return "£"
  }

  function flash(msg) {
    notice = sanitize(String(msg || ""))
    flashTimer.restart()
  }

  Timer {
    id: flashTimer
    interval: 4000
    repeat: false
    onTriggered: appWindow.notice = ""
  }

  function valueColor(v) {
    if (v !== v) return appWindow.dim
    if (v < 200) return appWindow.red
    if (v < 500) return appWindow.orange
    return appWindow.fg
  }

  function amountColor(amount) {
    return amount >= 0 ? appWindow.green : appWindow.red
  }

  // category pickers: objects with textRole-friendly shape
  function categoryNames(kind) {
    var out = []
    for (var i = 0; i < categories.length; i++) {
      var c = categories[i]
      var k = String(c.kind || "")
      if (k === kind || (kind === "expense" && k === "")) out.push({ name: String(c.name), id: Number(c.id) })
    }
    if (out.length === 0) out.push({ name: "(no categories — add in web app)", id: 0 })
    return out
  }

  function categoryIdAt(model, idx) {
    var it = model && model.length ? model[Math.min(idx, model.length - 1)] : null
    return it ? it.id : 0
  }

  function accountIdAt(model, idx) {
    var it = model && model.length ? model[Math.min(idx, model.length - 1)] : null
    return it ? Number(it.id) : 0
  }

  // ── auth bootstrap ──────────────────────────────────────────────────
  // One cheap /api/profile call decides: 200 = signed in, 401 = show auth.
  // exit 9 = no session file yet (fresh start).
  function authCheckStart() {
    authBusy = true
    authProc.running = true
    authWatchdog.restart()
  }

  Process {
    id: authProc
    running: false
    property string buffer: ""
    command: ["timeout", "-k", "2", "10", "bash", "-c",
      "set -o pipefail; test -f '" + appWindow.sessionFile + "' || exit 9; " +
      "curl -sS -b '" + appWindow.sessionFile + "' --connect-timeout 5 --max-time 8 " +
      "'" + appWindow.baseUrl + "/api/profile' 2>&1 | head -c 4000"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (authProc.buffer.length + s.length <= 4000) authProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      authWatchdog.stop()
      authProc.running = false
      var buf = authProc.buffer.trim()
      authProc.buffer = ""
      appWindow.authBusy = false
      if (exitCode === 9) {
        appWindow.view = "auth"
        appWindow.regMode = false
        return
      }
      if (exitCode === 0 && buf.indexOf("{") >= 0) {
        try {
          var d = JSON.parse(buf.substring(buf.indexOf("{")))
          if (d.user && d.user.email) {
            appWindow.authed = true
            appWindow.userEmail = String(d.user.email)
            appWindow.currencySymbol = appWindow.currencySymbolFor(String(d.user.currency || "GBP"))
            if (d.user.onboarded) {
              appWindow.view = "main"
              appWindow.refresh()
            } else {
              appWindow.view = "onboard"
              appWindow.obName = String(d.user.name || "")
              appWindow.obEmail = String(d.user.email)
            }
            return
          }
        } catch (e) { /* fall through to auth view */ }
      }
      appWindow.view = "auth"
    }
  }

  Timer {
    id: authWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (authProc.running) authProc.running = false
      appWindow.authBusy = false
      appWindow.view = "auth"
      appWindow.authError = "Connection timed out — check the instance URL and your network"
    }
  }

  // ── login ───────────────────────────────────────────────────────────
  // Password travels over stdin into a bash `read` (never argv), then into
  // the JSON body via a 0600 mktemp file so it never appears in cmdline.
  property string _pwToWrite: ""

  function login(email, password) {
    var e = String(email || "").trim()
    var p = String(password || "")
    if (e === "" || p === "") { authError = "Email and password are required"; return }
    authBusy = true
    authError = ""
    regMode = false
    _pwToWrite = p
    loginProc.emailJson = JSON.stringify(e)
    loginProc.running = true
    loginWatchdog.restart()
  }

  Process {
    id: loginProc
    running: false
    property string emailJson: "\"\""
    property string buffer: ""
    stdinEnabled: true
    command: ["timeout", "-k", "2", "12", "bash", "-c",
      "set -o pipefail; IFS= read -r _pw; " +
      "_f=$(mktemp \"${XDG_RUNTIME_DIR:-/tmp}/omafinsight-login.XXXXXX\") || exit 1; " +
      "trap 'rm -f \"$_f\"' EXIT; " +
      "printf '{\"email\":%s,\"password\":%s}' " + loginProc.emailJson.replace(/\\/g, "\\\\") + " " +
      "\"$(printf '%s' \"$_pw\" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '\"\"')\" > \"$_f\"; " +
      "chmod 600 \"$_f\"; " +
      "mkdir -p '" + sessionSvc.sessionDirFor(appWindow.baseUrl) + "' && chmod 700 '" + sessionSvc.sessionDirFor(appWindow.baseUrl) + "'; " +
      "code=$(curl -sS --connect-timeout 5 --max-time 10 -c '" + appWindow.sessionFile + "' " +
      "-o \"$_f.out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" '" + appWindow.baseUrl + "/api/auth/login' 2>&1 | head -c 8); " +
      "cat \"$_f.out\" 2>/dev/null | head -c 4000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: {
      write(_pwToWrite + '\n')
      _pwToWrite = ""
    }
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (loginProc.buffer.length + s.length <= 4000) loginProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      loginWatchdog.stop()
      loginProc.running = false
      var raw = loginProc.buffer.trim()
      loginProc.buffer = ""
      appWindow.authBusy = false
      if (exitCode === 124 || exitCode === 137) { authError = "Login timed out — check the URL and your network"; return }
      if (exitCode !== 0) { authError = "Login failed (exit " + exitCode + ")"; return }
      var idx = raw.lastIndexOf("__CODE__")
      var code = idx >= 0 ? raw.substring(idx + 8, idx + 11) : ""
      var body = idx >= 0 ? raw.substring(0, idx) : raw
      if (code === "200") {
        try {
          var d = JSON.parse(body.substring(body.indexOf("{")))
          var u = d.user || {}
          appWindow.authed = true
          appWindow.userEmail = String(u.email || loginProc.emailJson)
          appWindow.currencySymbol = appWindow.currencySymbolFor(String(u.currency || "GBP"))
          if (u.onboarded) { appWindow.view = "main"; appWindow.refresh() }
          else {
            appWindow.view = "onboard"
            appWindow.obName = String(u.name || "")
            appWindow.obEmail = String(u.email || "")
          }
          authError = ""
        } catch (e) { authError = "Unexpected login response" }
      } else if (code === "401") {
        authError = "Invalid email or password"
      } else if (code === "429") {
        authError = "Too many attempts — wait a few minutes and try again"
      } else {
        var msg = ""
        try { msg = String(JSON.parse(body.substring(body.indexOf("{"))).error || "") } catch (e2) {}
        authError = msg !== "" ? sanitize(msg) : (code === "" ? "Could not reach FinSight — check the URL and your network" : "Login failed (HTTP " + code + ")")
      }
    }
  }

  Timer {
    id: loginWatchdog
    interval: 18000
    repeat: false
    onTriggered: {
      if (loginProc.running) loginProc.running = false
      appWindow.authBusy = false
      appWindow.authError = "Login timed out — check the URL and your network"
    }
  }

  // ── register ────────────────────────────────────────────────────────
  // Same stdin discipline as login. Success → the account exists and a
  // session cookie is set → straight to onboarding.
  function register(name, email, password, currency) {
    var n = String(name || "").trim()
    var e = String(email || "").trim()
    var p = String(password || "")
    if (n === "" || e === "" || p === "") { authError = "Name, email and password are required"; return }
    if (p.length < 8) { authError = "Password must be at least 8 characters"; return }
    authBusy = true
    authError = ""
    regMode = true
    _pwToWrite = p
    registerProc.nameJson = JSON.stringify(n)
    registerProc.emailJson = JSON.stringify(e)
    registerProc.currencyJson = JSON.stringify(String(currency || "GBP"))
    registerProc.running = true
    registerWatchdog.restart()
  }

  Process {
    id: registerProc
    running: false
    property string nameJson: "\"\""
    property string emailJson: "\"\""
    property string currencyJson: "\"GBP\""
    property string buffer: ""
    stdinEnabled: true
    command: ["timeout", "-k", "2", "12", "bash", "-c",
      "set -o pipefail; IFS= read -r _pw; " +
      "_f=$(mktemp \"${XDG_RUNTIME_DIR:-/tmp}/omafinsight-reg.XXXXXX\") || exit 1; " +
      "trap 'rm -f \"$_f\"' EXIT; " +
      "printf '{\"name\":%s,\"email\":%s,\"password\":%s,\"currency\":%s}' " +
      registerProc.nameJson + " " + registerProc.emailJson + " " +
      "\"$(printf '%s' \"$_pw\" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '\"\"')\" " +
      registerProc.currencyJson + " > \"$_f\"; " +
      "chmod 600 \"$_f\"; " +
      "code=$(curl -sS --connect-timeout 5 --max-time 10 -c '" + appWindow.sessionFile + "' " +
      "-o \"$_f.out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" '" + appWindow.baseUrl + "/api/auth/register' 2>&1 | head -c 8); " +
      "cat \"$_f.out\" 2>/dev/null | head -c 4000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: {
      write(_pwToWrite + '\n')
      _pwToWrite = ""
    }
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (registerProc.buffer.length + s.length <= 4000) registerProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      registerWatchdog.stop()
      registerProc.running = false
      var raw = registerProc.buffer.trim()
      registerProc.buffer = ""
      appWindow.authBusy = false
      if (exitCode === 124 || exitCode === 137) { authError = "Registration timed out — check the URL and your network"; return }
      if (exitCode !== 0) { authError = "Registration failed (exit " + exitCode + ")"; return }
      var idx = raw.lastIndexOf("__CODE__")
      var code = idx >= 0 ? raw.substring(idx + 8, idx + 11) : ""
      var body = idx >= 0 ? raw.substring(0, idx) : raw
      if (code === "200" || code === "201") {
        try {
          var d = JSON.parse(body.substring(body.indexOf("{")))
          var u = d.user || {}
          appWindow.authed = true
          appWindow.userEmail = String(u.email || "")
          appWindow.currencySymbol = appWindow.currencySymbolFor(String(u.currency || "GBP"))
          appWindow.view = "onboard"
          appWindow.obName = String(u.name || "")
          appWindow.obEmail = String(u.email || "")
          authError = ""
        } catch (e) { authError = "Unexpected registration response" }
      } else if (code === "429") {
        authError = "Too many signups from this network — try again later"
      } else {
        var msg = ""
        try { msg = String(JSON.parse(body.substring(body.indexOf("{"))).error || "") } catch (e2) {}
        authError = msg !== "" ? sanitize(msg) : (code === "" ? "Could not reach FinSight — check the URL and your network" : "Registration failed (HTTP " + code + ")")
      }
    }
  }

  Timer {
    id: registerWatchdog
    interval: 18000
    repeat: false
    onTriggered: {
      if (registerProc.running) registerProc.running = false
      appWindow.authBusy = false
      appWindow.authError = "Registration timed out — check the URL and your network"
    }
  }

  // ── onboarding submit ───────────────────────────────────────────────
  // POST /api/onboarding { openingBalance, currency, accountName, openingDate }
  function submitOnboarding() {
    var bal = Number(obOpening)
    if (obOpening === "" || isNaN(bal)) { obError = "Enter a valid opening balance (0 is fine)"; return }
    obSubmitting = true
    obError = ""
    var body = JSON.stringify({
      openingBalance: bal,
      currency: obCurrency,
      accountName: String(obAccountName || "Main Account").trim() || "Main Account",
      openingDate: String(obOpeningDate || todayISO())
    })
    onboardProc.body = body
    onboardProc.running = true
    onboardWatchdog.restart()
  }

  Process {
    id: onboardProc
    running: false
    property string body: ""
    property string buffer: ""
    stdinEnabled: true
    command: ["timeout", "-k", "2", "12", "bash", "-c",
      "set -o pipefail; " +
      "_f=$(mktemp \"${XDG_RUNTIME_DIR:-/tmp}/omafinsight-onb.XXXXXX\") || exit 1; " +
      "trap 'rm -f \"$_f\"' EXIT; " +
      "while IFS= read -r _l; do [ \"$_l\" = __EOFMUT__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; chmod 600 \"$_f\"; " +
      "code=$(curl -sS --connect-timeout 5 --max-time 10 -b '" + appWindow.sessionFile + "' " +
      "-o \"$_f.out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" '" + appWindow.baseUrl + "/api/onboarding' 2>&1 | head -c 8); " +
      "cat \"$_f.out\" 2>/dev/null | head -c 2000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: { write(body + "\n__EOFMUT__\n"); body = "" }
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (onboardProc.buffer.length + s.length <= 2000) onboardProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      onboardWatchdog.stop()
      onboardProc.running = false
      var raw = onboardProc.buffer.trim()
      onboardProc.buffer = ""
      appWindow.obSubmitting = false
      if (exitCode === 124 || exitCode === 137) { obError = "Timed out — try again"; return }
      if (exitCode !== 0) { obError = "Onboarding failed (exit " + exitCode + ")"; return }
      var idx = raw.lastIndexOf("__CODE__")
      var code = idx >= 0 ? raw.substring(idx + 8, idx + 11) : ""
      if (code === "200") {
        appWindow.view = "main"
        appWindow.refresh()
      } else {
        var msg = ""
        try { msg = String(JSON.parse(raw.substring(0, idx)).error || "") } catch (e) {}
        obError = msg !== "" ? sanitize(msg) : "Onboarding failed (HTTP " + code + ")"
      }
    }
  }

  Timer {
    id: onboardWatchdog
    interval: 18000
    repeat: false
    onTriggered: {
      if (onboardProc.running) onboardProc.running = false
      appWindow.obSubmitting = false
      appWindow.obError = "Onboarding timed out — try again"
    }
  }
  // ── main data loading ───────────────────────────────────────────────
  readonly property int capSection: 100000
  property int _outstanding: 0
  property string scope: "primary"

  function truncateStr(s, n) {
    s = String(s || "")
    return s.length <= n ? s : s.substring(0, n) + "…"
  }

  function refresh() {
    if (busy) return
    busy = true
    lastError = ""
    _outstanding = 3
    dashProc.url = baseUrl + "/api/dashboard" + (scope === "all" ? "?account=all" : "")
    chartProc.url = baseUrl + "/api/chart?days=" + chartDays + "&back=30" + (scope === "all" ? "&account=all" : "")
    dashProc.running = true
    chartProc.running = true
    listsProc.running = true
    dashWatchdog.restart()
    chartWatchdog.restart()
    listsWatchdog.restart()
  }

  function _finish(ok, errMsg) {
    _outstanding = _outstanding - 1
    if (_outstanding <= 0) {
      _outstanding = 0
      busy = false
      if (!ok && lastError === "" && errMsg) lastError = errMsg
    }
  }

  function applyDashboard(raw) {
    try {
      var d = JSON.parse(raw)
      if (d.onboarded === false) {
        view = "onboard"
        _finish(false, "")
        return
      }
      dash = d
      var acc = []
      var arr = d.accounts || []
      for (var i = 0; i < arr.length && i < 12; i++) {
        var a = arr[i]
        if (!a || typeof a.id !== "number") continue
        acc.push({
          id: a.id,
          name: sanitize(truncateStr(String(a.name || ""), 48)),
          kind: String(a.kind || ""),
          isPrimary: a.isPrimary === true,
          balanceNow: typeof a.balanceNow === "number" ? a.balanceNow : NaN
        })
      }
      accounts = acc
      var u = d.user || {}
      if (u.currency) currencySymbol = currencySymbolFor(String(u.currency))
    } catch (e) {
      _finish(false, "Unexpected dashboard response (not JSON)")
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

  // Lists arrive as __MARKER__-separated single-line JSON payloads from one
  // hardened bash run. Bounded: 5 sections × capSection, 500 rows each.
  function _jsonArr(section, key, cap, strFields) {
    try {
      var d = JSON.parse(section)
      var arr = d[key] || []
      var out = []
      for (var i = 0; i < arr.length && i < cap; i++) {
        var it = arr[i]
        for (var f = 0; f < strFields.length; f++) {
          var k = strFields[f]
          it[k] = sanitize(String(it[k] === undefined || it[k] === null ? "" : it[k]))
        }
        out.push(it)
      }
      return out
    } catch (e) { return null }
  }

  function _parseLists(raw) {
    var parts = {}
    var cur = ""
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var L = lines[i]
      if (L.length > 4 && L.charAt(0) === "_" && L.charAt(1) === "_" && L.substring(L.length - 2) === "__") {
        cur = L.substring(2, L.length - 2)
        parts[cur] = ""
      } else if (cur !== "" && L !== "") {
        parts[cur] = (parts[cur] || "") + L
      }
    }
    var a = _jsonArr(parts["ADHOCS"] || "", "adhocs", 500, ["label", "category"])
    if (a !== null) adhocs = a
    var r = _jsonArr(parts["REPEATS"] || "", "repeats", 500, ["label", "category"])
    if (r !== null) repeats = r
    var t = _jsonArr(parts["TRANSFERS"] || "", "transfers", 500, ["label", "fromName", "toName"])
    if (t !== null) transfers = t
    var tr = _jsonArr(parts["TREFS"] || "", "transferRepeats", 500, ["label", "fromName", "toName"])
    if (tr !== null) transferRepeats = tr
    var c = _jsonArr(parts["CATS"] || "", "categories", 200, ["name"])
    if (c !== null) categories = c
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

  Process {
    id: listsProc
    running: false
    property string buffer: ""
    command: ["timeout", "-k", "2", "20", "bash", "-c",
      "set -o pipefail; B='" + appWindow.baseUrl + "'; S='" + appWindow.sessionFile + "'; " +
      "emit() { echo \"__$1__\"; curl -sS -b \"$S\" --connect-timeout 5 --max-time 8 \"$B/api/$2\" 2>&1 | head -c " + appWindow.capSection + "; echo; }; " +
      "emit ADHOCS adhoc; emit REPEATS repeats; emit TRANSFERS transfers; emit TREFS transfers/recurring; emit CATS categories"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (listsProc.buffer.length + s.length <= 550000) listsProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      listsWatchdog.stop()
      listsProc.running = false
      var buf = listsProc.buffer
      listsProc.buffer = ""
      if (exitCode === 0) {
        appWindow._parseLists(buf)
        appWindow._finish(true, "")
      } else {
        appWindow._finish(false, exitCode === 124 ? "Timed out" : "List fetch failed (exit " + exitCode + ")")
      }
    }
  }

  Timer {
    id: listsWatchdog
    interval: 25000
    onTriggered: {
      if (listsProc.running) listsProc.running = false
      appWindow._finish(false, "List fetch timed out")
    }
  }

  // ── mutations (add/edit/delete) ─────────────────────────────────────
  // One hardened generic runner: JSON body written to a 0600 mktemp file
  // (quoted heredoc — no shell interpolation), method + path per call.
  property string _mutDesc: ""

  function mutate(desc, method, path, bodyObj) {
    if (mutationProc.running) { flash("Still working — try again in a moment"); return }
    _mutDesc = sanitize(truncateStr(desc, 60))
    var hasBody = bodyObj !== null && bodyObj !== undefined
    mutationProc.bodyJson = hasBody ? JSON.stringify(bodyObj) : ""
    mutationProc.hasBodyFlag = hasBody
    mutationProc.method = String(method)
    mutationProc.path = String(path)
    mutationBusy = mutationBusy + 1
    mutationProc.running = true
    mutationWatchdog.restart()
  }

  Process {
    id: mutationProc
    running: false
    property string bodyJson: ""
    property bool hasBodyFlag: false
    property string method: "POST"
    property string path: ""
    property string buffer: ""
    stdinEnabled: true
    command: ["timeout", "-k", "2", "15", "bash", "-c",
      "set -o pipefail; " +
      "_f=$(mktemp \"${XDG_RUNTIME_DIR:-/tmp}/omafinsight-mut.XXXXXX\") || exit 1; " +
      "trap 'rm -f \"$_f\" \"$_f.out\"' EXIT; " +
      (hasBodyFlag ? "while IFS= read -r _l; do [ \"$_l\" = __EOFMUT__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; chmod 600 \"$_f\"; " : "rm -f \"$_f\"; ") +
      "code=$(curl -sS --connect-timeout 5 --max-time 12 -b '" + appWindow.sessionFile + "' " +
      "-o \"$_f.out\" -w '%{http_code}' -X " + method + " -H 'Content-Type: application/json' " +
      (hasBodyFlag ? "--data @\"$_f\" " : "") +
      "'" + appWindow.baseUrl + path + "' 2>&1 | head -c 8); " +
      "cat \"$_f.out\" 2>/dev/null | head -c 2000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: {
      if (bodyJson !== "") { write(bodyJson + "\n__EOFMUT__\n"); bodyJson = "" }
    }
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (mutationProc.buffer.length + s.length <= 2000) mutationProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      mutationWatchdog.stop()
      mutationProc.running = false
      var raw = mutationProc.buffer.trim()
      mutationProc.buffer = ""
      mutationBusy = Math.max(0, mutationBusy - 1)
      if (exitCode === 124 || exitCode === 137) { lastError = _mutDesc + " timed out — try again"; return }
      var idx = raw.lastIndexOf("__CODE__")
      var code = idx >= 0 ? raw.substring(idx + 8, idx + 11) : ""
      if (exitCode === 0 && code.charAt(0) === "2") {
        lastError = ""
        flash(_mutDesc + " — done")
        refresh()
      } else {
        var body = idx >= 0 ? raw.substring(0, idx) : raw
        var msg = ""
        try { msg = String(JSON.parse(body.substring(body.indexOf("{"))).error || "") } catch (e) {}
        lastError = msg !== "" ? sanitize(truncateStr(msg, 200)) : (_mutDesc + " failed (HTTP " + code + ")")
      }
    }
  }

  Timer {
    id: mutationWatchdog
    interval: 20000
    repeat: false
    onTriggered: {
      if (mutationProc.running) mutationProc.running = false
      appWindow.mutationBusy = Math.max(0, appWindow.mutationBusy - 1)
      appWindow.lastError = appWindow._mutDesc + " timed out — try again"
    }
  }

  // CRUD wrappers (API shapes mirror the web app's own fetches)
  function saveAdhoc(id, f) {
    var body = {
      categoryId: Number(f.categoryId),
      label: String(f.label || "").trim(),
      amount: Math.abs(Number(f.amount)),
      direction: f.direction === "income" ? "income" : "expense",
      date: String(f.date),
      fromAccountId: Number(f.accountId) || undefined
    }
    if (id) mutate("Transaction updated", "PUT", "/api/adhoc/" + Number(id), body)
    else mutate("Transaction added", "POST", "/api/adhoc", body)
  }

  function deleteAdhoc(id) { mutate("Transaction deleted", "DELETE", "/api/adhoc/" + Number(id), null) }

  function saveRepeat(id, f) {
    var body = {
      categoryId: Number(f.categoryId),
      label: String(f.label || "").trim(),
      amount: Math.abs(Number(f.amount)),
      direction: f.direction === "income" ? "income" : "expense",
      frequency: String(f.frequency),
      subType: String(f.subType || ""),
      startDate: String(f.startDate),
      neverExpires: f.neverExpires === true
    }
    if (!body.neverExpires && String(f.endDate || "") !== "") body.endDate = String(f.endDate)
    if (Number(f.accountId)) body.fromAccountId = Number(f.accountId)
    if (id) mutate("Repeat updated", "PUT", "/api/repeats/" + Number(id), body)
    else mutate("Repeat added", "POST", "/api/repeats", body)
  }

  function deleteRepeat(id) { mutate("Repeat deleted", "DELETE", "/api/repeats/" + Number(id), null) }

  function addTransfer(f) {
    mutate("Transfer added", "POST", "/api/transfers", {
      fromAccountId: Number(f.from),
      toAccountId: Number(f.to),
      amount: Math.abs(Number(f.amount)),
      label: String(f.label || "").trim(),
      date: String(f.date)
    })
  }

  function deleteTransfer(id) { mutate("Transfer deleted", "DELETE", "/api/transfers?id=" + Number(id), null) }

  function addTref(f) {
    var body = {
      fromAccountId: Number(f.from),
      toAccountId: Number(f.to),
      amount: Math.abs(Number(f.amount)),
      label: String(f.label || "").trim(),
      frequency: String(f.frequency),
      subType: String(f.subType || ""),
      startDate: String(f.startDate),
      neverExpires: f.neverExpires === true
    }
    if (!body.neverExpires && String(f.endDate || "") !== "") body.endDate = String(f.endDate)
    mutate("Recurring transfer added", "POST", "/api/transfers/recurring", body)
  }

  function deleteTref(id) { mutate("Recurring transfer deleted", "DELETE", "/api/transfers/recurring?id=" + Number(id), null) }

  // ── sign out ────────────────────────────────────────────────────────
  function signOut() {
    logoutProc.running = true
    logoutWatchdog.restart()
  }

  Process {
    id: logoutProc
    running: false
    command: ["timeout", "-k", "2", "10", "bash", "-c",
      "curl -sS --connect-timeout 5 --max-time 8 -X POST -b '" + appWindow.sessionFile + "' " +
      "'" + appWindow.baseUrl + "/api/auth/logout' >/dev/null 2>&1; " +
      "rm -f '" + appWindow.sessionFile + "'"]
    onExited: function() { appWindow._resetToAuth() }
  }

  Timer {
    id: logoutWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (logoutProc.running) logoutProc.running = false
      appWindow._resetToAuth()
    }
  }

  function _resetToAuth() {
    authed = false
    userEmail = ""
    dash = null
    series = []
    adhocs = []
    repeats = []
    transfers = []
    transferRepeats = []
    categories = []
    accounts = []
    view = "auth"
    regMode = false
    authError = ""
    lastError = ""
    notice = ""
    tab = 0
  }

  // ═════════════════════════════════════════════════════════════════════
  // UI
  // ═════════════════════════════════════════════════════════════════════

  // ── reusable pieces ──────────────────────────────────────────────────
  component FieldInput: TextField {
    id: fi
    color: appWindow.fg
    placeholderTextColor: appWindow.dim
    font.family: appWindow.fontFamily
    font.pixelSize: 13
    background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
  }

  component Card: Rectangle {
    color: appWindow.card
    radius: 10
    border.color: appWindow.border
  }

  component PillButton: Button {
    id: pb
    contentItem: Text {
      text: pb.text
      color: pb.enabled ? appWindow.fg : appWindow.dim
      font.family: appWindow.fontFamily
      font.pixelSize: 12
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
      radius: 6
      color: pb.down ? appWindow.accent : (pb.hovered ? Qt.lighter(appWindow.card, 1.4) : appWindow.card)
      border.color: pb.down ? appWindow.accent : appWindow.border
    }
  }

  // ── AUTH VIEW ────────────────────────────────────────────────────────
  Loader {
    anchors.fill: parent
    active: appWindow.view === "auth"
    sourceComponent: authComp
  }

  Component {
    id: authComp
    Rectangle {
      color: "#11131c"
      anchors.fill: parent

      Flickable {
        id: authFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: authCol.height + 60
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: authCol
          width: Math.min(560, parent.width - 48)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 40
          spacing: 14

          Row {
            spacing: 10
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
              text: "\ue933"
              color: appWindow.accent
              font.family: appWindow.fontFamily
              font.pixelSize: 30
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "OmaFinSight"
              color: appWindow.fg
              font.family: appWindow.fontFamily
              font.pixelSize: 24
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
          }

          Text {
            width: parent.width
            text: appWindow.regMode
              ? "Create your account on " + sanitize(appWindow.baseUrl.replace(/^https?:\/\//, ""))
              : "Sign in to " + sanitize(appWindow.baseUrl.replace(/^https?:\/\//, ""))
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }

          TextField {
            id: nameField
            visible: appWindow.regMode
            width: parent.width
            placeholderText: "Your name"
            color: appWindow.fg
            placeholderTextColor: appWindow.dim
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
            enabled: !appWindow.authBusy
          }

          TextField {
            id: emailField
            width: parent.width
            placeholderText: "Email address"
            color: appWindow.fg
            placeholderTextColor: appWindow.dim
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
            Component.onCompleted: {
              if (!appWindow.regMode) forceActiveFocus()
              else Qt.callLater(function() { if (!nameField.activeFocus) nameField.forceActiveFocus() })
            }
          }

          TextField {
            id: passwordField
            width: parent.width
            placeholderText: appWindow.regMode ? "Password (min 8 characters)" : "Password"
            echoMode: TextInput.Password
            color: appWindow.fg
            placeholderTextColor: appWindow.dim
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
            enabled: !appWindow.authBusy
          }

          ComboBox {
            id: currencyBox
            visible: appWindow.regMode
            width: 200
            model: ["GBP", "USD", "EUR", "JPY", "CNY", "INR", "AUD", "CAD", "CHF", "BRL"]
            enabled: !appWindow.authBusy
          }

          Button {
            id: goButton
            width: parent.width
            enabled: !appWindow.authBusy && emailField.text.trim() !== "" && passwordField.text !== "" &&
                     (!appWindow.regMode || nameField.text.trim() !== "")
            contentItem: Text {
              text: appWindow.authBusy ? "Working…" : (appWindow.regMode ? "Create account" : "Sign in")
              color: goButton.enabled ? appWindow.fg : appWindow.dim
              font.family: appWindow.fontFamily
              font.pixelSize: 13
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
              radius: 6
              color: goButton.down ? appWindow.accent : (goButton.enabled ? Qt.lighter(appWindow.card, 1.6) : appWindow.card)
              border.color: appWindow.border
            }
            onClicked: {
              if (appWindow.regMode)
                appWindow.register(nameField.text, emailField.text, passwordField.text, currencyBox.currentText)
              else
                appWindow.login(emailField.text, passwordField.text)
            }
          }

          Text {
            width: parent.width
            visible: appWindow.authError !== ""
            text: appWindow.authError
            color: appWindow.red
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Text {
            text: appWindow.regMode ? "Already have an account? Sign in" : "New here? Create an account"
            color: appWindow.accent
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                appWindow.regMode = !appWindow.regMode
                appWindow.authError = ""
              }
            }
          }

          Text {
            width: parent.width
            text: "Your password is sent once over HTTPS and never stored — only the session cookie is kept, at ~/.local/state/omafinsight/session.txt (0600)."
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 11
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  // ── ONBOARDING VIEW ──────────────────────────────────────────────────
  Loader {
    anchors.fill: parent
    active: appWindow.view === "onboard"
    sourceComponent: onboardComp
  }

  Component {
    id: onboardComp
    Rectangle {
      color: "#11131c"
      anchors.fill: parent

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: onbCol.height + 60
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: onbCol
          width: Math.min(560, parent.width - 48)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 40
          spacing: 14

          Row {
            spacing: 10
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
              text: "\ue933"
              color: appWindow.accent
              font.family: appWindow.fontFamily
              font.pixelSize: 30
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "Welcome, " + sanitize(appWindow.obName || "there")
              color: appWindow.fg
              font.family: appWindow.fontFamily
              font.pixelSize: 22
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
          }

          Text {
            width: parent.width
            text: "Three quick things to set up your forecast: your starting balance, a name for your main account, and the date that balance was true."
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Text {
            text: "OPENING BALANCE"
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }
          Row {
            spacing: 8
            Text {
              text: appWindow.currencySymbol
              color: appWindow.fg
              font.family: appWindow.fontFamily
              font.pixelSize: 14
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
            TextField {
              id: obBalanceField
              objectName: "obBalanceField"
              width: 160
              placeholderText: "0.00"
              color: appWindow.fg
              placeholderTextColor: appWindow.dim
              font.family: appWindow.fontFamily
              background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
              enabled: !appWindow.obSubmitting
              text: appWindow.obOpening === 0 ? "" : String(appWindow.obOpening)
              Component.onCompleted: forceActiveFocus()
            }
          }

          Text {
            text: "MAIN ACCOUNT NAME"
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }
          TextField {
            id: obNameField
            width: 320
            text: appWindow.obAccountName
            color: appWindow.fg
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
            enabled: !appWindow.obSubmitting
          }

          Text {
            text: "BALANCE WAS TRUE ON"
            color: appWindow.dim
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.2
            textFormat: Text.PlainText
          }
          TextField {
            id: obDateField
            width: 160
            placeholderText: appWindow.todayISO()
            color: appWindow.fg
            placeholderTextColor: appWindow.dim
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.inputBg; radius: 6; border.color: appWindow.border }
            enabled: !appWindow.obSubmitting
          }

          Button {
            width: 320
            enabled: !appWindow.obSubmitting && obBalanceField.text.trim() !== ""
            contentItem: Text {
              text: appWindow.obSubmitting ? "Setting up…" : "Start forecasting"
              color: appWindow.fg
              font.family: appWindow.fontFamily
              font.pixelSize: 13
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
              radius: 6
              color: appWindow.accent
              opacity: parent.enabled ? 1 : 0.4
            }
            onClicked: {
              appWindow.obOpening = Number(obBalanceField.text)
              appWindow.obAccountName = obNameField.text.trim() !== "" ? obNameField.text.trim() : "Main Account"
              appWindow.obOpeningDate = obDateField.text.trim() !== "" ? obDateField.text.trim() : appWindow.todayISO()
              appWindow.submitOnboarding()
            }
          }

          Text {
            width: parent.width
            visible: appWindow.obError !== ""
            text: appWindow.obError
            color: appWindow.red
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  // ── MAIN VIEW ────────────────────────────────────────────────────────
  Loader {
    anchors.fill: parent
    active: appWindow.view === "main"
    sourceComponent: mainComp
  }

  Component {
    id: mainComp
    Rectangle {
      color: "#11131c"
      anchors.fill: parent

      Column {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 10

        // header
        Item {
          width: parent.width
          height: 42

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Text {
              text: "\ue933"
              color: appWindow.accent
              font.family: appWindow.fontFamily
              font.pixelSize: 22
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "OmaFinSight"
              color: appWindow.fg
              font.family: appWindow.fontFamily
              font.pixelSize: 18
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
            Text {
              text: {
                if (!appWindow.dash) return ""
                var s = appWindow.dash.scope
                if (s === "all") return "· all accounts"
                var prim = null
                var arr = appWindow.accounts
                for (var i = 0; i < arr.length; i++) if (arr[i].isPrimary) { prim = arr[i]; break }
                return "· " + ((prim && prim.name) || "primary")
              }
              color: appWindow.dim
              font.family: appWindow.fontFamily
              font.pixelSize: 12
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            ComboBox {
              id: scopeBox
              width: 170
              model: ["Primary account", "All accounts"]
              enabled: !appWindow.busy
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
              enabled: !appWindow.busy
              onActivated: function(idx) {
                appWindow.chartDays = [30, 90, 365][idx]
                appWindow.refresh()
              }
              currentIndex: [30, 90, 365].indexOf(appWindow.chartDays)
            }

            PillButton {
              text: appWindow.busy ? "…" : "Refresh"
              onClicked: appWindow.refresh()
            }

            PillButton {
              text: "Open web"
              onClicked: Qt.openUrlExternally(appWindow.baseUrl)
            }

            PillButton {
              text: "Sign out"
              enabled: !appWindow.mutationsBusy
              onClicked: appWindow.signOut()
            }
          }
        }

        Text {
          visible: appWindow.lastError !== ""
          text: appWindow.lastError
          color: appWindow.red
          font.family: appWindow.fontFamily
          font.pixelSize: 12
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Text {
          visible: appWindow.notice !== ""
          text: appWindow.notice
          color: appWindow.green
          font.family: appWindow.fontFamily
          font.pixelSize: 12
          textFormat: Text.PlainText
          width: parent.width
        }

        // tabs
        Row {
          spacing: 6

          Repeater {
            model: ["Overview", "Transactions", "Recurring"]

            PillButton {
              required property int index
              required property var modelData
              objectName: "tabBtn" + index
              text: modelData
              onClicked: appWindow.tab = index
              background: Rectangle {
                radius: 6
                color: appWindow.tab === index ? appWindow.accent : appWindow.card
                border.color: appWindow.border
              }
            }
          }
        }

        // tab content
        StackLayout {
          width: parent.width
          height: {
            var h = parent.height - 42 - 36 - 20
            return Math.max(300, h)
          }
          currentIndex: appWindow.tab

          // ── TAB 0: OVERVIEW ───────────────────────────────────────
          Flickable {
            id: overviewFlick
            contentWidth: width
            contentHeight: overviewCol.height + 20
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }

            Column {
              id: overviewCol
              width: overviewFlick.width
              spacing: 10

              // summary cards
              Row {
                width: parent.width
                spacing: 10
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
                    width: (parent.width - 30) / 4
                    height: 70
                    radius: 10
                    color: modelData.hero ? "#232a45" : appWindow.card
                    border.color: modelData.hero ? appWindow.accent : appWindow.border

                    Column {
                      anchors.fill: parent
                      anchors.margins: 10
                      spacing: 4

                      Text {
                        text: modelData.label
                        color: appWindow.dim
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
                        font.pixelSize: modelData.hero ? 22 : 17
                        font.bold: true
                        textFormat: Text.PlainText
                      }
                    }
                  }
                }
              }

              // balance chart
              Card {
                width: parent.width
                height: 240

                Column {
                  anchors.fill: parent
                  anchors.margins: 12
                  spacing: 6

                  Text {
                    text: "BALANCE FORECAST (" + appWindow.chartDays + " DAYS)"
                    color: appWindow.dim
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
                    mode: "balance"
                    symbol: appWindow.currencySymbol
                  }
                }
              }

              // in/out chart
              Card {
                width: parent.width
                height: 160

                Column {
                  anchors.fill: parent
                  anchors.margins: 12
                  spacing: 6

                  Text {
                    text: "MONEY IN VS OUT (LAST 30 DAYS + FORECAST)"
                    color: appWindow.dim
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
                spacing: 10

                Card {
                  width: (parent.width - 10) / 2
                  height: accountsCol.height + 26
                  implicitHeight: 180

                  Column {
                    id: accountsCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 6

                    Text {
                      text: "ACCOUNTS"
                      color: appWindow.dim
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.2
                      textFormat: Text.PlainText
                    }

                    Repeater {
                      model: appWindow.accounts

                      Row {
                        required property var modelData
                        width: parent.width
                        spacing: 8

                        Text {
                          width: parent.width - 120
                          text: modelData.name + (modelData.isPrimary ? "  · primary" : "")
                          color: appWindow.fg
                          font.family: appWindow.fontFamily
                          font.pixelSize: 12
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
                          font.pixelSize: 12
                          font.bold: true
                          textFormat: Text.PlainText
                        }
                      }
                    }
                  }
                }

                Card {
                  width: (parent.width - 10) / 2
                  height: upcomingCol.height + 26
                  implicitHeight: 180

                  Column {
                    id: upcomingCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 6

                    Text {
                      text: "UPCOMING (NEXT 6)"
                      color: appWindow.dim
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
                          width: 66
                          text: appWindow.fmtDateUK(modelData.date)
                          color: appWindow.dim
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: parent.width - 66 - 80 - 16
                          text: sanitize(modelData.label)
                          color: appWindow.fg
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 80
                          text: (modelData.amount >= 0 ? "+" : "-") + appWindow.currencySymbol + Math.abs(modelData.amount).toFixed(2)
                          color: appWindow.amountColor(modelData.amount)
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          textFormat: Text.PlainText
                        }
                      }
                    }
                  }
                }
              }
            }
          }

          // ── TAB 1: TRANSACTIONS ────────────────────────────────────
          Flickable {
            id: txFlick
            contentWidth: width
            contentHeight: txCol.height + 20
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }

            Column {
              id: txCol
              width: txFlick.width
              spacing: 10

              Row {
                spacing: 8

                PillButton {
                  id: addTxButton
                  objectName: "addTxButton"
                  text: appWindow.mutationsBusy ? "…" : "+ Add transaction"
                  enabled: !appWindow.mutationsBusy
                  onClicked: txEditor.openFor(null)
                }
                PillButton {
                  text: "+ Transfer between accounts"
                  enabled: !appWindow.mutationsBusy
                  onClicked: transferEditor.openFor()
                }
              }

              // section: ad-hoc transactions
              Card {
                width: parent.width
                height: txAdhocCol.height + 24

                Column {
                  id: txAdhocCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: 12
                  spacing: 4

                  Text {
                    text: "AD-HOC TRANSACTIONS (" + appWindow.adhocs.length + ")"
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1.2
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: appWindow.adhocs

                    Row {
                      required property var modelData
                      required property int index
                      width: parent.width
                      spacing: 8

                      Text {
                        width: 66
                        text: appWindow.fmtDateUK(modelData.date)
                        color: appWindow.dim
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: parent.width - 66 - 90 - 150
                        text: sanitize(modelData.label) + (modelData.category ? "  · " + sanitize(modelData.category) : "")
                        color: appWindow.fg
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 90
                        text: {
                          var sign = modelData.direction === "income" ? "+" : "-"
                          return sign + appWindow.fmtMoney(modelData.amount)
                        }
                        color: modelData.direction === "income" ? appWindow.green : appWindow.red
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        textFormat: Text.PlainText
                      }

                      Row {
                        width: 150
                        spacing: 4
                        PillButton {
                          text: "Edit"
                          enabled: !appWindow.mutationsBusy
                          onClicked: txEditor.openFor(modelData)
                        }
                        PillButton {
                          text: "Delete"
                          enabled: !appWindow.mutationsBusy
                          onClicked: appWindow.deleteAdhoc(modelData.id)
                        }
                      }
                    }
                  }

                  Text {
                    visible: appWindow.adhocs.length === 0
                    text: "No ad-hoc transactions yet — add your first one above."
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    textFormat: Text.PlainText
                  }
                }
              }
            }
          }

          // ── TAB 2: RECURRING ───────────────────────────────────────
          Flickable {
            id: recFlick
            contentWidth: width
            contentHeight: recCol.height + 20
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar { }

            Column {
              id: recCol
              width: recFlick.width
              spacing: 10

              Row {
                spacing: 8

                PillButton {
                  text: appWindow.mutationsBusy ? "…" : "+ Add repeat"
                  enabled: !appWindow.mutationsBusy
                  onClicked: repeatEditor.openFor(null)
                }
                PillButton {
                  text: "+ Add recurring transfer"
                  enabled: !appWindow.mutationsBusy
                  onClicked: transferEditor.openForRecurring()
                }
              }

              // repeats
              Card {
                width: parent.width
                height: repCol.height + 24

                Column {
                  id: repCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: 12
                  spacing: 4

                  Text {
                    text: "REPEATS (" + appWindow.repeats.length + ")"
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1.2
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: appWindow.repeats

                    Row {
                      required property var modelData
                      required property int index
                      width: parent.width
                      spacing: 8

                      Text {
                        width: 260
                        text: sanitize(modelData.label) + "  · " + sanitize(modelData.category)
                        color: appWindow.fg
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 130
                        text: {
                          var f = modelData.frequency
                          var st = modelData.subType
                          var txt = f
                          if (f === "monthly" && st === "last-working-day") txt = "monthly · last working day"
                          else if (f === "monthly" && st.indexOf("day-") === 0) txt = "monthly · day " + st.substring(4)
                          else if (f === "weekly") txt = "weekly · " + st
                          else if (f === "annually") txt = "annually · " + st
                          return txt
                        }
                        color: appWindow.dim
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 90
                        text: (modelData.direction === "income" ? "+" : "-") + appWindow.fmtMoney(modelData.amount)
                        color: modelData.direction === "income" ? appWindow.green : appWindow.red
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 100
                        text: modelData.nextDate ? appWindow.fmtDateUK(modelData.nextDate) : "—"
                        color: appWindow.dim
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }

                      Row {
                        spacing: 4
                        PillButton {
                          text: "Edit"
                          enabled: !appWindow.mutationsBusy
                          onClicked: repeatEditor.openFor(modelData)
                        }
                        PillButton {
                          text: "Delete"
                          enabled: !appWindow.mutationsBusy
                          onClicked: appWindow.deleteRepeat(modelData.id)
                        }
                      }
                    }
                  }

                  Text {
                    visible: appWindow.repeats.length === 0
                    text: "No repeats yet — rent, salary, subscriptions belong here."
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    textFormat: Text.PlainText
                  }
                }
              }

              // one-off transfers
              Card {
                width: parent.width
                height: trCol.height + 24

                Column {
                  id: trCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: 12
                  spacing: 4

                  Text {
                    text: "ONE-OFF TRANSFERS (" + appWindow.transfers.length + ")"
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1.2
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: appWindow.transfers

                    Row {
                      required property var modelData
                      required property int index
                      width: parent.width
                      spacing: 8

                      Text {
                        width: 66
                        text: appWindow.fmtDateUK(modelData.date)
                        color: appWindow.dim
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: parent.width - 66 - 90 - 120
                        text: sanitize(modelData.fromName) + " → " + sanitize(modelData.toName) + (modelData.label ? "  · " + sanitize(modelData.label) : "")
                        color: appWindow.fg
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 90
                        text: appWindow.fmtMoney(modelData.amount)
                        color: appWindow.accent
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        textFormat: Text.PlainText
                      }

                      Row {
                        width: 120
                        spacing: 4
                        PillButton {
                          text: "Delete"
                          enabled: !appWindow.mutationsBusy
                          onClicked: appWindow.deleteTransfer(modelData.id)
                        }
                      }
                    }
                  }

                  Text {
                    visible: appWindow.transfers.length === 0
                    text: "No one-off transfers yet."
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    textFormat: Text.PlainText
                  }
                }
              }

              // recurring transfers
              Card {
                width: parent.width
                height: trefCol.height + 24

                Column {
                  id: trefCol
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: 12
                  spacing: 4

                  Text {
                    text: "RECURRING TRANSFERS (" + appWindow.transferRepeats.length + ")"
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    font.bold: true
                    font.letterSpacing: 1.2
                    textFormat: Text.PlainText
                  }

                  Repeater {
                    model: appWindow.transferRepeats

                    Row {
                      required property var modelData
                      required property int index
                      width: parent.width
                      spacing: 8

                      Text {
                        width: 220
                        text: sanitize(modelData.fromName) + " → " + sanitize(modelData.toName) + (modelData.label ? "  · " + sanitize(modelData.label) : "")
                        color: appWindow.fg
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 110
                        text: {
                          var f = modelData.frequency
                          var st = modelData.subType
                          var txt = f
                          if (f === "monthly" && st === "last-working-day") txt = "monthly · last working day"
                          else if (f === "monthly" && st.indexOf("day-") === 0) txt = "monthly · day " + st.substring(4)
                          else if (f === "weekly") txt = "weekly · " + st
                          return txt
                        }
                        color: appWindow.dim
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }

                      Text {
                        width: 90
                        text: appWindow.fmtMoney(modelData.amount)
                        color: appWindow.accent
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        textFormat: Text.PlainText
                      }

                      Row {
                        spacing: 4
                        PillButton { text: "Delete"; enabled: !appWindow.mutationsBusy; onClicked: appWindow.deleteTref(modelData.id) }
                      }
                    }
                  }

                  Text {
                    visible: appWindow.transferRepeats.length === 0
                    text: "No recurring transfers yet."
                    color: appWindow.dim
                    font.family: appWindow.fontFamily
                    font.pixelSize: 11
                    textFormat: Text.PlainText
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // ── EDITORS ──────────────────────────────────────────────────────────
  // Transaction editor (add/edit ad-hoc)
  Popup {
    id: txEditor
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: 420
    height: 470
    modal: true
    background: Rectangle { color: appWindow.card; radius: 10; border.color: appWindow.border }

    property var editing: null
    property string categoryId: ""
    property string accountId: ""
    readonly property bool isIncome: directionBox.currentIndex === 1

    function openFor(tx) {
      editing = tx
      open()
      if (tx) {
        titleLabel.text = "Edit transaction"
        labelField.text = String(tx.label || "")
        amountField.text = String(tx.amount || "")
        dateField.text = String(tx.date || "")
        directionBox.currentIndex = tx.direction === "income" ? 1 : 0
        accountId = String(tx.accountId || "")
      } else {
        titleLabel.text = "Add transaction"
        labelField.text = ""
        amountField.text = ""
        dateField.text = appWindow.todayISO()
        directionBox.currentIndex = 0
        accountId = ""
      }
      // resolve category id from stored name (category models are name-keyed)
      categoryId = tx ? String(tx.categoryId || "") : ""
      catBox.refreshModel()
      open()
      labelField.forceActiveFocus()
    }

    Column {
      anchors.fill: parent
      anchors.margins: 14
      spacing: 8

      Text {
        id: titleLabel
        text: "Add transaction"
        color: appWindow.fg
        font.family: appWindow.fontFamily
        font.pixelSize: 15
        font.bold: true
        textFormat: Text.PlainText
      }

      Text { text: "DESCRIPTION"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
      FieldInput { id: labelField; width: parent.width; placeholderText: "e.g. Tesco shop" }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "AMOUNT"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          Row {
            spacing: 6
            Text { text: appWindow.currencySymbol; color: appWindow.fg; font.family: appWindow.fontFamily; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText }
            FieldInput { id: amountField; width: 120; placeholderText: "0.00" }
          }
        }
        Column {
          spacing: 4
          Text { text: "DIRECTION"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox { id: directionBox; width: 130; model: ["Money out", "Money in"] }
        }
      }

      Text { text: "CATEGORY"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
      ComboBox {
        id: catBox
        width: parent.width
        model: appWindow.categoryNames("expense")
        onActivated: function(idx) { txEditor.categoryId = String(appWindow.categoryIdAt(catBox.model, idx)) }

        function refreshModel() {
          var kind = txEditor.isIncome ? "income" : "expense"
          model = appWindow.categoryNames(kind)
          // preselect: editing → saved category; new → first of kind
          var want = String(txEditor.categoryId)
          var idx = 0
          for (var i = 0; i < model.length; i++) {
            if (String(appWindow.categoryIdAt(model, i)) === want) { idx = i; break }
          }
          currentIndex = idx
          txEditor.categoryId = String(appWindow.categoryIdAt(model, currentIndex))
        }
      }

      Text { text: "DATE"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
      FieldInput { id: dateField; width: parent.width; placeholderText: appWindow.todayISO() }

      Row {
        anchors.right: parent.right
        spacing: 8

        PillButton {
          text: "Cancel"
          onClicked: txEditor.close()
        }
        PillButton {
          text: txEditor.editing ? "Save" : "Add"
          enabled: !appWindow.mutationsBusy && labelField.text.trim() !== "" && amountField.text !== "" && dateField.text.trim() !== ""
          onClicked: {
            appWindow.saveAdhoc(txEditor.editing ? txEditor.editing.id : null, {
              label: labelField.text,
              amount: Number(amountField.text),
              direction: txEditor.isIncome ? "income" : "expense",
              date: dateField.text.trim(),
              categoryId: txEditor.categoryId,
              accountId: txEditor.accountId
            })
            txEditor.close()
          }
        }
      }
    }
  }

  // Repeat editor (add/edit recurring items)
  Popup {
    id: repeatEditor
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: 440
    height: 540
    modal: true
    background: Rectangle { color: appWindow.card; radius: 10; border.color: appWindow.border }

    property var editing: null
    property string categoryId: ""
    property string accountId: ""

    function openFor(r) {
      editing = r
      if (r) {
        titleLabel2.text = "Edit repeat"
        rLabelField.text = String(r.label || "")
        rAmountField.text = String(r.amount || "")
        rStartField.text = String(r.startDate || "")
        rEndField.text = String(r.endDate || "")
        rNeverBox.checked = r.neverExpires === true
        rDirectionBox.currentIndex = r.direction === "income" ? 1 : 0
        rFreqBox.setFor(String(r.frequency || "monthly"))
        rSubField.text = String(r.subType || "")
        categoryId = String(r.categoryId || "")
        accountId = String(r.accountId || "")
      } else {
        titleLabel2.text = "Add repeat"
        rLabelField.text = ""
        rAmountField.text = ""
        rStartField.text = appWindow.todayISO()
        rEndField.text = ""
        rNeverBox.checked = true
        rDirectionBox.currentIndex = 0
        rFreqBox.setFor("monthly")
        rSubField.text = ""
        categoryId = ""
        accountId = ""
      }
      catBox2.refreshModel()
      open()
      rLabelField.forceActiveFocus()
    }

    Column {
      anchors.fill: parent
      anchors.margins: 14
      spacing: 7

      Text {
        id: titleLabel2
        text: "Add repeat"
        color: appWindow.fg
        font.family: appWindow.fontFamily
        font.pixelSize: 15
        font.bold: true
        textFormat: Text.PlainText
      }

      Text { text: "DESCRIPTION"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
      FieldInput { id: rLabelField; width: parent.width; placeholderText: "e.g. Rent" }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "AMOUNT"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          Row {
            spacing: 6
            Text { text: appWindow.currencySymbol; color: appWindow.fg; font.family: appWindow.fontFamily; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText }
            FieldInput { id: rAmountField; width: 110; placeholderText: "0.00" }
          }
        }
        Column {
          spacing: 4
          Text { text: "DIRECTION"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox { id: rDirectionBox; width: 130; model: ["Money out", "Money in"] }
        }
      }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "FREQUENCY"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox {
            id: rFreqBox
            width: 150
            model: ["daily", "weekly", "monthly", "annually"]

            function setFor(f) {
              var i = model.indexOf(f)
              currentIndex = i >= 0 ? i : 2
            }
          }
        }
        Column {
          spacing: 4
          Text { text: "DETAIL (weekday / day-N / MM-DD)"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: rSubField; width: 180; placeholderText: "mon · day-1 · 12-25 · leave blank" }
        }
      }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "START DATE"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: rStartField; width: 130; placeholderText: appWindow.todayISO() }
        }
        Column {
          spacing: 4
          Text { text: "END DATE (optional)"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: rEndField; width: 130; placeholderText: "never expires" }
        }
      }

      CheckBox {
        id: rNeverBox
        text: "Never expires"
        checked: true
        contentItem: Text { text: rNeverBox.text; color: appWindow.fg; font.family: appWindow.fontFamily; font.pixelSize: 12; verticalAlignment: Text.AlignVCenter; textFormat: Text.PlainText }
      }

      Text { text: "CATEGORY"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
      ComboBox {
        id: catBox2
        width: parent.width
        model: appWindow.categoryNames("expense")
        onActivated: function(idx) { repeatEditor.categoryId = String(appWindow.categoryIdAt(catBox2.model, idx)) }

        function refreshModel() {
          var kind = rDirectionBox.currentIndex === 1 ? "income" : "expense"
          model = appWindow.categoryNames(kind)
          var want = String(repeatEditor.categoryId)
          var idx = 0
          for (var i = 0; i < model.length; i++) {
            if (String(appWindow.categoryIdAt(model, i)) === want) { idx = i; break }
          }
          currentIndex = idx
          repeatEditor.categoryId = String(appWindow.categoryIdAt(model, currentIndex))
        }
      }

      Row {
        anchors.right: parent.right
        spacing: 8

        PillButton {
          text: "Cancel"
          onClicked: repeatEditor.close()
        }
        PillButton {
          text: repeatEditor.editing ? "Save" : "Add"
          enabled: !appWindow.mutationsBusy && rLabelField.text.trim() !== "" && rAmountField.text !== "" && rStartField.text.trim() !== ""
          onClicked: {
            var ne = rNeverBox.checked
            appWindow.saveRepeat(repeatEditor.editing ? repeatEditor.editing.id : null, {
              label: rLabelField.text,
              amount: Number(rAmountField.text),
              direction: rDirectionBox.currentIndex === 1 ? "income" : "expense",
              frequency: rFreqBox.currentText,
              subType: rSubField.text.trim(),
              startDate: rStartField.text.trim(),
              endDate: ne ? "" : rEndField.text.trim(),
              neverExpires: ne,
              categoryId: repeatEditor.categoryId,
              accountId: repeatEditor.accountId
            })
            repeatEditor.close()
          }
        }
      }
    }
  }

  // Transfer editor — one-off or recurring (toggle)
  Popup {
    id: transferEditor
    parent: Overlay.overlay
    anchors.centerIn: parent
    width: 420
    height: recurring ? 480 : 400
    modal: true
    background: Rectangle { color: appWindow.card; radius: 10; border.color: appWindow.border }

    property bool recurring: false
    function openFor() { recurring = false; tLabelField.text = ""; tAmountField.text = ""; tDateField.text = appWindow.todayISO(); open() }
    function openForRecurring() {
      recurring = true
      tLabelField.text = ""; tAmountField.text = ""
      tDateField.text = appWindow.todayISO(); tEndField.text = ""
      open()
    }

    Column {
      anchors.fill: parent
      anchors.margins: 14
      spacing: 8

      Text {
        id: transferTitle
        text: transferEditor.recurring ? "Add recurring transfer" : "Add one-off transfer"
        color: appWindow.fg
        font.family: appWindow.fontFamily
        font.pixelSize: 15
        font.bold: true
        textFormat: Text.PlainText
      }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "FROM"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox {
            id: fromBox2
            width: 180
            textRole: "name"
            model: appWindow.accounts
          }
        }
        Column {
          spacing: 4
          Text { text: "TO"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox {
            id: toBox
            width: 180
            textRole: "name"
            model: appWindow.accounts
          }
        }
      }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: "AMOUNT"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          Row {
            spacing: 6
            Text { text: appWindow.currencySymbol; color: appWindow.fg; font.family: appWindow.fontFamily; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter; textFormat: Text.PlainText }
            FieldInput { id: tAmountField; width: 110; placeholderText: "0.00" }
          }
        }
        Column {
          spacing: 4
          Text { text: "LABEL (optional)"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: tLabelField; width: 180; placeholderText: "e.g. monthly save" }
        }
      }

      Row {
        visible: transferEditor.recurring
        spacing: 8
        Column {
          spacing: 4
          Text { text: "FREQUENCY"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          ComboBox { id: tFreqBox; width: 150; model: ["daily", "weekly", "monthly", "annually"] }
        }
        Column {
          spacing: 4
          Text { text: "DETAIL"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: tSubField; width: 150; placeholderText: "mon · day-1 · blank ok" }
        }
      }

      Row {
        spacing: 8
        Column {
          spacing: 4
          Text { text: transferEditor.recurring ? "START DATE" : "DATE"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: tDateField; width: 130; placeholderText: appWindow.todayISO() }
        }
        Column {
          visible: transferEditor.recurring && !tNeverBox.checked
          spacing: 4
          Text { text: "END (optional)"; color: appWindow.dim; font.family: appWindow.fontFamily; font.pixelSize: 9; font.bold: true; textFormat: Text.PlainText }
          FieldInput { id: tEndField; width: 130; placeholderText: "never expires" }
        }
        Column {
          visible: transferEditor.recurring
          CheckBox {
            id: tNeverBox
            checked: true
            contentItem: Text { text: "Never ends"; color: appWindow.fg; font.family: appWindow.fontFamily; font.pixelSize: 12; textFormat: Text.PlainText }
          }
        }
      }

      Row {
        anchors.right: parent.right
        spacing: 8

        PillButton {
          text: "Cancel"
          onClicked: transferEditor.close()
        }
        PillButton {
          text: "Add"
          enabled: !appWindow.mutationsBusy && tAmountField.text !== "" && tDateField.text.trim() !== "" &&
                   appWindow.accounts.length >= 2
          onClicked: {
            var from = appWindow.accounts[fromBox2.currentIndex]
            var to = appWindow.accounts[toBox.currentIndex]
            if (!from || !to || from.id === to.id) { appWindow.flash("Choose two different accounts"); return }
            if (transferEditor.recurring) {
              var ne = tNeverBox.checked
              appWindow.addTref({
                from: from.id, to: to.id,
                amount: Number(tAmountField.text),
                label: tLabelField.text,
                frequency: tFreqBox.currentText,
                subType: tSubField.text.trim(),
                startDate: tDateField.text.trim(),
                endDate: ne ? "" : tEndField.text.trim(),
                neverExpires: ne
              })
            } else {
              appWindow.addTransfer({
                from: from.id, to: to.id,
                amount: Number(tAmountField.text),
                label: tLabelField.text,
                date: tDateField.text.trim()
              })
            }
            transferEditor.close()
          }
        }
      }
    }
  }

  // ── chart painter ────────────────────────────────────────────────────
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

        // grid + axis labels
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
          ctx.fillText(appWindow._group(String(Math.round(gv))), 4, gy + 4)
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
        for (var m = 1; m < m + 1 && m < pts.length; m++) ctx.lineTo(x(m), y(pts[m].balance))
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
      ctx.fillText(appWindow._group(String(Math.round(maxBar))), 4, padT + 4)
      ctx.fillText(appWindow._group(String(Math.round(maxBar / 2))), 4, padT + H / 2 + 4)
    }
  }
}
