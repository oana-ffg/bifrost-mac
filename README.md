# Bifrost

A native macOS companion that lets local AI agents use Mac capabilities independently of their host app's privacy declarations. Built for T3 Code and usable from other agent hosts.

**Trust model:** Bifrost exposes approved Calendar reads to processes running as your macOS user. It is not a sandbox between your agents and your personal data. There is no network listener, arbitrary command runner, or Calendar write API.

Bifrost is an early local-development release. Calendar permission and a logged-in Mac session are required. Computer History is not supported by the bridge: its vendor authentication rejects a companion-launched client.

## What works in this release

- A signed, independently running background app owns EventKit access.
- Read-only Calendar listing and event queries, with recurrence expansion, time zones, all-day dates, source coverage and explicit permission errors.
- A CLI and stdio MCP adapter with status, Calendar and unattended preflight tools.
- Explicit Calendar and per-app Automation permission setup. Ordinary reads never request permission.
- Start-at-login registration and an on-demand settings/diagnostics window with a metadata-only recent-access view. Event contents are not logged.

Accessibility control, screenshots, Reminders, Full Disk Access and a generic integration proxy are not implemented. Those require separate work and verification; a permission declaration alone is not an integration.

## Build and install

Requires macOS 14 or later and Xcode command-line tools with Swift 5.9 or later. The project has no third-party runtime dependencies.

```sh
scripts/check
scripts/build
scripts/install
/Applications/Bifrost.app/Contents/MacOS/bifrost start
```

The default build is ad hoc signed for development. For a reliable daily installation, set `BIFROST_SIGN_IDENTITY` to an existing signing identity when running `scripts/build`. The build derives a designated requirement from the certificate's team, rather than pinning a certificate fingerprint. Use that same identity/team and bundle identifier for subsequent builds. No certificates or signing configuration belong in Git.

Ad hoc signing can invalidate grants after rebuilds; `doctor` reports it as unsuitable for unattended use. A development-signed build is for your own Mac. Public binary distribution needs Developer ID signing and notarization; this project does not ship notarized binaries yet.

The installer requires the running app to be quit first. It archives a previous installation under the user's private `.bifrost/backups` directory before replacing it. `scripts/restore` restores a trusted archive when the destination app has been moved aside. Old archives are retained for deliberate recovery and are not live app registrations.

## Setup

Bifrost runs without a menu-bar item or Dock icon. Run `/Applications/Bifrost.app/Contents/MacOS/bifrost settings` to open its setup window when needed. Closing that window keeps the service running.

Request Calendar access from the setup window, or run:

```sh
/Applications/Bifrost.app/Contents/MacOS/bifrost permissions request calendar
/Applications/Bifrost.app/Contents/MacOS/bifrost login enable
/Applications/Bifrost.app/Contents/MacOS/bifrost doctor --json --require calendar,login
```

Approve the macOS prompt. If access was denied previously, review Bifrost in System Settings → Privacy & Security → Calendars. A start-at-login registration can require approval in System Settings → General → Login Items.

`doctor` runs a real, bounded Calendar query. It exits nonzero on missing permission, absent calendar coverage, unstable ad hoc signing, a wrong running-app location, or a required login item that is not enabled. Zero events is fine when calendars were actually covered. Calendar data is the locally synced copy; server sync freshness is not verified.

There is no supported command to silently grant macOS privacy permissions. After FileVault reboot, a user must log in before a user-session app can run.

## Agent access

Configure a stdio MCP server using:

- Command: `/Applications/Bifrost.app/Contents/MacOS/bifrost`
- Arguments: `mcp`

For Codex, a native user-configuration entry is:

```toml
[mcp_servers.bifrost]
command = "/Applications/Bifrost.app/Contents/MacOS/bifrost"
args = ["mcp"]
```

For Claude Code, use its supported CLI:

```sh
claude mcp add --scope user --transport stdio bifrost -- /Applications/Bifrost.app/Contents/MacOS/bifrost mcp
```

Restart or reconnect the relevant agent session after configuration. T3's provider sessions use their provider's MCP configuration; verify the tools in the actual session. A successful terminal call is not proof that every agent sandbox can connect. MCP servers launched by the host are the primary route; a sandboxed CLI can require ordinary host-access approval.

Tools: `bifrost_status`, `bifrost_doctor`, `bifrost_calendars`, `bifrost_events`. All are read-only. Run `bifrost_doctor` with required capabilities before relying on unattended results. A failed tool returns `isError: true`, rather than a successful empty agenda.

The `apple-calendar` subcommand preserves the existing skill’s argument and JSON shape. Its default time zone is the Mac’s current zone; callers needing a fixed zone should pass `--timezone`. It also includes event status so canceled meetings remain distinguishable.

For CLI usage and event-query arguments, run the installed binary with `--help`. Event ranges have an exclusive end and a maximum length of 366 days. Use `--timezone` to select an IANA time zone; the app's current zone is the default. Calendar IDs are local-store identifiers, and occurrence IDs are not durable cross-device IDs.

## Automation and Computer History

`bifrost automation check` takes an already running app's bundle identifier and checks OS authorization without prompting. `bifrost permissions request automation` takes that same identifier and explicitly requests permission. Checks are bounded and report unresolved OS calls. These commands check macOS permission only; they do not execute scripts or prove that a vendor accepts the client.

A signed-app test proved that macOS attributes an app-launched client to Bifrost, independently of T3. After macOS Automation access was explicitly authorized, the installed Computer History client returned `Sender process is not authenticated` from its read-only status call. The companion-launched path is therefore rejected by vendor authentication. The diagnostic route was removed; no proxy or identity workaround is shipped.

T3 0.1.2 and the inspected upstream source still lack the Apple Events entitlement and usage description. [T3 issue #21282](https://github.com/pingdotgg/t3code/issues/21282) tracks the packaging defect. A corrected T3 build must preserve the normal Codex client ancestry, obtain its own Automation approval, and pass an actual Computer History status call before recovery can be claimed.

## Development

Run `scripts/check` for Swift tests, MCP lifecycle/error tests, tracked-source privacy checks, CLI linkage checks and resource/script validation. `scripts/build` produces the signed app bundle in ignored `dist/`.

CI does not grant TCC permissions or read real calendars. Real-device acceptance checks are in [docs/acceptance.md](docs/acceptance.md). The rationale and boundaries are in [docs/design.md](docs/design.md); the local protocol is in [docs/protocol.md](docs/protocol.md).

MIT licensed. Local configuration, diagnostics, signing material and private results must stay outside tracked source.
