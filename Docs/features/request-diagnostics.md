# Structured request failure diagnostics

New local request records include a fixed error category and numeric app/runtime versions so
failures can be investigated across upgrades. The existing SQLite request table is extended
in place; old records and aggregate counters remain compatible.

## Fields

- `error_code`: a fixed category on failed records. Typed memory, timeout and unsupported errors
  map to `out_of_memory`, `timeout` and `unsupported`. HTTP 400/422 map to `invalid_request`,
  408/504 to `timeout`, and 501 to `unsupported`. Other exceptions and HTTP 5xx map to
  `runtime_error`; unclassified HTTP errors use `unknown`.
- `app_version`: Nativ's bundle version passed to the child server as `NATIV_APP_VERSION`.
- `runtime_version`: the bundled inference backend version.

Version fields accept only two or three numeric components. Missing or unexpected strings
remain null. Existing records are not backfilled. Error classification inspects exception types
and HTTP status codes; it never reads exception text, response bodies or stack traces. These
new fields do not contain prompts, generated content or audio and add no network destination.
Existing server logging behavior is unchanged.

Cancellation is saved with `status = cancelled`, `finish_reason = cancelled` and a null error
category. Failed requests use `finish_reason = error`. Existing aggregate failed-attempt counters
continue including all non-completed attempts for compatibility; the per-request status gives
the distinction. Exceptions and cancellation continue propagating to their caller, including
while streaming or reading a buffered response.

## Applying the change

Rebuild Nativ and its bundled Python overlay, then restart the local inference server. The
server adds three nullable columns when opening its existing database. It stamps only newly
inserted records; duplicate request IDs keep the original record.

## Validation

```sh
python3 -m unittest discover -s scripts/tests -p 'test_request_diagnostics.py' -v
```

The tests execute the actual SQLite store, tracker and middleware without requiring MLX. They
cover existing-database migration, repeatable initialization, exception/status classification,
version validation, private-text rejection, streaming/buffered failures and cancellation.
