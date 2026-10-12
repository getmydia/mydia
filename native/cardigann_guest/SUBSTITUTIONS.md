# Substitutions

Upstream files that are not compiled, with the Mydia shim that replaces each.
Files under `.prowlarr/` are never edited. Every shim keeps the upstream
namespace and the members the vendored code uses.

| Upstream file | Replaced by | Why |
|---|---|---|
| src/NzbDrone.Core/IndexerVersions/IndexerDefinitionUpdateService.cs | shim/DefinitionService.cs | Interface shares the file with a service that reads the database and fetches definitions over HTTP; the guest receives the YAML from the host instead. The deserializer settings (IgnoreUnmatchedProperties, CamelCaseNamingConvention) are copied verbatim. `CardigannDefinition` does not derive from `CardigannMetaDefinition` at the pin, so `All()` projects a meta entry from the definition. |
| src/NzbDrone.Core/Indexers/IndexerStatusService.cs | shim/IndexerStatus.cs | `IIndexerStatusService` shares the file with a repository-backed service. The shim keeps the interface and adds a per-call implementation that holds the session cookies. |
| src/NzbDrone.Core/ThingiProvider/Status/ProviderStatusServiceBase.cs | shim/IndexerStatus.cs | `IProviderStatusServiceBase<T>` (the base of `IIndexerStatusService`) shares the file with an abstract service that needs a repository, the event aggregator and `IRuntimeInfo`. Only the interface is kept. |
| src/NzbDrone.Core/IndexerProxies/IndexerProxyFactory.cs | shim/IndexerProxyFactory.cs | `IIndexerProxyFactory` shares the file with a database-backed `ProviderFactory`. Only the interface is kept; the guest registers no proxies. |
| src/NzbDrone.Core/Localization/LocalizationService.cs | shim/Localization.cs | `ILocalizationService` shares the file with a service that reads language files from disk. The shim returns the English key with tokens substituted. |
| src/NzbDrone.Core/Datastore/LazyLoaded.cs | shim/LazyLoaded.cs | Upstream `LazyLoaded<T>` takes an `IDatabase` and logs through `SqlBuilderExtensions`. The shim keeps the public surface (`Value`, `IsLoaded`, implicit conversions, the JSON converter attribute) without the database hooks. |
| src/NzbDrone.Common/EnvironmentInfo/RuntimeInfo.cs | shim/RuntimeInfo.cs | Upstream reads the process, OS and Windows service state and needs Microsoft.Extensions.Hosting. The vendored HTTP code only reads the static `IsProduction`, which the shim fixes to `true` (a released Prowlarr: requests auto redirect). |
| src/NzbDrone.Common/EnsureThat/EnsureStringExtensions.cs | shim/EnsureStringExtensions.cs | Upstream also has path validators that pull in `PathExtensions`, `IAppFolderInfo` and `OsInfo`. Only `IsNotNullOrWhiteSpace` (the one the vendored cache code uses) is kept, with the upstream message. |
| src/NzbDrone.Common/Http/HttpClient.cs | shim/HttpClient.cs | Verbatim copy minus one line, `ServicePointManager.DefaultConnectionLimit = 12;`, which throws `PlatformNotSupportedException` on wasi-wasm (System.Net.Requests is not supported there). Found by running the component under Wasmex (Task 4). |
| src/NzbDrone.Core/Indexers/IndexerCapabilitiesCategories.cs | shim/IndexerCapabilitiesCategories.cs | Verbatim copy except one call: `SHA1.Create().ComputeHash(...)` becomes `ManagedSha1.Hash(...)`. `System.Security.Cryptography` throws `PlatformNotSupportedException` on wasi-wasm, and every string tracker category with a description reaches that line. The id must equal Prowlarr's, so `shim/ManagedSha1.cs` is a plain SHA-1, tested against the BCL. Found by the Engine fixtures (Task 7). |
| src/NzbDrone.Core/Indexers/Definitions/Cardigann/CardigannDefinition.cs | shim/CardigannDefinition.cs | Verbatim copy except `FilterBlock.Args`, which is `dynamic` upstream and `FilterArgs` here. Upstream indexes it (`(string)filter.Args[0]`), and the C# runtime binder cannot index anything under NativeAOT: a `List<object>` fails with "Cannot apply indexing with []" (trimmed reflection metadata), and a type with its own indexer or an array fails with an `ArgumentNullException` in the binder's expression rewriter. Every filter with more than one argument (`re_replace`, `replace`, `split`, ...) then failed on wasm and silently dropped its field or request. Found by the Engine fixtures (Task 7). |
| src/NzbDrone.Core/Indexers/TorrentIndexerBase.cs | shim/TorrentIndexerBase.cs | Verbatim copy except `ValidateDownloadData`: upstream calls MonoTorrent's `Torrent.Load`, which SHA-1 hashes the info dictionary and so throws on wasi-wasm, failing every torrent download. The shim makes the checks `Torrent.Load` 3.0.2 makes, minus the hash, for a v1 torrent: the bencode decodes to a dictionary with an `info` dictionary; `info` has an integer `piece length` and a `pieces` byte string whose length is a multiple of 20; it has `files` (a list of dictionaries, each entry with a `path` needing an integer `length`) or an integer `length`; the total size is not zero. `name` is not required (Torrent.Load leaves it empty). Not checked: path validity, hybrid v1/v2 consistency, optional metadata. A v2-only torrent is rejected. Found by the Engine fixtures (Task 7). |
| src/NzbDrone.Core/Indexers/HttpIndexerBase.cs | shim/HttpIndexerBase.cs | Verbatim copy except one line: the retry `ResiliencePipelineBuilder` gets `TimeProvider = BlockingTimeProvider.Instance`. Upstream retries a server error (5xx, 408) twice behind a Polly delay built on `TimeProvider.Delay`; the guest has no event loop or second thread, so the timer never fires and the blocking wait on the pending delay throws `PlatformNotSupportedException`. `shim/BlockingTimeProvider.cs` makes a timer sleep the thread for its due time (`Thread.Sleep`, which wasi supports) and then run its callback before `CreateTimer` returns, so the delay is as long as upstream's and already complete when awaited. Retry count, delays and outcomes are upstream's. |

