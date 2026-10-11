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

## Added, not substituted

These have no upstream counterpart because upstream wires them with dependency injection and a database.

| Shim | Purpose |
|---|---|
| shim/Services.cs | `NullEventAggregator`, `NoRateLimitService` (the host rate-limits), `NoProxyFactory` (no indexer proxies), `CallConfigService` (Prowlarr's default values). |
| shim/ExchangeDispatcher.cs, shim/RequestMapping.cs | Test seam and mapping for the HTTP exchange, replacing `ManagedHttpDispatcher`'s socket code. `RequestMapping` mirrors its user agent, Cookie header, Set-Cookie and response header handling. |

## Compile-time resources

`EnsureThat/Resources/ExceptionMessages.resx` is embedded from `.prowlarr/` by `CardigannGuest.csproj` with the logical name the upstream designer file expects.
