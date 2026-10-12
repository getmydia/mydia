# Cardigann Indexers

Mydia includes built-in Cardigann indexer support, allowing direct indexer connections without Prowlarr or Jackett.

!!! warning "Public indexers are covered, private ones are not"
    Mydia's Cardigann engine is tested against public trackers, which are the
    ones it handles well. Private and semi-private trackers need a login, and
    several login mechanisms (CAPTCHA, selector-derived inputs, separate submit
    paths) are not implemented. Expect those to fail. If you hit a problem,
    please report it on GitHub.

Cardigann is the community indexer definition format from Jackett, also used by
Prowlarr. Mydia reads those definitions natively, so you can point it at trackers
without running a separate indexer manager.

For why Mydia ships its own engine and what that trades away, see
[Why Mydia ships its own indexer implementation](../explanation/media-pipeline.md#why-mydia-ships-its-own-indexer-implementation).
The short version: use Prowlarr or Jackett when reliability matters more than
running fewer services.

## Enabling Cardigann

Cardigann is enabled by default:

```bash
ENABLE_CARDIGANN=true
```

To disable:

```bash
ENABLE_CARDIGANN=false
```

## Using Prowlarr's engine (experimental)

Mydia can run Prowlarr's own Cardigann engine instead of its built-in one:

```bash
CARDIGANN_ENGINE=prowlarr
```

The default is `builtin`, and anything else stops Mydia at startup with a message
naming the two valid values. With `prowlarr`, definitions are read by the same
code Prowlarr uses, so results match Prowlarr's, and a search that hits a dead or
blocked mirror moves on to the next link the definition lists. Against Prowlarr on
the 44 public trackers where Prowlarr returned results, it matched on all of them,
and the built-in engine on 28.

It is opt-in because it costs something. Read this before turning it on:

- **The first start downloads about 39 MB from GitHub and compiles it.** The
  compile takes about 18 s on the Alpine image and uses up to about 1.6 GB of
  memory while it runs, then settles at about 500 MB. A container limited to
  1.5 GB or less can be killed during it. Cardigann searches fail with a message
  saying why until it finishes; the rest of Mydia is not held up. If the download
  fails, Mydia retries in the background.
- **Later starts load the compiled copy in under a second.** It is kept in a
  `cardigann` folder in your data directory (`MYDIA_DATA_DIR`, or next to the
  database file, which is `/config` in the Docker image): 39 MB for the download
  and 119 MB for the compiled copy. Keep that folder on a volume. Without one,
  every container recreate downloads and compiles again.
- **Memory.** About 65 MB more than the built-in engine when idle, and about
  290 MB more while four searches run at once.
- **Speed.** About 60 ms slower per search at the median, 110 ms at the 95th
  percentile, not counting the tracker's own response time.
- **Errors are Prowlarr's wording**, such as an HTTP status, "Cloudflare protection
  detected" or "No answer from the tracker". In the benchmark, 20 of 81 public
  trackers ended in one of these; Prowlarr could not search any of those 20 either.
  FlareSolverr still applies.
- **It cannot reach trackers on your local network**, and it is only measured
  against public trackers. Private-tracker logins are untested.
- **It is built with an experimental toolchain** (a pre-release .NET compiled to
  WebAssembly). Expect rough edges, and report them.

Without internet access on the server, download `cardigann-<hash>.wasm` for your
Mydia version yourself, put it on the server and point Mydia at it:

```bash
CARDIGANN_WASM_PATH=/path/to/cardigann-<hash>.wasm
```

Mydia checks the file against the checksum built into your version and refuses
one that does not match. Nothing is downloaded, and the compiled copy is still
cached in the data directory.

If you set `ENABLE_CARDIGANN=false`, Cardigann is off whichever engine you pick.

## Supported Indexers

Mydia syncs the full upstream definition catalogue. Coverage is strongest for
public trackers.

**Covered by regression tests:**

These indexers have captured responses in the test suite, so their parsing is
verified on every build.

- 1337x
- blueroms
- EZTV
- KickassTorrents
- LimeTorrents
- MagnetDownload
- Nyaa.si
- ShowRSS
- The Pirate Bay
- TorrentGalaxy (clone)
- TorrentLT
- YTS

**Everything else:**

The remaining definitions are included and may well work, but nothing pins their
behaviour, so an upstream site change can break them silently. Private trackers
in particular are likely to fail at login.

To see what the engine actually supports against the current upstream
catalogue, run the compatibility report:

```bash
mix mydia.cardigann_compat --type public
```

It lists, per unsupported feature, how many definitions that feature blocks.

### Dead and moved domains

Public trackers rotate domains often. Mydia probes every link a definition
ships, including its historical ones, picks the first that responds, and stores
it. If that host later stops answering, a search transparently fails over to the
next candidate and remembers the new one. No configuration is involved.

## Configuration

### Adding a Cardigann Indexer

1. Navigate to **Admin > Configuration > Indexers**
2. Click **Add Indexer**
3. Select the indexer from the Cardigann list
4. Enter required credentials (if applicable)
5. Test and save

### Indexer Settings

Each indexer may have specific settings:

- Username/Password
- API Key
- Cookie authentication
- Site-specific options

Refer to the indexer's requirements in the Admin UI.

## FlareSolverr Integration

Some indexer sites are protected by Cloudflare or similar anti-bot services. You can use [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) to bypass these challenges automatically.

### Setup

1. Run a FlareSolverr instance (e.g., via Docker)
2. Configure the following environment variables:

```bash
FLARESOLVERR_URL=http://flaresolverr:8191
# FLARESOLVERR_ENABLED is auto-enabled when URL is set
# FLARESOLVERR_TIMEOUT=60000
# FLARESOLVERR_MAX_TIMEOUT=120000
# FLARESOLVERR_MAX_CONCURRENT_REQUESTS=1
```

See [Environment Variables](../reference/environment-variables.md#flaresolverr) for the full reference.

## Limitations

### Known Issues

- Some indexers may not parse results correctly
- Authentication may fail on some sites
- Rate limiting varies by indexer
- CAPTCHA challenges not supported

## Troubleshooting

### Search Returns No Results

1. Test the indexer connection
2. Check if the site is accessible
3. Verify credentials if required
4. Check application logs for errors

### Authentication Errors

1. Verify credentials are correct
2. Some sites require manual cookie refresh
3. Check if site requires 2FA (not supported)

### Rate Limiting

1. Reduce search frequency
2. Add delay between requests
3. Consider using fewer indexers

## Reporting Issues

When reporting Cardigann issues:

1. Include the indexer name
2. Describe the expected vs. actual behavior
3. Include relevant log entries
4. Specify if it works with Prowlarr/Jackett

## Next Steps

- [Indexers](connect-indexer.md) - Prowlarr, Jackett, and Newznab setup
- [How a Title Becomes a File](../explanation/media-pipeline.md#why-mydia-ships-its-own-indexer-implementation) - Why Mydia has a native Cardigann engine at all, and what it trades away
