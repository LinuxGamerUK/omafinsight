import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // ── Settings ────────────────────────────────────────────────────────
  property var settings: {}

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 900, 120, 7200)
  readonly property string baseUrl: normaliseUrl(strSettingRaw("baseUrl", "https://finsight.cresta.digital"))
  readonly property real warnBalance: numSetting("warnBalance", 500, 0, 1000000)
  readonly property real criticalBalance: numSetting("criticalBalance", 200, 0, 1000000)
  readonly property string barShows: strSetting("barShows", "today")
  readonly property string scope: strSetting("scope", "primary")
  readonly property bool hideByDefault: boolSetting("hideByDefault", true)

  // Privacy eye: amounts hidden by default (streaming/screen-share safe).
  // Toggled from the bar (eye icon) or panel; remembered per session.
  property bool hidden: hideByDefault
  function toggleHidden() { hidden = !hidden }

  // Static helpers for the standalone Oma-App window. The launcher passes
  // the configured base URL as an argument, so no settings file is read there.
  function sessionPath() {
    var xdg = Quickshell.env("XDG_STATE_HOME") || ""
    var home = Quickshell.env("HOME") || "/"
    return (xdg !== "" ? xdg : home + "/.local/state") + "/omafinsight/session.txt"
  }

  // Launch the Oma-App desktop window (user-scope, no privileges). Runs the
  // user's quickshell binary pointed at AppWindow.qml with the base URL.
  function openApp() {
    openAppProcess.url = baseUrl
    openAppProcess.running = true
  }

  Process {
    id: openAppProcess
    running: false
    property string url: ""
    command: ["bash", "-c",
      "OMAFIN_URL='" + normaliseUrl(openAppProcess.url) + "' nohup qs -n -p '" +
      Quickshell.env('HOME') + "/.config/omarchy/plugins/com.github.linuxgameruk.omafinsight/AppWindow.qml' " +
      ">/dev/null 2>&1 & disown"]
  }
  readonly property bool hideAmounts: hidden

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function numSetting(name, fallback, min, max) {
    var n = parseFloat(String(setting(name, fallback)))
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    return v === true || v === "true"
  }

  function strSettingRaw(name, fallback) {
    var v = String(setting(name, fallback))
    return v.trim()
  }

  function strSetting(name, fallback) {
    var v = String(setting(name, fallback))
    return v === "" ? fallback : v
  }

  function normaliseUrl(u) {
    var s = String(u || "").trim()
    while (s.length > 0 && (s.charAt(0) === "'" || s.charAt(0) === '"')) s = s.substring(1)
    while (s.length > 0 && (s.charAt(s.length - 1) === "'" || s.charAt(s.length - 1) === '"')) s = s.substring(0, s.length - 1)
    if (s === "") return "https://finsight.cresta.digital"
    if (s.indexOf("http") !== 0) s = "https://" + s
    while (s.length > 0 && s.charAt(s.length - 1) === "/") s = s.substring(0, s.length - 1)
    return s
  }

  // ── Data model (bounded) ────────────────────────────────────────────
  readonly property int maxAccounts: 8
  readonly property int capSummary: 65536

  property bool authed: false
  property string email: ""
  property string currencySymbol: "£"

  property real expectedToday: NaN
  property real monthEnd: NaN
  property real yearEnd: NaN
  property real next7: NaN
  property real next30: NaN
  property real monthlyIncome: NaN
  property real monthlyExpenses: NaN

  // [{ id, name, kind, isPrimary, balanceNow }]
  property var accounts: []
  property bool anyData: false
  property string lastError: ""
  property string lastRefreshText: ""
  property bool busy: false

  readonly property bool alerting: anyData && expectedToday === expectedToday && expectedToday < criticalBalance
  readonly property bool warning: !alerting && anyData && expectedToday === expectedToday && expectedToday < warnBalance

  // ── Hardening constants (marketplace baseline) ──────────────────────
  readonly property int netTimeoutSec: 10
  readonly property int watchdogMs: 15000

  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  // ── Session store ───────────────────────────────────────────────────
  // The JWT session cookie is stored 0600 in XDG_STATE_HOME. The password
  // itself is never persisted — only the session token. The file is written
  // by curl's own cookie jar (curl -c), read back with curl -b.
  function sessionDir() {
    var xdg = Quickshell.env("XDG_STATE_HOME") || ""
    var home = Quickshell.env("HOME") || "/"
    return (xdg !== "" ? xdg : home + "/.local/state") + "/omafinsight"
  }

  function sessionFile() {
    return sessionDir() + "/session.txt"
  }

  // ── Cycle state ─────────────────────────────────────────────────────
  property bool _authCheckDone: false
  property int _outstanding: 0

  function refresh() {
    if (busy) return
    if (!_authCheckDone) {
      busy = true
      authCheck.running = true
      authWatchdog.restart()
      return
    }
    if (!authed) return
    busy = true
    lastError = ""
    _outstanding = 2
    launch(dashboardProcess, dashboardWatchdog, composeSummaryUrl())
    launch(accountsProcess, accountsWatchdog, composeAccountsUrl())
  }

  function launch(process, watchdog, url) {
    if (process.running) return
    process.url = url
    process.running = true
    watchdog.restart()
  }

  function _finish(ok) {
    _outstanding = _outstanding - 1
    if (_outstanding <= 0) {
      anyData = expectedToday === expectedToday
      busy = false
      lastRefreshText = Qt.formatDateTime(new Date(), "HH:mm")
      if (!ok && lastError === "") lastError = "Some data failed to load — try Refresh"
    }
  }

  function composeSummaryUrl() {
    if (scope === "all") return baseUrl + "/api/dashboard?account=all"
    return baseUrl + "/api/dashboard"  // unset = primary
  }

  function composeAccountsUrl() {
    return baseUrl + "/api/accounts"
  }

  // Qt's V4 toLocaleString ignores fraction-digit options — format manually
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
    var abs = Math.abs(n)
    var fixed = abs.toFixed(dp)
    var parts = fixed.split(".")
    var grouped = _group(parts[0])
    var frac = dp > 0 ? "." + parts[1] : ""
    return (neg ? "-" : "") + currencySymbol + grouped + frac
  }

  function fmtMoneyNoDp(n) {
    if (n === null || n === undefined || n !== n) return "—"
    var neg = n < 0
    var rounded = Math.round(Math.abs(n))
    return (neg ? "-" : "") + currencySymbol + _group(rounded)
  }

  // ── Auth bootstrap ──────────────────────────────────────────────────
  // Runs once at startup: if a session file exists, one cheap /api/profile
  // call validates it. Anything 401/403 clears the session and flips the
  // panel to the login form.
  Process {
    id: authCheck
    running: false
    property string buffer: ""
    command: ["timeout", "-k", "2", "" + root.netTimeoutSec, "bash", "-c",
      "set -o pipefail; test -f '" + root.sessionFile() + "' || exit 9; " +
      "curl -sS -b '" + root.sessionFile() + "' --connect-timeout 5 --max-time 8 " +
      "-o /dev/null -w '%{http_code}' '" + root.baseUrl + "/api/profile' 2>&1 | head -c 8"]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (authCheck.buffer.length + s.length <= 16) authCheck.buffer += s
    } }
    onExited: function(exitCode) {
      authWatchdog.stop()
      authCheck.running = false
      _authCheckDone = true
      var code = truncate(authCheck.buffer.trim(), 8)
      authCheck.buffer = ""
      if (exitCode === 9) {
        authed = false
        lastError = ""
      } else if (exitCode === 0 && code === "200") {
        authed = true
      } else {
        authed = false
        clearSession()
        lastError = code === "" ? "Could not reach FinSight — check your connection or the base URL" : "Session expired — sign in again"
      }
      if (authed) {
        busy = false
        refresh()
      } else {
        busy = false
      }
    }
  }

  Timer {
    id: authWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: {
      if (authCheck.running) authCheck.running = false
      root._authCheckDone = true
      root.authed = false
      root.busy = false
      root.lastError = "Connection timed out — check the base URL and your network"
    }
  }

  function clearSession() {
    clearProcess.running = true
  }

  Process {
    id: clearProcess
    running: false
    command: ["bash", "-c", "rm -f '" + root.sessionFile() + "'"]
  }

  // ── Login (panel form) ──────────────────────────────────────────────
  // Password travels over stdin into a bash `read` (never argv/cmdline).
  // curl writes the session cookie to the 0600 store; we then parse the
  // profile JSON to pick up the user's currency + email.
  property string _loginEmail: ""
  property string _passwordToWrite: ""

  function login(email, password) {
    if (busy) return
    busy = true
    lastError = ""
    _loginEmail = truncate(email, 120)
    _passwordToWrite = String(password || "")
    loginProcess.running = true
    loginWatchdog.restart()
  }

  Process {
    id: loginProcess
    running: false
    property string buffer: ""
    stdinEnabled: true
    command: ["timeout", "-k", "2", "" + root.netTimeoutSec, "bash", "-c",
      "set -o pipefail; IFS= read -r _creds; " +
      "_e=$(printf '%s' \"$_creds\" | cut -d: -f1); " +
      "_p=$(printf '%s' \"$_creds\" | cut -d: -f2-); " +
      "mkdir -p '" + root.sessionDir() + "' && chmod 700 '" + root.sessionDir() + "'; " +
      "_b=$(mktemp \"${XDG_RUNTIME_DIR:-/tmp}/omafinsight-body.XXXXXX\") || exit 1; " +
      "trap 'rm -f \"$_b\"' EXIT; " +
      "code=$(curl -sS --connect-timeout 5 --max-time 8 -c '" + root.sessionFile() + "' " +
      "-o \"$_b\" -w '%{http_code}' " +
      "-H 'Content-Type: application/json' " +
      "--data \"{\\\"email\\\":\\\"$_e\\\",\\\"password\\\":\\\"$_p\\\"}\" " +
      "'" + root.baseUrl + "/api/auth/login' 2>&1 | head -c 8); " +
      "cat \"$_b\" | head -c " + root.capSummary + "; " +
      "printf '\\n__CODE__%s' \"$code\""]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (loginProcess.buffer.length + s.length <= root.capSummary) loginProcess.buffer += s + "\n"
    } }
    onStarted: {
      write(_loginEmail + ':' + _passwordToWrite + '\n')
      _passwordToWrite = ""
    }
    onExited: function(exitCode) {
      loginWatchdog.stop()
      loginProcess.running = false
      var raw = truncate(loginProcess.buffer.trim(), capSummary)
      loginProcess.buffer = ""
      if (exitCode === 124 || exitCode === 137) {
        busy = false
        lastError = "Login timed out — check the base URL and your network"
        return
      }
      if (exitCode !== 0) {
        busy = false
        lastError = "Login failed (exit " + exitCode + ")"
        return
      }
      var codeIdx = raw.lastIndexOf("__CODE__")
      var code = codeIdx >= 0 ? raw.substring(codeIdx + 8, codeIdx + 11) : ""
      var body = codeIdx >= 0 ? raw.substring(0, codeIdx) : raw
      if (code === "200") {
        authed = true
        email = _loginEmail
        try {
          var d = JSON.parse(body)
          if (d && d.user) {
            currencySymbol = currencySymbolFor(String(d.user.currency || "GBP"))
            email = truncate(String(d.user.email || _loginEmail), 120)
          }
        } catch (e) { /* currency stays default */ }
        lastError = ""
        _authCheckDone = true
        refresh()
      } else if (code === "401") {
        busy = false
        lastError = "Invalid email or password"
      } else if (code === "429") {
        busy = false
        lastError = "Too many attempts — wait a few minutes and try again"
      } else {
        busy = false
        lastError = code === "" ? "Could not reach FinSight — check the base URL and your network" : "Login failed (HTTP " + code + ")"
      }
    }
  }

  Timer {
    id: loginWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: {
      if (loginProcess.running) loginProcess.running = false
      root.busy = false
      root.lastError = "Login timed out — check the base URL and your network"
    }
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

  function logout() {
    authed = false
    accounts = []
    anyData = false
    expectedToday = NaN
    monthEnd = NaN
    yearEnd = NaN
    next7 = NaN
    next30 = NaN
    clearSession()
  }

  // ── Dashboard fetch ─────────────────────────────────────────────────
  // Session cookie comes straight from the curl cookie jar (0600 file).
  Process {
    id: dashboardProcess
    running: false
    property string url: ""
    property string buffer: ""
    command: ["timeout", "-k", "2", "" + root.netTimeoutSec, "bash", "-c",
      "set -o pipefail; curl -sS -b '" + root.sessionFile() + "' " +
      "--connect-timeout 5 --max-time 8 '" + dashboardProcess.url + "' 2>&1 | head -c " + root.capSummary]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (dashboardProcess.buffer.length + s.length <= root.capSummary) dashboardProcess.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      dashboardWatchdog.stop()
      dashboardProcess.running = false
      var buf = truncate(dashboardProcess.buffer.trim(), capSummary)
      dashboardProcess.buffer = ""
      if (exitCode === 0) root._parseDashboard(buf)
      else if (exitCode === 124 || exitCode === 137) root._failAll("Dashboard fetch timed out")
      else root._failAll("Dashboard fetch failed (exit " + exitCode + ")")
    }
  }

  Timer {
    id: dashboardWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: {
      if (dashboardProcess.running) dashboardProcess.running = false
      root._failAll("Dashboard fetch timed out")
    }
  }

  // ── Accounts fetch ──────────────────────────────────────────────────
  Process {
    id: accountsProcess
    running: false
    property string url: ""
    property string buffer: ""
    command: ["timeout", "-k", "2", "" + root.netTimeoutSec, "bash", "-c",
      "set -o pipefail; curl -sS -b '" + root.sessionFile() + "' " +
      "--connect-timeout 5 --max-time 8 '" + accountsProcess.url + "' 2>&1 | head -c " + root.capSummary]
    stdout: SplitParser { onRead: function(line) {
      var s = String(line || "")
      if (accountsProcess.buffer.length + s.length <= root.capSummary) accountsProcess.buffer += s + "\n"
    } }
    onExited: function(exitCode) {
      accountsWatchdog.stop()
      accountsProcess.running = false
      var buf = truncate(accountsProcess.buffer.trim(), capSummary)
      accountsProcess.buffer = ""
      if (exitCode === 0) root._parseAccounts(buf)
      else if (exitCode === 124 || exitCode === 137) root._finish(false)
      else root._finish(false)
    }
  }

  Timer {
    id: accountsWatchdog
    interval: root.watchdogMs
    repeat: false
    onTriggered: {
      if (accountsProcess.running) accountsProcess.running = false
      root._finish(false)
    }
  }

  // ── Parsers ─────────────────────────────────────────────────────────
  property string _lastErrorSeen: ""

  function _failAll(msg) {
    lastError = truncate(sanitize(msg), 200)
    _finish(false)
  }

  function _parseDashboard(raw) {
    if (raw === "") { _failAll("Empty response from FinSight"); return }
    var first = raw.indexOf("{")
    if (first < 0) { _failAll(truncate(sanitize(raw), 120)); return }
    try {
      var d = JSON.parse(raw.substring(first))
      if (d.onboarded === false) {
        _failAll("This FinSight account hasn't finished setup yet — open the web app once")
        return
      }
      if (d.needsAccount === true) {
        _failAll("Account data is migrating — open the web app once to complete it")
        return
      }
      var s = d.summary || {}
      expectedToday = typeof s.expectedToday === "number" ? s.expectedToday : NaN
      monthEnd = typeof s.monthEnd === "number" ? s.monthEnd : NaN
      yearEnd = typeof s.yearEnd === "number" ? s.yearEnd : NaN
      next7 = typeof s.next7 === "number" ? s.next7 : NaN
      next30 = typeof s.next30 === "number" ? s.next30 : NaN
      monthlyIncome = typeof s.monthlyIncome === "number" ? s.monthlyIncome : NaN
      monthlyExpenses = typeof s.monthlyExpenses === "number" ? s.monthlyExpenses : NaN
      // the dashboard payload also carries per-account balances (balanceNow)
      var dacc = []
      var darr = d.accounts || []
      for (var i = 0; i < darr.length && i < maxAccounts; i++) {
        var a = darr[i]
        if (!a || typeof a.id !== "number") continue
        dacc.push({
          id: a.id,
          name: sanitize(truncate(String(a.name || ""), 48)),
          kind: sanitize(truncate(String(a.kind || ""), 16)),
          isPrimary: a.isPrimary === true,
          balanceNow: typeof a.balanceNow === "number" ? a.balanceNow : NaN
        })
      }
      if (dacc.length > 0) accounts = dacc
      lastError = ""
      _finish(true)
    } catch (e) {
      _failAll("Unexpected response from FinSight (not JSON)")
    }
  }

  function _parseAccounts(raw) {
    if (raw === "") { _finish(false); return }
    var first = raw.indexOf("{")
    if (first < 0) { _finish(false); return }
    try {
      var d = JSON.parse(raw.substring(first))
      var list = accounts.slice()  // keep dashboard balances; patch the rest
      var arr = d.accounts || []
      for (var i = 0; i < arr.length && i < maxAccounts; i++) {
        var a = arr[i]
        if (!a || typeof a.id !== "number") continue
        var found = null
        for (var j = 0; j < list.length; j++) {
          if (list[j].id === a.id) { found = list[j]; break }
        }
        var patch = {
          name: sanitize(truncate(String(a.name || ""), 48)),
          kind: sanitize(truncate(String(a.kind || ""), 16)),
          isPrimary: a.isPrimary === true
        }
        if (found) {
          found.name = patch.name
          found.kind = patch.kind
          found.isPrimary = patch.isPrimary
        } else if (list.length < maxAccounts) {
          patch.id = a.id
          patch.balanceNow = NaN
          list.push(patch)
        }
      }
      accounts = list
      _finish(true)
    } catch (e) {
      _finish(false)
    }
  }

  // ── Refresh timer ───────────────────────────────────────────────────
  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    // bootstrap auth check, then initial refresh
    refresh()
  }
}