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
with owner-only permissions. The default per-device budget is **1 GB (1,000,000,000 bytes)**, including space
reserved for SQLite's temporary files:

- At most one snapshot per minute, including across app restarts.
- On each write, discard snapshots older than seven days and retain at most 10,080 rows.
- Limit the database itself to 375 MB using SQLite's page limit. Evict the oldest rows before
  inserting when space is tight; the byte limit can shorten the retained time window.
- Use a rollback journal instead of a WAL, leaving room for a journal up to the database's
  size plus bookkeeping. A long-lived reader can delay a write but cannot cause a growing WAL.
- Reclaim free pages incrementally without creating a second full database copy.
- Skip writes when less than 1 GiB of actual disk space is available, or capacity cannot be read.
- Throttle retries on a full or busy disk to once per minute. Recording errors do not stop
  live monitoring or inference.

The storage policy applies only to this hardware-history database. Existing request history,
application logs and model downloads are separate.

## Validation

On macOS with Swift 6.3 and the macOS SDK:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_system_history.py' -v
```

This compiles the actual System collector and recorder and checks safe projection, automatic startup in a fresh directory,
permissions, missing values, restart throttling, pause behavior, age/count eviction, a reduced
byte budget, low-disk suppression and recovery after a reader blocks a commit.
