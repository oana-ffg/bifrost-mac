# Bifrost design

Status: initial Calendar bridge implemented and verified on device. Claude's delayed review of an earlier revision is reconciled; a follow-up on the fixes is pending; Computer History remains unresolved. See acceptance.md for the verified scope.

## User requirement

Use T3 Code with different AI agents for interactive and unattended Mac work, without the host application's missing privacy declarations breaking integrations. The motivating failures were Calendar access and the Computer History client's Apple Events bootstrap. The project is public open source; personal content, signing material, machine configuration and private diagnostics must remain outside Git.

The companion is useful independently of an upstream T3 packaging fix: it owns narrowly exposed capabilities, supports other agent hosts, and can evolve independently of T3's release schedule. It does not guarantee that unattended work can never fail, or bypass restrictions imposed by Apple or integration vendors.

## Architecture

`Bifrost.app` is an AppKit background app installed under `/Applications`. It has no menu-bar item or Dock icon. The settings and diagnostics windows open only on explicit request; closing them keeps the service alive. LaunchServices or its user-approved login item starts it independently of T3. The `bifrost` executable is only a client and stdio MCP adapter; it does not link EventKit. All protected Calendar operations occur inside the app.

A Unix socket under the user's private `.bifrost/run` directory provides the local interface. The directory is mode 0700 and socket mode 0600. Both ends check peer UID. The app holds a lifetime file lock, checks ownership/type before removing stale sockets, and removes only its own socket inode. Framing, deadlines and concurrency are bounded. A disconnected client is a connection failure and does not terminate the service.

Any same-user process that can reach this socket can use its exposed read capabilities. This is a deliberate trust boundary, not protection against arbitrary code already running as the user. There is no TCP listener and no arbitrary command or script execution API. The in-memory recent-access log contains only timestamp, peer PID, method, success and result count; it never stores event contents. It is limited to 40 entries.

## Calendar behavior

EventKit full access is requested only through explicit setup. macOS grants read/write Calendar access at that level; Bifrost's API exposes reads only. Every read rechecks permission, refreshing EventKit after an authorization-state change. Denied access is an error, never an empty agenda.

Queries use exclusive-end ISO 8601 ranges, at most 366 days, with at most 10,000 occurrences. Unknown calendar identifiers fail. EventKit expands recurring occurrences; occurrence IDs include the store item and occurrence time so a series does not collapse into one ID. Results include status, source coverage, caller-selected time zone and explicit all-day date fields. Local sync freshness is not verified. A preflight with no covered calendars is degraded, even when zero events would otherwise be legitimate.

## Setup and unattended operation

Use the on-demand settings window or CLI to approve Calendar and target-specific Automation access. Read-only MCP tools never request permission. `doctor` probes required sources with real bounded operations and exits nonzero when requirements are unmet. It checks the app location, stable signing, Calendar coverage, and the login item when requested. A running process or permission toggle alone is insufficient proof of a working integration.

Automation permission calls use a separate bounded coordinator because the macOS API can wait on consent even for a non-prompting check. The CLI request deadline is not presented as cancellation of the underlying OS call. At most four OS calls can remain pending, and duplicate checks are coalesced.

The app is not App Sandbox enabled. Hardened Runtime still requires the Calendar resource-access entitlement as well as the usage description; both are embedded and checked. Development signing uses a stable designated requirement anchored on the certificate's Team OU. Ad hoc builds are unsuitable for unattended updates because grants may be invalidated. Public binary distribution requires Developer ID and notarization, which are not claimed here. Updates are manual and keep compressed recovery archives.

## Independent Claude review and reconciliation

Claude reviewed the design before implementation and independently reviewed the initial implementation. The implementation review found a connection-setup failure that could stop the listener. That was fixed and a disconnect-before-accept regression test added. Calendar time zones, occurrence identity, event status and permission-change handling were corrected. The CLI's LaunchServices completion uses synchronized state. The CLI/EventKit boundary is checked by linkage tests.

A delayed Claude review found that all-day civil dates moved when the caller selected another time zone, and that malformed MCP IDs were echoed. Regression checks reproduced both failures before correction. All-day projection now preserves calendar dates and query membership across zones and daylight-saving changes, normalizing EventKit's inclusive 23:59:59 ends to exclusive next-day boundaries; timed events retain their instants. MCP IDs are restricted to strings or integers. Unknown listener errors are fatal rather than spinning. The always-JSON doctor retains `--json` for compatibility with existing callers.

The design review required a minimal signed-app test before a generic proxy. The test proved independent Bifrost TCC responsibility. After explicit macOS Automation authorization, the vendor client's read-only status call returned `Sender process is not authenticated`. This confirms vendor rejection of the companion-launched path. The diagnostic route was removed. Recovery now requires a T3 packaging fix that preserves normal Codex client ancestry, followed by a real status test under that corrected host.

A generic proxy was therefore deferred: there is no verified working integration justifying that privileged code yet. There is no private responsibility-disclaim API, trusted-parent insertion, or vendor allowlist workaround. Accessibility driving, screen capture, Reminders and Full Disk Access are separate future integrations, not implied by this release.

## Acceptance

Core tests cover request validation, time ranges, permission error envelopes, private runtime paths, file preservation, locking, stale sockets, concurrency, fragmented frames, oversize frames, deadlines and early disconnection. MCP tests cover initialization, schemas, protocol errors and clean stdout. CI performs those tests without touching user data or granting permissions.

Real acceptance additionally requires approved Calendar reads from T3, recurrence/all-day verification where actual events exist, a rebuild/reinstall with retained grant, login item verification, and both harnesses' real MCP access. Existing Calendar skill routing must be migrated through its canonical source and reviewed independently. Building Bifrost does not complete or settle an earlier failed nightly run.

## Primary references

- https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription
- https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events
- https://developer.apple.com/documentation/servicemanagement/smappservice
- https://developer.apple.com/documentation/security/applying-launch-environment-and-library-constraints
- https://modelcontextprotocol.io/specification/2025-11-25/basic/transports

- https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime
