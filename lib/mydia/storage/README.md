# Storage

`Mydia.Storage` is the facade over where library files live: local
directories (`Mydia.Storage.Local`) and S3-compatible buckets
(`Mydia.Storage.S3`). A library path is local unless its path is
`s3://<backend name>/<prefix>`. Backends come from the `storage_backends`
table, `storage_backends:` in YAML, or `STORAGE_BACKEND_<N>_*` env vars
(layered like the rest of the config, see `lib/mydia/config/README.md`).

S3 libraries are fully supported: scanning, analysis and streaming (the read
path), and import, organize, rename, trash, delete, NFO and subtitle writes
(see Writes below).

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
  scheme into a path segment under the working directory. `Dirs.normalize/1`
  and `Dirs.inside?/2` are S3-safe, but `Path.expand/1` itself must still never
  see an `s3://` string.
- `Source` and `Location` carry the backend; `Location.key/2` builds the object
  key from the prefix and a relative path.

## Secrets and presigned URLs

Presigned URLs carry the signature in the query string and must never reach a
log, an Oban error, a DB column or a user-facing message. They are minted per
ffmpeg or ffprobe (re)start with a 12 hour expiry, and redacted at the source in
`Mydia.Library.Ffmpeg.invoke` (which scrubs error output) plus
`Storage.redact/1` (URL, query dropped) and `Storage.redact_text/1` (any term,
inspected and scrubbed) for everything that logs a URL. Secret keys use
`redact: true` on the schema fields. The secret access key is stored in the
database like the other service credentials (download client passwords, indexer
keys), and `secret_access_key` is a Phoenix filtered parameter.

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

Every call returns `{:error, %Error{kind: kind}}` with kind one of
`:not_found`, `:forbidden`, `:unreachable`, `:provider`, `:misconfigured` or
`:exists` (a refused exclusive create). `:misconfigured` is an unknown backend, a malformed storage
path or an unusable endpoint. Only `:not_found` means "the file is missing";
every other kind is treated as an outage or setup problem, and callers must
never delete, stamp or trash because of it.

- A scan that cannot reach the backend fails and trashes nothing. Only a
  definitive not-found for a file marks it missing.
- `CandidatePromotion` checks S3 existence with `Storage.stat` and keeps the
  candidate on any error other than `:not_found`.
- A storage backend that a library path still references cannot be deleted.
- Req retries (`:transient`, 3 attempts) cost about 7 seconds per call against a
  dead backend. Keep calls to an unreachable backend out of DB transactions
  where you can.

## Writes

Every write goes through the facade, so local and S3 libraries share one call
shape. Local code keeps its branch; S3 gets an explicit one for placement,
rename, trash, delete and item folders.

- `put_file/3` uploads a local file. Up to 64 MB it is a single PUT; above that
  it is a multipart upload with 64 MB parts read from disk, 4 parts in flight
  at once, so up to 4 parts (256 MB) in memory. A failed part stops the others
  and aborts the upload, and the object appears only after
  `CompleteMultipartUpload`, so nothing partial is ever visible.
- `put_binary/3` replaces an object atomically. `exclusive: true` sends
  `If-None-Match: *` after a HEAD check and returns `:exists` when the target is
  taken. `mkdir:` is local only and off by default, so an unmounted share never
  gets a directory tree created on the root filesystem.
- `copy/2` and `move/2` work across any backend pair: CopyObject within a
  bucket, `UploadPartCopy` above 5 GB (4 parts at a time), and a temp file for
  S3 to S3 across backends. A move is copy then delete; if the source delete
  fails, the copy is deleted and the error returned.
- `delete/1` is idempotent. `delete_prefix/2` refuses the whole location; on S3
  it deletes in batches of 1000 with `Content-MD5`.
- `ls/1` never turns an error into an empty listing.
- Path helpers for code that still holds a string: `at/1` (string to `Source`),
  `path_exists?/1`, `read_path/1` and `delete_path/1`. `MediaFile.storage_path/1`
  is the string form of a file's location, local or `s3://`.
- S3 ListObjectsV2 query strings are built with RFC 3986 encoding
  (`Request.bucket_query_url/2`). Req would encode a space as `+`, which SigV4
  rejects with a signature mismatch.

Behaviour to know:

- Imports copy into S3 and keep the source in place for seeding. `use_hardlinks`
  does not apply to S3 destinations.
- The S3 trash is `<library prefix>.mydia-trash/<media_file_id>/<basename>` in
  the same bucket. It ignores `MYDIA_TRASH_DIR`, and the trash audit and sweep
  do not cover it. The scanner's `:missing` trash stays database-only, since
  the object is already gone.
- `Dirs.prune_empty/2` is a no-op on S3, where folders do not exist on their own.
- `LibraryPath` accepts `auto_organize`, `auto_rename`, `write_nfo` and the
  default-library flags on `s3://` paths like on any other library.

## Tests

S3 tests run against RustFS, started by devenv (`mydia-s3`, part of
`./dev up`). They are tagged `:s3`; `test_helper.exs` includes them when a server answers at
`MYDIA_TEST_S3_ENDPOINT` and excludes them otherwise. `Mydia.S3Helpers` builds
the backend and fixtures from `MYDIA_TEST_S3_*`. CI sets `MYDIA_TEST_S3_REQUIRED=1` so a missing server fails instead.
`test/mydia/storage/flow_test.exs` is the end-to-end scenario (scan, analyze,
Range stream, deletion handling).