## Added, not substituted

These have no upstream counterpart because upstream wires them with dependency injection and a database.

| Shim | Purpose |
|---|---|
| shim/Services.cs | `NullEventAggregator`, `NoRateLimitService` (the host rate-limits), `NoProxyFactory` (no indexer proxies), `CallConfigService` (Prowlarr's default values). |
| shim/FilterArgs.cs | The statically typed `FilterBlock.Args` that replaces `dynamic` (see the `CardigannDefinition.cs` row), and the YamlDotNet converter that reads `args:` into it. It reproduces upstream's outcome per shape: null forms (`~`, `null`, empty, absent) give a null Args; a scalar casts to string but cannot be indexed; a sequence indexes but cannot be cast; a nested sequence or mapping (skipped with `SkipThisAndNestedEvents`) loads and throws only when that element is read. Registered in `shim/DefinitionService.cs`; pinned by `FilterArgsTests.cs`. |
| shim/ManagedSha1.cs | SHA-1 for the category ids above. |
| shim/ExchangeDispatcher.cs, shim/RequestMapping.cs | Test seam and mapping for the HTTP exchange, replacing `ManagedHttpDispatcher`'s socket code. `RequestMapping` mirrors its Cookie header, Set-Cookie and response header handling (repeated response headers collapse to one value joined by ";", as `HttpHeaders.ToNameValueCollection` does). One deliberate difference: the default User-Agent is a desktop browser string, not `Prowlarr/<version> (<os>)`, because Cloudflare refuses the latter on trackers that serve a browser (found by the gating benchmark: megapeer, 0magnet and 52bt answered Prowlarr's string with a 403 or a block page and a browser string with results; kickasstorrents-ws, magnetcat and torrentsome stayed blocked after the change); a definition's own User-Agent header still wins. |

## Behaviour added around unmodified upstream code

- `shim/ExchangeDispatcher.cs` records, per call, whether any request failed (a
  transport error, a status of 400 or more, or `CloudFlareDetectionService`
  reporting a challenge), the status of the last response of 400 or more and
  whether a challenge was seen. `Runner.Search` reports them as `request-failed`
  and `failed-status`. Upstream swallows a failed search request as an empty
  page, and that is still what the guest returns; the flags are the only way the
  host can tell a block from "no results". The dispatcher only records: retries,
  Cloudflare detection, `login.error` selectors and download errors are upstream's.
- `Runner.Build` maps the `baseUrl` setting onto `CardigannSettings.BaseUrl`, the
  property upstream's `ResolveSiteLink` reads, so the host picks the mirror.
  Upstream rewrites a `legacylinks` entry to the first link, so the host offers
  only `links:`.
- The default User-Agent (see `RequestMapping.cs`) is the browser string the Elixir
  engine sends, not `Prowlarr/<version>`.

## Compile-time resources

`EnsureThat/Resources/ExceptionMessages.resx` is embedded from `.prowlarr/` by `CardigannGuest.csproj` with the logical name the upstream designer file expects.
