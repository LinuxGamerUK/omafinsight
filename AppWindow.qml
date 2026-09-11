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
    if (u === "") u = "https://finsight.cresta.digital"
    if (u.indexOf("http") !== 0) u = "https://" + u
    while (u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    // structural validation: https/http only, then a host[:port][/path] with
    // characters safe for both URLs and shell embedding. Reject anything else.
    if (!/^https:\/\/[^'"\\\s;$&|<>`(){}!*?\[\]^~]+(\/[^'"\\\s;$&|<>`(){}!*?\[\]^~]*)?$/.test(u)
        && !/^http:\/\/[^'"\\\s;$&|<>`(){}!*?\[\]^~]+(\/[^'"\\\s;$&|<>`(){}!*?\[\]^~]*)?$/.test(u))
      return "https://finsight.cresta.digital"
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
  color: cBg
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
    environment: appWindow.procEnv
    property string buffer: ""
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "test -f \"$__OMAFIN_SESSION_FILE__\" || exit 9; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\") || exit 9; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 9; " +
      "/usr/bin/curl -sS -b \"$__OMAFIN_SESSION_FILE__\" --connect-timeout 5 --max-time 8 " +
      "\"$__OMAFIN_URL__/api/profile\" 2>&1 | /usr/bin/head -c 4000"]
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
    // the full body is escaped here by JSON.stringify and travels over stdin;
    // nothing user-controlled ever enters the command array.
    _authBody = JSON.stringify({ email: e, password: p })
    loginProc.running = true
    loginWatchdog.restart()
  }

  property string _authBody: ""

  // Environment for all subprocesses. Every value is QML-generated:
  // baseUrl passes structural validation (no quotes/whitespace/shell metas),
  // sessionFile/sessionDir are derived from it inside the state directory.
  property var procEnv: ({
    "__OMAFIN_URL__": baseUrl,
    "__OMAFIN_SESSION_FILE__": sessionFile,
    "__OMAFIN_SESSION_DIR__": sessionSvc.sessionDirFor(baseUrl)
  })

  Process {
    id: loginProc
    running: false
    property string buffer: ""
    stdinEnabled: true
    // argv is fully static: no user data is interpolated into shell source.
    // The complete JSON body (including the password, escaped by JSON.stringify)
    // arrives over stdin between sentinel markers and is written by bash itself.
    environment: appWindow.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "12", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "/usr/bin/mkdir -p \"$__OMAFIN_SESSION_DIR__\" && /usr/bin/chmod 700 \"$__OMAFIN_SESSION_DIR__\" || exit 1; " +
      "_rd=$(/usr/bin/realpath \"$__OMAFIN_SESSION_DIR__\") || exit 1; " +
      "_di=$(/usr/bin/stat -c '%F:%u:%a' \"$_rd\") || exit 1; " +
      "[ \"$_di\" = \"directory:$EUID:700\" ] || exit 1; " +
      "_t=$(/usr/bin/mktemp -d \"$_rd/auth.XXXXXX\") || exit 1; " +
      "trap '/usr/bin/rm -rf \"$_t\"' EXIT; " +
      "_f=\"$_t/body\"; _j=\"$_t/jar\"; " +
      "while IFS= read -r _l; do [ \"$_l\" = __OMAFIN_EOF__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; " +
      "/usr/bin/chmod 600 \"$_f\"; " +
      "code=$(/usr/bin/curl -sS --connect-timeout 5 --max-time 10 -c \"$_j\" " +
      "-o \"$_t/out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" \"$__OMAFIN_URL__/api/auth/login\" 2>&1 | /usr/bin/head -c 8); " +
      "if [ \"$code\" = 200 ] && /usr/bin/chmod 600 \"$_j\" 2>/dev/null && /usr/bin/test \"$(/usr/bin/stat -c '%F:%u:%a:%h' \"$_j\" 2>/dev/null)\" = \"regular file:$EUID:600:1\"; then " +
      "/usr/bin/mv -f \"$_j\" \"$__OMAFIN_SESSION_FILE__\"; fi; " +
      "/usr/bin/cat \"$_t/out\" 2>/dev/null | /usr/bin/head -c 4000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: {
      write(_authBody + '\n__OMAFIN_EOF__\n')
      _authBody = ""
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
    _authBody = JSON.stringify({ name: n, email: e, password: p, currency: String(currency || "GBP") })
    registerProc.running = true
    registerWatchdog.restart()
  }

  Process {
    id: registerProc
    running: false
    property string buffer: ""
    stdinEnabled: true
    environment: appWindow.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "12", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "/usr/bin/mkdir -p \"$__OMAFIN_SESSION_DIR__\" && /usr/bin/chmod 700 \"$__OMAFIN_SESSION_DIR__\" || exit 1; " +
      "_rd=$(/usr/bin/realpath \"$__OMAFIN_SESSION_DIR__\") || exit 1; " +
      "_di=$(/usr/bin/stat -c '%F:%u:%a' \"$_rd\") || exit 1; " +
      "[ \"$_di\" = \"directory:$EUID:700\" ] || exit 1; " +
      "_t=$(/usr/bin/mktemp -d \"$_rd/reg.XXXXXX\") || exit 1; " +
      "trap '/usr/bin/rm -rf \"$_t\"' EXIT; " +
      "_f=\"$_t/body\"; _j=\"$_t/jar\"; " +
      "while IFS= read -r _l; do [ \"$_l\" = __OMAFIN_EOF__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; " +
      "/usr/bin/chmod 600 \"$_f\"; " +
      "code=$(/usr/bin/curl -sS --connect-timeout 5 --max-time 10 -c \"$_j\" " +
      "-o \"$_t/out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" \"$__OMAFIN_URL__/api/auth/register\" 2>&1 | /usr/bin/head -c 8); " +
      "if [ \"$code\" = 200 ] && /usr/bin/chmod 600 \"$_j\" 2>/dev/null && /usr/bin/test \"$(/usr/bin/stat -c '%F:%u:%a:%h' \"$_j\" 2>/dev/null)\" = \"regular file:$EUID:600:1\"; then " +
      "/usr/bin/mv -f \"$_j\" \"$__OMAFIN_SESSION_FILE__\"; fi; " +
      "/usr/bin/cat \"$_t/out\" 2>/dev/null | /usr/bin/head -c 4000; printf '\\n__CODE__%s' \"$code\""]
    onStarted: {
      write(_authBody + '\n__OMAFIN_EOF__\n')
      _authBody = ""
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
    environment: appWindow.procEnv
    property string body: ""
    property string buffer: ""
    stdinEnabled: true
    command: ["/usr/bin/timeout", "-k", "2", "12", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null) || exit 1; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 1; " +
      "_t=$(/usr/bin/mktemp -d \"$__OMAFIN_WORK_DIR__/onb.XXXXXX\") || exit 1; " +
      "trap '/usr/bin/rm -rf \"$_t\"' EXIT; " +
      "_f=\"$_t/body\"; " +
      "while IFS= read -r _l; do [ \"$_l\" = __EOFMUT__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; " +
      "/usr/bin/chmod 600 \"$_f\"; " +
      "code=$(/usr/bin/curl -sS --connect-timeout 5 --max-time 10 -b \"$__OMAFIN_SESSION_FILE__\" " +
      "-o \"$_t/out\" -w '%{http_code}' -H 'Content-Type: application/json' " +
      "--data @\"$_f\" \"$__OMAFIN_URL__/api/onboarding\" 2>&1 | /usr/bin/head -c 8); " +
      "/usr/bin/cat \"$_t/out\" 2>/dev/null | /usr/bin/head -c 2000; printf '\\n__CODE__%s' \"$code\""]
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

  property int _cycle: 0

  function refresh() {
    // re-arm even if a previous cycle stalled: kill in-flight procs and bump
    // the cycle token so stale exit handlers can't decrement the new round.
    _cycle = _cycle + 1
    dashProc.running = false
    chartProc.running = false
    listsProc.running = false
    busy = true
    lastError = ""
    _outstanding = 3
    var myCycle = _cycle
    procEnv = ({
      "__OMAFIN_URL__": baseUrl,
      "__OMAFIN_SESSION_FILE__": sessionFile,
      "__OMAFIN_SESSION_DIR__": sessionSvc.sessionDirFor(baseUrl),
      "__OMAFIN_WORK_DIR__": sessionSvc.sessionDirFor(baseUrl),
      "__OMAFIN_FETCH_URL__": baseUrl + "/api/dashboard" + (scope === "all" ? "?account=all" : ""),
      "__OMAFIN_CHART_URL__": baseUrl + "/api/chart?days=" + chartDays + "&back=30" + (scope === "all" ? "&account=all" : "")
    })
    dashProc.fetchCycle = myCycle
    chartProc.fetchCycle = myCycle
    listsProc.fetchCycle = myCycle
    dashProc.running = true
    chartProc.running = true
    listsProc.running = true
    dashWatchdog.restart()
    chartWatchdog.restart()
    listsWatchdog.restart()
  }

  function currentCycle() { return _cycle }

  function _finish(ok, errMsg) {
    if (_outstanding <= 0) return   // stale exit from an aborted cycle
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
    environment: appWindow.procEnv
    property string url: ""
    property int fetchCycle: 0
    property string buffer: ""
    command: ["/usr/bin/timeout", "-k", "2", "12", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null) || exit 0; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 0; " +
      "/usr/bin/curl -sS -b \"$__OMAFIN_SESSION_FILE__\" " +
      "--connect-timeout 5 --max-time 10 \"$__OMAFIN_FETCH_URL__\" 2>&1 | /usr/bin/head -c 400000"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (dashProc.buffer.length + s.length <= 400000) dashProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      dashWatchdog.stop()
      dashProc.running = false
      var buf = dashProc.buffer
      dashProc.buffer = ""
      if (dashProc.fetchCycle !== currentCycle()) return
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
    environment: appWindow.procEnv
    property string url: ""
    property int fetchCycle: 0
    property string buffer: ""
    command: ["/usr/bin/timeout", "-k", "2", "12", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null) || exit 0; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 0; " +
      "/usr/bin/curl -sS -b \"$__OMAFIN_SESSION_FILE__\" " +
      "--connect-timeout 5 --max-time 10 \"$__OMAFIN_CHART_URL__\" 2>&1 | /usr/bin/head -c 400000"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (chartProc.buffer.length + s.length <= 400000) chartProc.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      chartWatchdog.stop()
      chartProc.running = false
      var buf = chartProc.buffer
      chartProc.buffer = ""
      if (chartProc.fetchCycle !== currentCycle()) return
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
    environment: appWindow.procEnv
    property int fetchCycle: 0
    property string buffer: ""
    command: ["/usr/bin/timeout", "-k", "2", "20", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null) || exit 0; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 0; " +
      "emit() { echo \"__$1__\"; /usr/bin/curl -sS -b \"$__OMAFIN_SESSION_FILE__\" --connect-timeout 5 --max-time 8 \"$__OMAFIN_URL__/api/$2\" 2>&1 | /usr/bin/head -c " + appWindow.capSection + "; echo; }; " +
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
      if (listsProc.fetchCycle !== currentCycle()) return
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
    environment: appWindow.procEnv
    property string bodyJson: ""
    property bool hasBodyFlag: false
    property string method: "POST"
    property string path: ""
    property string buffer: ""
    stdinEnabled: true
    command: ["/usr/bin/timeout", "-k", "2", "15", "/usr/bin/bash", "-c",
      "set -o pipefail; " +
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null) || exit 1; " +
      "[ \"$_s\" = \"regular file:$EUID:600:1\" ] || exit 1; " +
      "_t=$(/usr/bin/mktemp -d \"$__OMAFIN_WORK_DIR__/mut.XXXXXX\") || exit 1; " +
      "trap '/usr/bin/rm -rf \"$_t\"' EXIT; " +
      "_f=\"$_t/body\"; " +
      (hasBodyFlag ? "while IFS= read -r _l; do [ \"$_l\" = __EOFMUT__ ] && break; printf '%s\\n' \"$_l\"; done > \"$_f\"; /usr/bin/chmod 600 \"$_f\"; " : "") +
      "code=$(/usr/bin/curl -sS --connect-timeout 5 --max-time 12 -b \"$__OMAFIN_SESSION_FILE__\" " +
      "-o \"$_t/out\" -w '%{http_code}' -X \"$__OMAFIN_METHOD__\" -H 'Content-Type: application/json' " +
      (hasBodyFlag ? "--data @\"$_f\" " : "") +
      "\"$__OMAFIN_URL__$__OMAFIN_PATH__\" 2>&1 | /usr/bin/head -c 8); " +
      "/usr/bin/cat \"$_t/out\" 2>/dev/null | /usr/bin/head -c 2000; printf '\\n__CODE__%s' \"$code\""]
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
    environment: appWindow.procEnv
    command: ["/usr/bin/timeout", "-k", "2", "10", "/usr/bin/bash", "-c",
      "_s=$(/usr/bin/stat -c '%F:%u:%a:%h' \"$__OMAFIN_SESSION_FILE__\" 2>/dev/null); " +
      "if [ \"$_s\" = \"regular file:$EUID:600:1\"; then " +
      "/usr/bin/curl -sS --connect-timeout 5 --max-time 8 -X POST -b \"$__OMAFIN_SESSION_FILE__\" " +
      "\"$__OMAFIN_URL__/api/auth/logout\" >/dev/null 2>&1; fi; " +
      "/usr/bin/rm -f \"$__OMAFIN_SESSION_FILE__\""]
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
  // ── M3 components ────────────────────────────────────────────────────
  component Card: Rectangle {
    color: appWindow.cSurface
    radius: 14
    border.color: appWindow.cOutline
  }

  component PillButton: Button {
    id: pb
    height: 32
    leftPadding: 12
    rightPadding: 12
    contentItem: Text {
      text: pb.text
      color: pb.enabled ? appWindow.cOnSurface : appWindow.cOnVar
      font.family: appWindow.fontFamily
      font.pixelSize: 11
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
    }
    background: Rectangle {
      radius: 16
      color: pb.down ? appWindow.cPrimary : (pb.hovered ? appWindow.cSurfaceHi : appWindow.cSurface)
      border.color: pb.down ? appWindow.cPrimary : appWindow.cOutline
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  // UI — Material You tonal surfaces on a deep-navy terminal canvas
  // ═════════════════════════════════════════════════════════════════════

  // ── M3-derived palette (tonal surfaces on #0b0e1a) ───────────────────
  readonly property color cBg: "#0b0e1a"
  readonly property color cSurface: "#141a2e"        // surface-container
  readonly property color cSurfaceHi: "#1c2340"      // surface-container-high
  readonly property color cSurfaceLo: "#101527"      // surface-container-low (sidebar)
  readonly property color cOutline: "#2c3352"
  readonly property color cOutlineVar: "#232a45"
  readonly property color cPrimary: "#a5c8ff"        // M3 primary (tonal blue)
  readonly property color cOnPrimary: "#0a2c6b"
  readonly property color cPrimaryDim: "#4a6db5"
  readonly property color cSecondary: "#7fd0c9"      // teal accent
  readonly property color cTertiary: "#c9a5ff"       // violet accent
  readonly property color cGreen: "#8fd6a0"
  readonly property color cRed: "#f0989c"
  readonly property color cOrange: "#f5b57f"
  readonly property color cOnSurface: "#e4e6f5"
  readonly property color cOnVar: "#9aa3c7"          // on-surface-variant
  readonly property color cInputBg: "#0d1224"
  readonly property color cPrimaryContainer: "#1b2a4a"

  // ── derived analytics (pure functions of loaded data) ────────────────
  function monthKey(iso) { return String(iso || "").substring(0, 7) }

  function thisMonthKey() {
    var d = new Date()
    return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0")
  }

  // adhoc spend per category this month (expenses only)
  function categorySpend() {
    var mk = thisMonthKey()
    var out = {}
    for (var i = 0; i < adhocs.length; i++) {
      var a = adhocs[i]
      if (monthKey(a.date) !== mk) continue
      if (a.direction !== "expense") continue
      var k = String(a.category || "Uncategorised")
      out[k] = (out[k] || 0) + Math.abs(Number(a.amount) || 0)
    }
    // merge repeat amounts (monthly ×1 as committed spend)
    for (var j = 0; j < repeats.length; j++) {
      var r = repeats[j]
      if (r.direction !== "expense") continue
      var k2 = String(r.category || "Uncategorised")
      out[k2] = (out[k2] || 0) + Math.abs(Number(r.amount) || 0)
    }
    var arr = []
    for (var name in out) arr.push({ name: name, spend: out[name] })
    arr.sort(function(a, b) { return b.spend - a.spend })
    return arr.slice(0, 6)
  }

  // month totals from adhocs (last 6 months): {in, out}
  function monthTotals(offset) {
    var d = new Date()
    d.setMonth(d.getMonth() - offset)
    var mk = d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0")
    var t = { in: 0, out: 0 }
    for (var i = 0; i < adhocs.length; i++) {
      var a = adhocs[i]
      if (monthKey(a.date) !== mk) continue
      if (a.direction === "income") t.in += Math.abs(Number(a.amount) || 0)
      else t.out += Math.abs(Number(a.amount) || 0)
    }
    return t
  }

  function cashflowSeries() {
    var out = []
    for (var i = 5; i >= 0; i--) {
      var t = monthTotals(i)
      var d = new Date()
      d.setMonth(d.getMonth() - i)
      var names = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
      out.push({ label: names[d.getMonth()], in: t.in, out: t.out, net: t.in - t.out })
    }
    return out
  }

  // savings rate this month: (in - out) / in
  function savingsRate() {
    var t = monthTotals(0)
    if (t.in <= 0) return 0
    return Math.max(0, Math.round((t.in - t.out) / t.in * 100))
  }

  function monthOutTotal() {
    return monthTotals(0).out
  }

  function sparklinePoints() {
    // balance history from chart series (back 30 days)
    var pts = []
    for (var i = 0; i < series.length; i++) {
      if (series[i].balance === series[i].balance) pts.push(series[i].balance)
    }
    return pts.slice(-30)
  }

  function totalCash() {
    var sum = 0
    if (scope === "all" || !dash) {
      for (var i = 0; i < accounts.length; i++) {
        var b = accounts[i].balanceNow
        if (b === b && b > 0) sum += b
      }
      return sum
    }
    return dash && dash.summary ? dash.summary.expectedToday : NaN
  }

  function recentAdhocs() {
    return adhocs.slice(0, 6)
  }

  function upcomingBills() {
    var out = []
    var src = dash && dash.upcoming ? dash.upcoming : []
    for (var i = 0; i < src.length && out.length < 5; i++) {
      if (src[i].amount < 0) out.push(src[i])
    }
    return out
  }

  function nextPayday() {
    for (var i = 0; i < repeats.length; i++) {
      if (repeats[i].direction === "income" && repeats[i].nextDate) return repeats[i]
    }
    return null
  }

  readonly property var cashflow: cashflowSeries()
  readonly property var catSpend: categorySpend()
  readonly property int savRate: savingsRate()
  readonly property real monthOut: monthOutTotal()
  readonly property var sparkPts: sparklinePoints()

  // ── reusable components ──────────────────────────────────────────────
  component NavItem: Rectangle {
    id: navItem
    property string iconGlyph: ""
    property string label: ""
    property int idx: 0
    readonly property bool active: appWindow.navPage === idx
    width: parent ? parent.width - 20 : 200
    height: 44
    radius: 22
    color: active ? appWindow.cPrimaryContainer : (navMa.containsMouse ? appWindow.cSurfaceHi : "transparent")
    border.color: active ? appWindow.cPrimaryDim : "transparent"

    Row {
      anchors.left: parent.left
      anchors.leftMargin: 18
      anchors.verticalCenter: parent.verticalCenter
      spacing: 12

      Text {
        text: navItem.iconGlyph
        color: navItem.active ? appWindow.cPrimary : appWindow.cOnVar
        font.family: appWindow.fontFamily
        font.pixelSize: 15
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        text: navItem.label
        color: navItem.active ? appWindow.cOnSurface : appWindow.cOnVar
        font.family: appWindow.fontFamily
        font.pixelSize: 13
        font.bold: navItem.active
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: navMa
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: appWindow.navPage = navItem.idx
    }
  }

  component KpiCard: Rectangle {
    id: kpiCard
    property string title: ""
    property string bigValue: ""
    property string subLine: ""
    property color subColor: appWindow.cGreen
    property bool showSpark: false

    color: appWindow.cSurface
    radius: 14
    border.color: appWindow.cOutlineVar
    height: 118

    Column {
      anchors.fill: parent
      anchors.margins: 16
      spacing: 6

      Text {
        text: kpiCard.title
        color: appWindow.cOnVar
        font.family: appWindow.fontFamily
        font.pixelSize: 10
        font.letterSpacing: 1.4
        font.bold: true
        textFormat: Text.PlainText
      }

      Row {
        width: parent.width
        spacing: 10

        Text {
          text: kpiCard.bigValue
          color: appWindow.cOnSurface
          font.family: appWindow.fontFamily
          font.pixelSize: 26
          font.bold: true
          textFormat: Text.PlainText
        }

        Item { width: 8; height: 1 }

        MiniSparkline {
          width: Math.min(160, parent.width - 160)
          height: 34
          pts: kpiCard.showSpark ? appWindow.sparkPts : []
          visible: kpiCard.showSpark && appWindow.sparkPts.length > 2
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        text: kpiCard.subLine
        color: kpiCard.subColor
        font.family: appWindow.fontFamily
        font.pixelSize: 11
        textFormat: Text.PlainText
      }
    }
  }

  component MiniSparkline: Canvas {
    id: spark
    property var pts: []
    onPtsChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (pts.length < 2) return
      var min = Infinity, max = -Infinity
      for (var i = 0; i < pts.length; i++) {
        if (pts[i] < min) min = pts[i]
        if (pts[i] > max) max = pts[i]
      }
      if (max === min) max = min + 1
      ctx.strokeStyle = appWindow.cPrimary
      ctx.lineWidth = 1.5
      ctx.beginPath()
      for (var j = 0; j < pts.length; j++) {
        var x = (j / (pts.length - 1)) * width
        var y = height - ((pts[j] - min) / (max - min)) * (height - 4) - 2
        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }
  }

  component SectionHeader: Row {
    property string title: ""
    spacing: 8

    Text {
      text: sectionTitle()
      color: appWindow.cPrimary
      font.family: appWindow.fontFamily
      font.pixelSize: 12
      font.bold: true
      font.letterSpacing: 1.6
      textFormat: Text.PlainText

      function sectionTitle() { return title }
    }
  }

  component CatBar: Rectangle {
    id: catBar
    property string catName: ""
    property real spent: 0
    property color barColor: appWindow.cPrimary
    property string iconGlyph: ""

    color: appWindow.cSurfaceHi
    radius: 12
    border.color: appWindow.cOutlineVar
    height: 86

    readonly property real maxSpend: {
      var m = 0
      var arr = appWindow.catSpend
      for (var i = 0; i < arr.length; i++) if (arr[i].spend > m) m = arr[i].spend
      return m > 0 ? m : 1
    }
    readonly property real pct: Math.min(100, Math.round(spent / maxSpend * 100))

    Column {
      anchors.fill: parent
      anchors.margins: 12
      spacing: 6

      Row {
        width: parent.width
        spacing: 8

        Text {
          text: catBar.iconGlyph
          color: catBar.barColor
          font.family: appWindow.fontFamily
          font.pixelSize: 13
          textFormat: Text.PlainText
        }
        Text {
          width: parent.width - 40
          text: sanitize(catBar.catName)
          color: appWindow.cOnSurface
          font.family: appWindow.fontFamily
          font.pixelSize: 12
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }

      Text {
        text: appWindow.fmtMoney(spent, 0)
        color: appWindow.cOnSurface
        font.family: appWindow.fontFamily
        font.pixelSize: 15
        font.bold: true
        textFormat: Text.PlainText
      }

      Row {
        width: parent.width
        spacing: 6

        Rectangle {
          width: parent.width - 34
          height: 5
          radius: 3
          color: appWindow.cInputBg

          Rectangle {
            width: parent.width * catBar.pct / 100
            height: 5
            radius: 3
            color: catBar.barColor
          }
        }

        Text {
          text: catBar.pct + "%"
          color: appWindow.cOnVar
          font.family: appWindow.fontFamily
          font.pixelSize: 10
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
        }
      }
    }
  }

  component CashflowChart: Canvas {
    id: cfChart
    property var months: []
    property real padL: 42
    property real padB: 22
    property real padT: 10

    onMonthsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (months.length === 0) return
      var maxV = 1
      for (var i = 0; i < months.length; i++) {
        if (months[i].in > maxV) maxV = months[i].in
        if (months[i].out > maxV) maxV = months[i].out
      }
      maxV *= 1.1
      var H = height - padB - padT
      var W = width - padL - 8
      var group = W / months.length
      var bw = Math.max(6, group / 3.6)

      // gridlines
      ctx.strokeStyle = appWindow.cOutlineVar
      ctx.fillStyle = appWindow.cOnVar
      ctx.font = "9px sans-serif"
      for (var g = 0; g <= 3; g++) {
        var gy = padT + H - (H * g) / 3
        ctx.beginPath(); ctx.moveTo(padL, gy); ctx.lineTo(width - 8, gy); ctx.stroke()
        ctx.fillText(appWindow._group(String(Math.round(maxV * g / 3))), 2, gy + 3)
      }

      for (var m = 0; m < months.length; m++) {
        var gx = padL + m * group + group / 2
        // income bar (green)
        var inH = (months[m].in / maxV) * H
        ctx.fillStyle = appWindow.cGreen
        ctx.fillRect(gx - bw - 1, padT + H - inH, bw, inH)
        // expense bar (red)
        var outH = (months[m].out / maxV) * H
        ctx.fillStyle = appWindow.cRed
        ctx.fillRect(gx + 1, padT + H - outH, bw, outH)
        // label
        ctx.fillStyle = appWindow.cOnVar
        ctx.fillText(months[m].label, gx - 10, height - 6)
      }
    }
  }

  component CashflowLegend: Row {
    spacing: 14

    Repeater {
      model: [
        { label: "Income", c: appWindow.cGreen },
        { label: "Expenses", c: appWindow.cRed }
      ]
      Row {
        required property var modelData
        spacing: 5
        Rectangle { width: 10; height: 10; radius: 2; color: modelData.c; anchors.verticalCenter: parent.verticalCenter }
        Text { text: modelData.label; color: appWindow.cOnVar; font.family: appWindow.fontFamily; font.pixelSize: 10; textFormat: Text.PlainText; anchors.verticalCenter: parent.verticalCenter }
      }
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
      color: appWindow.cBg
      anchors.fill: parent

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: authCol.height + 60
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: authCol
          width: Math.min(520, parent.width - 48)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 44
          spacing: 14

          Row {
            spacing: 10
            anchors.horizontalCenter: parent.horizontalCenter

            Image {
              source: Qt.resolvedUrl("assets/logo.png")
              sourceSize: Qt.size(28, 28)
              width: 28; height: 28
              fillMode: Image.PreserveAspectFit
              mipmap: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "OmaFinSight"
              color: appWindow.cOnSurface
              font.family: appWindow.fontFamily
              font.pixelSize: 22
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
            color: appWindow.cOnVar
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
            height: 44
            placeholderText: "Your name"
            color: appWindow.cOnSurface
            placeholderTextColor: appWindow.cOnVar
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
            enabled: !appWindow.authBusy
          }

          TextField {
            id: emailField
            width: parent.width
            height: 44
            placeholderText: "Email address"
            color: appWindow.cOnSurface
            placeholderTextColor: appWindow.cOnVar
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
            enabled: !appWindow.authBusy
            Component.onCompleted: {
              if (!appWindow.regMode) forceActiveFocus()
              else Qt.callLater(function() { if (!nameField.activeFocus) nameField.forceActiveFocus() })
            }
          }

          TextField {
            id: passwordField
            width: parent.width
            height: 44
            placeholderText: appWindow.regMode ? "Password (min 8 characters)" : "Password"
            echoMode: TextInput.Password
            color: appWindow.cOnSurface
            placeholderTextColor: appWindow.cOnVar
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
            enabled: !appWindow.authBusy
          }

          ComboBox {
            id: currencyBox
            visible: appWindow.regMode
            width: 180
            height: 40
            model: ["GBP", "USD", "EUR", "JPY", "CNY", "INR", "AUD", "CAD", "CHF", "BRL"]
            enabled: !appWindow.authBusy
          }

          Button {
            id: goButton
            width: parent.width
            height: 46
            enabled: !appWindow.authBusy && emailField.text.trim() !== "" && passwordField.text !== "" &&
                     (!appWindow.regMode || nameField.text.trim() !== "")
            contentItem: Text {
              text: appWindow.authBusy ? "Working…" : (appWindow.regMode ? "Create account" : "Sign in")
              color: goButton.enabled ? appWindow.cOnPrimary : appWindow.cOnVar
              font.family: appWindow.fontFamily
              font.pixelSize: 13
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
              radius: 23
              color: goButton.enabled ? appWindow.cPrimary : appWindow.cSurfaceHi
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
            color: appWindow.cRed
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Text {
            text: appWindow.regMode ? "Already have an account? Sign in" : "New here? Create an account"
            color: appWindow.cPrimary
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
            text: "Your password is sent once over HTTPS and never stored — only the session cookie is kept, at ~/.local/state/omafinsight (0600)."
            color: appWindow.cOnVar
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
      color: appWindow.cBg
      anchors.fill: parent

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: onbCol.height + 60
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: onbCol
          width: Math.min(520, parent.width - 48)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          anchors.topMargin: 44
          spacing: 14

          Row {
            spacing: 10
            anchors.horizontalCenter: parent.horizontalCenter

            Image {
              source: Qt.resolvedUrl("assets/logo.png")
              sourceSize: Qt.size(28, 28)
              width: 28; height: 28
              fillMode: Image.PreserveAspectFit
              mipmap: true
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              text: "Welcome, " + sanitize(appWindow.obName || "there")
              color: appWindow.cOnSurface
              font.family: appWindow.fontFamily
              font.pixelSize: 20
              font.bold: true
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
          }

          Text {
            width: parent.width
            text: "Three quick things to set up your forecast: your starting balance, a name for your main account, and the date that balance was true."
            color: appWindow.cOnVar
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }

          Text {
            text: "OPENING BALANCE"
            color: appWindow.cOnVar
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.4
            textFormat: Text.PlainText
          }
          Row {
            spacing: 8
            Text {
              text: appWindow.currencySymbol
              color: appWindow.cOnSurface
              font.family: appWindow.fontFamily
              font.pixelSize: 14
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
            }
            TextField {
              id: obBalanceField
              objectName: "obBalanceField"
              width: 160
              height: 42
              placeholderText: "0.00"
              color: appWindow.cOnSurface
              placeholderTextColor: appWindow.cOnVar
              font.family: appWindow.fontFamily
              background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
              enabled: !appWindow.obSubmitting
              text: appWindow.obOpening === 0 ? "" : String(appWindow.obOpening)
              Component.onCompleted: forceActiveFocus()
            }
          }

          Text {
            text: "MAIN ACCOUNT NAME"
            color: appWindow.cOnVar
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.4
            textFormat: Text.PlainText
          }
          TextField {
            id: obNameField
            width: 320
            height: 42
            text: appWindow.obAccountName
            color: appWindow.cOnSurface
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
            enabled: !appWindow.obSubmitting
          }

          Text {
            text: "BALANCE WAS TRUE ON"
            color: appWindow.cOnVar
            font.family: appWindow.fontFamily
            font.pixelSize: 10
            font.bold: true
            font.letterSpacing: 1.4
            textFormat: Text.PlainText
          }
          TextField {
            id: obDateField
            width: 160
            height: 42
            placeholderText: appWindow.todayISO()
            color: appWindow.cOnSurface
            placeholderTextColor: appWindow.cOnVar
            font.family: appWindow.fontFamily
            background: Rectangle { color: appWindow.cInputBg; radius: 10; border.color: appWindow.cOutline }
            enabled: !appWindow.obSubmitting
          }

          Button {
            width: 320
            height: 46
            enabled: !appWindow.obSubmitting && obBalanceField.text.trim() !== ""
            contentItem: Text {
              text: appWindow.obSubmitting ? "Setting up…" : "Start forecasting"
              color: appWindow.cOnPrimary
              font.family: appWindow.fontFamily
              font.pixelSize: 13
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
              radius: 23
              color: appWindow.cPrimary
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
            color: appWindow.cRed
            font.family: appWindow.fontFamily
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
          }
        }
      }
    }
  }

  // ── MAIN VIEW (sidebar + pages) ──────────────────────────────────────
  property int navPage: 0   // 0 dashboard, 1 transactions, 2 recurring, 3 accounts

  Loader {
    anchors.fill: parent
    active: appWindow.view === "main"
    sourceComponent: mainComp
  }

  Component {
    id: mainComp
    Rectangle {
      color: appWindow.cBg
      anchors.fill: parent

      Row {
        anchors.fill: parent

        // ── sidebar ─────────────────────────────────────────────────
        Rectangle {
          width: 220
          height: parent.height
          color: appWindow.cSurfaceLo

          Column {
            anchors.fill: parent
            anchors.margins: 14
            spacing: 4

            Row {
              spacing: 10
              leftPadding: 6
              topPadding: 4

              Image {
                source: Qt.resolvedUrl("assets/logo.png")
                sourceSize: Qt.size(20, 20)
                width: 20; height: 20
                fillMode: Image.PreserveAspectFit
                mipmap: true
              }
              Text {
                text: "OmaFinSight"
                color: appWindow.cOnSurface
                font.family: appWindow.fontFamily
                font.pixelSize: 15
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
              }
            }

            Item { width: 1; height: 10 }

            NavItem { iconGlyph: "\uf109"; label: "Dashboard"; idx: 0 }
            NavItem { iconGlyph: "\uf03a"; label: "Transactions"; idx: 1 }
            NavItem { iconGlyph: "\uf021"; label: "Recurring"; idx: 2 }
            NavItem { iconGlyph: "\uf19c"; label: "Accounts"; idx: 3 }

            Item { width: 1; height: 1 }

            Rectangle {
              width: parent.width - 20
              height: 1
              color: appWindow.cOutlineVar
            }

            Item { width: 1; height: 8 }

            Text {
              leftPadding: 12
              text: "Your money.\nYour instance.\nAlways yours."
              color: appWindow.cOnVar
              font.family: appWindow.fontFamily
              font.pixelSize: 11
              textFormat: Text.PlainText
              lineHeight: 1.3
            }

            Item { width: 1; height: 1 }

            Text {
              leftPadding: 12
              text: {
                if (!appWindow.dash) return ""
                var s = appWindow.dash.scope
                var prim = null
                var arr = appWindow.accounts
                for (var i = 0; i < arr.length; i++) if (arr[i].isPrimary) { prim = arr[i]; break }
                var scopeTxt = s === "all" ? "all accounts" : ((prim && prim.name) || "primary")
                return "\uf007 " + sanitize(appWindow.userEmail) + "\n\uf093 " + scopeTxt
              }
              color: appWindow.cOnVar
              font.family: appWindow.fontFamily
              font.pixelSize: 10
              textFormat: Text.PlainText
              lineHeight: 1.4
              elide: Text.ElideRight
              width: parent.width - 24
            }

            Item { height: 1; width: 1 }

            Rectangle {
              width: parent.width - 20
              height: 1
              color: appWindow.cOutlineVar
            }

            Item { width: 1; height: 6 }

            Row {
              leftPadding: 10
              spacing: 6

              PillButton {
                text: appWindow.busy ? "…" : "Refresh"
                onClicked: appWindow.refresh()
              }
              PillButton {
                text: "Web"
                onClicked: Qt.openUrlExternally(appWindow.baseUrl)
              }
              PillButton {
                text: "Sign out"
                enabled: !appWindow.mutationsBusy
                onClicked: appWindow.signOut()
              }
            }
          }
        }

        // ── page column ─────────────────────────────────────────────
        Column {
          width: parent.width - 220
          height: parent.height
          spacing: 0

          // topbar
          Item {
            width: parent.width
            height: 56

            Row {
              anchors.left: parent.left
              anchors.leftMargin: 22
              anchors.verticalCenter: parent.verticalCenter
              spacing: 12

              ComboBox {
                id: scopeBox
                width: 160
                height: 36
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
                height: 36
                model: ["Next 30 days", "Next 90 days", "Next 12 months"]
                enabled: !appWindow.busy
                onActivated: function(idx) {
                  appWindow.chartDays = [30, 90, 365][idx]
                  appWindow.refresh()
                }
                currentIndex: [30, 90, 365].indexOf(appWindow.chartDays)
              }

              Text {
                visible: appWindow.notice !== ""
                text: appWindow.notice
                color: appWindow.cGreen
                font.family: appWindow.fontFamily
                font.pixelSize: 11
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: appWindow.lastError !== ""
                text: appWindow.lastError
                color: appWindow.cRed
                font.family: appWindow.fontFamily
                font.pixelSize: 11
                textFormat: Text.PlainText
                elide: Text.ElideRight
                width: Math.min(420, parent.width - 400)
                anchors.verticalCenter: parent.verticalCenter
              }
            }
          }

          Rectangle { width: parent.width; height: 1; color: appWindow.cOutlineVar }

          StackLayout {
            width: parent.width
            height: parent.height - 57
            currentIndex: appWindow.navPage

            // ═══ PAGE 0: DASHBOARD ═══════════════════════════════════
            Flickable {
              id: dashFlick
              contentWidth: width
              contentHeight: dashCol.height + 24
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { }

              Column {
                id: dashCol
                width: dashFlick.width
                spacing: 14

                // KPI row
                Row {
                  width: parent.width - 44
                  x: 22
                  spacing: 12

                  KpiCard {
                    width: (parent.width - 24) / 3
                    title: "EXPECTED TODAY"
                    bigValue: appWindow.fmtMoney(appWindow.dash ? appWindow.dash.summary.expectedToday : NaN)
                    subLine: {
                      var me = appWindow.dash ? appWindow.dash.summary.monthEnd : NaN
                      return (me === me ? "month-end " + appWindow.fmtMoney(me, 0) : "—")
                    }
                    subColor: appWindow.valueColor(appWindow.dash ? appWindow.dash.summary.expectedToday : NaN)
                    showSpark: true
                  }

                  KpiCard {
                    width: (parent.width - 24) / 3
                    title: "SPENDING (THIS MONTH)"
                    bigValue: appWindow.fmtMoney(appWindow.monthOut, 0)
                    subLine: appWindow.savRate + "% savings rate"
                    subColor: appWindow.savRate >= 15 ? appWindow.cGreen : (appWindow.savRate >= 5 ? appWindow.cOrange : appWindow.cRed)
                  }

                  KpiCard {
                    width: (parent.width - 24) / 3
                    title: "YEAR END FORECAST"
                    bigValue: appWindow.fmtMoney(appWindow.dash ? appWindow.dash.summary.yearEnd : NaN, 0)
                    subLine: {
                      var n30 = appWindow.dash ? appWindow.dash.summary.next30 : NaN
                      return (n30 === n30 ? "in 30 days " + appWindow.fmtMoney(n30, 0) : "—")
                    }
                    subColor: appWindow.valueColor(appWindow.dash ? appWindow.dash.summary.yearEnd : NaN)
                  }
                }

                // budget-by-category + cashflow row
                Row {
                  width: parent.width - 44
                  x: 22
                  spacing: 12

                  // category spend card
                  Rectangle {
                    width: (parent.width - 12) / 2
                    height: 250
                    radius: 14
                    color: appWindow.cSurface
                    border.color: appWindow.cOutline

                    Column {
                      anchors.fill: parent
                      anchors.margins: 16
                      spacing: 10

                      Text {
                        text: "SPENDING BY CATEGORY (THIS MONTH)"
                        color: appWindow.cPrimary
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        font.letterSpacing: 1.6
                        textFormat: Text.PlainText
                      }

                      Flow {
                        width: parent.width
                        spacing: 10

                        Repeater {
                          model: appWindow.catSpend

                          CatBar {
                            required property var modelData
                            required property int index
                            property int cIdx: index
                            width: (parent.width - 20) / 3
                            catName: modelData.name
                            spent: modelData.spend
                            barColor: [appWindow.cSecondary, appWindow.cPrimary, appWindow.cTertiary,
                                       appWindow.cGreen, appWindow.cOrange, appWindow.cPrimaryDim][cIdx % 6]
                            iconGlyph: ["\uf07a", "\uf0f5", "\uf0e7", "\uf1ad", "\uf015", "\uf02d"][cIdx % 6]
                          }
                        }
                      }

                      Text {
                        visible: appWindow.catSpend.length === 0
                        text: "No spending recorded this month yet."
                        color: appWindow.cOnVar
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }
                    }
                  }

                  // cashflow card
                  Rectangle {
                    width: (parent.width - 12) / 2
                    height: 250
                    radius: 14
                    color: appWindow.cSurface
                    border.color: appWindow.cOutline

                    Column {
                      anchors.fill: parent
                      anchors.margins: 16
                      spacing: 8

                      Row {
                        width: parent.width

                        Text {
                          text: "CASHFLOW (6 MONTHS)"
                          color: appWindow.cPrimary
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          font.letterSpacing: 1.6
                          textFormat: Text.PlainText
                        }

                        CashflowLegend {
                          anchors.right: parent.right
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      CashflowChart {
                        width: parent.width
                        height: parent.height - 46
                        months: appWindow.cashflow
                      }
                    }
                  }
                }

                // recent transactions + upcoming row
                Row {
                  width: parent.width - 44
                  x: 22
                  spacing: 12

                  // recent transactions table
                  Rectangle {
                    width: (parent.width - 12) / 2
                    height: 240
                    radius: 14
                    color: appWindow.cSurface
                    border.color: appWindow.cOutline

                    Column {
                      anchors.fill: parent
                      anchors.margins: 16
                      spacing: 8

                      Row {
                        width: parent.width

                        Text {
                          text: "RECENT TRANSACTIONS"
                          color: appWindow.cPrimary
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          font.letterSpacing: 1.6
                          textFormat: Text.PlainText
                        }

                        Text {
                          text: "Manage on Transactions →"
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 10
                          anchors.right: parent.right
                          textFormat: Text.PlainText
                        }
                      }

                      Column {
                        width: parent.width
                        spacing: 2

                        Repeater {
                          model: appWindow.recentAdhocs()

                          Item {
                            id: recentRow
                            required property var modelData
                            required property int index
                            width: parent.width
                            height: 28

                            Rectangle {
                              width: parent.width
                              height: 26
                              radius: 6
                              color: recentRow.index % 2 === 0 ? appWindow.cSurfaceHi : "transparent"
                            }

                            Text {
                              x: 8
                              width: 70
                              text: appWindow.fmtDateUK(modelData.date)
                              color: appWindow.cOnVar
                              font.family: appWindow.fontFamily
                              font.pixelSize: 10
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                              x: 86
                              width: parent.width - 200
                              text: sanitize(modelData.label) + (modelData.category ? "  ·  " + sanitize(modelData.category) : "")
                              color: appWindow.cOnSurface
                              font.family: appWindow.fontFamily
                              font.pixelSize: 11
                              elide: Text.ElideRight
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                              x: parent.width - 100
                              width: 92
                              text: (modelData.direction === "income" ? "+" : "-") + appWindow.fmtMoney(modelData.amount)
                              color: modelData.direction === "income" ? appWindow.cGreen : appWindow.cRed
                              font.family: appWindow.fontFamily
                              font.pixelSize: 11
                              font.bold: true
                              horizontalAlignment: Text.AlignRight
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }
                          }
                        }
                      }

                      Text {
                        visible: appWindow.recentAdhocs().length === 0
                        text: "No transactions yet — add one from Transactions."
                        color: appWindow.cOnVar
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }
                    }
                  }

                  // upcoming bills
                  Rectangle {
                    width: (parent.width - 12) / 2
                    height: 240
                    radius: 14
                    color: appWindow.cSurface
                    border.color: appWindow.cOutline

                    Column {
                      anchors.fill: parent
                      anchors.margins: 16
                      spacing: 8

                      Text {
                        text: "UPCOMING BILLS"
                        color: appWindow.cPrimary
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        font.letterSpacing: 1.6
                        textFormat: Text.PlainText
                      }

                      Column {
                        width: parent.width
                        spacing: 2

                        Repeater {
                          model: appWindow.upcomingBills()

                          Item {
                            id: billRow
                            required property var modelData
                            required property int index
                            width: parent.width
                            height: 30

                            Rectangle {
                              width: parent.width
                              height: 28
                              radius: 6
                              color: billRow.index % 2 === 0 ? appWindow.cSurfaceHi : "transparent"
                            }

                            Text {
                              x: 8
                              width: 70
                              text: appWindow.fmtDateUK(modelData.date)
                              color: appWindow.cOnVar
                              font.family: appWindow.fontFamily
                              font.pixelSize: 11
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                              x: 86
                              width: parent.width - 190
                              text: sanitize(modelData.label)
                              color: appWindow.cOnSurface
                              font.family: appWindow.fontFamily
                              font.pixelSize: 11
                              elide: Text.ElideRight
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                              x: parent.width - 96
                              width: 88
                              text: appWindow.fmtMoney(modelData.amount)
                              color: appWindow.cRed
                              font.family: appWindow.fontFamily
                              font.pixelSize: 11
                              font.bold: true
                              horizontalAlignment: Text.AlignRight
                              textFormat: Text.PlainText
                              anchors.verticalCenter: parent.verticalCenter
                            }
                          }
                        }
                      }

                      Text {
                        visible: appWindow.upcomingBills().length === 0
                        text: "No upcoming bills in the forecast window."
                        color: appWindow.cOnVar
                        font.family: appWindow.fontFamily
                        font.pixelSize: 11
                        textFormat: Text.PlainText
                      }
                    }
                  }
                }

                // balance forecast chart (wide)
                Rectangle {
                  width: parent.width - 44
                  x: 22
                  height: 230
                  radius: 14
                  color: appWindow.cSurface
                  border.color: appWindow.cOutline

                  Column {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 6

                    Text {
                      text: "BALANCE FORECAST (" + appWindow.chartDays + " DAYS)"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    ChartCanvas {
                      width: parent.width
                      height: parent.height - 40
                      series: appWindow.series
                      mode: "balance"
                      symbol: appWindow.currencySymbol
                    }
                  }
                }

                Item { width: 1; height: 8 }
              }
            }

            // ═══ PAGE 1: TRANSACTIONS ════════════════════════════════
            Flickable {
              id: txFlick
              contentWidth: width
              contentHeight: txCol.height + 24
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { }

              Column {
                id: txCol
                width: txFlick.width
                spacing: 12

                Row {
                  x: 22
                  spacing: 8

                  PillButton {
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

                Card {
                  x: 22
                  width: parent.width - 44
                  height: txAdhocCol.height + 24

                  Column {
                    id: txAdhocCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 4

                    Text {
                      text: "AD-HOC TRANSACTIONS (" + appWindow.adhocs.length + ")"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
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
                          width: 70
                          text: appWindow.fmtDateUK(modelData.date)
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: parent.width - 70 - 100 - 160
                          text: sanitize(modelData.label) + (modelData.category ? "  · " + sanitize(modelData.category) : "")
                          color: appWindow.cOnSurface
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 100
                          text: (modelData.direction === "income" ? "+" : "-") + appWindow.fmtMoney(modelData.amount)
                          color: modelData.direction === "income" ? appWindow.cGreen : appWindow.cRed
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          textFormat: Text.PlainText
                        }

                        Row {
                          width: 160
                          spacing: 6
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
                      text: "No ad-hoc transactions yet."
                      color: appWindow.cOnVar
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      textFormat: Text.PlainText
                    }
                  }
                }

                Item { width: 1; height: 6 }
              }
            }

            // ═══ PAGE 2: RECURRING ═══════════════════════════════════
            Flickable {
              id: recFlick
              contentWidth: width
              contentHeight: recCol.height + 24
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { }

              Column {
                id: recCol
                width: recFlick.width
                spacing: 12

                Row {
                  x: 22
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
                  x: 22
                  width: parent.width - 44
                  height: repCol.height + 24

                  Column {
                    id: repCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 4

                    Text {
                      text: "REPEATS (" + appWindow.repeats.length + ")"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    Repeater {
                      model: appWindow.repeats

                      Row {
                        required property var modelData
                        width: parent.width
                        spacing: 8

                        Text {
                          width: 240
                          text: sanitize(modelData.label) + "  ·  " + sanitize(modelData.category)
                          color: appWindow.cOnSurface
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 150
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
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 100
                          text: (modelData.direction === "income" ? "+" : "-") + appWindow.fmtMoney(modelData.amount)
                          color: modelData.direction === "income" ? appWindow.cGreen : appWindow.cRed
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 90
                          text: modelData.nextDate ? appWindow.fmtDateUK(modelData.nextDate) : "—"
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Row {
                          spacing: 6
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
                      color: appWindow.cOnVar
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      textFormat: Text.PlainText
                    }
                  }
                }

                // one-off transfers
                Card {
                  x: 22
                  width: parent.width - 44
                  height: trCol.height + 24

                  Column {
                    id: trCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 4

                    Text {
                      text: "ONE-OFF TRANSFERS (" + appWindow.transfers.length + ")"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    Repeater {
                      model: appWindow.transfers

                      Row {
                        required property var modelData
                        width: parent.width
                        spacing: 8

                        Text {
                          width: 70
                          text: appWindow.fmtDateUK(modelData.date)
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: parent.width - 70 - 100 - 120
                          text: sanitize(modelData.fromName) + "  →  " + sanitize(modelData.toName) + (modelData.label ? "  ·  " + sanitize(modelData.label) : "")
                          color: appWindow.cOnSurface
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 100
                          text: appWindow.fmtMoney(modelData.amount)
                          color: appWindow.cPrimary
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          textFormat: Text.PlainText
                        }

                        Row {
                          width: 120
                          spacing: 6
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
                      color: appWindow.cOnVar
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      textFormat: Text.PlainText
                    }
                  }
                }

                // recurring transfers
                Card {
                  x: 22
                  width: parent.width - 44
                  height: trefCol.height + 24

                  Column {
                    id: trefCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 4

                    Text {
                      text: "RECURRING TRANSFERS (" + appWindow.transferRepeats.length + ")"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    Repeater {
                      model: appWindow.transferRepeats

                      Row {
                        required property var modelData
                        width: parent.width
                        spacing: 8

                        Text {
                          width: 220
                          text: sanitize(modelData.fromName) + "  →  " + sanitize(modelData.toName) + (modelData.label ? "  ·  " + sanitize(modelData.label) : "")
                          color: appWindow.cOnSurface
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
                            return txt
                          }
                          color: appWindow.cOnVar
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          textFormat: Text.PlainText
                        }

                        Text {
                          width: 100
                          text: appWindow.fmtMoney(modelData.amount)
                          color: appWindow.cPrimary
                          font.family: appWindow.fontFamily
                          font.pixelSize: 11
                          font.bold: true
                          textFormat: Text.PlainText
                        }

                        Row {
                          spacing: 6
                          PillButton { text: "Delete"; enabled: !appWindow.mutationsBusy; onClicked: appWindow.deleteTref(modelData.id) }
                        }
                      }
                    }

                    Text {
                      visible: appWindow.transferRepeats.length === 0
                      text: "No recurring transfers yet."
                      color: appWindow.cOnVar
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      textFormat: Text.PlainText
                    }
                  }
                }

                Item { width: 1; height: 6 }
              }
            }

            // ═══ PAGE 3: ACCOUNTS ════════════════════════════════════
            Flickable {
              id: accFlick
              contentWidth: width
              contentHeight: accCol.height + 24
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { }

              Column {
                id: accCol
                width: accFlick.width
                spacing: 12

                Rectangle {
                  x: 22
                  width: parent.width - 44
                  height: accInner.height + 28
                  radius: 14
                  color: appWindow.cSurface
                  border.color: appWindow.cOutline

                  Column {
                    id: accInner
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 10

                    Text {
                      text: "ACCOUNTS"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    Repeater {
                      model: appWindow.accounts

                      Item {
                        required property var modelData
                        required property int index
                        width: parent.width
                        height: 46

                        Rectangle {
                          width: parent.width
                          height: 42
                          radius: 10
                          color: index % 2 === 0 ? appWindow.cSurfaceHi : appWindow.cSurface
                        }

                        Text {
                          x: 14
                          width: parent.width - 180
                          text: sanitize(modelData.name) + (modelData.isPrimary ? "   ·  primary" : "")
                          color: appWindow.cOnSurface
                          font.family: appWindow.fontFamily
                          font.pixelSize: 12
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                          x: parent.width - 170
                          width: 156
                          text: appWindow.fmtMoney(modelData.balanceNow)
                          color: {
                            var v = modelData.balanceNow
                            if (v !== v) return appWindow.cOnVar
                            if (v < 0) return appWindow.cRed
                            if (v < 500) return appWindow.cOrange
                            return appWindow.cOnSurface
                          }
                          font.family: appWindow.fontFamily
                          font.pixelSize: 13
                          font.bold: true
                          horizontalAlignment: Text.AlignRight
                          textFormat: Text.PlainText
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }
                    }
                  }
                }

                // typical month in/out
                Rectangle {
                  x: 22
                  width: parent.width - 44
                  height: 110
                  radius: 14
                  color: appWindow.cSurface
                  border.color: appWindow.cOutline

                  Column {
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 8

                    Text {
                      text: "TYPICAL MONTH"
                      color: appWindow.cPrimary
                      font.family: appWindow.fontFamily
                      font.pixelSize: 11
                      font.bold: true
                      font.letterSpacing: 1.6
                      textFormat: Text.PlainText
                    }

                    Row {
                      spacing: 30

                      Column {
                        spacing: 2
                        Text { text: "INCOME"; color: appWindow.cOnVar; font.family: appWindow.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.2; textFormat: Text.PlainText }
                        Text {
                          text: appWindow.dash ? "+" + appWindow.fmtMoney(appWindow.dash.summary.monthlyIncome, 0) : "—"
                          color: appWindow.cGreen
                          font.family: appWindow.fontFamily
                          font.pixelSize: 19
                          font.bold: true
                          textFormat: Text.PlainText
                        }
                      }

                      Column {
                        spacing: 2
                        Text { text: "EXPENSES"; color: appWindow.cOnVar; font.family: appWindow.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.2; textFormat: Text.PlainText }
                        Text {
                          text: appWindow.dash ? "-" + appWindow.fmtMoney(appWindow.dash.summary.monthlyExpenses, 0) : "—"
                          color: appWindow.cRed
                          font.family: appWindow.fontFamily
                          font.pixelSize: 19
                          font.bold: true
                          textFormat: Text.PlainText
                        }
                      }

                      Column {
                        spacing: 2
                        Text { text: "NET"; color: appWindow.cOnVar; font.family: appWindow.fontFamily; font.pixelSize: 10; font.letterSpacing: 1.2; textFormat: Text.PlainText }
                        Text {
                          text: appWindow.dash ? appWindow.fmtMoney(appWindow.dash.summary.monthlyIncome - appWindow.dash.summary.monthlyExpenses, 0) : "—"
                          color: appWindow.cOnSurface
                          font.family: appWindow.fontFamily
                          font.pixelSize: 19
                          font.bold: true
                          textFormat: Text.PlainText
                        }
                      }
                    }
                  }
                }

                Item { width: 1; height: 6 }
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
