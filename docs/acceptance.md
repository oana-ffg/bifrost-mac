# Acceptance checks

This is the release checklist, not a record of completed verification.

## Build and public hygiene

- Build with the documented minimum Swift/macOS versions; run unit and integration tests.
- Verify the installed app signature, signing requirement, privacy strings and automation entitlement.
- Confirm tracked source contains no user paths, account IDs, signing certificates, secrets, calendar/history output, or local profiles.
- Confirm the public repository's license and documentation describe what is actually implemented and tested.

## Permission boundary

- Start the installed app through LaunchServices, independently of the invoking agent process.
- Call status from T3. Denied or not-yet-requested permissions must be explicit.
- Before Calendar authorization, a native read fails promptly without a consent prompt and without an empty-success result.
- Through explicit setup, request Calendar access. Confirm macOS names Bifrost in its prompt and System Settings.
- Query real events from T3 through the CLI and MCP adapter. Compare the same range directly through a configured EventKit integration, without persisting private content in source or public logs.
- Verify recurrence expansion for a real recurring series if one exists. Do not invent events merely to claim coverage.
- Preflight checks must fail for a missing required permission/profile and return a nonzero process status.
- Restart the app and repeat preflight and reads. Verify the signing requirement stays the same between builds with the same identity.

## Existing integrations

- Use a fixture to verify proxy initialization, binary/multiline stdio, stderr separation, EOF, child failure, cancellation and concurrent sessions.
- Register the actual installed Computer History client in local-only profiles.
- Through the proxy perform initialize, tools/list, then computer_history_status. Inspect whether the bootstrap succeeds; never infer success from an Automation grant alone.
- Do not change observation policies, start/stop the recorder or substitute filesystem freshness for successful live status.
- If the vendor client does not work through this ownership boundary, retain the failure and document the exact error. Do not claim it fixed.

## Unattended integration

- Configure both agent harnesses to find the native MCP server and the vendor proxy as appropriate, preserving unrelated configuration with a before/after comparison.
- Route the existing local Calendar helper through Bifrost with compatibility for its current arguments/output, via a separately reviewed change to the canonical agentfiles source.
- Run the actual nightly source preflight through the same paths it will use unattended. An already failed nightly run remains incomplete until its own report/publish steps have actually completed; building this app must not settle or overwrite that run.
- Confirm missing app, changed profile executable, permission revocation and service restart produce actionable errors. No automatic content logging or private result files.

## Known boundaries

macOS still requires a logged-in user session and explicit permission approvals. Computer sleep, remote-Mac selection, upstream application defects, revoked permissions and private entitlements are separate failure causes. Bifrost must report them rather than promise that all future runs cannot fail.
