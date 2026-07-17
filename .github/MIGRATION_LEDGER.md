# Historical Ticket Migration Ledger

This ledger maps every historical T-### ticket to its GitHub Issue number.
All new work uses GitHub issue numbers. Historical T-IDs are retained in issue
titles and bodies as searchable migration metadata.

| T-ID | Title | GitHub Issue | Status |
|------|-------|-------------|--------|
| T-016 | Wire fixture harness | #26 | Closed |
| T-017 | Pin and containerize reference agents | #27 | Closed |
| T-018 | Capture reference wire fixtures | #28 | Closed |
| T-019 | Live core interoperability matrix | #29 | Closed |
| T-020 | Lifecycle and failure compatibility | #30 | Open |
| T-021 | IO and SensorThings compatibility decision | #31 | Open |
| T-022 | Compatibility CI gates | #32 | Open |
| T-023 | Full package rename to Axoloty | #2 | Closed |
| T-024 | DocC catalog and containerized build | #3 | Closed |
| T-025 | Adopt ErrorKit and record error compatibility policy | #4 | Closed |
| T-026 | Establish the Swift 6.3 event-stream foundation | #5 | Closed |
| T-027 | Migrate one-way communication APIs to EventStream | #6 | Closed |
| T-028 | Remove RxSwift and close the migration release | #7 | Closed |
| T-029 | Organize tests by subsystem | #8 | Closed |
| T-030 | SwiftWasm/WASI feasibility spike | #33 | Open |
| T-031 | Migrate codebase errors to ErrorKit | #34 | Closed |
| T-032 | Migrate stored-property setter access syntax for Swift 6 | #35 | Closed |
| T-033 | Fix topic matcher wildcard exhaustion | #9 | Closed |
| T-034 | Make fuzz campaign artifacts complete on every exit path | #10 | Closed |
| T-035 | Dependency audit | #11 | Closed |
| T-036 | Remove vendored AnyCodable | #12 | Closed |
| T-037 | Deploy DocC documentation to GitHub Pages | #13 | Closed |
| T-038 | Cache Docker image and SwiftPM build artifacts in CI | #14 | Closed |
| T-039 | Migrate request/reply and communication IO streams | #15 | Closed |
| T-040 | Migrate IO routing to structured concurrency | #16 | Closed |
| T-041 | Diagnose containerized test command non-exit | #17 | Closed |
| T-042 | Integrate and remove the stale fuzz worktree | #18 | Closed |
| T-043 | Eliminate false-positive and assertion-free tests | #19 | Closed |
| T-044 | Make broker-backed Swift tests deterministic and fast | #36 | Closed |
| T-045 | Make the test-tier contract executable | #20 | Closed |
| T-046 | Optimize and harden the pull-request CI test graph | #37 | Closed |
| T-047 | Add a containerized source-coverage baseline and ratchet | #21 | Closed |
| T-048 | Add deterministic IO-routing module tests | #22 | Closed |
| T-049 | Run auditable fuzz campaigns in scheduled CI | #23 | Closed |
| T-050 | Migrate SensorThings to structured concurrency | #24 | Closed |
| T-051 | Migrate runtime and lifecycle ownership to structured tasks | #25 | Closed |

## Verification

- **Total T-IDs:** 36 (T-016 through T-051)
- **Open issues:** 4 (T-020, T-021, T-022, T-030)
- **Closed issues:** 32 (T-016–T-019, T-023–T-029, T-031–T-051)
- **No duplicates:** Every T-ID maps to exactly one GitHub Issue.
- **Source files preserved:** Local ticket files remain in `.agents/tickets/` for reference
