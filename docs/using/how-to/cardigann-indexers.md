# Cardigann Indexers

Mydia includes built-in Cardigann indexer support, allowing direct indexer connections without Prowlarr or Jackett.

## Which option to use

Mydia can search trackers three ways. The first two run inside Mydia; the third
is a separate indexer manager Mydia connects to.

| | Built-in engine | Prowlarr-based engine (experimental) | Prowlarr or Jackett server |
|---|---|---|---|
| **Extra services** | None | None, runs inside Mydia | One more container to run |
| **Setup** | On by default | One switch under **Configuration > Indexers**, then a 68 MB download on first use | Run the server, then [add a connection](connect-indexer.md) |
| **Matches Prowlarr's results** (44 public trackers) | 28 of 44 | 44 of 44 | It is Prowlarr |
| **Private trackers** | API key, cookie and form logins, including captcha and 2FA ([details](#private-trackers)); tested against simulated trackers | Prowlarr's own login code; captcha and 2FA as on the built-in engine | Supported |
| **Trackers on your local network** | Yes | No | Yes |
| **Extra memory** | None | About 65 MB idle, up to about 120 MB more while searching | A separate process |
| **Maturity** | Default; parsing regression-tested on [12 trackers](#supported-indexers) | Built with an experimental toolchain | Mature |
| **Pick it when** | You want zero setup | You want Prowlarr's results without running Prowlarr | You already run Prowlarr, or a tracker does not work with either built-in option |

The costs of the Prowlarr-based engine are detailed in
[Using the Prowlarr-based engine](#using-the-prowlarr-based-engine-experimental).
For why Mydia ships its own engine at all, see
[Why Mydia ships its own indexer implementation](../explanation/media-pipeline.md#why-mydia-ships-its-own-indexer-implementation).
If you hit a problem with either built-in option, please report it on GitHub.

Cardigann is the community indexer definition format from Jackett, also used by
Prowlarr. Mydia reads those definitions natively, so you can point it at trackers
without running a separate indexer manager.

## Enabling Cardigann

Cardigann is enabled by default:

```bash
ENABLE_CARDIGANN=true
```

To disable:

```bash
ENABLE_CARDIGANN=false
```

## Using the Prowlarr-based engine (experimental)

Mydia can run Prowlarr's own Cardigann code, compiled from C# and built into
Mydia, instead of its built-in engine. It needs no Prowlarr server and is
unrelated to adding a Prowlarr connection. It is recommended for private
trackers, since their logins then follow Prowlarr's code exactly.

Choose the engine under **Configuration > Indexers**, in the **Library
Indexers** section: **How library indexers run** shows the active engine, and
**Change** opens a Built-in and a Prowlarr-based card. The default is Built-in.
Switching takes effect without a restart.

The first time you switch to Prowlarr-based, Mydia downloads the engine and prepares it
while the built-in engine keeps serving your searches, and the page shows
progress. When it is ready, searches move over by themselves. If something goes
wrong, the page shows the reason. Problems that can pass, such as a network
failure, are retried in the background (use **Retry now** to try again at once).
Permanent ones, such as a checksum mismatch or a Mydia version with no published
engine, need the cause fixed first. If the Prowlarr-based engine stops being ready
later, for example if the engine crashes and restarts, the built-in engine serves searches again
until it is.

Switching back to Built-in frees the engine's memory but keeps the downloaded
and prepared files, so switching to Prowlarr-based again takes about a second. Use
**Remove cached Prowlarr-based engine** under **Change** to delete them. The button
appears while Built-in is selected.

A "verified" badge on a tracker means that engine returned results for it that
matched Prowlarr's in our benchmark. No badge means "not verified", not
"broken".

To pin the choice instead, for example in a Docker Compose file, set:

```bash
CARDIGANN_ENGINE=prowlarr
```

The variable wins over the page and locks the choice there. Use `builtin` or
`prowlarr`; anything else stops Mydia at startup with a message naming the two
valid values. With `prowlarr`, definitions are read by the same
code Prowlarr uses, so results match Prowlarr's, and a search that hits a dead or
blocked mirror moves on to the next link the definition lists. Against Prowlarr on
the 44 public trackers where Prowlarr returned results, it matched on all of them,
and the built-in engine on 28.

It is opt-in because it costs something. Read this before turning it on:

- **The first start downloads about 68 MB from GitHub.** With the usual setup the
  engine is ready about 6 s after the container starts and uses up to about
  0.65 GB of memory on the way, then settles at about 500 MB. If the prepared
  copy cannot be downloaded, Mydia prepares the engine on your server instead.
  That takes about 18 s and uses up to about 1.6 GB of memory, and a container
  limited to less than about 2 GB can be killed during it. The built-in engine
  keeps serving searches meanwhile, and the rest of Mydia is not held up. If the
  download fails, Mydia retries in the background.
- **Later starts load the prepared copy in under a second.** It is kept in a
  `cardigann` folder in your data directory (`MYDIA_DATA_DIR`, or next to the
  database file, which is `/config` in the Docker image): 39 MB for the engine
  and 119 MB for the prepared copy. Keep that folder on a volume. Without one,
  every container recreate downloads the engine again.
- **Memory.** About 65 MB more than the built-in engine when idle. A search in
  progress adds roughly 60 MB for a typical result page, and up to about 180 MB
  for a very large one, and gives it back when it finishes. Mydia runs at most two
  searches at a time on this engine and queues the rest, so the extra stays near
  120 MB however many indexers you search at once.
- **Speed.** About 60 ms slower per search at the median, 110 ms at the 95th
  percentile, not counting the tracker's own response time. When many indexers are
  searched at once, the searches beyond the second wait their turn, which adds a
  fraction of a second to the slowest of them.
- **Errors are Prowlarr's wording**, such as an HTTP status, "Cloudflare protection
  detected" or "No answer from the tracker". In the benchmark, 20 of 81 public
  trackers ended in one of these; Prowlarr could not search any of those 20 either.
  FlareSolverr still applies.
- **It cannot reach trackers on your local network**, and it is only measured
  against public trackers. Private-tracker logins are tested against simulated
  trackers only; see [Private trackers](#private-trackers).
- **It is built with an experimental toolchain** (a pre-release .NET compiled to
  WebAssembly). Expect rough edges, and report them.

Without internet access on the server, download `cardigann-<hash>.wasm` for your
Mydia version yourself, put it on the server and point Mydia at it:

```bash
CARDIGANN_WASM_PATH=/path/to/cardigann-<hash>.wasm
```

Mydia checks the file against the checksum built into your version and refuses
one that does not match. Nothing is downloaded, and the prepared copy is still
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
behaviour, so an upstream site change can break them silently. For private
trackers, see [Private trackers](#private-trackers).

To see what the engine actually supports against the current upstream
catalogue, run the compatibility report:

```bash
mix mydia.cardigann_compat --type public
```

It lists, per unsupported feature, how many definitions that feature blocks,
and how many logins it supports.

## Private trackers

A private tracker needs an account, and Mydia logs in to it for you. Which
settings an indexer asks for comes from its definition, so the form under
**Admin > Configuration > Indexers** shows exactly the fields that tracker
needs. Most use one of three kinds of login.

### API key

Trackers with an API (many UNIT3D sites, whose definitions end in `-api`) ask
for an **API key**. Generate one in your account settings on the tracker's
website, usually under a "Security" or "API key" tab, and paste it in. Mydia
sends it with every search. There is no session to expire; if the key is
revoked, searches fail with an authentication error until you paste a new one.

### Username and password

Most other trackers ask for a **username** and **password**. Mydia fetches the
tracker's login page, fills in the form (including the hidden security token
many sites put on it), submits it and keeps the session cookie the tracker
hands back. That session is reused for every search and grab until the
tracker stops accepting it. Then Mydia logs in again once, by itself, and
repeats the search. Changing the indexer's settings drops the stored session,
so new credentials get a fresh login.

### Cookie

Some trackers block automated logins altogether, and their definitions ask for
a **cookie** instead. Log in to the tracker in your browser, open the
developer tools, copy the `Cookie` header of any request to the site, and
paste the whole value into the indexer's cookie setting. When the tracker ends
that browser session, searches fail until you paste a fresh cookie.

### Captcha and two-factor codes

Some login forms show a captcha image or ask for a one-time two-factor (2FA)
code. Mydia cannot answer those, so it asks you:

1. The first search that needs a login stops, and the indexer shows
   **Needs login** on the Indexers page. Searches skip it from then on rather
   than fail over and over.
2. Click the key icon (**Log in**) on that indexer. Mydia opens the tracker's
   login page and shows its captcha image and a field for the 2FA code, if the
   tracker asks for one. If the image is unreadable, **New image** fetches
   another.
3. Type the answers and press **Log in**. The indexer goes back to healthy and
   searches resume on the session the tracker returned.

The answers are used once and never stored. When the tracker ends the session
later, the indexer shows **Needs login** again and you repeat these steps. If you leave the 2FA field empty, Mydia submits it empty, which is
what trackers expect when 2FA is not turned on for your account.

This works the same with the built-in and the Prowlarr-based engine: the
**Log in** button always runs the built-in login, and both engines use the
session it stores.

### Grabs and your passkey

A grab downloads the `.torrent` from the tracker with your session or key, and
Mydia hands that file to your download client unchanged, so the tracker's own
announce URL and your passkey stay in it. Grab log lines name the tracker's
host, never the download link or the file's contents, so the passkey they carry
stays out of the logs at the default log level. With `LOG_LEVEL=debug`, the
database query log prints stored download links, passkey included, so keep debug
logs private and do not paste them into public reports.

### What is covered

Of the 440 private-tracker definitions in the upstream catalogue (counted on
2026-10-30 with `mix mydia.cardigann_compat --type private`), all 440 log in
with features the built-in engine implements:

| Login | Definitions |
| --- | --- |
| API or URL (`get`) | 142 |
| Pasted cookie (`cookie`) | 134 |
| Login form (`form`) | 97 |
| Posted credentials (`post`) | 65 |
| No login | 2 |
| Stops for an image captcha | 41 |
| Stops for a 2FA code | 21 |

"Implements" means the definition's login features are supported, not that a
login to that tracker has been seen working. Mydia's tests run full journeys
(log in, search, session expiry, captcha, grab) against simulated trackers built
like the common tracker software (UNIT3D, Gazelle and captcha login forms), but
nobody on the project has accounts on most real ones.

**Please report what you find.** If a private tracker works, or fails, open an
issue or a discussion on GitHub with the tracker's name, which engine you use,
and the error the Indexers page shows. Leave out your passkey, API key and
cookies. Reports from real accounts are how private-tracker support gets
verified.

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
- Captcha and 2FA logins need you to log in from the Indexers page whenever the
  tracker ends the session (see [Captcha and two-factor codes](#captcha-and-two-factor-codes))

## Troubleshooting

### Search Returns No Results

1. Test the indexer connection
2. Check if the site is accessible
3. Verify credentials if required
4. Check application logs for errors

### Authentication Errors

1. Verify credentials are correct
2. For a cookie login, paste a fresh cookie from your browser
3. An indexer showing **Needs login** wants a captcha or 2FA code: use its
   **Log in** button

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
