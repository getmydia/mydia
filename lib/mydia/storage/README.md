# Storage

`Mydia.Storage` is the facade over where library files live: local
directories (`Mydia.Storage.Local`) and S3-compatible buckets
(`Mydia.Storage.S3`). A library path is local unless its path is
`s3://<backend name>/<prefix>`. Backends come from the `storage_backends`
table, `storage_backends:` in YAML, or `STORAGE_BACKEND_<N>_*` env vars
(layered like the rest of the config, see `lib/mydia/config/README.md`).

PR 1 of the S3 work is the read path. Everything that writes is refused for S3.

## The seam

- `MediaFile.absolute_path/1` is `nil` for S3 files. Code that reads a file
  asks `Storage.source/1` for a `%Source{}` and then uses `Storage.stat/1`,
  `read_range/3`, `stream_range/5`, `input/1` (an absolute path locally, a
  presigned URL for S3) or `media_input/1` (source, existence check and input
  in one call). Do not `File.*` a `MediaFile` without checking `Storage.s3?/1`
  or going through the seam. `s3?/1` on a `MediaFile` needs `library_path`
  preloaded; an unloaded association reads as local.
- `s3://` strings survive `Path.join/2`, `Path.relative_to/2` and
  `Path.dirname/1`, but **never** pass one to `Path.expand/1`: it turns the
  scheme into a path segment under the working directory. `Dirs.inside?/2`
  expands, so keep `s3://` values away from it.
- `Source` and `Location` carry the backend; `Location.key/2` builds the object
  key from the prefix and a relative path.

## Secrets and presigned URLs

Presigned URLs carry the signature in the query string and must never reach a
log, an Oban error, a DB column or a user-facing message. They are minted per
ffmpeg or ffprobe (re)start with a 12 hour expiry, and redacted at the source in
`Mydia.Library.Ffmpeg.invoke` (which scrubs error output) plus
`Storage.redact/1` (URL, query dropped) and `Storage.redact_text/1` (any term,
inspected and scrubbed) for everything that logs a URL. Secret keys use
`redact: true` on the schema fields.

## Streaming

- Clients are always proxied through Mydia, never redirected to a presigned URL.
  p2p clients cannot reach the bucket directly, and a bucket on a LAN-only
  server (MinIO, RustFS) is not reachable from the client either.
- `RangeHelper.send_source_ranged/2` serves HTTP direct play. `stream_range`
  runs with retries off (a retry would resend bytes already written to the
  client); `read_range` and `stat` keep the default retries.
- Bandit 1.12.5 keeps `content-length` when a response uses `send_chunked`
  (observed with a real Bandit server in `range_helper_source_test.exs`), so no
  small-range fallback was built.
- HEAD requests are recorded by `MydiaWeb.Plugs.RecordHeadRequest` before
  `Plug.Head` rewrites them to GET, so an S3 HEAD answers from `stat` and never
  reads the object.
- HLS and remux hand ffmpeg a presigned URL from `Storage.input/1`.
  p2p streaming reads through `Storage.stream_range/5` as well.

## Failure behaviour

- A scan that cannot reach the backend fails and trashes nothing. Only a
  definitive not-found for a file marks it missing.
- `CandidatePromotion` checks S3 existence with `Storage.stat` and keeps the
  candidate on any error other than `:not_found`.
- Req retries (`:transient`, 3 attempts) cost about 7 seconds per call against a
  dead backend. Keep calls to an unreachable backend out of DB transactions
  where you can.

## Read-only guard

`Storage.ensure_writable/1` returns `{:error, %Error{kind: :read_only}}` for S3
libraries; import, organize, rename, user-facing trash and delete, and sidecar
writes call it first. `LibraryPath` also refuses `auto_rename` and write toggles
on `s3://` paths, and the admin UI disables them.

`TrashStore.store` is deliberately not guarded: the scanner's `:missing` trash
is database-only (the object is already gone), so it never writes to the bucket.
`Library.trash_media_file` refuses every other reason for S3.

PR 2 (write path) removes the guard, adds `put_file`, `copy`, `move` and
`delete` to the backend behaviour, and then this section.

## Tests

S3 tests run against RustFS, started by devenv (`mydia-s3`, part of
`./dev up`). They are tagged `:s3`; `test_helper.exs` includes them when a server answers at
`MYDIA_TEST_S3_ENDPOINT` and excludes them otherwise. `Mydia.S3Helpers` builds
the backend and fixtures from `MYDIA_TEST_S3_*`. CI sets `MYDIA_TEST_S3_REQUIRED=1` so a missing server fails instead.
`test/mydia/storage/flow_test.exs` is the end-to-end scenario (scan, analyze,
Range stream, deletion handling).
