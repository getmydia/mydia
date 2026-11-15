# S3-compatible buckets in the player's files library

## Why

The files library (`design/specs/2026-11-06-player-files-library-design.md`)
reads local folders, WebDAV shares, SMB shares
(`design/specs/2026-11-07-player-smb-files-design.md`) and paired players.
A viewer who keeps media in object storage, whether a public cloud bucket
(AWS S3, Backblaze B2, Cloudflare R2, Wasabi) or a self-hosted server on the
LAN (MinIO, RustFS, Garage), has no way in.

This is the first of two cloud specs. Consumer clouds behind OAuth (Google
Drive, Dropbox, OneDrive) come in a second spec: they need sign-in flows on
every platform, token refresh and app registrations with outside approval
(Google's restricted `drive.readonly` scope requires verification and a
yearly security assessment), none of which S3 needs.

## Goal

Add S3-compatible storage as a files backend, so a bucket scans, matches,
plays, downloads, casts and is lent to paired players exactly like a WebDAV
share, on every native platform.

Success: a B2 bucket and a LAN RustFS bucket are each added with an access
key, browsed, scanned, and a large remux plays with seeking. A wrong key, a
wrong bucket, a wrong region and a skewed clock each produce a message that
names the cause.

## Decisions

| Question | Decision |
| --- | --- |
| Audience | Anyone with a bucket: public clouds and self-hosted servers alike |
| What an account is | One bucket at one endpoint, optionally narrowed to a key prefix |
| Implementation | Pure Dart backend with a hand-rolled SigV4 signer; no Rust, no new package |
| How mpv reads a file | A presigned GET URL, valid 12 hours, with no headers |
| Addressing | Virtual-hosted style for `*.amazonaws.com`, path style for everything else; overridable |
| Discovery | None; the bucket is entered in a form with provider presets |
| Web | Not supported, filtered out like WebDAV and SMB (it would need bucket CORS) |

### Rejected

- **A Rust crate (`object_store`) over FRB, like `mydia_smb`.** With
  presigned URLs no video byte passes through the backend: mpv, the
  downloader, the cast receiver and the peer host fetch straight from the
  bucket. What is left is listing, `HEAD` and signing, which Dart already does
  well over the `http` and `xml` packages the WebDAV backend uses. A crate
  would add cargokit builds on four targets, FRB surface and a few MB per
  Android ABI for that. SMB went to Rust because no Dart SMB client exists and
  mpv needed a loopback server; neither holds for S3. The cost of going
  without the crate is learning provider quirks ourselves, which the
  compatibility table below and the RustFS integration test cover.
- **A pub package (`minio`, `aws_signature_v4`).** `minio` is lightly
  maintained, and Amplify's signer brings a large dependency tree for one
  function. Presigning is the only subtle part, and AWS's published test
  vectors pin it down.
- **A loopback proxy for playback** (the SMB design). Every provider in
  scope serves HTTP range requests on a presigned URL, so there is nothing to
  proxy.

## Architecture

Only the signer, the backend, the account plumbing and the add screen are
new. `FileScanner`, `FileMatcher`, `FileLibraryIndex`, the Folders view, the
files playback session, downloads and media info are unchanged, because S3
sits behind the existing `FileSystemBackend` interface.

### `backend/s3_signer.dart`

AWS Signature Version 4, with two entry points:

- `sign(request)`: adds `Authorization`, `x-amz-date` and
  `x-amz-content-sha256` (`UNSIGNED-PAYLOAD` is never used; every request this
  backend sends has an empty body, whose hash is a constant).
- `presign(method, uri, expires)`: returns the URL with
  `X-Amz-Algorithm`, `X-Amz-Credential`, `X-Amz-Date`, `X-Amz-Expires`,
  `X-Amz-SignedHeaders=host` and `X-Amz-Signature` in the query.

Canonical URI encoding follows the SigV4 rules: every byte other than the
unreserved set `A-Z a-z 0-9 - _ . ~` is percent-encoded with uppercase hex,
`/` is kept in the path and encoded in query values, and S3 paths are not
normalized (a key may contain `//` or end in a space). It depends only on
`crypto`, which the player already uses, and on an injectable clock.

### `backend/s3_backend.dart`

`S3Backend implements FileSystemBackend`. Paths the backend hands out are
relative to the account's prefix and start with `/`: under prefix `media/`,
the key `media/Movies/x.mkv` is the path `/Movies/x.mkv`.

- `list(dir)`: `ListObjectsV2` with `delimiter=/`, `prefix=<prefix><dir>/`
  and `max-keys=1000`, following `NextContinuationToken` until the listing is
  complete. Each `CommonPrefixes` entry becomes a directory with size 0 and
  `modified` at the epoch (S3 folders have no time). Each `Contents` entry
  becomes a file with its `Size` and `LastModified`. The zero-byte `dir/`
  marker objects that web consoles create are skipped. An object whose
  `StorageClass` is `GLACIER` or `DEEP_ARCHIVE` is listed as `unreadable`,
  since a GET on it fails until it is restored.
