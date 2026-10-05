# Local hardware diagnostic history

Nativ automatically keeps a bounded history of this Mac's hardware state for local troubleshooting
while the app is running. The recorder has no network code.

Each snapshot contains the public Mac model identifier, chip generation and tier, memory
capacity, CPU/core load, GPU and ANE activity where available, disk activity and health,
and temperature, fan and power readings. Unavailable readings remain null. Computer names,
serial numbers, volume names, paths and raw sensor names are omitted.

## Automatic recording

History starts with Nativ and continues while the System tab is closed. There is no enrollment,
marker file or setup step. The System page's Pause action also pauses history; Resume restarts it.
The initial CPU/disk baseline is skipped so it is not saved as a measured zero.

Quit Nativ before deleting `SystemTelemetry.sqlite3` to clear history. The next app launch
starts a new history automatically. No new settings UI is introduced by this change.

## Storage policy

The database is `~/Library/Application Support/Nativ/Diagnostics/SystemTelemetry.sqlite3`,
with owner-only permissions. The saved-history database is capped at **1 GB (1,000,000,000 bytes)**
per device. SQLite's temporary rollback journal uses additional working space during a write and
is removed after the transaction:

- At most one snapshot per minute, including across app restarts.
- Keep history regardless of age or row count while it fits within the storage budget.
- Limit the database itself to 1 GB using SQLite's page limit. Evict the oldest rows before
  inserting only when another snapshot would exceed the available page budget.
- Use a rollback journal instead of a WAL. A long-lived reader can delay a write but cannot
  cause a growing WAL.
- Reclaim free pages incrementally without creating a second full database copy.
- Skip writes when less than 1 GiB of actual disk space is available, or capacity cannot be read.
- Throttle retries on a full or busy disk to once per minute. Recording errors do not stop
  live monitoring or inference.

The storage policy applies only to this hardware-history database. Existing request history,
application logs and model downloads are separate.

## Validation

The existing Dev Build workflow runs `SystemTelemetryTests` and
`SystemMonitorObservationPolicyTests` in the `NativTests` target alongside the software-update tests.
After building the app with `make xcode-build`, run the hardware-history checks locally with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project Nativ.xcodeproj -scheme Nativ -configuration Debug \
  -derivedDataPath build/NativDevelopmentDerivedData \
  CODE_SIGNING_ALLOWED=NO NATIV_SKIP_PYTHON_RESOURCE_BUILD=YES \
  -only-testing:NativTests/SystemTelemetryTests \
  -only-testing:NativTests/SystemMonitorObservationPolicyTests test
```

These tests exercise the production recorder, including automatic startup, permissions, missing
values, throttling, pause behavior, retention below the budget, oldest-first eviction at the limit,
low disk space and recovery after a reader blocks a commit.
