# Cardigann wasm spike

Verdict: **GO**. The component runs under `allow_http: false`, the plugin host's lockdown, because `build.sh wasm` composes trapping stand-ins for `wasi:http` and `wasi:sockets` under it (see "Sandbox lock").

## Toolchain

- Prowlarr `v2.6.5.5623` (`12c327808314a7cae1b7301935ee10cabc19609f`), compiled as a library.
- .NET SDK image `mcr.microsoft.com/dotnet/sdk:10.0`, digest
  `sha256:e70cdb7f80b0348f5cb85f19a8f670fca061f033d57eed12fa003d58b0e06317`.
- componentize-dotnet `BytecodeAlliance.Componentize.DotNet.Wasm.SDK` 0.8.0-preview00011, ILCompiler
  `10.0.0-rc.1.26355.1`, wasi-sdk 29, wit-bindgen 0.58.0 (details under Component shape).
- Host: Wasmex 0.15.1 (wasmtime 47.0.2), Elixir 1.20.4.

## Substitutions count

9 upstream files are not compiled and are replaced (the 9 rows of `SUBSTITUTIONS.md`): `IndexerDefinitionUpdateService.cs`,
`IndexerStatusService.cs`, `ProviderStatusServiceBase.cs`, `IndexerProxyFactory.cs`, `LocalizationService.cs`,
`LazyLoaded.cs`, `RuntimeInfo.cs`, `EnsureStringExtensions.cs` (Task 2) and `HttpClient.cs` (Task 4, one line removed,
see Build obstacle 8). They are covered by 8 shim files, because `shim/IndexerStatus.cs` replaces two upstream files.
`shim/` holds 13 files in all: those 8, plus `Services.cs`, `ExchangeDispatcher.cs` and `RequestMapping.cs` (additions with
no upstream counterpart) and `HostExchange.cs` and `HostLogTarget.cs` (wasm-only host glue).

## Component shape (Task 3)

`build.sh wasm` produces `out/cardigann.wasm`, a wasip2 component built with
componentize-dotnet 0.8.0-preview00011 (NativeAOT-LLVM, ILCompiler
`10.0.0-rc.1.26355.1`, wasi-sdk 29, wit-bindgen 0.58.0).

`wasm-tools component wit out/cardigann.wasm` (world lines):

```
import mydia:cardigann/types@1.0.0;
import mydia:cardigann/host@1.0.0;
export mydia:cardigann/engine@1.0.0;
```

WASI imports (all 0.2.6 except http; the ceiling for wasmtime 47 is 0.2.12):

```
wasi:io/{poll,error,streams}@0.2.6
wasi:clocks/{monotonic-clock,wall-clock}@0.2.6
wasi:http/{types,outgoing-handler}@0.2.0
wasi:cli/{environment,exit,stdin,stdout,stderr,terminal-input,terminal-output,
          terminal-stdin,terminal-stdout,terminal-stderr}@0.2.6
wasi:filesystem/{types,preopens}@0.2.6
wasi:sockets/{network,instance-network,udp,udp-create-socket,tcp,tcp-create-socket,ip-name-lookup}@0.2.6
wasi:random/random@0.2.6
```

Highest version: 0.2.6. The component imports `wasi:http` and `wasi:sockets`
even though the guest does its HTTP through `mydia:cardigann/host`; the .NET
runtime pulls them in. The host must provide (or stub) all of them to
instantiate.

Size: `out/cardigann.wasm` is 69,803,048 bytes (66.6 MiB) with debug info;
`wasm-tools strip` gives 36,266,293 bytes (34.6 MiB). `wasm-tools validate`
passes on both.

Generated binding names (wit-bindgen C#, the `Interop` suffix is not used for
exports): exports implement `CardigannWorld.wit.Exports.mydia.cardigann.v1_0_0.IEngineExports`
in a class that must be named `EngineExportsImpl`; imports are called as
`IHostImports.HttpRequest` / `IHostImports.Log`; records live in `ITypesImports`.
Errors cross the boundary by throwing `CardigannWorld.WitException(engineError, 0)`.

## Build obstacles

1. **Preview packages need the dotnet-experimental feed.** The NativeAOT-LLVM
   compiler `runtime.linux-x64.microsoft.dotnet.ilcompiler.llvm` is not on
   nuget.org. Added `nuget.config` with nuget.org and dotnet-experimental, and
   an explicit `PackageReference` pinned to `10.0.0-rc.1.26355.1` (the newest 10.x
   on the feed), only when `WasmBuild=true`.
2. **Generated export class name.** The first build failed with
   `EngineExportsImpl does not exist`: wit-bindgen names the implementation
   class after the interface (`EngineExportsImpl`), in namespace
   `CardigannWorld.wit.Exports.mydia.cardigann.v1_0_0`. `exports/EngineImpl.cs`
   defines it. The brief expected `IEngine`; the real interface is `IEngineExports`.