- `stat(path)`: `HeadObject`. On 404 it lists `<path>/` with `max-keys=1`: a
  hit is a directory, a miss is null.
- `playable(path)`: `presign('GET', …, 12 hours)` with no headers. The 12
  hours match the server's presigned URLs (`lib/mydia/storage/README.md`).
- `probe()`: `ListObjectsV2` with `max-keys=1` under the prefix. It needs
  `s3:ListBucket`, which every other call needs too; `HeadBucket` would add a
  second permission to explain for no gain.

### `LazyS3Backend`

In `files_providers.dart`, beside `LazyWebDavBackend` and built the same
way: on first use, from the account's connection and the credentials in
`SourceSecrets`. `backendFor` gains an S3 branch ahead of the WebDAV
fallback.

### The account

- **Id.** `3` followed by the first 16 hex characters of SHA-256 over
  `normalizeS3Url`, with `isS3AccountId` beside `isSmbAccountId`. (`s` is
  SMB's prefix, so S3 cannot use it.)
- **Connection.** The account's one server has one connection,
  `s3+https://<endpoint host[:port]>/<bucket>/<prefix>?region=<r>&style=<path|vhost>`
  (`s3+http` for a plain-HTTP LAN endpoint). `normalizeS3Url` lowercases the
  scheme and host, drops a default port, keeps the bucket and prefix as given
  (keys are case sensitive), strips trailing slashes from the prefix and
  sorts the query. The same bucket typed two ways is one account; adding it
  again opens the existing one.
- **Credentials.** `S3Credentials` (`accessKeyId`, `secretAccessKey`) is
  stored as the account token in `SourceSecrets`, as `WebDavCredentials` is.
  The secret is never in the connection URI.

### Addressing style

`style=vhost` sends requests to `https://<bucket>.<endpoint>/<key>`;
`style=path` sends them to `https://<endpoint>/<bucket>/<key>`. The add
screen picks `vhost` for an endpoint ending in `.amazonaws.com` (AWS no
longer serves path style for buckets created since 2020) and `path` for
every other endpoint, which MinIO, RustFS, Garage, B2, R2 and Wasabi all
accept. An advanced toggle overrides it.

### Provider compatibility

| Provider | Endpoint preset | Region | Style | Notes |
| --- | --- | --- | --- | --- |
| AWS S3 | `s3.<region>.amazonaws.com` | the bucket's | vhost | Wrong region answers `PermanentRedirect` naming the right one |
| Backblaze B2 | `s3.<region>.backblazeb2.com` | from the endpoint | path | Application keys scoped to one bucket cannot list buckets; probe lists the bucket, so they work |
| Cloudflare R2 | `<account id>.r2.cloudflarestorage.com` | `auto` | path | Signs with region `auto` |
| Wasabi | `s3.<region>.wasabisys.com` | the bucket's | path | |
| Other / self-hosted | typed in full; `http://` allowed | `us-east-1` unless set | path | RustFS, MinIO, Garage. Garage's default region is `garage` and is typed by hand |

### Existing code that learns about S3

- `filesAccountKind` (`core/p2p/peer_files_host.dart`) returns `s3`. Today
  every non-local, non-SMB id falls through to `webdav`, which would mislabel
  an S3 account to paired players.
- `filesDedupeKey` returns `normalizeS3Url` of the connection.
- The router gains the add route and the account detail branch, next to
  SMB's.
- The platform filter that hides WebDAV and SMB on web hides S3.

### Paired players

The peer host answers a grant with `playable()`'s URL and headers, and Rust
fetches it. A presigned URL needs nothing more, but a grant held past its 12
hours would fail. When a granted fetch answers `403`, the Rust side drops the
grant and asks the host for a fresh one once before failing the read.

## Add flow

`presentation/screens/sources/add_s3_screen.dart`, reached from "Add files
source" beside WebDAV and SMB.

1. **Provider.** AWS, Backblaze B2, Cloudflare R2, Wasabi, or Other. The
   choice fills the endpoint template, region default and style.
2. **Fields.** Endpoint, region, bucket, access key, secret key, and an
   optional prefix. The prefix can be typed or picked with
   `remote_folder_picker` once the keys work. Advanced: the addressing style.
3. **Save** builds a backend from the form and runs `probe()`. On success it
   stores the account and secret and starts the first scan, as WebDAV does. On
   failure it shows the mapped message below and keeps the form.

The secret field is obscured, and the account detail page never shows it
again; changing it means typing a new one.

## Errors

Mapped onto the existing `BackendFailure` kinds from the HTTP status and the
`<Code>` in the XML error body:

| Condition | Failure | Message |
| --- | --- | --- |
| DNS failure, refused, timeout, TLS failure | `BackendUnreachable` | Can't reach the endpoint |
| `InvalidAccessKeyId`, `SignatureDoesNotMatch` | `BackendUnauthorized` | The access key or secret is wrong |
| `RequestTimeTooSkewed` | `BackendUnauthorized` | This device's clock is more than 15 minutes off |
| `AccessDenied` on probe or list | `BackendUnauthorized` | These keys can't list this bucket |
| `AccessDenied` on one object's `HEAD` | entry marked `unreadable` | (none; the listing goes on) |
| `NoSuchBucket` | `BackendNotFound` | No bucket with this name at this endpoint |
| `PermanentRedirect`, `AuthorizationHeaderMalformed` | `BackendUnreachable` | The bucket is in region X (X read from the error body when present) |
| Any other 4xx or 5xx | `BackendUnreachable` with the status | The server answered with an error |

The player does not try to correct a skewed clock; it names the cause.

## Secrets

The server's rule (`lib/mydia/storage/README.md`, "Secrets and presigned
URLs") applies here too: a presigned URL or an `Authorization` header never
reaches a log, a `toString`, an error message or a crash report.

- `redactS3Url` drops the query string. Every `debugPrint` that mentions an S3
  URL goes through it.
- `BackendFailure` messages built by `S3Backend` name the endpoint, bucket and
  key, never a URL with a query.
- The grant-failure log in `PeerFilesHost._grantFor` prints the failure kind,
  not the exception text, so a future backend cannot leak through it either.

## Edge cases

- **Large folders.** Listing is per folder (delimiter `/`), never a flat walk
  of the bucket. A folder of 50,000 objects is 50 sequential requests; the
  scanner already awaits each `list`.
- **URL expiry during playback.** Twelve hours covers any single title.
  Playback reopened after a long pause re-resolves `playable()` through the
  files playback session, which it already does on reopen; a test pins it.
  A download takes a fresh URL each time it resumes.
- **Archived objects.** Glacier and Deep Archive objects are `unreadable`:
  never scanned, never offered for play.
- **Cost.** Each scan lists every folder and `HEAD`s only entries whose size
  or time changed. The existing six-hour rescan interval applies. Egress is
  the viewer's own bill and the screen says nothing about it.
- **Casting.** The cast bridge proxies the presigned URL as it proxies any
  `PlayableFile`. A plain-HTTP LAN endpoint on iOS and macOS needs the same
  App Transport Security allowance plain-HTTP WebDAV relies on; the plan
  confirms which one.

## Testing

- **Signer.** AWS's published SigV4 test-suite vectors for header signing,
  and AWS's documented presigned-URL example, byte for byte. Fixtures of our
  own for keys with spaces, `+`, `//`, non-ASCII characters and a trailing
  slash.
- **Backend, against a fake `http.Client`** (the WebDAV tests' pattern):
  pagination across continuation tokens, `CommonPrefixes` to directories,
  marker objects skipped, archived objects unreadable, prefix stripping,
  `stat` telling a folder from a missing path, one case per row of the error
  table including the region read from the body, and an assertion that no
  failure's `toString` contains `X-Amz-Signature` or the secret.
- **Integration, against RustFS.** The `mydia-s3` devenv script and the CI
  step that starts it for the server's `:s3` tests already exist. The test
  creates a bucket, uploads a small tree (one key with spaces and non-ASCII
  characters), runs `probe`, `list` and `stat`, fetches `playable()` with a
  `Range` header and checks the `206` and its bytes, and checks that a URL
  presigned in the past answers `403`. It is skipped when
  `MYDIA_TEST_S3_ENDPOINT` is unset, as the server's tests are, and runs in a
  player CI job beside a RustFS step.
- **Wiring.** `backendFor`, `filesAccountKind` and `filesDedupeKey` give the
  S3 answer for an S3 id; `normalizeS3Url` makes one account of the same
  bucket typed two ways; web hides the S3 option.
- **Add screen, widget test.** A preset fills the endpoint, region and style;
  a probe failure shows its mapped message; success stores the account with
  the secret in `SourceSecrets` and not in the connection.
- **Manual, before merge.** A real B2 or R2 bucket: add, scan, and play a
  large file with seeking on desktop and Android. RustFS does not reproduce
  every provider's quirks.

## Out of scope

- Google Drive, Dropbox and OneDrive (the second cloud spec).
- Writing to a bucket: uploads, deletes, renames.
- Listing the buckets an access key can see. The bucket is typed.
- STS session tokens and IAM role credentials. Static access keys only.
- Server-side encryption with customer-provided keys (SSE-C), which needs
  headers on every GET and so cannot use a plain presigned URL.
