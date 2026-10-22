# Acceptance and remaining gates

This records the scope of the initial implementation. Real-device evidence stays private; public documentation records outcomes without personal Calendar contents.

## Verified

- Swift tests, MCP lifecycle/error tests, tracked-source privacy checks, resource/entitlement validation and CLI linkage checks pass. Public macOS CI builds and checks the project.
- The installed app is signed with a stable Team-OU requirement, has the required Hardened Runtime resource entitlements, and runs independently through LaunchServices.
- Before Calendar approval, reads return an explicit error without prompting or reporting an empty agenda. After explicit approval, the real Calendar preflight passes.
- Real native, compatibility and MCP queries match over a date range containing all-day and recurring occurrences. Occurrence IDs remain distinct, all-day civil dates are preserved across output time zones, and unknown calendar IDs fail. A later real-data check preserved all Copenhagen occurrence identities and timed values, corrected inclusive all-day ends, and verified the civil dates in New York, Tokyo and Honolulu; compatibility output matches native queries.
- Restarting the app preserves the grant and passes a new real Calendar query. Start-at-login is enabled in the verified local installation.
- The canonical Calendar skill routing was independently reviewed by Claude and merged through agentfiles PR #27. The live plan changed only the four Calendar skill/documentation files across the two harnesses. Prior outputs were backed up, both live wrappers return matching real output, and Ratatoskr reports no pending changes or conflicts.
- Both provider user configurations contain the native stdio MCP entry, with unrelated settings preserved. The adapter-to-installed-app path was exercised from T3 with approved host access. A sandboxed direct CLI is explicitly reported as blocked rather than mistaken for a stopped app.
- Claude independently approved implementation commit `30018bc` with no blockers. Its clean-copy review passed the 12 Swift tests, MCP checks, tracked-source privacy, plist, shell syntax and CLI linkage checks, and independently exercised additional civil-date edge cases.
- Native MCP discovery and a real Calendar/login doctor call pass from both T3-hosted Codex and Claude. Claude's fresh session reported healthy on installed version 0.1.2, with authorized Calendar access, enabled login registration and a successful bounded Calendar query.

## Background presentation

Bifrost runs without a persistent menu-bar item or Dock icon. The CLI starts it without activation. `bifrost settings` explicitly opens the setup window; reopening the running app also opens settings. Closing settings leaves the service running. The CLI remains available for permission and startup setup.

## Remaining gates

- Direct sandboxed CLI access remains subject to host restrictions; the host-launched MCP adapter is the primary route.
- Automation authorization checks return authorized after the explicit grant. A fresh consent prompt through the bounded setup coordinator and the denied-state behavior have not been independently tested. `consent_required` deliberately avoids distinguishing an unrequested grant from a prior denial.
- Same-identity rebuild/reinstall preserves Calendar permission. Actual login-item startup after logout or reboot remains untested.
- Computer History is not recovered. After explicit macOS Automation authorization, the read-only status call returned `Sender process is not authenticated`, confirming rejection of the companion-launched client. The diagnostic route was removed and the supported app reinstalled. A corrected T3 build and a real status test under its normal Codex ancestry are still needed. No generic proxy, private API, or identity workaround is included.
- Calendar server sync freshness is not verified. The bridge reads EventKit's locally synced copy.
- The earlier failed nightly run retains its own unfinished work. Calendar source recovery does not complete, publish or settle that run.

## Known edge cases

- All-day projection assumes EventKit uses the Mac's current time zone. A Mac time-zone change while the app is running, or a Calendar.app time-zone override, has not been verified. Restart Bifrost after changing the Mac's zone and verify its Calendar output.
- With matching Mac/output zones, a query starting inside an all-day event's final inclusive `23:59:59` second can omit that occurrence. Normal day-boundary agenda queries are unaffected.

## Outside this release

Generic UI driving, screen capture, Reminders, Full Disk Access, arbitrary executable profiles, a stdio integration proxy, and remote-Mac transport are not implemented. Add an integration only with a concrete use case and real end-to-end verification. Do not infer capability from a privacy declaration alone.

## Operational boundaries

A user must log in after a FileVault reboot. Sleep, permission revocation, upstream application changes and vendor restrictions remain independent failure causes. Repeat the actual required-source preflight before unattended work and report failures honestly.