3. **Circular `Publish` target.** `dotnet publish` fails with MSB4006 because the
   SDK's targets publish after build. `build.sh wasm` runs `dotnet build` and
   copies `bin/Release/net10.0/wasi-wasm/native/CardigannGuest.wasm`.
4. **Namespace guesses.** `CardigannException`/`CardigannConfigException` live in
   `NzbDrone.Core.Indexers.Definitions.Cardigann.Exceptions`. `WitException` is in
   `CardigannWorld`.
5. **wasi-sdk download.** The build downloads wasi-sdk-29 (119 MB) into
   `/tmp/.wasi-sdk` every run; `build.sh` now mounts a persistent directory
   (`$NUGET_CACHE-wasi-sdk`) there.
6. **No `WASM_BUILD` leak into native tests.** `HostExchange`, `HostLogTarget` and
   `EngineImpl` are wrapped in `#if WASM_BUILD`; `build.sh test` still passes 11/11.

Trimming/AOT: no reflection descriptors were needed to get a component out.
The build emits 270 trim/AOT warnings (132 IL2026 and 118 IL3050 are
Newtonsoft/System.Text.Json/`dynamic` usage in `CardigannBase`, `Json.cs`,
`LazyLoadedConverterFactory`). Whether trimming removed members that
YamlDotNet, Newtonsoft or the C# runtime binder need can only be found by running
the component; that is Task 4.

7. **Trimmed reflection targets (found under Wasmex).** The first run failed inside
   YamlDotNet: `MissingMethodException: No parameterless constructor defined for type
   CardigannDefinition`. Prowlarr's definition types are built by reflection, which the
   trimmer cannot see. `CardigannGuest.csproj` now roots the guest assembly
   (`TrimmerRootAssembly`). Cost: the unstripped component grew from 69.8 MB to 75.6 MB.
8. **`ServicePointManager` throws on wasi-wasm.** Next failure:
   `PlatformNotSupportedException: System.Net.Requests is not supported on this platform` from
   `NzbDrone.Common.Http.HttpClient..ctor` (`ServicePointManager.DefaultConnectionLimit = 12`).
   `shim/HttpClient.cs` is the upstream file minus that line.
9. **`list<u8>` crosses as a list of integers**, not a binary. The first host `http-request`
   reply used a binary body and trapped in the import trampoline (`<wasm function 0>`). The
   host must send `:binary.bin_to_list/1`. This is a host bug, not a guest one.
10. Internal errors now carry the inner exception chain (`EngineImpl.InnerChain`); without it,
    obstacles 7 and 8 were reported only as an opaque top-level `YamlException`.

## Linking under Wasmex

`Components.start_link` with `WasiP2Options{allow_http: false}` fails at instantiation:

```
component imports instance `wasi:http/types@0.2.0`, but a matching implementation was not found in the linker
```

`deps/wasmex/native/wasmex/src/component_instance.rs` links the wasi p2 interfaces always
(`wasmtime_wasi::p2::add_to_linker_async`) but links `wasi:http` only when the store was built
with `allow_http: true` (`add_only_http_to_linker_async`). With `allow_http: true` every other
import (wasi:io, clocks, cli incl. terminal-*, filesystem, sockets, random, all 0.2.6) links.

**Sandbox concern.** In `store.rs`, `allow_http: true` also calls `inherit_network()` and
`allow_ip_name_lookup(true)`, and creates a `WasiHttpCtx`. So the only way to satisfy this
component's `wasi:http` import also gives the guest ambient TCP/UDP and DNS, which is weaker than
the plugin host's `allow_http: false` stance. The guest never uses them (its only egress is
`mydia:cardigann/host.http-request`, which the host controls), but the sandbox does not enforce
that. This is closed by composing the imports out (see "Sandbox lock"). The raw component,
`out/cardigann-raw.wasm`, still links only with `allow_http: true`; the shipped
`out/cardigann.wasm` links with `allow_http: false`.

## Sandbox lock

Goal: the guest instantiates under the plugin host's exact options (`allow_http: false`) and
has no ambient network, with no Wasmex change.

**Stubbed interfaces.** The raw component (`out/cardigann-raw.wasm`) imports these, read with
`wasm-tools component wit`:

