# OmaFinSight

![OmaFinSight](assets/screenshot.png)

Your [FinSight](https://github.com/LinuxGamerUK/FinSight) personal finance data, living in your Omarchy bar and on your desktop. **One free account, one set of numbers, everywhere** — the bar chip, the quick panel, a native desktop app, and the web UI all read and write the same data on the same instance, so a transaction you add on the desktop app is in your web dashboard the moment you look.

OmaFinSight is a companion to a **FinSight instance** — a free, self-hostable personal finance forecaster. Don't have one? Point OmaFinSight at the author's free public instance at **[https://finsight.cresta.digital](https://finsight.cresta.digital)** (register in-app and go), or run your own — it's a single Node.js app + SQLite.

## What you get

### Bar chip
- **Expected balance today** (or month-end / year-end / nothing — configurable), comma-formatted, always current
- Turns **accent** under your warning threshold and **urgent red** under your critical threshold
- **Privacy eye** — one click masks every amount as `£**.**` across bar, panel *and* app, for streaming and screen sharing. Hidden by default on fresh installs; toggle with the eye icon or `H`

### Quick panel (click the bar chip)
- Expected today, end of month, end of year, +7 days, +30 days
- Typical monthly income vs expenses, per-account balances (credit card debt in red)
- **Privacy eye toggle**, last refresh time, thresholds honoured
- **Open web** and **Open Oma-App** buttons, keyboard shortcuts (`R` refresh, `H` hide, `A` app, `O` web)

### Oma-App — the native desktop window
A full Material You dashboard over your FinSight data, no browser needed:

- **Dashboard** — KPI cards (expected today with balance sparkline, spending this month with savings rate, year-end forecast), **spending by category** bars, **6-month cashflow** chart (income vs expenses), recent transactions table, upcoming bills, full balance forecast chart
- **Transactions** — add, **edit** and **delete** ad-hoc transactions (category, amount, direction, date); create one-off transfers between accounts
- **Recurring** — add, **edit** and **delete** repeats (daily / weekly / monthly / annually, with weekday, day-of-month, last-working-day and MM-DD detail, never-expires or end date); create recurring transfers
- **Accounts** — every account with live balances, and your typical month in / expenses / net
- Account scope (primary / all accounts) and forecast range (30 / 90 days / 12 months) selectors

### Register & onboarding — no browser required
New to FinSight? Create your account right inside the Oma-App: name, email, password, currency — then first-run onboarding (opening balance, account name, start date). The bar, panel and app sign in with the same credentials and stay in sync through the instance.

## Everything reads the same data

| Surface | Reads | Writes |
|---|---|---|
| Bar chip + panel | forecast, accounts, thresholds | — (read-only by design) |
| Oma-App | everything | transactions, repeats, transfers, register, onboarding |
| Web UI (`O` / *Open web*) | everything | everything |

All three talk to the same base URL over its REST API, so there's exactly one source of truth: your instance. Sign in on any surface and you're looking at the same ledger.

## Install

```sh
omarchy plugin install https://github.com/LinuxGamerUK/omafinsight
```

Or manually:

```sh
git clone https://github.com/LinuxGamerUK/omafinsight.git \
  ~/.config/omarchy/plugins/com.github.linuxgameruk.omafinsight
omarchy-shell shell rescanPlugins
omarchy plugin enable com.github.linuxgameruk.omafinsight right
omarchy-restart-shell
```

To remove:

```sh
omarchy plugin disable com.github.linuxgameruk.omafinsight
rm -rf ~/.config/omarchy/plugins/com.github.linuxgameruk.omafinsight
rm -rf ~/.local/state/omafinsight   # removes all stored sessions
```

## First run

1. Click the bar icon — the panel shows a sign-in form.
2. Enter the email + password of your FinSight account. (New? Use **Create an account** in the Oma-App, or register at the instance's web UI.)
3. That's it. The session cookie is stored locally (see Privacy); your password is never saved.

You need a reachable FinSight instance. The default is the author's free public instance, `https://finsight.cresta.digital` — register for free and use it immediately, or point the Base URL setting at your own self-hosted instance (LAN, Tailscale, or a public URL).

## IPC commands

```sh
omarchy-shell com.github.linuxgameruk.omafinsight toggle    # open/close panel
omarchy-shell com.github.linuxgameruk.omafinsight refresh   # refresh now
omarchy-shell com.github.linuxgameruk.omafinsight eyetoggle # hide/show amounts
omarchy-shell com.github.linuxgameruk.omafinsight openapp   # launch the Oma-App window
omarchy-shell com.github.linuxgameruk.omafinsight openweb   # open the web app
```

## Settings

| Setting | Default | Description |
|---|---|---|
| Refresh interval | 900s | How often to poll the API (min 120s) |
| Base URL | finsight.cresta.digital | Your FinSight instance (yours or the free public one) |
| Warning threshold | 500 | Balance under this → accent colour |
| Critical threshold | 200 | Balance under this → urgent colour |
| Bar shows | today | `today` / `month-end` / `year-end` / `none` |
| Account scope | primary | `primary` account or `all` accounts combined |
| Start hidden | on | Privacy eye state when the shell starts |

## Privacy & security

- **Your credentials go only to your FinSight instance.** The password is sent once over HTTPS to the `/api/auth/login` (or `/register`) endpoint you configured, and is never written to disk.
- **The session cookie is stored locally** at `~/.local/state/omafinsight/<instance>/session.txt` (namespaced per instance URL) with `0600` permissions (directory `0700`). It is a bearer token for *your* instance only — different instances (e.g. a test server) get their own sessions and can never touch each other's.
- The password travels over **stdin** into the login/register process — it never appears in a process argument list, so it can't leak via `/proc/<pid>/cmdline`. JSON request bodies likewise travel over stdin into a 0600 temp file, never via argv or shell interpolation.
- No telemetry, no third-party calls, no analytics. The plugin talks to exactly one host: the base URL you configure.
- **Amounts can be hidden at any time** (eye icon / `H`) — useful when streaming or screen sharing. Hidden state is per-session, not persisted.
- The Oma-App window is the same trust domain: it reuses the stored session, runs as your user, and only talks to your instance.
- **Sign out** in the Oma-App sidebar (or delete the session dir) clears the stored session.

## Dependencies

- Omarchy (with the Quickshell shell) — this is a bar plugin
- `curl` (pre-installed on Omarchy/Arch)
- A reachable FinSight instance — the free public one at [finsight.cresta.digital](https://finsight.cresta.digital), or self-host your own ([FinSight repo](https://github.com/LinuxGamerUK/FinSight), single Node.js app + SQLite)

## Privileges

None. The plugin runs entirely as your user, makes no privileged calls, installs no services, and never downloads or executes third-party code at runtime. All subprocess I/O is bounded (`timeout` + watchdogs, capped output, parse-only-on-success).

## License

MIT — see [LICENSE](LICENSE).