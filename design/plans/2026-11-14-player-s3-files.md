# S3-compatible buckets in the player files library: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add S3-compatible storage as a fourth files backend, so a bucket scans, plays, downloads, casts and is lent to paired players like a WebDAV share.

**Architecture:** A pure Dart `S3Backend` implements the existing `FileSystemBackend` over a hand-rolled SigV4 signer; `playable()` returns a 12 hour presigned URL, so no byte passes through the backend. The account is one connection URI (`s3+https://endpoint/bucket/prefix?region=&style=`) with the keys in `SourceSecrets`, and the add screen follows `AddWebDavScreen`'s connect, pick folders, save flow.

**Tech Stack:** Dart (`http`, `xml`, `crypto`, all existing dependencies), Riverpod, go_router, Flutter widgets; one Rust change in `player/rust/mydia_player_p2p`; RustFS for the integration test.

**Spec:** `design/specs/2026-11-14-player-s3-files-design.md`

## Global Constraints

- No new Dart or Rust dependency. `http`, `xml`, `crypto` are already in `player/pubspec.yaml`.
- Native only: every S3 entry point is hidden when `isWeb` (as WebDAV and SMB are in `add_source_screen.dart`).
- A presigned URL, an `Authorization` header or the secret key never appears in a `debugPrint`, `tracing` line, `toString`, exception message or crash report.
- The secret key is stored only through `SourceSecrets.writeAccountToken`; never in the connection URI or the account record.
- Presigned URLs expire after exactly 12 hours: `const kS3PresignExpiry = Duration(hours: 12)`.
- Request timeout `const kS3Timeout = Duration(seconds: 20)` (WebDAV's `kWebDavTimeout`).
- Plain `http://` endpoints are accepted only for private hosts (`isPrivateHost`), the rule `AddWebDavScreen` applies to credentials over `http`.
- Account id: `3` + first 16 hex chars of SHA-256 over `normalizeS3Url`; regex `^3[0-9a-f]{16}$`.
- No real movie or TV titles in tests or fixtures; invent them.
- User-facing text goes through `context.l10n` (ARB in `player/lib/l10n/app_en.arb`, per `player/docs/l10n.md`); provider and protocol names carry `// l10n-ignore`.
- Commits run inside the devenv shell (`direnv exec . git commit -F <msgfile>`), and each is checked with `git show --stat`.

## Review Focus

1. **Keys with reserved characters** (spaces, `+`, `&`, `#`, `%`, non-ASCII, a trailing space): a file listed by `list()` must open through `playable()` and `stat()`. Pinned by Task 3's `keys round-trip from list to playable` and Task 7's integration upload.
2. **The prefix typed in any shape** (`media`, `/media`, `media/`, `/media/`, empty): all name the same account and the same keys. Pinned by Task 4's `normalizeS3Url` cases.
3. **An endpoint typed without a scheme, or `http://` on a public host:** no scheme means `https`. `http` on a public host is refused before any request, and a TLS failure on a private host suggests `http://`. Pinned by Task 5's widget tests and Task 2's `HandshakeException` mapping.
4. **An expired URL in a paired player's read:** the first read after expiry must still succeed, not fail once and work on the retry. Pinned by Task 6's Rust test.
5. **An empty bucket, or a prefix with nothing under it:** probe succeeds and the picker shows an empty folder, not an error. Pinned by Task 3's `probe succeeds on an empty listing`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| Create `player/lib/core/sources/files/backend/s3_signer.dart` | SigV4 header signing, presigning, S3 URI encoding |
| Create `player/lib/core/sources/files/backend/s3_errors.dart` | Error-body parsing, status/code to `BackendFailure`, URL redaction |
| Create `player/lib/core/sources/files/backend/s3_backend.dart` | `S3Location`, `S3Style`, `S3Backend` |
| Modify `player/lib/core/sources/files/backend/file_system_backend.dart` | `BackendFailure` gains optional `code` and `hint` |
| Modify `player/lib/core/sources/files/files_account.dart` | `normalizeS3Url`, `s3AccountId`, `isS3AccountId`, `S3Credentials` |
| Modify `player/lib/core/sources/files/files_accounts.dart` | `addS3Account`, `addS3Root` |
| Modify `player/lib/core/sources/files/files_providers.dart` | `LazyS3Backend`, `s3ConnectorProvider`, `backendFor` branch |
| Modify `player/lib/core/p2p/peer_files_host.dart` | `filesAccountKind` → `s3`, `filesDedupeKey`, grant log prints kind only |
| Modify `player/lib/core/p2p/peer_files_client.dart` | `_dedupable` accepts `s3` |
| Create `player/lib/core/sources/files/s3_presets.dart` | `S3Preset` enum: endpoint, region and style per provider |
| Create `player/lib/presentation/screens/sources/add_s3_screen.dart` | The add / sign-in-again screen |
| Modify `player/lib/presentation/screens/sources/add_source_screen.dart` | The S3 tile |
| Modify `player/lib/core/router/app_router.dart` | `/sources/add/s3` route, `filesReauthLocation` branch |
| Modify `player/rust/mydia_player_p2p/src/peer_files_host.rs` | Re-grant once on upstream 401/403; scrub URLs from errors |
| Create `player/test/core/sources/files/backend/s3_integration_test.dart` | Against RustFS |
| Modify `.github/workflows/ci-player.yml` | RustFS service for `test-player` |
| Modify `player/lib/core/sources/README.md` | The S3 backend section |

---

### Task 1: SigV4 signer

**Files:**
- Create: `player/lib/core/sources/files/backend/s3_signer.dart`
- Test: `player/test/core/sources/files/backend/s3_signer_test.dart`

**Interfaces:**
- Produces:
  - `String s3UriEncode(String s, {required bool encodeSlash})`
  - `class S3Signer { S3Signer({required String accessKeyId, required String secretAccessKey, required String region, String service = 's3', DateTime Function()? clock}); Map<String, String> sign({required String method, required Uri uri, Map<String, String> headers = const {}}); Uri presign({required String method, required Uri uri, required Duration expires}); }`
  - `sign` returns the full header map to send: the given headers plus `host`, `x-amz-date`, `x-amz-content-sha256` (only when `service == 's3'`; the value is the SHA-256 of the empty body, `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`) and `authorization`. Every header given is signed.
  - `presign` signs only `host` and returns `uri` with the `X-Amz-*` query parameters added.

- [ ] **Step 1: Write the failing tests**

Expected values come from AWS's S3 SigV4 documentation, "Signature Calculations for the Authorization Header: Transferring Payload in a Single Chunk" (GET object example) and "Authenticating Requests: Using Query Parameters" (presigned example). The values below are from those pages. If they differ from the live page, the page wins.

```dart
const akid = 'AKIAIOSFODNN7EXAMPLE';
const secret = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY';
final at = DateTime.utc(2013, 5, 24);

test('signs the documented GET object request', () {
  final s = S3Signer(accessKeyId: akid, secretAccessKey: secret,
      region: 'us-east-1', clock: () => at);
  final h = s.sign(method: 'GET',
      uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      headers: {'range': 'bytes=0-9'});
  expect(h['authorization'],
      'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
      'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,'
      'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41');
});

test('presigns the documented URL', () {
  final s = S3Signer(accessKeyId: akid, secretAccessKey: secret,
      region: 'us-east-1', clock: () => at);
  final u = s.presign(method: 'GET',
      uri: Uri.parse('https://examplebucket.s3.amazonaws.com/test.txt'),
      expires: const Duration(seconds: 86400));
  expect(u.queryParameters['X-Amz-Signature'],
      'aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404');
  expect(u.queryParameters['X-Amz-SignedHeaders'], 'host');
});
```

Also add these tests:
- `s3UriEncode`: `'a b+c&d#e%f/é ~'` with `encodeSlash: false` gives `'a%20b%2Bc%26d%23e%25f/%C3%A9%20~'`, and with `encodeSlash: true` the `/` becomes `%2F`.
- `canonical path is not normalized`: signing `/a//b/` and `/a/b` gives different signatures, and the request URI keeps `//`.
- `query parameters are sorted and encoded`: `list-type=2&prefix=a b/&delimiter=/` signs identically in any input order.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player && flutter test test/core/sources/files/backend/s3_signer_test.dart`
Expected: FAIL, `s3_signer.dart` does not exist.

- [ ] **Step 3: Implement `s3_signer.dart`**

Use `crypto`'s `Hmac(sha256, …)` for the key derivation chain (`AWS4`+secret → date → region → service → `aws4_request`). The canonical URI is `uri.path` exactly as given. Callers build it with `Uri(path: …)`, which already percent-encodes, and S3 paths are never normalized (no collapsing of `//`, no decoding and re-encoding). The canonical query is sorted by encoded name and then value, each encoded with `encodeSlash: true`. The clock defaults to `DateTime.now().toUtc()`.

- [ ] **Step 4: Run them and see them pass**

Run: `cd player && flutter test test/core/sources/files/backend/s3_signer_test.dart`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add player/lib/core/sources/files/backend/s3_signer.dart player/test/core/sources/files/backend/s3_signer_test.dart
git commit -F <msgfile>   # feat(player): SigV4 signer for S3 files
```

---

### Task 2: Error mapping and redaction

**Files:**
- Modify: `player/lib/core/sources/files/backend/file_system_backend.dart` (`BackendFailure` and its four subclasses)
- Create: `player/lib/core/sources/files/backend/s3_errors.dart`
- Test: `player/test/core/sources/files/backend/s3_errors_test.dart`

**Interfaces:**
- Produces:
  - `BackendFailure` gains named `{String? code, String? hint}`; every subclass forwards them (`const BackendUnreachable([super.message, this.status, {super.code, super.hint}])`, the rest `([super.message, {super.code, super.hint}])`). `code` is the provider's machine-readable reason and `hint` a value the message needs (a region). Existing call sites compile unchanged.
  - `String redactS3Url(Uri u)`: `u` without query or fragment.
  - `BackendFailure s3Failure({required int status, required String body, required String host, required String bucket, required bool atProbe})`
  - `BackendFailure s3TransportFailure(Object error, {required String host})`
  - `const kS3CodeClockSkew = 'RequestTimeTooSkewed'`, `kS3CodeWrongRegion = 'WrongRegion'`, `kS3CodeTls = 'Tls'`, `kS3CodeCannotList = 'CannotList'`, `kS3CodeBadKeys = 'BadKeys'`, `kS3CodeNoSuchBucket = 'NoSuchBucket'`.

- [ ] **Step 1: Write the failing tests**

There is one test per row. `body` is the S3 XML error `<Error><Code>X</Code><Message>…</Message><Region>…</Region></Error>`.

| Input | Expected |
| --- | --- |
| 403 `InvalidAccessKeyId` | `BackendUnauthorized`, `code: kS3CodeBadKeys` |
| 403 `SignatureDoesNotMatch` | `BackendUnauthorized`, `code: kS3CodeBadKeys` |
| 403 `RequestTimeTooSkewed` | `BackendUnauthorized`, `code: kS3CodeClockSkew` |
| 403 `AccessDenied`, `atProbe: true` | `BackendUnauthorized`, `code: kS3CodeCannotList` |
| 403 `AccessDenied`, `atProbe: false` | `BackendPermissionLost` |
| 404 `NoSuchBucket` | `BackendNotFound`, `code: kS3CodeNoSuchBucket`, `hint: bucket` |
| 301 `PermanentRedirect` with `<Region>eu-west-1</Region>` | `BackendUnreachable`, `code: kS3CodeWrongRegion`, `hint: 'eu-west-1'` |
| 400 `AuthorizationHeaderMalformed` with `<Region>eu-west-1</Region>` | same as above |
| 301 with header `x-amz-bucket-region` only | the backend passes it in; covered in Task 3 |
| 500 with an empty body | `BackendUnreachable`, `status: 500`, `code: null` |
| `SocketException`, `TimeoutException`, `http.ClientException` | `BackendUnreachable`, message names `host` |
| `HandshakeException` | `BackendUnreachable`, `code: kS3CodeTls` |

Plus a redaction test: `redactS3Url(Uri.parse('https://h/b/k?X-Amz-Signature=abc'))` has no `?`. Also, for every row, `failure.toString()` contains neither `X-Amz-Signature` nor `abc`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player && flutter test test/core/sources/files/backend/s3_errors_test.dart`
Expected: FAIL, `s3_errors.dart` does not exist.

- [ ] **Step 3: Implement** the `BackendFailure` fields, then `s3_errors.dart`. The body is parsed with `package:xml`; a body that does not parse gives a null code.

- [ ] **Step 4: Run them and see them pass**, plus `cd player && flutter test test/core/sources/files/backend/` to show the other backends still pass.

- [ ] **Step 5: Commit** (`feat(player): S3 error mapping and URL redaction`).

---

### Task 3: `S3Location` and `S3Backend`

**Files:**
- Create: `player/lib/core/sources/files/backend/s3_backend.dart`
- Test: `player/test/core/sources/files/backend/s3_backend_test.dart`

**Interfaces:**
- Consumes: `S3Signer` (Task 1), `s3Failure`, `s3TransportFailure`, `redactS3Url` (Task 2).
- Produces:
  - `enum S3Style { path, vhost }`
  - `class S3Location { const S3Location({required Uri endpoint, required String bucket, required String prefix, required String region, required S3Style style}); Uri toConnectionUri(); static S3Location? fromConnectionUri(Uri u); Uri objectUri(String key); Uri bucketUri([Map<String, String> query = const {}]); }`
    - `endpoint` has scheme `http` or `https`, a host, an optional port, and no path.
    - `prefix` is either empty or ends in `/`, never starts with `/`, and keeps its case.
    - The connection URI is `s3+<scheme>://<host>[:port]/<bucket>/<prefix>?region=<r>&style=<path|vhost>`.
  - `const kS3PresignExpiry = Duration(hours: 12)`, `const kS3Timeout = Duration(seconds: 20)`
  - `class S3Backend implements FileSystemBackend { S3Backend({required S3Location location, required String accessKeyId, required String secretAccessKey, http.Client? client, DateTime Function()? clock, Duration timeout = kS3Timeout}); void close(); }`
  - Backend paths: `/` is the prefix. Path `/Movies/x.mkv` is key `<prefix>Movies/x.mkv`.

- [ ] **Step 1: Write the failing tests** with `MockClient` from `package:http/testing.dart`, as in `webdav_backend_test.dart`:
  - `lists folders and files under the prefix`: a `ListObjectsV2` reply with `CommonPrefixes` `media/Movies/` and `Contents` `media/a.mkv` (size 10, `LastModified` `2026-01-02T03:04:05.000Z`), prefix `media/`. Expect a dir `/Movies` (size 0, modified epoch UTC) and a file `/a.mkv` (size 10, that time). The request carries `list-type=2`, `delimiter=/`, `prefix=media/`, `max-keys=1000`.
  - `follows continuation tokens`: the first reply has `<IsTruncated>true</IsTruncated><NextContinuationToken>t1</NextContinuationToken>`. The second request carries `continuation-token=t1`, and the entries of both pages are returned.
  - `skips the folder marker`: a `Contents` key equal to the listed prefix (`media/Movies/`, size 0) is not returned.
  - `archived objects are unreadable`: `StorageClass` `GLACIER` or `DEEP_ARCHIVE` gives `unreadable: true`. `STANDARD`, `STANDARD_IA` and `INTELLIGENT_TIERING` do not.
  - `stat file`: `HEAD` 200 with `content-length` and `last-modified` gives a file entry.
  - `stat folder`: `HEAD` 404, then a list of `<key>/` with `max-keys=1` that has one `Contents` entry, gives a dir. When the list is empty, the result is null.
  - `probe succeeds on an empty listing`: `KeyCount` 0 completes normally.
  - `probe AccessDenied is CannotList`: a 403 `AccessDenied` throws `BackendUnauthorized` with `code: kS3CodeCannotList`.
  - `wrong region from header`: a 301 with an empty body and `x-amz-bucket-region: eu-west-1` gives `code: kS3CodeWrongRegion`, `hint: 'eu-west-1'`.
  - `path style and vhost style URLs`:
    - path: `https://h:9000/bkt/media/a.mkv`
    - vhost: `https://bkt.s3.us-east-1.amazonaws.com/media/a.mkv`
  - `playable is a presigned URL with no headers`: `X-Amz-Expires=43200`, `headers` empty, the host matches the endpoint (or `bkt.` + endpoint for vhost).
  - `keys round-trip from list to playable`: list returns the key `media/Sp ace+&#%é /x.mkv`. Its path, passed to `playable` and `stat`, produces a request path that decodes back to exactly that key.
  - `requests time out`: a client that never answers throws `BackendUnreachable` after a 50 ms `timeout`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player && flutter test test/core/sources/files/backend/s3_backend_test.dart`
Expected: FAIL.

- [ ] **Step 3: Implement `s3_backend.dart`**
  - Build each object URL with `Uri(scheme:, host:, port:, path: '/' + (path style ? '$bucket/' : '') + key)`, letting `Uri` encode it, so the signer and the server both see the canonical encoding.
  - Parse the list XML with `package:xml`, without requesting `encoding-type`; XML escaping already carries `&` and `<`.
  - On a 301 with no XML region, read `x-amz-bucket-region` and pass it to `s3Failure` as the region.
  - Wrap each send in `.timeout(timeout)`, and route every non-2xx response through `s3Failure` and every thrown error through `s3TransportFailure`.
  - Never interpolate a signed `Uri` into a message; use `redactS3Url` where a URL must be named.

- [ ] **Step 4: Run them and see them pass.**

- [ ] **Step 5: Commit** (`feat(player): S3 files backend`).

---

### Task 4: Account, credentials and wiring

**Files:**
- Modify: `player/lib/core/sources/files/files_account.dart`
- Modify: `player/lib/core/sources/files/files_accounts.dart` (beside `addWebDavAccount`, line ~179, and `addWebDavRoot`, line ~433)
- Modify: `player/lib/core/sources/files/files_providers.dart` (`backendFor` at ~line 170, next to `LazyWebDavBackend` at ~386, and its `close` at ~309)
- Modify: `player/lib/core/p2p/peer_files_host.dart` (`filesAccountKind` :116, `filesDedupeKey` :129, `_grantFor` log :370)
- Modify: `player/lib/core/p2p/peer_files_client.dart` (`_dedupable` :382)
- Modify: `player/lib/core/sources/README.md` (an S3 section after SMB's)
- Test: `player/test/core/sources/files/files_accounts_test.dart`, `player/test/core/sources/files/files_ids_test.dart`, `player/test/core/sources/files/backend/lazy_s3_backend_test.dart`, and the existing peer files tests (`peer_files_sources_test.dart`)

**Interfaces:**
- Consumes: `S3Location`, `S3Backend` (Task 3).
- Produces:
  - `String normalizeS3Url(Uri connection)`: the canonical connection string, made with `S3Location.fromConnectionUri(u)!.toConnectionUri().toString()`. This lowercases the scheme and host, drops `:443` from https and `:80` from http, normalizes the prefix (no leading `/`, a trailing `/` unless empty), and sorts the query.
  - `String s3AccountId(Uri connection)`, `bool isS3AccountId(String id)`
  - `class S3Credentials { const S3Credentials({required String accessKeyId, required String secretAccessKey}); String toJson(); static S3Credentials fromJson(String s); }`. Its `toString` prints the access key id only.
  - `Future<SourceId> FilesAccounts.addS3Account({required S3Location location, required S3Credentials credentials})`. This mirrors `addWebDavAccount`: it writes the credentials before the record, reuses an existing account and clears `needsReauth`. The display name is `bucket`, or `bucket/prefix-without-trailing-slash`. There is one server whose one connection is `toConnectionUri()`, with `local: isPrivateHost(host)`.
  - `Future<void> FilesAccounts.addS3Root(SourceId id, {required String path, required FilesLibraryKind kind})`, which delegates to `addWebDavRoot` as `addSmbRoot` does.
  - `typedef S3Connector = FileSystemBackend Function(S3Location location, S3Credentials credentials, http.Client? client)` and `final s3ConnectorProvider = Provider<S3Connector>(…)`, shaped like `webDavConnectorProvider`.
  - `class LazyS3Backend implements FileSystemBackend { LazyS3Backend({required Uri connection, required Future<String?> Function() credentials}); void close(); }`. This mirrors `LazyWebDavBackend`: a missing or unparseable token throws `BackendUnauthorized`.

- [ ] **Step 1: Write the failing tests**
  - `files_ids_test.dart`: `normalizeS3Url` maps `s3+https://H.example.com:443/bkt/media?style=path&region=r`, `…/bkt//media/`, `…/bkt/media/` and `…/bkt/media` to one string. `…/bkt/Media/` is a different string, because keys are case-sensitive. `s3AccountId` matches `^3[0-9a-f]{16}$`. `isSmbAccountId(s3AccountId(x))` is false, and `isS3AccountId(smbAccountId(y))` is false.
  - `files_accounts_test.dart`, `addS3Account stores the secret only in SourceSecrets`:
    - the stored record's connection URI contains neither the secret nor the access key;
    - `sourceSecrets.accountToken(account)` decodes to the given `S3Credentials`;
    - adding the same bucket again returns the same `SourceId` and clears `needsReauth`.
  - `lazy_s3_backend_test.dart`: a missing token throws `BackendUnauthorized`. Otherwise the first call builds the backend once, and `close` closes the client.
  - The `backendFor` test (where the WebDAV case lives, `files_providers` tests): an S3 account yields a `LazyS3Backend`.
  - Peer tests: `filesAccountKind(s3Id) == 's3'`; `filesDedupeKey` of an S3 record equals `normalizeS3Url` of its connection; a wire account of kind `s3` with a dedupe key is dedupable.
  - Playback reopen: in the files playback session tests (`player/test/presentation/screens/player/session/`, beside the existing files session tests), opening the same file twice calls `backend.playable` twice. This pins that an expired URL is re-minted on reopen.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player && flutter test test/core/sources/files/ test/presentation/screens/player/session/`
Expected: the new tests fail; existing ones pass.

- [ ] **Step 3: Implement**
  - Put the S3 branch in `backendFor` before the WebDAV fallback, and close `LazyS3Backend` where `LazyWebDavBackend` is closed.
  - In `PeerFilesHost._grantFor`, log `'[PeerFilesHost] No grant for a read in $accountId: ${e.runtimeType}'` instead of `$e`.
  - Add a README section of a few paragraphs covering the connection URI shape, the id prefix `3`, presigned playback and the redaction rule.

- [ ] **Step 4: Run them and see them pass**, plus `cd player && dart analyze --fatal-infos`.

- [ ] **Step 5: Commit** (`feat(player): S3 files accounts and backend wiring`).

---

### Task 5: Presets, add screen, route

**Files:**
- Create: `player/lib/core/sources/files/s3_presets.dart`
- Create: `player/lib/presentation/screens/sources/add_s3_screen.dart`
- Modify: `player/lib/presentation/screens/sources/add_source_screen.dart` (a tile after SMB's, ~line 85)
- Modify: `player/lib/core/router/app_router.dart` (a route after `/sources/add/smb` ~line 384; `filesReauthLocation` ~line 205)
- Modify: `player/lib/l10n/app_en.arb` (plus the other locales per `player/docs/l10n.md`)
- Test: `player/test/core/sources/files/s3_presets_test.dart`, `player/test/presentation/screens/sources/add_s3_screen_test.dart`, the router test that covers `filesReauthLocation`, and the add-source screen test

**Interfaces:**
- Consumes: `S3Location`, `S3Style` (Task 3); `addS3Account`, `addS3Root`, `s3ConnectorProvider`, `isS3AccountId`, `S3Credentials` (Task 4); `RemoteFolderPicker`; the `kS3Code*` constants (Task 2).
- Produces:
  - `enum S3Preset { aws, backblazeB2, cloudflareR2, wasabi, other }` with:
    - `String get label`
    - `bool get needsRegion`
    - `bool get needsAccountId`
    - `bool get needsEndpoint`
    - `String? get defaultRegion`
    - `S3Style get defaultStyle`
    - `Uri? endpointFor({String region = '', String accountId = ''})`

    | Preset | Endpoint | Default region | Style |
    | --- | --- | --- | --- |
    | `aws` | `https://s3.<region>.amazonaws.com` | `us-east-1` | `vhost` |
    | `backblazeB2` | `https://s3.<region>.backblazeb2.com` | none (required) | `path` |
    | `cloudflareR2` | `https://<accountId>.r2.cloudflarestorage.com` | `auto` (fixed) | `path` |
    | `wasabi` | `https://s3.<region>.wasabisys.com` | `us-east-1` | `path` |
    | `other` | typed; no scheme means `https` | `us-east-1` | `path` |

  - `Uri? parseS3Endpoint(String typed)`: trims the input and adds `https://` when no scheme is given. It returns null for a non-http(s) scheme, an empty host, or a path other than `/`.
  - `class AddS3Screen extends ConsumerStatefulWidget { const AddS3Screen({super.key, this.reauthAccountId}); }`
  - Route `/sources/add/s3`, named `add_source_s3`, reading `?account=` as `reauthAccountId`. `filesReauthLocation` sends an S3 id there.

The screen copies `AddWebDavScreen`'s flow:
1. **Form:** provider dropdown, then the fields the preset needs (region, account ID or endpoint), bucket, optional folder in bucket (prefix), access key, secret key (obscured), and an advanced style switch.
2. **Connect** (`Key('s3-connect')`): builds the location and runs `probe()` then `list('/')`.
3. **Folder picker** (`RemoteFolderPicker`, `keyPrefix: 's3'`): chooses roots and their kinds.
4. **Save:** `addS3Account`, then `addS3Root` for each chosen folder.

When signing in again, the location fields are filled from the stored connection and locked, and only the keys are editable. Form keys: `s3-provider`, `s3-region`, `s3-account-id`, `s3-endpoint`, `s3-bucket`, `s3-prefix`, `s3-access-key`, `s3-secret-key`, `s3-style`.

Copy (ARB key: English text):
- `sourcesAddS3Subtitle`: `Amazon S3, Backblaze B2, Cloudflare R2, Wasabi or a self-hosted server`
- `filesS3ProviderOther`: `Other or self-hosted`
- `filesS3Endpoint`: `Endpoint`
- `filesS3Region`: `Region`
- `filesS3AccountId`: `Account ID`
- `filesS3Bucket`: `Bucket`
- `filesS3Prefix`: `Folder in bucket (optional)`
- `filesS3AccessKey`: `Access key`
- `filesS3SecretKey`: `Secret key`
- `filesS3PathStyle`: `Path-style addressing`
- `filesS3ErrorUnreachable(host)`: `Can't reach {host}`
- `filesS3ErrorTls(host)`: `{host} didn't answer over HTTPS. A server without TLS needs an http:// address.`
- `filesS3ErrorBadKeys`: `The access key or secret is wrong`
- `filesS3ErrorClock`: `This device's clock is more than 15 minutes off`
- `filesS3ErrorCannotList`: `These keys can't list this bucket`
- `filesS3ErrorNoBucket(bucket)`: `No bucket named {bucket} at this endpoint`
- `filesS3ErrorRegion(region)`: `The bucket is in region {region}`
- `filesS3ErrorRegionUnknown`: `The bucket is in a different region`
- `filesS3ErrorServer(status)`: `The server answered with an error ({status})`
- `filesS3ErrorHttpsRequired`: `Use an https:// address for a server outside your network`

`S3Preset.label` returns brand names, marked `// l10n-ignore`, except `other`, which uses `filesS3ProviderOther`.

- [ ] **Step 1: Write the failing tests**
  - `s3_presets_test.dart`: each preset's `endpointFor` matches the table. `parseS3Endpoint` behaves as follows:

    | Input | Result |
    | --- | --- |
    | `'minio.lan:9000'` | `https://minio.lan:9000` |
    | `' http://10.0.0.5:9000 '` | `http://10.0.0.5:9000` |
    | `'ftp://x'` | null |
    | `'https://h/path'` | null |
  - `add_s3_screen_test.dart` (inject `s3ConnectorProvider` with a fake backend, the way the WebDAV screen test injects `webDavConnectorProvider`):
    - `the AWS preset fills region and vhost`: choosing `aws` shows `s3-region` with `us-east-1`, and the connector receives a `vhost` location.
    - `R2 asks for the account ID`: `s3-account-id` is shown, `s3-region` is not, and the endpoint is `https://abc.r2.cloudflarestorage.com` with region `auto`.
    - `http on a public host is refused without a request`: `other` plus `http://example.com` shows `filesS3ErrorHttpsRequired`, and the connector is never called.
    - `each probe failure shows its message`, one case per row:

      | Failure | Message |
      | --- | --- |
      | `kS3CodeClockSkew` | `filesS3ErrorClock` |
      | `kS3CodeWrongRegion` with hint `eu-west-1` | `filesS3ErrorRegion('eu-west-1')` |
      | `kS3CodeTls` | `filesS3ErrorTls` |
      | `kS3CodeBadKeys` | `filesS3ErrorBadKeys` |
      | `kS3CodeCannotList` | `filesS3ErrorCannotList` |
      | `kS3CodeNoSuchBucket` | `filesS3ErrorNoBucket` |
      | a plain `BackendUnreachable(null, 503)` | `filesS3ErrorServer('503')` |
    - `save stores the account and chosen roots`: connect, choose one folder as movies, then save. `addS3Account` was called with the typed location, and the secret is in `SourceSecrets`.
    - `sign in again locks the location`: opened with `reauthAccountId`, the location fields are read-only and prefilled.
  - The add-source screen test: `add-source-s3` is present on native and absent with `isWeb: true`.
  - The router test: `filesReauthLocation(s3Id)` is `/sources/add/s3?account=<id>`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player && flutter test test/core/sources/files/s3_presets_test.dart test/presentation/screens/sources/ test/core/router/`
Expected: the new tests fail.

- [ ] **Step 3: Implement** the presets, the screen, the tile (`Key('add-source-s3')`, `Icons.cloud_rounded`, `ExperimentalTitle(title: Text('S3'))` with `// l10n-ignore`, `if (!isWeb)`), the route and the ARB keys. Then regenerate localizations as `player/docs/l10n.md` describes.

- [ ] **Step 4: Run them and see them pass**, plus `cd player && dart analyze --fatal-infos`.

- [ ] **Step 5: Commit** (`feat(player): add S3 bucket screen`).

---

### Task 6: Paired players re-grant an expired URL

**Files:**
- Modify: `player/rust/mydia_player_p2p/src/peer_files_host.rs` (`serve` ~line 442, `serve_http` ~line 499, tests module)

**Interfaces:**
- Produces: a new `Outcome::Stale` variant. `serve_http` returns it when the upstream answers 401 or 403, before any header has been written to the sink. `serve` handles `Stale` by removing the cached grant, resolving a fresh one through `self.grant` and serving once more. A second `Stale` is answered with 502 and handled like `Failed`.

- [ ] **Step 1: Write the failing tests** in the existing `tests` module, using its `start_server`, `MapResolver` and `RecordingSink`:
  - `expired_grant_is_reissued_once`: the resolver hands out `…/expired` first and `…/ok` second, where the test server answers `/expired` with 403 and `/ok` with 206. One read gets 206, and the resolver was called twice.
  - `grant_still_forbidden_after_reissue_is_502`: both grants point at `/expired`. The read gets 502, the resolver was called twice, and the next read asks again (a third call).
  - `upstream_error_log_has_no_url`: make `upstream.send()` fail against an unroutable `http://127.0.0.1:1/x?X-Amz-Signature=secret`. Capture `tracing` output with the test subscriber pattern already used in this crate (or `tracing_subscriber::fmt().with_writer(…)`) and assert it does not contain `X-Amz-Signature`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd player/rust/mydia_player_p2p && cargo test peer_files_host`
Expected: the new tests fail.

- [ ] **Step 3: Implement**
  - Add `Outcome::Stale` and handle it in `serve` as described.
  - Log `upstream unreachable: {}` with `e.without_url()`.
  - Keep the existing `upstream answered {status}` line; it carries no URL.

- [ ] **Step 4: Run them and see them pass**, plus `cargo clippy --all-targets -- -D warnings` in the same crate (the devenv hook runs it on commit anyway).

- [ ] **Step 5: Commit** (`fix(player): re-grant expired peer file URLs and keep URLs out of logs`).

---

### Task 7: Integration test against RustFS, and CI

**Files:**
- Create: `player/test/core/sources/files/backend/s3_integration_test.dart`
- Modify: `.github/workflows/ci-player.yml` (job `test-player`, line 139)

**Interfaces:**
- Consumes: `S3Backend`, `S3Location`, `S3Signer` (Tasks 1 and 3).
- Uses the environment variables devenv already defines (`devenv.nix:277-280`): `MYDIA_TEST_S3_ENDPOINT`, `MYDIA_TEST_S3_ACCESS_KEY_ID`, `MYDIA_TEST_S3_SECRET_ACCESS_KEY`. Locally, start the server with `devenv shell -- mydia-s3` in a second terminal.

- [ ] **Step 1: Write the test**
  - The whole file is skipped (`skip:` with a reason) when `MYDIA_TEST_S3_ENDPOINT` is unset.
  - `setUpAll`:
    - Create a bucket named `player-s3-<random>` with a signed `PUT /<bucket>` through `S3Signer`.
    - Upload these objects with signed `PUT`s:
      - `lib/Films/Fictional Title (2020)/a.mkv` (64 KiB of known bytes)
      - `lib/Odd/Sp ace+&#%é /b.mkv`
      - `lib/Films/` (a zero-byte marker)
  - `tearDownAll` deletes the objects and the bucket.
  - Tests, all on prefix `lib/` with `S3Style.path` and region `us-east-1`:
    - `probe` completes;
    - `list('/')` returns dirs `/Films` and `/Odd` and no marker;
    - `stat('/Films/Fictional Title (2020)/a.mkv')` gives size 65536;
    - `stat('/Films')` gives a dir;
    - `stat('/nope.mkv')` gives null;
    - `playable(...)` fetched with plain `http` and `Range: bytes=10-19` returns 206 and bytes 10 to 19;
    - the odd key round-trips through `list`, then `stat`, then `playable`, then GET 200;
    - a URL presigned with a clock 13 hours in the past answers 403;
    - a wrong secret makes `probe` throw `BackendUnauthorized` with `code: kS3CodeBadKeys`.

- [ ] **Step 2: Run it locally** with RustFS up:

Run: `devenv shell -- bash -c 'cd player && flutter test test/core/sources/files/backend/s3_integration_test.dart'`
Expected: all pass. Without the env vars set, the file reports as skipped.

- [ ] **Step 3: Wire CI**
  - Add a `services: rustfs:` container to `test-player`, using the `rustfs/rustfs` image pinned to an exact version tag, never `latest`. Use the version nixpkgs packages for devenv's `rustfs`, as shown by `devenv shell -- rustfs --version`.
  - Map port 9000 and set `RUSTFS_ACCESS_KEY` and `RUSTFS_SECRET_KEY` to the devenv values.
  - Set the three `MYDIA_TEST_S3_*` env vars on the test step.
  - Check that the existing `very_good test` step picks the file up. If its `--exclude` / file-list logic would skip it, add it explicitly.

- [ ] **Step 4: Push and confirm** in the `Test / Player` job log that `s3_integration_test.dart` ran and was not skipped.

- [ ] **Step 5: Commit** (`test(player): S3 backend against RustFS in CI`).

---

### Task 8: Manual check on a real provider

- [ ] Add a real Backblaze B2 or Cloudflare R2 bucket with a bucket-scoped key, on Linux desktop and on Android:
  - pick a folder, scan, and confirm a match;
  - play a large file and seek several times;
  - download it;
  - cast it to a Chromecast;
  - lend it to a paired player and play it there.
- [ ] On iOS or macOS, play from a plain-`http` LAN RustFS. Dart's `http` and mpv use their own sockets, not `URLSession`, so App Transport Security should not apply and no `Info.plist` change is planned. If playback fails, add `NSAllowsLocalNetworking` and say so in the PR.
- [ ] Type a wrong region and a wrong secret, and confirm the region and keys messages.
- [ ] Grep the session's logs (`./dev player logs`, `adb logcat`) for `X-Amz-Signature` and the secret. There must be no hits.
- [ ] Record the provider, platforms and result in the PR description.