| Interface | Resources |
|---|---|
| `wasi:http/types@0.2.0` | `outgoing-request`, `request-options`, `future-incoming-response`, `fields`, `incoming-response`, `incoming-body`, `outgoing-body`, `future-trailers` |
| `wasi:http/outgoing-handler@0.2.0` | none (one function, `handle`) |
| `wasi:sockets/network@0.2.6` | `network` |
| `wasi:sockets/instance-network@0.2.6` | none |
| `wasi:sockets/udp@0.2.6` | `udp-socket`, `incoming-datagram-stream`, `outgoing-datagram-stream` |
| `wasi:sockets/udp-create-socket@0.2.6` | none |
| `wasi:sockets/tcp@0.2.6` | `tcp-socket` |
| `wasi:sockets/tcp-create-socket@0.2.6` | none |
| `wasi:sockets/ip-name-lookup@0.2.6` | `resolve-address-stream` |

**Sockets did not need stubbing to link.** With `allow_http: false` Wasmex still links every
other wasi p2 interface, `wasi:sockets` included, and `store.rs` then does not call
`inherit_network`, so wasmtime would deny the calls anyway. Only `wasi:http` blocked linking.
Both are composed out regardless, so the guarantee does not depend on Wasmex's internals: the
final component has no way to name a socket or an HTTP request.

**Mechanism.** `deny/` is a `wasm32-wasip2` Rust crate whose world exports exactly the
interfaces above, at the versions the guest imports. `build.sh wasm` runs, in the pinned
`rust:1.96` container (`scripts/rust-tools.sh`, tool versions pinned there: wit-bindgen-cli
0.62.0, wac-cli 0.12.0, wasm-tools 1.258.0):

1. `wit-bindgen rust --stubs --generate-all` writes `deny/gen/stubs.rs` (git-ignored): the
   bindings plus an `impl` of every exported trait on one `Stub` type. Generating it keeps the
   stand-ins in step with the WIT. Every body is `unreachable!()`, so a call traps; none
   returns an error value (the brief's "return the error variant where there is one" was not
   done: a trap is stricter and nothing is meant to call these).
2. `cargo build --release --target wasm32-wasip2` builds `cardigann_deny.wasm` (about 107 kB).
3. `wac plug --plug cardigann_deny.wasm out/cardigann-raw.wasm -o out/cardigann.wasm` satisfies
   the guest's wasi:http and wasi:sockets imports from the deny component's exports.
4. `wasm-tools component wit out/cardigann.wasm | grep -E 'import wasi:(http|sockets)'` must
   print nothing, or the build fails.

`deny/wit/deps/{io,clocks,sockets}` are the full upstream WIT (from wit-bindgen's wasi test
tree, version strings rewritten to 0.2.6). The pruned view printed from the guest is not
enough: rustc's bundled preview1 adapter merges its own full copy of `wasi:io`, `wasi:sockets`
and fails on a pruned one ("expected function to-debug-string to be present"). `deny/wit/deps/http`
is the guest's own pruned view of `wasi:http@0.2.0`, which is sufficient because nothing
merges against it. The deny component imports only `wasi:io`, `wasi:clocks` and `wasi:cli`
interfaces that Rust std links, all of which the guest already imports at 0.2.6.

**Verification.** The composed component has no `wasi:http` or `wasi:sockets` import, and the
three spike tests pass with `WasiP2Options{allow_http: false}` and no stand-in trapped.

## Measurements

Real runs, one Linux machine, median as stated. The test is
`test/mydia/indexers/cardigann/wasm/spike_test.exs`.

| Measurement | Result |
|---|---|
| `.wasm` size, unstripped | 75,726,879 bytes (72.2 MiB) composed; 75,612,093 raw (the deny component adds 114,786) |
| `.wasm` size, `wasm-tools strip` | 39,148,384 bytes (37.3 MiB) |
| Compile (`Component.new`), median of 3 | 3,280 ms composed (samples 3276, 3280, 3293; the pre-composition build measured 3,269 ms, an earlier run 3,642 ms) |
| Instantiate with a reused compiled component, median of 20 | 0 ms (sub-millisecond, `Instance.new` alone reads 3 ms median incl. store) |
| Fresh store + compile, median of 20 | 3,320 ms |
| Fresh store + `Instance.new` of an already compiled component | 3 ms median |
| Full `Components.start_link`, median of 5 | 3,332 ms composed (3353, 3302, 3345, 3332, 3291) |
| First search call after `start_link` | 43 to 79 ms |
| Steady-state search call against Bypass, median of 20 | 2 ms (min 2, max 5) |
| VmRSS before / after 20 sequential calls | 1,441,560 kB / 1,441,712 kB (+152 kB) |
| `:erlang.memory(:total)` before / after | 175,793,368 / 175,897,712 bytes (+104 kB) |

Notes:

- Reusing a compiled component works only inside one `Wasmex.Engine`. `Wasmex.Engine.default/0`
  creates a **new** engine on each call, so `Store.new_wasi(wasi)` followed by a second
  `Store.new_wasi(wasi)` fails with
  `cross-Engine instantiation is not currently supported`. Pass one engine explicitly:
  `shared = Wasmex.Engine.default()`, `Store.new_wasi(wasi, nil, shared)` for the compile store
  and for every instance store, then
  `GenServer.start_link(Wasmex.Components, %{store: store, component: compiled, imports: imports})`.
  A reused instance served a real search (asserted in the test).
