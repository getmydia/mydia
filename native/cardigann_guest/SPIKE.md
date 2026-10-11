# Cardigann wasm spike

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
