# Runtime waste audit

The audit found two avoidable costs on Calendar request paths. No idle polling
was found. The installed app and real Calendar data were not accessed.

## Occurrence formatting

Previously, `CalendarOccurrence.project` constructed two ISO formatters, one
day formatter, and two Gregorian calendars for every returned occurrence.
`CalendarService.events` called it once per occurrence, up to the existing
10,000-occurrence result limit.

The request now owns one `CalendarOccurrenceProjector`, reusing its calendars
and formatters across all occurrences. Each concurrent request gets its own
projector; mutable formatters are not shared between workers. Output fields,
civil-date projection, occurrence identities, sorting, and limits are preserved.

Measured with 10,000 synthetic occurrences, half all-day, projecting from
Copenhagen to New York:

| Formatter constructions | Before | After |
| --- | ---: | ---: |
| ISO8601DateFormatter | 20,000 | 2 |
| DateFormatter | 10,000 | 1 |

Run `python3 scripts/measure-projection.py origin/main` for the pre-fix source
while main still predates this change, and `python3 scripts/measure-projection.py`
for the working source. The script compiles the actual projection source with
constructor counters inserted into a temporary copy, using `swiftc -O`. It runs
no app or EventKit operation. Both revisions produced the same SHA-256 of the
complete sorted-key JSON output. The counter covers occurrence projection only,
not query parsing or response-envelope formatting.

`testProjectionReusesThreeFormattersForTenThousandOccurrences` asserts formatter
factory counts and distinct occurrence identities over 10,000 projections.
Existing tests retain cross-zone civil dates, inclusive all-day ends, DST,
timed-event instants, and zero-duration boundary coverage.

## Compatibility command queries

Previously, `bifrost apple-calendar` queried the requested range, today, and
tomorrow separately, even when the range covered both day sections. Each query
repeated native calendar enumeration, fetching, projection, and transport work.

The command now derives fully covered day sections from its range result using
the same overlap rule as the native service. Uncovered days still make their
own requests. Reuse lasts for this command only; no persistent cache is added.
Chunking, occurrence deduplication, stable ordering, and the JSON contract remain.

`python3 scripts/test-calendar.py .build/debug/bifrost` drives the actual CLI
and transport through a synthetic Unix socket in a private temporary HOME:

| Invocation | Event requests before | After |
| --- | ---: | ---: |
| Default two-day range, 10,000 returned occurrences | 3 | 1 |
| Today only | 3 | 2 |
| Tomorrow only | 3 | 2 |
| Historical range covering neither day | 3 | 3 |
| 366-day range spanning a chunk boundary | 4 | 2 |
| Maximum 3,660-day compatibility range | 13 | 11 |

One calendar-list request remains in every case. The harness compares all
output rows and counts requests; fixtures include spanning/all-day events,
distinct recurring occurrences, zero-duration events, exclusive-end boundaries,
and cross-chunk duplicates. It fails on the old CLI's redundant requests and
passes on the fixed CLI. `scripts/check` runs this regression in CI.

## Checked and rejected

- Idle work: no timers, scheduled permission checks, or status-item refreshes.
  The listener blocks in `accept`; setup and diagnostics are explicitly invoked.
- EventKit lifecycle: one store belongs to the app's service and is reused;
  reset occurs after an authorization-state change, not each request.
- Calendar enumeration: needed for current identifiers, coverage metadata, and
  rejecting unavailable calendars. No per-item processes or config reads exist.
- Range fetching: EventKit receives the selected calendars and bounded dates.
  Cross-zone padding and in-memory overlap filtering preserve all-day semantics;
  this is not a fetch of the entire event database. Recurrence is expanded by
  EventKit within the query, with a 366-day caller range and result-count limit.
- Concurrency: accept and request handling run off the main thread. Connection
  slots and pending Automation checks are bounded; duplicate checks coalesce.
- Storage: access history is in memory and capped at 40 entries. Runtime socket
  setup is not repeated per request. No event-history files or temporary copies
  are written on Calendar reads. Wire frames are limited to 8 MiB.
- Small fixed work such as status signing checks and copying the bounded access
  history did not justify speculative caching. No persistent growth or repeated
  whole-collection work was established there.

## Validation and limits

Measurements ran locally on arm64 macOS with Swift 6.4.2. Counts are the evidence;
elapsed times printed by the projection harness depend on shared-machine load.
Both CI commands, `scripts/check` and `scripts/build`, passed with an isolated
HOME. The latter used `BIFROST_SIGN_IDENTITY=-` and built/verified only the ignored
local bundle. Nothing was installed, launched, or registered as a login item.

Native EventKit store/fetch counts, recurrence expansion cost on real data,
Calendar permission behavior, live response latency, and idle energy were not
measured. The harness measures real projection code and real CLI request counts,
not Apple's framework internals. EventKit's synchronous call remains
uncancellable, as documented in the protocol. The occurrence-count check runs
after EventKit returns, so it does not cap allocations inside the framework.
Existing real-device acceptance
gates and documented Calendar edge cases are unchanged.