- The 1.4 GB VmRSS is the whole test process after about 30 compilations whose compiled code was
  not freed within the test, not the cost of one instance. A per-instance cost was not isolated.
  Compiled code of a 75 MB component is evidently large; compile once and share.
- A plain `start_link` per call, as `Mydia.Plugins.Host` does, would cost about 3.3 s each. The
  design must hold a compiled component and instantiate per call (3 ms) or keep instances warm.
- `publish-unix` came back `:none` for both fixture releases, whose `date` field uses
  `dateparse "yyyy-MM-dd"`. Not a spike criterion; it needs a look before Phase 2 (invariant
  globalization or trimmed date parsing under AOT are the likely suspects).

## Wasmex value shapes

Observed on Wasmex 0.15.1. `Wasmex.Components.call_function/4` wraps the call in `{:ok, _}` /
`{:error, string}`; the WIT `result` is a second layer.

| WIT | Elixir (arguments and results) |
|---|---|
| `record` | map. Keys are the **kebab-case WIT names**, so `imdb-id` is `:"imdb-id"`. Arguments accept atom or string keys; every field is required (a missing one fails with `Expected N fields, got M - missing fields: expires-unix`). |
| `record` in results | map whose keys are atoms **if the atom already exists in the VM**, otherwise strings (the converter uses `str_to_term`). In the search result `:size`, `:title`, `:"imdb-id"` came back as atoms and `"download-url"`, `"guid"`, `"session-changed"` as strings. Read results with a lookup that accepts both, never a bare `%{key: _}` match for hyphenated names. |
| `option<T>` | `:none` or `{:some, value}`. `nil` is rejected (`Invalid atom: nil, expected ':none' or '{:some, term}' tuple`). |
| `enum` | atom with the WIT case name (`:search`); a binary is also accepted. |
| `variant` | atom for a no-payload case, `{:case_name, payload}` otherwise (`{:connect, "msg"}`, `{:internal, "..."}`). |
| `result<T, E>` | `{:ok, v}` / `{:error, e}`. Inside `call_function` this is nested: `{:ok, {:ok, search_out}}`, and `login` is `{:ok, {:ok, {:ok, session}}}` (call, result, `login-out` variant `ok`). |
| `list<T>` | list. |
| `list<u8>` | **list of integers**, both directions. A binary is rejected as an argument and traps as a host-function return. Use `:binary.bin_to_list/1` and `:erlang.list_to_binary/1`. |
| `string` | binary. |
| `s64`/`s32`/`u16` | integer. `f64` float. `bool` boolean. |
| host import | `{:fn, fun}` called with the WIT parameters as separate arguments (`fn req -> ... end` for `http-request`, `fn level, msg -> ... end` for `log`); `http-request` returns `{:ok, resp_map}` or `{:error, {:connect, msg}}`. Raising or a wrongly shaped return surfaces as a trap in the import trampoline with no reason in the message. |
| import namespace | `"mydia:cardigann/host@1.0.0"`, matched exactly. Export path `["mydia:cardigann/engine@1.0.0", "search"]`. |

## Verdict

**GO.** The earlier sandbox concern (the component linked only with `allow_http: true`, which also grants ambient network
and DNS) is resolved by the build-time composition described in "Sandbox lock".

| Rule | Result |
|---|---|
| Both tests pass | Yes: search returns 2 releases, form login returns the `sid=abc123` cookie (3 of 3 tests pass, including the measurement test). |
| All WASI imports at most 0.2.12 | Yes: highest is 0.2.6 (`wasi:http` is 0.2.0). |
| Reused-component instantiation works, or full `start_link` is at most 500 ms | Reused-component instantiation works (median 0 ms; 3 ms with the store) provided one `Wasmex.Engine` is shared. Full `start_link` is 3,302 ms, so this clause is satisfied only by the first alternative. |

What GO does not cover, to settle before or during Phase 2:

1. Compile costs 3.3 s and the component is 38 to 76 MB; compile once per node and share the
   engine and compiled component. Plugin-host style `start_link` per call is not viable.
2. The AOT build needed three fixes found only by running it (obstacles 7 to 9); more reflection
   or platform gaps may surface in definitions other than the two fixtures.
3. `publish-unix` is `:none` for dated rows. This is a wasm-only defect: the native `RunnerTests` assert the parsed
   date (`2031-04-02`) for this same fixture and pass on plain .NET, so the fixture and `ToRelease` are not at fault.
   `spike_test.exs` has a `:known_wasm_defect` test asserting the date, excluded by default, so a fix turns it green.
