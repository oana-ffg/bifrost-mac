# Local protocol, version 1

The CLI is a client; the independently running app owns protected operations.

## Transport

Default socket: the user's `.bifrost/run/bridge.sock`. A private directory, same-UID checks, private socket and lifetime lock govern access. The socket path must be ASCII and at most 103 bytes. There is no network listener.

Each message is a four-byte unsigned network-order length followed by a UTF-8 JSON object, up to 8 MiB. One request/reply per connection. Request fields: `version: 1`, `method` string, optional `params` object. A reply includes `version: 1` and either `ok: true, result` or `ok: false, error: {code, message}`. Failed queries never become successful empty results.

At most 16 connection workers are active. Initial framing has a five-second deadline, and reply writes are bounded. Native Calendar queries have bounded ranges and result counts. EventKit's synchronous framework call itself is not cancellable; a client deadline does not imply that macOS has canceled the operation.

## Methods

- `status`: app version/location, signing, Calendar permission, login-item state.
- `calendar.list`: identifiers, names and sources. Requires prior Calendar approval.
- `calendar.events`: required `start` and `end` ISO 8601 timestamps, end exclusive; optional nonempty `calendarIDs` array and IANA `timezone`. Maximum 366 days and 10,000 occurrences. Includes covered calendars and `local_sync_not_verified` freshness.
- `permissions.request`: explicit setup only. `capability: calendar`, or `capability: automation` with `target` bundle identifier. Denial/timeout is a failure.
- `automation.check`: `target` bundle identifier of a running app. No prompt. Reports OS authorization independently of vendor functionality.
- `ui.open`: explicit CLI/GUI setup only; opens the settings window without changing background service operation.
- `login.set`: explicit setup with `enabled` boolean. Result reports whether registration is enabled or still needs approval.

There is no profile configuration, command runner, stdio proxy, or remote transport in version 1.

## MCP

`bifrost mcp` uses newline-delimited JSON-RPC on stdio. Tools are `bifrost_status`, `bifrost_doctor`, `bifrost_calendars`, and `bifrost_events`. All are read-only. Tool failures use `isError: true`. Protocol versions 2024-11-05, 2025-03-26, 2025-06-18 and 2025-11-25 are negotiated. Initialize and send `notifications/initialized` before normal requests. Only protocol messages go to stdout; diagnostics go to stderr.

Permission and login setup are intentionally absent from the MCP tool surface. Configure provider clients through their supported stdio MCP mechanism, then verify from their actual runtime and sandbox.
