# OmaFinSight

![OmaFinSight](assets/screenshot.png)

FinSight balance forecast in the Omarchy bar — plus a **native Quickshell desktop app** with charts — your **expected balance today**, **end of month** and **end of year**, per-account balances, in/out history and a low-balance warning glow, pulled live from your self-hosted [FinSight](https://github.com/LinuxGamerUK/FinSight) instance (Next.js, self-hosted on your own server).

**Read-only companion.** The bar and app show your numbers; all data entry happens in the FinSight web app (`O` in the panel, or the *Open web* button).

## What it shows

- **Bar chip:** expected balance today (or month-end / year-end / nothing — configurable), turning accent-coloured under your warning threshold and urgent under your critical threshold
- **Privacy eye:** an eye icon beside the balance toggles `£**.**` masking — hidden by default so streams and screen shares never leak your balance; one click (or `H`) shows the numbers
- **Panel:** today / month-end / year-end / +7 days / +30 days forecast, typical monthly in vs out, per-account balances, last refresh time
- **Oma-App (`A` / *Open Oma-App*):** a native desktop window — balance forecast chart, money-in vs money-out bars, summary cards, per-account balances and upcoming items, with account-scope and date-range selectors. Same session, same instance, zero browser.
- **Keyboard:** `R` refreshes, `H` toggles the privacy eye, `A` opens the Oma-App, `O` opens the web app, arrows scroll, `Tab` switches panels

## IPC commands

```sh
omarchy-shell com.github.linuxgameruk.omafinsight toggle    # open/close panel
omarchy-shell com.github.linuxgameruk.omafinsight refresh   # refresh now
omarchy-shell com.github.linuxgameruk.omafinsight eyetoggle # hide/show amounts
omarchy-shell com.github.linuxgameruk.omafinsight openapp   # launch the Oma-App window
omarchy-shell com.github.linuxgameruk.omafinsight openweb   # open the web app
```

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
rm -rf ~/.local/state/omafinsight   # removes the stored session
```

## First run

1. Click the bar icon — the panel shows a sign-in form.
2. Enter the email + password you use on your FinSight web instance.
3. That's it. The session cookie is stored locally (see Privacy); your password is never saved.

You need a running FinSight instance somewhere you can reach (self-hosted, e.g. on your own server via Tailscale/LAN, or a public URL). The instance URL is set in the widget settings (default `https://finsight.cresta.digital`, the author's public instance — point it at your own).

## Settings

| Setting | Default | Description |
|---|---|---|
| Refresh interval | 900s | How often to poll the API (min 120s) |
| Base URL | finsight.cresta.digital | Your FinSight instance |
| Warning threshold | 500 | Balance under this → accent colour |
| Critical threshold | 200 | Balance under this → urgent colour |
| Bar shows | today | `today` / `month-end` / `year-end` / `none` |
| Account scope | primary | `primary` account or `all` accounts combined |
| Start hidden | on | Privacy eye state when the shell starts |

## Privacy & security

- **Your credentials go only to your FinSight instance.** The password is sent once over HTTPS to the `/api/auth/login` endpoint you configured, and is never written to disk.
- **The session cookie is stored locally** at `~/.local/state/omafinsight/session.txt` with `0600` permissions (directory `0700`). It is a bearer token for *your* instance only.
- The password travels over **stdin** into the login process — it never appears in a process argument list, so it can't leak via `/proc/<pid>/cmdline`.
- No telemetry, no third-party calls, no analytics. The plugin talks to exactly one host: the base URL you configure.
- **Amounts can be hidden at any time** (eye icon / `H`) — useful when streaming or screen sharing. Hidden state is per-session, not persisted.
- The Oma-App window is the same trust domain: it reuses the stored session, runs as your user, and only talks to your instance.
- **Sign out** = delete the session: `rm -rf ~/.local/state/omafinsight`.

## Dependencies

- Omarchy (with the Quickshell shell) — this is a bar plugin
- `curl` (pre-installed on Omarchy/Arch)
- A reachable FinSight instance (self-hosted — see the [FinSight repo](https://github.com/LinuxGamerUK/FinSight) to run your own; it's a single Node.js app + SQLite)

## Privileges

None. The plugin runs entirely as your user, makes no privileged calls, installs no services, and never downloads or executes third-party code at runtime.

## License

MIT — see [LICENSE](LICENSE).