# Cardigann wasm engine: gating benchmark

Prowlarr's Cardigann engine compiled to wasm (the "wasm" engine) against Mydia's
Elixir engine, judged against a real Prowlarr v2.6.5.5623 in Docker, over every
public definition at Prowlarr/Indexers `d34bddc56cfd6a55f75a9f69dcc2df9eb591662c`
(81 definitions, 162 queries; 498 definitions left out because they need
credentials). Single-session runs, `--concurrency 1`, fresh Prowlarr data directory.

The engine ships as an opt-in (`CARDIGANN_ENGINE=prowlarr`); the Elixir engine
stays the default. The gate therefore decides whether the engine is offered at all,
and every item it still fails is a caveat a user has to be told about. The caveats
are listed under "Caveats for users" and are repeated in
`lib/mydia/indexers/README.md` and `docs/using/how-to/cardigann-indexers.md`.

## Gate result for the opt-in: items 1 to 3 pass, M5 does not

Second run, 2026-10-12, Mydia `10d19901f` (after the mirror failover and the retry
fixes), next to the first run, 2026-10-11, `7118d17f7`.

| Gate item | Required | First run (`7118d17f7`) | This run (`10d19901f`) | This run passes |
|---|---|---|---|---|
| M1 fidelity | wasm > elixir | wasm 44/44 (100.0%), elixir 29/44 (65.9%) | wasm 44/44 (100.0%), elixir 28/44 (63.6%) | PASS |
| M2 coverage | wasm >= elixir | wasm 54/81, elixir 55/81: **FAIL** | wasm 55/81, elixir 54/81 | PASS (by one definition; see below) |
| M3 regressions | 0 unexplained | 0 | 0 | PASS |
| M4 p95 overhead | <= max(2x elixir, 50 ms) | wasm 243.9 ms vs elixir 126.0 ms (limit 252.0), paired n=66 | wasm 248.6 ms vs elixir 136.1 ms (limit 272.2), paired n=67 | PASS, with 23.6 ms of headroom; one run, treat as unstable (see below) |
| M5 RSS, pool warm | <= 200 MB | +955 MB glibc, compile at boot, no trim: **FAIL** | +64 MB steady state (538 to 543 MB against 475 MB for the default engine), Alpine image, precompiled `.cwasm` | PASS at steady state; **FAIL under load**: 762 to 770 MB during 4 concurrent searches, +288 to +295 MB over the default engine |
| M5 cold start | <= 5 s | 3.8 s, glibc, compile only | first boot 18.2 to 18.6 s of compile on Alpine (22.8 to 23.5 s from container start to engine available, with the database migrating); second boot 0.58 to 0.71 s to load, 2.2 to 2.4 s from container start | **FAIL** on a first boot (it runs in the background and does not delay the rest of boot); PASS on every later boot. **Superseded for first boots by the precompiled download (2026-10-13, below): about 6 s from container start to ready, 633 to 662 MB peak; the local-compile fallback is unchanged** |
| M5 image size | <= 60 MB | +75.1 MB in the image: **FAIL** | -6.7 MB in the image (728.9 MB against 735.6 MB); a 38.9 MB download (stripped; 75.1 MB before stripping) plus 119.0 MB of cache in the data directory | PASS for the image and for the download. 158 MB of disk per install |

Items 1 to 3 pass this time, so the engine is offered, behind the flag. What the
table does not hide:

- **M5 cold start fails on a first boot**, by a factor of 3.6 on Alpine, and the
  first boot also peaks at about 1.55 to 1.59 GB of resident memory (`VmHWM`)
  while it compiles, then falls back to 490 to 500 MB. A container limited to
  less than about 2 GB can be killed on that first boot. This is a caveat, not a gate
  item; the old gate did not measure the peak. Since 2026-10-13 a first boot that
  can download the precompiled guest takes about 6 s with a 633 to 662 MB peak (see
  "M5 re-measured, precompiled download"); the figures in this bullet now describe
  only the local-compile fallback.
- **M5 RSS fails under load.** Four concurrent searches take the BEAM from
  541 MB to 762 to 770 MB. The gate figure (steady state, pool warm) passes.
- **M2 passes by one definition**, and the single definition on which the Elixir
  engine still wins (torrentsome) is a Cloudflare 403 that Prowlarr hits as well.
  The wasm-only wins are not robust: anisource resolves only some of the time from
  this host and pandacd is an HTTP 400 for the Elixir engine. The first run was one
  short the other way. Read M2 as parity, not as a win.
- **M4 passes with 23.6 ms to spare** (p95 248.6 ms against a limit of 272.2 ms),
  and the Elixir p95 has been as low as 69 ms in other runs, which would put the
  wasm engine over the limit. The p50 is 89.0 ms against 29.5 ms: a search through
  the wasm engine costs about 60 ms more at the median. A fresh sandboxed instance
  per call costs about 31 ms with no network involved.

### Reading the first run's failures

These are kept as written for the first run; the failover and 5xx items were fixed
afterwards (see "Known wasm defects" below) and this run's table is above.

**M2 (54 vs 55 in the first run).** Three definitions gave the Elixir engine
results and the wasm engine none: kickasstorrents-ws, magnetcat and torrentsome.
For kickasstorrents-ws and magnetcat the logs showed the first link in `links:`
answering with a Cloudflare 403 and the Elixir engine parsing results from the
next mirror. Prowlarr has no mirror failover, so for those two it was a Mydia
feature the wasm adapter lacked. The adapter now fails over (see below):
kickasstorrents-ws returns 60 and 50 releases, the same counts as the Elixir
engine. magnetcat returns nothing on either engine this time (HTTP 410 on every
mirror). torrentsome is a Cloudflare 403 for the wasm engine and for Prowlarr; why
the Elixir engine is not blocked there was never established.

**M5 (first run).** The +955 MB was Cranelift's compile memory held by glibc malloc;
see the memory spike below. The 75.1 MB was the `.wasm` baked into the image.

## M5 re-measured for the opt-in (Alpine image, 2026-10-12)

All numbers are from the production Alpine image of this branch, run as a
container with `CARDIGANN_ENGINE=prowlarr`, a fresh `/config` volume, and the
locally built component mounted through `CARDIGANN_WASM_PATH` with a temporary local
pin (the asset is not published, so a download from GitHub was not measured; the
size of the download is the file size). The pin was reverted and is not committed.
RSS is `VmRSS` of the BEAM process read inside the container. The measurements
before the strip below used the unstripped component; the container measurements
were repeated with the stripped one and agree.

| Item | Result |
|---|---|
| Image size, branch vs `origin/master` (`272ef9447`) | **728,900,297 B vs 735,603,871 B: -6,703,574 B (-6.7 MB)**. The branch image contains no guest. Both are `docker image inspect` sizes (the branch built from the working tree with a stray `priv/data/cardigann` removed, see below; master from a `git archive`) |
| First boot, fresh volume | engine available 22.8 s after container start (unstripped) and 23.5 s (stripped): 18.2 s and 18.6 s of compile ("compiled and cached in N ms"), the rest is the application booting and migrating a fresh database. `/config/cardigann/` then holds the `.cwasm` (118,975,992 B, 0600) and its `.sha256` |
| RSS after the first boot | 488 to 499 MB (493 MB stripped). Peak during the compile: `VmHWM` 1,585 MB (1,549 MB stripped). `malloc_trim` is a no-op on musl, but the heap does fall back |
| Second boot (restart, same volume) | engine available 2.35 s after container start (2.2 s stripped), "loaded precompiled in 714 ms" (576 ms stripped). RSS 548 MB (510 MB stripped) 20 s after ready; `VmHWM` 614 MB |
| RSS during 4 concurrent searches | 4 workers x 25 searches against a local fixture tracker inside the container (100 searches in 1.4 s), sampled every 20 ms: peak **769.7 and 769.3 MB (762.4 MB stripped)**, from 541.5 MB before. After the burst: 541 to 543 MB (538 MB stripped) |
| Default engine, branch vs master, idle | branch 474.9, 475.1, 466.8 MB (median 474.9); master 454.5, 461.2, 466.0 MB (median 461.2), three fresh containers each, 75 s after start. **+13.7 MB** at the median, ranges overlapping at the edges (466.8 vs 466.0). The plan expected about 0; the cause of the 14 MB was not established (the branch carries other code, and a source-built, patched Wasmex NIF) |
| Container cgroup memory (`docker stats`) | 373 to 401 MiB with the engine ready; `VmRSS` counts the file-backed pages of the mapped `.cwasm`, the cgroup figure counts them differently |

Method notes.

- **Fixture tracker.** The wasm host refuses private addresses, loopback included,
  outside the test environment, so a loopback fixture does not work in a release.
  The fixture server listens on 198.51.100.7 (TEST-NET-2), added to the container's
  `lo` with `docker exec --privileged -u root ... ip addr add`, and serves the
  `lantern` fixture definition and page that the test suite uses. No real tracker
  was contacted by the memory measurements. The script runs through
  `bin/mydia rpc` inside the container.
- **Image sizes.** `docker build` of this branch (with the temporary pin and the
  locally built component mounted in at run time, not in the build) and of a
  `git archive` of `origin/master`. A first branch build came out at 847.9 MB
  because the build context included a developer's `priv/data/cardigann` (a cached
  `.cwasm`, 116 MB, written by running the dev server in the same worktree).
  `.dockerignore` now excludes `priv/data/cardigann`, and the figure above is the
  rebuild.
- **Second boot** restarts the same container (`docker restart`), so the volume
  and the cached `.cwasm` are the ones the first boot wrote.

### Shrinking the component

Cheap, so done. The component the build produced had about 35 MB of DWARF debug
sections (`.debug_info`, `.debug_str`, `.debug_line`, ...) inside 75.1 MB.
`wasm-tools strip` (already in the pinned toolchain image) removes them in a
second; `build.sh wasm` now runs it as its last step, after the import check, and
validates the result.

| Variant | `.wasm` bytes | gzip -9 |
|---|---|---|
| as built (`cardigann.wasm`, previous) | 75,071,873 | 16,486,724 |
| `wasm-tools strip` (kept; name section retained, so a trap names its functions) | 38,945,911 | n/a |
| `wasm-tools strip --all` (not used) | 29,172,950 | 8,321,622 |

The stripped component validates, exposes the same imports and exports, and
compiles to the same `.cwasm` (118,975,960 B against 118,975,992 B), so the memory
and load figures do not change. No `wasm-opt` is in the toolchain image and none
was tried. The download is 38.9 MB. GitHub serves release assets without
compression, so the gzip column is for reference only. `--all` would save a
further 9.8 MB at the cost of function names in traps.

## M5 re-measured, precompiled download (Alpine image, 2026-10-13)

CI now publishes the compiled guest (`.cwasm.gz`) for each architecture, and the
engine downloads it, checks it against a pin baked into the image and loads it
instead of compiling. These are container numbers from the production Alpine image
of this branch (`docker buildx build --load -t mydia-cwasm-bench .`, 728,947,434 B),
run with `CARDIGANN_ENGINE=prowlarr` and a fresh `/config` volume, on a 16-core host.
`VmHWM` and `VmRSS` are read from the BEAM process (`/proc/1`) 20 s after the engine
reported ready.

The `.cwasm.gz` was built with the Dockerfile's own stage (`--target cwasm-out`, the
same one CI runs) from the published guest, and served from a local HTTP server on the
Docker bridge, together with the `.wasm`. The pins and base URLs were set at run time
through `ERL_AFLAGS` (`-mydia cardigann_cwasm_pin ...`), so the image holds no pin and
nothing was committed. Nothing was fetched from GitHub, so the download time is the
time to read two files from the local machine; the sizes below say what a real
download moves. The fallback case is the same image without a `.cwasm` pin, which is
what an install gets when no `.cwasm` is published or its pin is missing.

| Item | Result |
|---|---|
| First boot, download | engine ready **5.9 s and 6.05 s** after container start (two fresh volumes); the engine itself reports "downloaded precompiled in 870 ms" and "827 ms" (download, inflate, verify and deserialize, after the `.wasm`). `VmHWM` **633 MB and 662 MB**, `VmRSS` 517 MB and 505 MB. The rest of the time is the application booting and migrating a fresh database |
| First boot, fallback (no `.cwasm` pin) | engine ready 23.9 s after container start, "compiled and cached in 18,769 ms". `VmHWM` **1,607 MB**, `VmRSS` 546 MB. Within a few percent of the previous section (18.2 to 18.6 s of compile, 1,549 to 1,585 MB) |
| Second boot (restart, same volume) | engine ready 2.7 s and 2.5 s after container start, "loaded precompiled in 751 ms" and "718 ms". `VmHWM` 597 MB and 562 MB, `VmRSS` 512 MB and 503 MB. The path is the same for both first-boot cases, which write an identical cached file |
| Download size | `.wasm` 38,945,911 B plus `.cwasm.gz` 28,782,677 B: **67.7 MB**, against 38.9 MB before |
| Disk per install | 158 MB in `/config/cardigann/` (`.wasm` 38,945,911 B, `.cwasm` 118,975,960 B, a 65 B checksum file), unchanged. The `.gz` is inflated while it downloads and never stored |
| Image size | 728,947,434 B, against 728,900,297 B for the previous section's branch image (+47 KB, from an unrelated rebuild of the same stages) |
| Precompile in the Docker stage | 18.1 s on Alpine in the Docker stage (measured in the Docker stage; 4.4 s for the parallel compile, measured on the 16-core glibc host), 118,975,960 B in both. The two files differ in content, so a pin has to come from the Alpine build CI runs, never from a host build |

What the download case saves: about 18 s of first-boot time and about 1 GB of peak
memory (633 to 662 MB against 1,607 MB). A container capped near 1 GB is enough for
it.

### Does the fallback need to be cheaper

Serial compilation was evaluated as a way to cap the fallback's peak, and dropped.
One compile per OS process, same guest and native ISA, 16 cores; "before" is after
loading the 39 MB of bytes and creating the engine, so it includes the BEAM and the
application code.

| Variant | Run | Wall ms | VmHWM before kB | VmHWM after kB |
|---|---|---|---|---|
| serial | 1 | 24,883 | 182,844 | 1,223,484 |
| serial | 2 | 25,244 | 180,688 | 1,224,104 |
| parallel | 1 | 4,421 | 185,360 | 1,294,368 |
| parallel | 2 | 4,447 | 191,872 | 1,297,392 |

Serial lowers the peak by about 70 MB (6 %, 1.22 against 1.30 GB) and takes about
5.7 times as long, so most of the compile's memory is single-threaded state that
the worker count barely changes. The fallback therefore keeps Wasmex's defaults. **When the
download is unavailable the compile still peaks at about 1.3 GB in the compile
benchmark and 1.6 GB of `VmHWM` in the container, so a container capped below about
2 GB can still be killed.**

### Portability of the precompiled file

- wasmtime 47 checks only the architecture and OS of the target triple when it loads
  a precompiled artifact, not the libc (gnu or musl), and accepts an artifact whose
  CPU feature flags are a subset of the host's. A baseline (x86-64-v2) `.cwasm`
  loaded into the native engine on this host, so the published file is not tied to
  the CPU generation that built it. The engine configuration is part of the asset
  name (`cfg<n>`), so a change to it publishes a new file instead of loading a stale
  one.
- aarch64 is built by the same workflow on a native arm64 runner and is **not
  verified**: nothing in this section ran on arm64. The first CI run is the check.
- A file that wasmtime rejects is deleted and the engine compiles locally, so an
  unexpected mismatch costs the old first boot and no more.

## Memory per instance (2026-10-13)

Where the extra memory under load comes from, measured to decide which memory
levers are worth applying. Production Alpine image of `origin/master`, engine
loaded from the cached `.cwasm` (second boot), fixture tracker on 198.51.100.7 as in
the 2026-10-12 section, driven through `bin/mydia rpc`. Nothing was committed or
baked in; no real tracker was contacted.

Method.

- **Pages.** `lantern` (the two-row test page, 639 B, 2 releases) and a 1 MB variant
  made by repeating the result row 3,400 times with invented release names
  (993,972 B, 3,400 releases). The large page is a worst case: real result pages are
  nearer 50 to 200 KB.
- **Readings.** `VmRSS` and `VmHWM` from `/proc/self/status` of the BEAM, and
  `Anonymous` from `/proc/self/smaps_rollup`, before and after each phase.
  `VmHWM` was reset before each phase (`/proc/self/clear_refs`, value 5), and `VmRSS`
  was also sampled every 4 ms during the phase to get the peak. Each phase was run
  twice, after a GC of the calling process and a 2.5 s pause. The BEAM's own
  baseline drifts by 30 to 70 MB between phases (263 to 333 MB anonymous), so only
  peak-minus-before differences are used, not absolute values.
- **Guest linear memory.** The patched Wasmex does not expose a memory size for a
  component store, so the guest's footprint is the anonymous-memory delta around the
  call. For the "while alive" readings, `Engine.run/4` was replicated in the script
  so memory could be read before the instance was killed.
- **Concurrency** is `Task.async_stream` over `Engine.call/3`, the real path.

| Case | Peak RSS over before (MB) | Anonymous while the instance is alive (MB) | Wall |
|---|---|---|---|
| Instantiate only, 1 instance | +0.1 | +0.05 | 8 to 11 ms |
| Instantiate only, 4 at once | +0.4 | +0.05 each | 0.3 s (held 300 ms) |
| One search, `lantern` | **+58** (58.4, 58.3) | **+49** to +51 | 32 ms |
| One search, 1 MB page | **+176 to +183** | +65 to +155 (noisy, includes the BEAM decoding 3,400 results) | 0.9 to 1.1 s |
| 4 concurrent, `lantern` | **+231** (230.9, 230.6) | n/a | 60 to 63 ms for all four |
| 4 concurrent, 1 MB page | **+614 to +693** | n/a | 6.4 to 6.6 s for all four |
| 8 concurrent, 1 MB page | +1,205 to +1,206 | n/a | 17.0 to 17.9 s for all eight |

Findings.

- **Instantiation is free.** A fresh instance costs 0.1 MB and about 10 ms. The
  `.cwasm` is mapped and its data segments are copy-on-write, and the .NET runtime
  does not start until the first export is called, so none of the guest's memory is
  touched at instantiation.
- **The cost is the first call.** The smallest possible search touches about 49 MB
  of anonymous memory in the guest (runtime start, the YAML definition, the parser)
  and raises the BEAM's RSS by about 58 MB, the same in every run. That is a floor
  per concurrent instance. Four concurrent small searches are 4 x 58 = 231 MB,
  which is the +229 MB seen in the 2026-10-12 section.
- **Large pages cost about 3 times more.** Peak memory is linear in the number of
  concurrent calls: 4 x 1 MB pages peak at +614 to +693 MB and 8 at +1.2 GB, about
  150 to 175 MB each.
- **Concurrency does not buy throughput on large pages.** One search takes 1.1 s,
  four at once take 6.5 s (4 x 1.1 would be 4.4 s serially) and eight take 17 s. For
  small pages four at once take 60 ms against 4 x 32 ms serially.
- **Memory returns only when the calling process lets go of the store.** After an
  instance is killed, its anonymous memory stayed resident until the owning process
  was garbage collected (in the replicated serial runs, +50 MB remained for the
  next phase until the script's process collected). When the caller was a
  short-lived `Task` the memory was back at baseline as soon as the task ended. A
  long-lived caller of `Engine.call/3` could therefore hold the last instance's
  memory between calls. Not investigated further.

Levers, tried where they could be.

| Lever | Test | Result |
|---|---|---|
| Guest GC environment | Passed `DOTNET_GCgen0size=0x100000`, `DOTNET_GCgen0MaxBudget=0x100000`, `DOTNET_GCConserveMemory=9`, `DOTNET_GCHeapHardLimit=0x4000000` through the WASI environment, 3 runs each | No change on `lantern` (49 MB in all 12 runs). On the 1 MB page 54 to 129 MB with every setting, within the run-to-run spread of the default (69, 86, 129 MB). Either the NativeAOT-LLVM runtime ignores them or they do not bind |
| Per-instance limit | Ran with 32, 48, 64, 80, 96, 128, 256 and 512 MB | 32 and 48 MB trap on the first call. 64 MB passes `lantern` but the 1 MB page **hangs until the call timeout** instead of failing. 80 MB and up pass the 1 MB page, using 71 to 83 MB at 80 MB against 69 to 129 MB at the default. The guest's GC adapts to the limit, but a smaller limit saves little for pages that fit in it; it mostly caps the worst case |
| Pooling allocator or copy-on-write memory init | Reasoned from instantiate-only and first-call numbers | Instantiation touches 0.1 MB, so there is nothing to save there. The 49 MB is written by the runtime after instantiation, which neither technique avoids |
| Compile store in `:persistent_term` | Dropped `store` from the persistent term on an idle engine and collected every process | Anonymous 292.2 to 286.9 MB, RSS 509.0 to 503.7 MB: **5.3 MB**. One sample. An earlier run in a busy VM showed 47 MB, which was the BEAM baseline settling, not the store |

Idle, engine ready (second boot, 30 s after start): `VmRSS` 501.6 MB, `VmHWM`
572.5 MB. By kind, from `smaps_rollup` and `status`: **anonymous 284.8 MB**,
shared memory 151.5 MB (the compiled code, in two `memfd:vmem` mappings of 64 to
65 MB each, one writable and one executable, so `Rss` counts the same pages twice;
`Pss_Shmem` is 76.5 MB), file-backed 65.3 MB (BEAM, NIF and shared libraries; the
Wasmex NIF alone is 15 MB). The anonymous part is the BEAM heap, the Wasmex engine
and the retained component state; the cached `.cwasm` is not file-backed here, it
sits in `memfd` shared memory.

What this means for the levers.

- **Concurrency cap: worth applying.** Per-instance memory is a hard 58 MB floor
  and rises to 150 to 180 MB on a 1 MB page, and peak memory is linear in the
  number of concurrent calls. A cap of 2 or 3 turns the 4-way peaks (+231 MB small,
  +614 to +693 MB large) into roughly half. It does not cost latency where it
  matters: on large pages concurrency was slower than serial, and on small pages
  the added wait is tens of milliseconds.
- **Guest GC variables: skip.** No setting moved the number.
- **Lowering the 512 MB limit: skip as a memory lever.** It saves nothing for
  normal pages, and too low a value (64 MB) makes a large page hang until the
  timeout instead of failing. If anything, a ceiling of 128 to 256 MB would only cap
  a pathological page; it is a safety choice, not a saving.
- **Pooling allocator and copy-on-write init: skip.** Instantiation is already
  0.1 MB.
- **Dropping the compile store: skip.** 5 MB of 500, not worth the change.

## Memory per instance, after the cap (2026-10-14)

The same measurement run on this branch, which caps concurrent guest instances at
`:cardigann_wasm_max_instances` (default 2; set it in application config) and runs
each guest call in a short-lived process so the instance's memory is released when
the call ends. Same method and fixture as the section above: Alpine image built
from `origin/master` (before) and from this branch (after), engine loaded from the
cached `.cwasm`, fixture tracker on 198.51.100.7, `lantern` and the 1 MB page of
invented releases, driven through `bin/mydia rpc` with `Engine.call/3`. Each case
ran twice, back to back, in separate containers for the two images; the table gives
both readings. Peak is the 4 ms `VmRSS` sampler minus `VmRSS` before the burst.
Latency is per search from the call to its return, so it includes any wait for a
slot.

| Burst | Peak over before (MB), before the cap | Peak over before (MB), with the cap | Wall (ms), before | Wall (ms), with the cap | p50 / p95 (ms), before | p50 / p95 (ms), with the cap |
|---|---|---|---|---|---|---|
| 4 x `lantern` | 229.9, 229.5 (226.6, 227.8) | **117.2, 117.2** | 89, 68 (57, 66) | 86, 73 | 88 / 89, 53 / 68 (55 / 57, 53 / 66) | 80 / 86, 70 / 73 |
| 8 x `lantern` | 452.9, 454.6 (454.2, 453.6) | **115.1, 117.3** | 104, 105 (95, 99) | 165, 147 | 92 / 103, 99 / 105 (83 / 95, 92 / 99) | 117 / 165, 107 / 146 |
| 4 x 1 MB page | 642.8, 617.1 (651.6, 563.6) | **447.3, 387.2** | 7,542, 7,235 (7,078, 6,659) | **4,327, 4,729** | 7,489 / 7,542, 7,157 / 7,235 (7,002 / 7,078, 6,641 / 6,659) | 4,274 / 4,327, 4,723 / 4,729 |
| 8 x 1 MB page | 993.7, 1,235.9 (1,138.2, 965.1) | **398.4, 362.0** | 18,606, 18,648 (16,476, 16,763) | **9,010, 8,459** | 18,566 / 18,604, 18,599 / 18,647 (16,413 / 16,476, 16,735 / 16,763) | 7,022 / 9,010, 6,712 / 8,459 |

Figures in brackets are a second, independent container run of the before image.

What changed.

- **Peak memory no longer grows with the number of callers.** Four and eight small
  searches peak at the same +115 to +117 MB, two instances' worth. A burst of large
  pages peaks at +360 to +450 MB, down from +565 to +1,240 MB, about half to a third.
- **The cap removes the contention on large pages.** Four 1 MB pages finish in 4.3
  to 4.7 s against 6.7 to 7.5 s, and eight in 8.5 to 9.0 s against 16.5 to 18.6 s.
  Median latency for the eight is 6.7 to 7.0 s against 16.4 to 18.6 s. The first
  measurement predicted this: on large pages concurrency was slower than serial.
- **Small pages pay the wait.** Four at once cost nothing visible (p95 73 to 86 ms
  against 57 to 89 ms). Eight at once take 147 to 165 ms against 95 to 105 ms,
  because six of them queue behind two instances; the added wait is tens of
  milliseconds.
- **A long-lived caller no longer holds the last instance.** One long-lived process
  (the rpc evaluator) ran a `lantern` search four times, waiting 6 s after each and
  reading anonymous memory around it, with no garbage collection of the caller. Before:
  +51.4, -2.0, +51.7, +0.9 MB (the last instance stays resident until the caller
  collects it, then the next call's instance adds 51 MB again). After: 0.0, 0.0, 0.0,
  0.0 MB.
- **Idle before and after a burst.** After the cap, RSS after all eight bursts and
  30 s of waiting was 570 MB against 558 MB before the first burst (anonymous 311
  against 299 MB). The before image's final readings (84 and 266 MB RSS, below its own
  idle value of 541 to 568 MB) mean the kernel reclaimed pages of the shared compiled
  code under the 1.5 to 1.6 GB peaks, so they do not say how much the instances held;
  the long-lived caller measurement above is the clean one.

Not measured: `mix mydia.cardigann_bench` (M4) was not re-run. It queries the 81
public definitions on live trackers, which this measurement does not do, and it
runs one definition at a time (`--concurrency 1`) for the latency comparison, where
the cap never queues. Its p95 is therefore expected to be unchanged: 248.6 ms
against a limit of 272.2 ms in the second run. What the cap changes is the case of
more than two searches in flight, covered by the table. The wait there is bounded by
the call timeout, which counts queue time.

## Caveats for users

Every remaining failure of this run, stated as a user would meet it. Nothing
here is softened; the same list is in the user docs.

1. **First boot downloads the compiled guest: about 6 s from container start to
   ready, with a 0.6 to 0.7 GB memory peak.** The engine is unavailable meanwhile
   (searches report why). When the compiled guest cannot be downloaded (no pin for
   the build, a network failure, a file wasmtime rejects), Mydia compiles it
   locally instead: 18 to 19 s on Alpine and a 1.5 to 1.6 GB peak, and a container
   capped below roughly 2 GB can be killed during it. Later boots load the cached
   `.cwasm` in under a second. The cache lives in the data directory and must
   survive restarts, or every restart repeats the first boot.
2. **Memory.** A warm engine adds about 64 to 67 MB over the default at rest. A
   running search adds about 58 MB on a tiny page and 175 to 185 MB on a 1 MB page
   (real result pages are nearer 50 to 200 KB), released when the search ends. At
   most `cardigann_wasm_max_instances` searches (default 2) run at once and the
   rest wait, so the peak is about 117 MB over idle for any number of small
   searches and 360 to 450 MB for a burst of 1 MB pages (before the cap: 230 MB for
   four small searches, 455 MB for eight, and up to 1.2 GB for eight large ones).
3. **Disk and download.** A 67.7 MB download from GitHub on first boot (38.9 MB
   for the component, 28.8 MB for its compressed precompiled form; 38.9 MB when
   the install has to compile) and 158 MB in the data directory.
4. **Latency.** About 60 ms more per search at the median (89.0 against 29.5
   ms) and 112 ms more at p95 (248.6 against 136.1 ms), engine overhead only,
   excluding the network. Definitions with a `requestDelay` wait as Prowlarr
   does (the Elixir engine ignores it), so their searches are slower: the unpaired
   p95 over every successful search is 1.3 s for the wasm engine. These are
   one-at-a-time figures. With more than two searches in flight the extra ones
   wait for a slot: eight small searches at once take 147 to 165 ms in total
   instead of 95 to 105 ms, while eight 1 MB pages take 8.5 to 9.0 s instead of
   16.5 to 18.6 s. The wait counts against the call timeout.
5. **Cloudflare and dead trackers.** 20 of the 81 public definitions end in an
   error on the wasm engine: 12 in HTTP 403 (1337x, btetree, damagnet, eztv,
   pornrips, sexypics, skidrowrepack, torrentbyte, torrentcore, torrentsome,
   uindex, xxxclub; a Cloudflare block where the guest logged one), 2 in HTTP 410
   on every mirror (52bt, magnetcat), and 6 in "No answer from the tracker"
   (acgrip, ebookbay, newstudio, postman, torrentby, torrentproject2, which also
   timed out once at 17.9 s). Prowlarr returned nothing on all 20 as well. The
   Elixir engine got results from torrentsome, where the wasm engine does not;
   FlareSolverr is the way through a Cloudflare block for either engine.
6. **Queries where the Elixir engine returns more.** pctorrent and plugintorrent
   (the generic query) and showrss-yml (the tv query) give the Elixir engine
   results and the wasm engine none; Prowlarr returned nothing on the first two
   and an error on the third. Treat them as differences in how the two engines read
   those trackers, not as established defects of either.
7. **Experimental toolchain.** The component is built with a pre-release .NET
   (`componentize-dotnet`, NativeAOT-LLVM, `wasm32-wasip2`) and run with a patched
   Wasmex. Expect the occasional runtime trap or an engine upgrade that changes
   behaviour.
8. **Error messages come from the C# engine.** A failed search reports Prowlarr's
   message (for example "Cloudflare protection detected", an HTTP status, "No
   answer from the tracker"), not the Elixir engine's wording.
9. **LAN trackers are refused** by the wasm host's SSRF gate; the Elixir engine
   connects to them. **Brotli** responses are not decoded (gzip is).
10. **Private trackers.** The gate corpus is public definitions only. Whether the
    wasm engine logs into private trackers was not measured.
11. **Build and platform.** Needs the patched Wasmex NIF (a source build); the
    `.cwasm` compiled locally is tied to the architecture, wasmtime version and CPU
    features of the host that wrote it. The published one targets a baseline CPU
    and loads on any CPU of its architecture (x86-64-v2 and up for x86_64; aarch64
    unverified). A wasmtime upgrade fetches the matching published file, or compiles
    once when there is none.
12. **Docker defaults.** The image's data directory is `/config` (next to the
    database) unless `MYDIA_DATA_DIR` is set. Both are volumes in the image
    contract; a container without a volume there repeats the download and the
    compile on every recreate.

## M6 maintenance

| Item | Result |
|---|---|
| M6 Elixir lines deleted at cutover vs C# shim lines added | The cutover (old Task 12) was cancelled: the Elixir engine stays. The first run counted up to **6,338** lines of `lib/` it would have deleted against **2,422** lines of C# the guest adds. Both engines now ship, so the Elixir code is not removed |

The harness report (`bench.md`) ends with the `EngineSupport` map; paste it into
`lib/mydia/indexers/cardigann/engine_support.ex` to refresh the "verified" badges.

## Methods (first run, still current for the harness)

- **Per-call overhead of the engine.** Without a network, a `capabilities` call
  takes a median 32.7 ms and a one-request `search` 31.0 ms on an idle machine:
  that is the cost of a fresh sandboxed instance per call.
- **RSS (first run).** A `mix run --no-start` script in the test environment on a
  copy of the bench database: start the app with `cardigann_wasm_eager: false`,
  read `VmRSS` from `/proc/self/status`, force the compile with
  `Engine.available?/0`, run 20 searches through `Wasm.Adapter.search/3` against a
  local fixture server. Three fresh processes per engine, median reported. Replaced
  by the container measurements above for the opt-in.
- **Cold start (first run).** The engine's own log line, "compiled in N ms", on
  glibc; the opt-in figures above are from Alpine.

## Memory spike

The first run's M5 RSS cause (undiagnosed at the time) is transient Cranelift
compile memory that glibc malloc keeps: the component compile peaks at about 1.1
GB and `malloc_trim(0)` afterwards returns about 880 MB of it.

| Variant (BEAM, `m5.exs`, 3 runs, 20 searches) | Delta MB, runs | Median |
| --- | --- | --- |
| `Component.new`, no trim (the first gating setup, re-measured) | 954.4, 951.0, 964.7 | 954.4 |
| `Component.new` + `malloc_trim(0)` | 180.0, 183.1, 180.4 | 180.4 |
| precompiled `.cwasm` via `Component::deserialize_file` + trim | 114.0, 112.0, 113.9 | 113.9 |

Standalone wasmtime 47.0.2, a fresh process loading the `.cwasm`: 21.9 MB RSS (4.8 MB
anonymous) after `deserialize_file` (7.8 ms), 72.4 MB after 20 search cycles, almost
all of it file-backed code pages. The `.cwasm` is 119 MB against the 75 MB (now 39
MB) `.wasm`. Compile at boot takes 3.8 s on glibc and 18 s on musl (standalone
binary, and the same in the Alpine image: 18.2 to 18.6 s); loading the `.cwasm`
takes 83 to 92 ms in a glibc BEAM and 576 to 714 ms in the Alpine image.

Wasmex 0.15.1 has no component precompile or deserialize, so the build carries
`patches/wasmex/component-precompile-and-deserialize.patch` (`@dep_patches` in
`mix.exs`; it needs a source build of Wasmex, `WASMEX_BUILD=1`). `Engine` loads the
cached `.cwasm` when present, otherwise compiles once, serializes it into the data
directory and loads that. The `.cwasm` is tied to the wasmtime version, the
architecture and the CPU features of the machine that built it, so it is built on
the host that runs it, never shipped. The Alpine BEAM was measured in the section
above: `malloc_trim` does not exist on musl, and the container figures stand
without it.

## Triage record

Every definition on which the wasm engine disagreed with Prowlarr in the
iteration runs, and what it was:

| Definitions | Symptom | Classification | Resolution |
|---|---|---|---|
| thepiratebay, anibt, onejav, freejavtorrent, pornxlab | 0 releases although the tracker answered 200 | host response mapping: a header the server repeats (`Vary` twice) made `HttpHeader.GetSingleValue` throw in the Cloudflare detection and the page was dropped | fixed in `shim/RequestMapping.cs` (`FromRaw` collapses repeated headers joined by ";", as `ToNameValueCollection` does); tests in `FixtureTests` and the Wasmex `engine_test` |
| bigfangroup, noname-club, pctorrent | 0 releases, no HTTP request made | shim/runtime: `windows-1251` and similar code pages unsupported until `CodePagesEncodingProvider` is registered (Prowlarr does it in `Bootstrap`) | fixed in `exports/Runner.cs` (static constructor); the failure only exists on wasm, so the regression test runs the real guest under Wasmex |
| torrent-pirat | `YamlDotNet ... multiline plain scalar` | the definition file starts with a byte order mark that upstream's `File.ReadAllText` drops | fixed in `shim/DefinitionService.cs`; tests in both suites |
| nyaasi, sukebeinyaasi | 0 releases for the keywordless query | host HTTP: the server sends a gzip body without being asked; the gate returns bodies undecoded | fixed in `HostHttp` (inflate gzip, drop `Content-Encoding` and `Content-Length`, capped); two Bypass tests |
| internetarchive | 0 releases on a 30 to 50 s answer | host HTTP: 30 s deadline against Prowlarr's 100 s | `HostHttp` default 100 s, adapter call default 120 s |
| megapeer, 0magnet, 52bt | Cloudflare 403 for the wasm engine and Prowlarr, 200 for a browser | host HTTP: upstream's `Prowlarr/<version> (linux)` User-Agent is refused. kickasstorrents-ws, magnetcat and torrentsome stayed blocked after this change | default User-Agent changed to the Chrome string the Elixir engine already sends (a definition's own header still wins); the one deliberate difference from upstream, recorded in `SUBSTITUTIONS.md` |
| image build | `mix mydia.cardigann_guest fetch` raised `DATABASE_PATH is missing` | task ran `app.config`, which evaluates `runtime.exs` | task now runs `loadpaths` and `loadconfig` |
| filemood (rss), limetorrents (rss), ehentai (rss) | differing release sets | tracker drift: a rate limit hit by the previous query, a live feed that moved between engines, a 4-release difference at Jaccard 0.96 | not a defect; agrees on rerun or inside the 0.95 bound |
| opensharing, torrent-pirat (generic) | slow tracker, 24 to 41 s | tracker slowness; agrees after the deadline change | none |

### Known wasm defects

- **Fixed after the first gating run: a 5xx response ended in
  `PlatformNotSupportedException`.** Upstream retries a server error twice through
  Polly with a real delay, and the guest has no event loop, so the blocking wait
  on a pending timer task threw. `shim/HttpIndexerBase.cs` (one line changed, see
  `SUBSTITUTIONS.md`) gives the retry pipeline a `TimeProvider` whose timers
  `Thread.Sleep` and fire at once. The retries now happen as upstream's do (three
  requests, the delays of `RateLimit`), a transient 503 followed by a good answer
  returns results, and a final 5xx is swallowed into an empty page with
  `request-failed` and the status set.
- **Fixed after the first gating run: no mirror failover.** The `search` result
  carries a `request-failed` flag (a transport error, an HTTP status of 400 or
  more, or a Cloudflare challenge on any request of the search), and the adapter
  repeats an empty, failed search against the next entry of `links:`, remembering
  the winner as `active_link` as the Elixir engine does. The second gating run
  above includes it: kickasstorrents-ws and megapeer return what the Elixir engine
  returns. A search whose every request failed now ends in an error naming the
  status or "No answer from the tracker" instead of an empty page.
- **LAN trackers are refused.** The wasm host goes through `Plugins.Net.Gate`,
  which rejects private addresses; the Elixir engine does not. Not exercised by
  the public corpus.
- **Brotli.** Prowlarr decompresses `gzip` and `br`; the host handles `gzip` only
  (the `brotli` library is not a dependency).

## Concerns about the numbers

- The trackers are live and the three engines run seconds apart, not at the same
  instant. Rotating the order spreads the effect but does not remove it.
- Prowlarr's own state degrades across runs (it disables indexers that fail), so
  both gating runs used a fresh data directory. 37 of 81 definitions return nothing
  on Prowlarr (Cloudflare, dead mirrors), which leaves M1 with 44 definitions.
- Two runs of the same gate differ in M2 (54 vs 55 first run, 55 vs 54 this run)
  and in the Elixir p95 (126.0 ms, 136.1 ms; 69 ms in an earlier non-gating run).
  Both M2 and M4 sit inside run-to-run noise.
- This run's component (75 MB, unstripped) is what the gate ran; the stripped
  component was checked by the test suites and by the container measurements, not
  by a second 25-minute gate run. Stripping removes debug sections only.
- M4 compares `wall - network` with the network time measured differently per
  engine (see the method below). The Elixir figure includes Req's own steps.
- The container measurements use a mounted local component with a temporary pin, not
  a download from the (unpublished) release. The fixture is a tiny page; real pages
  allocate more per search. Idle RSS was read 20 s (engine) and 75 s (default engine)
  after start, so the idle comparison favours the default engine slightly.

The bench needs live trackers, so its numbers move between runs and it cannot run
in CI. The parity oracle (`mix mydia.cardigann_parity`, described in
`lib/mydia/indexers/README.md`, "Cardigann parity oracle") is its offline
complement: it records the trackers' HTTP once, replays the same bytes through the
wasm and the built-in engine, and diffs the results field by field. A scrubbed seed
of those captures is committed, and `test/mydia/indexers/cardigann/parity_test.exs`
holds the built-in engine to the wasm engine on it through a ratchet of known
divergences that can only shrink. Use the bench for latency, memory and agreement
with a running Prowlarr; use the oracle to find and pin down why the built-in engine
reads a page differently.

Command: `PROWLARR_API_KEY=<key> ./dev mix mydia.cardigann_bench --concurrency 1 --prowlarr-url http://127.0.0.1:19696 --ref d34bddc56cfd6a55f75a9f69dcc2df9eb591662c --database <scratch>.db --out <dir>` at `10d19901f`, against `bench/cardigann/docker-compose.yml` with the port changed to 19696 and an empty data directory, torn down afterwards.

## Harness report (`mix mydia.cardigann_bench`), second run

| | |
|---|---|
| Mydia commit | `10d19901f2834a0c44a11b142ccba72d0b80da01` (worktree-cardigann-wasm-engine) |
| Rebased on origin/master | `272ef9447130ce54bf9f7dee751e8efe2df01edf` (origin/master tip `272ef9447130ce54bf9f7dee751e8efe2df01edf`) |
| Prowlarr tag (oracle and guest) | `v2.6.5.5623` |
| Prowlarr/Indexers ref | `d34bddc56cfd6a55f75a9f69dcc2df9eb591662c` |
| Date | 2026-10-12 |
| Definitions | 81 (162 queries) |
| Left out of the corpus | 498 (498 no_credentials) |
| Upstream files substituted by shims | 13 (`native/cardigann_guest/SUBSTITUTIONS.md`) |

Gate verdicts: M1 PASS, M2 PASS, M3 PASS, M4 PASS. M5 and M6 are measured by hand and recorded above.


### Metrics

| Metric | Elixir | Wasm | Gate | Verdict |
|---|---|---|---|---|
| M1 Fidelity (agree with Prowlarr, Jaccard >= 0.95 on every query) | 28/44 (63.6%) | 44/44 (100.0%) | wasm > Elixir | PASS |
| M2 Coverage (>= 1 release) | 54/81 | 55/81 | wasm >= Elixir | PASS |
| M3 Regressions (Elixir agrees, wasm does not) | | 0 | zero unexplained | PASS |
| M4 Engine overhead p50 / p95 (ms), paired searches, n=67 | 29.5 / 136.1 | 89.0 / 248.6 | wasm p95 <= max(2x Elixir, 50 ms); under 10 paired searches the verdict is insufficient sample | PASS (paired n=67) |

The M1 denominator is the 44 definitions on which Prowlarr returned results; 37 definitions where Prowlarr errored or returned nothing are excluded from it and listed under Engine health.

M1 and M3 above use the spec matching rule: same normalised title and (same info hash or sizes within 1%). A release whose size is unknown on one side only does not match.

Diagnostic, lenient rule (a size known on one side only counts as a size match; not gating):

| | Elixir | Wasm |
|---|---|---|
| M1 Fidelity, lenient | 28/44 (63.6%) | 44/44 (100.0%) |
| M3 Regressions, lenient | | 0  |

No definition's agreement changes between the strict and the lenient rule, so the gate does not hinge on missing sizes.


#### How M4 was measured

Overhead is `wall - network` per search, as nearest-rank percentiles. Wall time is the elapsed time of the adapter call in the task that made it. The gating figure is over **paired searches** only: (definition, query) pairs on definitions without a `requestDelay` where Prowlarr, Elixir and wasm all returned results, so both engines are timed on the same searches (n=67; under 10 the verdict is "insufficient sample"). For the gating run use `--concurrency 1`: with parallel definitions the searches contend for CPU and the database, which inflates overhead.

- **Wasm**: network is the sum of the host `http-request` import durations, recorded by the host (`HostHttp.exchange`, after the rate-limit throttle) and reported through the `[:mydia, :cardigann, :wasm, :call]` telemetry event, which fires in the calling task. Before timing starts the run waits for the component to compile and makes one capabilities call (a warm-up, discarded), so compilation is not in the numbers. Wall includes definition parsing, session reads and writes, and the guest's own work.
- **Elixir**: network is the time inside the `Req.Finch` adapter step, measured by `Bench.NetTimer` installed as the Req `:adapter` through `Req.default_options/1` for the run (Req 0.7.4 emits no telemetry). It is attributed to the calling task and its `$callers`. Req's own request and response steps (decompression, redirects, retry sleeps) and FlareSolverr round trips made outside Req are outside it and count as overhead.
- **Prowlarr**: only wall time is available. It is not part of M4.
- **`requestDelay`**: Prowlarr and the wasm engine honour a definition's `requestDelay` (the wasm host sleeps in its rate limiter, outside the timed network call). The Elixir engine does not honour it in practice: `CardigannSearchEngine.apply_rate_limit/1` sleeps for `request_delay`, but `CardigannParser` fills that field from the YAML key `requestdelay` (lower case) and every definition spells it `requestDelay`, so the field is always nil and Elixir never sleeps. That is a behavioural difference from Prowlarr (Elixir hits trackers faster than the definition allows). Paired M4 excludes delayed definitions because the delay would count as overhead for wasm only.
- Diagnostics (not gating). Unpaired, delay-free, every ok search: Elixir 29.4 / 116.2 ms (n=91), wasm 84.7 / 226.3 ms (n=100). Every ok search including delayed definitions: Elixir 27.0 / 98.7 ms (n=110), wasm 89.0 / 1311.6 ms (n=122).


### Engine health

| Engine | ok searches | ok but empty | empty with no HTTP request made | of which empty_with_credentials | errors by kind |
|---|---|---|---|---|---|
| prowlarr | 90 | 9 | 0 | 0 | prowlarr x2, indexer x70 |
| elixir | 110 | 10 | 0 | 0 | rate_limited x1, connection_failed x39, search_failed x12 |
| wasm | 122 | 21 | 0 | 0 | timeout x1, connection_failed x11, search_failed x28 |

"Empty with no HTTP request made" counts ok-but-empty searches whose measured network time is zero: the engine answered without contacting the tracker (Elixir and wasm only), which usually means it gave up before the request.

`empty_with_credentials` counts rows (a definition and query): a private or semi-private definition with credentials configured that returned no results. Prowlarr and the wasm engine swallow a failed login during search and return an empty list, so this is a possible silent login failure and not a genuine "no results". It is not counted as an error anywhere else.

Definitions Prowlarr errored or returned nothing on (excluded from M1): 0magnet, 1337x, 52bt, acgrip, anisource, btdirectory, btetree, damagnet, ebookbay, extratorrent-st, eztv, filemood, gamestorrents, kickasstorrents-to, kickasstorrents-ws, mactorrentsdownload, magnetcat, magnetdownload, megapeer, newstudio, nipponsei, pornrips, postman, sexypics, showrss-yml, skidrowrepack, tokyotosho, torrent9, torrentby, torrentbyte, torrentcore, torrentproject2, torrentsome, torrenttip, uindex, vsthouse, xxxclub


### Errors

| Definition | Query | Engine | Error |
|---|---|---|---|
| 0magnet | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 16mag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 0magnet | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 16mag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 1337x.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| 1337x | movie | wasm | {:search_failed, "HTTP 403"} |
| 1337x | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access 1337x.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| 1337x | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| 1337x | rss | wasm | {:search_failed, "HTTP 403"} |
| 52bt | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.52btbt.icu/ from indexer request", "isWarning" => f |
| 52bt | movie | elixir | {:search_failed, "HTTP 410"} |
| 52bt | movie | wasm | {:search_failed, "HTTP 410"} |
| 52bt | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.52btbt.icu/ from indexer request", "isWarning" => f |
| 52bt | rss | elixir | {:search_failed, "HTTP 410"} |
| 52bt | rss | wasm | {:search_failed, "HTTP 410"} |
| acgrip | tv | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Connection refused)", "errorMessage" => "Unable to connect to indexer. |
| acgrip | tv | elixir | {:connection_failed, "Connection failed: :econnrefused"} |
| acgrip | tv | wasm | {:connection_failed, "No answer from the tracker"} |
| acgrip | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Connection refused)", "errorMessage" => "Unable to connect to indexer. |
| acgrip | rss | elixir | {:connection_failed, "Connection failed: :econnrefused"} |
| acgrip | rss | wasm | {:connection_failed, "No answer from the tracker"} |
| anisource | tv | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Network unreachable)", "errorMessage" => "Unable to connect to indexer |
| anisource | tv | elixir | {:connection_failed, "Connection failed: :nxdomain"} |
| anisource | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "One or more errors occurred. (Network unreachable)", "errorMessage" => "Unable to connect to indexer |
| anisource | rss | elixir | {:connection_failed, "Connection failed: :nxdomain"} |
| btdirectory | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access btmulu.live, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btdirectory | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btdirectory | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access btmulu.live, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btdirectory | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btetree | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access bt.etree.org, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btetree | generic | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btetree | generic | wasm | {:search_failed, "HTTP 403"} |
| btetree | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access bt.etree.org, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| btetree | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| btetree | rss | wasm | {:search_failed, "HTTP 403"} |
| damagnet | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access damag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| damagnet | movie | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| damagnet | movie | wasm | {:search_failed, "HTTP 403"} |
| damagnet | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access damag.net, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| damagnet | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| damagnet | rss | wasm | {:search_failed, "HTTP 403"} |
| ebookbay | generic | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "The remote certificate was rejected by the provided RemoteCertificateValidationCallback.", "errorMes |
| ebookbay | generic | wasm | {:connection_failed, "No answer from the tracker"} |
| ebookbay | rss | prowlarr | {:indexer, {:http_status, 400, [%{"detailedDescription" => "The remote certificate was rejected by the provided RemoteCertificateValidationCallback.", "errorMes |
| ebookbay | rss | wasm | {:connection_failed, "No answer from the tracker"} |
| extratorrent-st | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access extratorrent.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| extratorrent-st | movie | elixir | {:search_failed, "Blocked page: 🚫 This Website is Blocked 🚫"} |
| extratorrent-st | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access extratorrent.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| extratorrent-st | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| eztv | tv | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access eztvx.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| eztv | tv | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| eztv | tv | wasm | {:search_failed, "HTTP 403"} |
| eztv | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access eztvx.to, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
| eztv | rss | elixir | {:connection_failed, "Cloudflare protection detected. Configure FlareSolverr to access this indexer."} |
| eztv | rss | wasm | {:search_failed, "HTTP 403"} |
| filemood | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer, check the log above the ValidationFailure for more details. HTTP request fail |
| filemood | movie | elixir | {:rate_limited, "Rate limit exceeded"} |
| filemood | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer, check the log above the ValidationFailure for more details. HTTP request fail |
| gamestorrents | generic | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.gamestorrents.app/juegos-pc/ from indexer request", |
| gamestorrents | rss | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to connect to indexer. Redirected to https://www.gamestorrents.app/juegos-pc/ from indexer request", |
| kickasstorrents-to | movie | prowlarr | {:indexer, {:http_status, 400, [%{"errorMessage" => "Unable to access kickass.torrentbay.st, blocked by CloudFlare Protection.", "isWarning" => false, ...}]}} |
(104 more in bench.json)


### Regressions

None.


### Largest wasm vs Prowlarr disagreements

None.


### Per-query results

Cell: releases, or the error kind. `!` marks empty_with_credentials. Jaccard is against Prowlarr.

| Definition | Type | Query | Prowlarr | Elixir | Wasm | Jaccard Elixir | Jaccard wasm |
|---|---|---|---|---|---|---|---|
| 0magnet | public | generic | err:indexer | 50 | 42 | n/a | n/a |
| 0magnet | public | rss | err:indexer | 50 | 50 | n/a | n/a |
| 1337x | public | movie | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| 1337x | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| 52bt | public | movie | err:indexer | err:search_failed | err:search_failed | n/a | n/a |
| 52bt | public | rss | err:indexer | err:search_failed | err:search_failed | n/a | n/a |
| acgrip | public | tv | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| acgrip | public | rss | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| anibt | public | tv | 100 | 100 | 100 | 1.00 | 1.00 |
| anibt | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| animetosho-xyz | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| animetosho-xyz | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| anisource | public | tv | err:indexer | err:connection_failed | 0 | n/a | n/a |
| anisource | public | rss | err:indexer | err:connection_failed | 24 | n/a | n/a |
| bangumi-moe | public | movie | 30 | 30 | 30 | 1.00 | 1.00 |
| bangumi-moe | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| bigfangroup | public | movie | 30 | 30 | 30 | 0.00 | 1.00 |
| bigfangroup | public | rss | 30 | 30 | 30 | 0.02 | 1.00 |
| blueroms | public | generic | 0 | 0 | 0 | n/a | n/a |
| blueroms | public | rss | 60 | 60 | 60 | 0.00 | 1.00 |
| btdirectory | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| btdirectory | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| btetree | public | generic | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| btetree | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| byrutor | public | generic | 0 | 0 | 0 | n/a | n/a |
| byrutor | public | rss | 12 | 12 | 12 | 0.00 | 1.00 |
| catorrent | public | generic | 20 | 20 | 20 | 1.00 | 1.00 |
| catorrent | public | rss | 20 | 20 | 20 | 1.00 | 1.00 |
| crackingpatching | public | generic | 9 | 15 | 9 | 0.60 | 1.00 |
| crackingpatching | public | rss | 31 | 31 | 31 | 1.00 | 1.00 |
| damagnet | public | movie | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| damagnet | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| dmhy | public | movie | 79 | 79 | 79 | 1.00 | 1.00 |
| dmhy | public | rss | 80 | 80 | 80 | 1.00 | 1.00 |
| ebookbay | public | generic | err:indexer | 0 | err:connection_failed | n/a | n/a |
| ebookbay | public | rss | err:indexer | 0 | err:connection_failed | n/a | n/a |
| ehentai | public | tv | 0 | 0 | 0 | n/a | n/a |
| ehentai | public | rss | 99 | 50 | 99 | 0.51 | 1.00 |
| extratorrent-st | public | movie | err:indexer | err:search_failed | 0 | n/a | n/a |
| extratorrent-st | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| eztv | public | tv | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| eztv | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| filemood | public | movie | err:indexer | err:rate_limited | 20 | n/a | n/a |
| filemood | public | rss | err:indexer | 20 | 20 | n/a | n/a |
| freejavtorrent | public | generic | 60 | 60 | 60 | 1.00 | 1.00 |
| freejavtorrent | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| gamestorrents | public | generic | err:indexer | 0 | 0 | n/a | n/a |
| gamestorrents | public | rss | err:indexer | 0 | 0 | n/a | n/a |
| internetarchive | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| internetarchive | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| kickasstorrents-to | public | movie | err:indexer | err:connection_failed | 0 | n/a | n/a |
| kickasstorrents-to | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| kickasstorrents-ws | public | movie | err:indexer | 60 | 60 | n/a | n/a |
| kickasstorrents-ws | public | rss | err:indexer | 50 | 50 | n/a | n/a |
| limetorrents | public | movie | 40 | 40 | 40 | 1.00 | 1.00 |
| limetorrents | public | rss | 150 | 150 | 150 | 1.00 | 1.00 |
| linuxtracker | public | generic | 25 | 25 | 25 | 1.00 | 1.00 |
| linuxtracker | public | rss | 25 | 25 | 25 | 1.00 | 1.00 |
| mactorrentsdownload | public | generic | 0 | 20 | 20 | n/a | n/a |
| mactorrentsdownload | public | rss | err:prowlarr | 20 | 20 | n/a | n/a |
| magnetcat | public | movie | err:indexer | err:search_failed | err:search_failed | n/a | n/a |
| magnetcat | public | rss | err:indexer | err:search_failed | err:search_failed | n/a | n/a |
| magnetdownload | public | movie | err:indexer | err:connection_failed | 10 | n/a | n/a |
| magnetdownload | public | rss | err:indexer | 10 | 10 | n/a | n/a |
| megapeer | public | movie | err:indexer | 50 | 50 | n/a | n/a |
| megapeer | public | rss | err:indexer | 50 | 50 | n/a | n/a |
| mikan | public | tv | 130 | 130 | 130 | 0.98 | 1.00 |
| mikan | public | rss | 99 | 99 | 99 | 1.00 | 1.00 |
| mixtapetorrent | public | generic | 1 | 9 | 1 | 0.11 | 1.00 |
| mixtapetorrent | public | rss | 10 | 9 | 10 | 0.90 | 1.00 |
| mypornclub | public | generic | 39 | 40 | 39 | 0.00 | 1.00 |
| mypornclub | public | rss | 40 | 40 | 40 | 0.00 | 1.00 |
| nekobt | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| nekobt | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| newstudio | public | tv | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| newstudio | public | rss | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| nipponsei | public | generic | err:indexer | 2 | 2 | n/a | n/a |
| nipponsei | public | rss | err:indexer | 30 | 30 | n/a | n/a |
| noname-club | public | movie | 50 | 50 | 50 | 0.72 | 1.00 |
| noname-club | public | rss | 50 | 50 | 50 | 0.79 | 1.00 |
| nyaasi | public | movie | 75 | 75 | 75 | 0.50 | 1.00 |
| nyaasi | public | rss | 150 | 75 | 150 | 0.50 | 1.00 |
| onejav | public | generic | 20 | 10 | 20 | 0.50 | 1.00 |
| onejav | public | rss | 20 | 10 | 20 | 0.50 | 1.00 |
| opensharing | public | generic | 24 | 24 | 24 | 1.00 | 1.00 |
| opensharing | public | rss | 24 | 24 | 24 | 1.00 | 1.00 |
| pandacd | public | generic | 10 | err:search_failed | 10 | n/a | 1.00 |
| pandacd | public | rss | 300 | err:search_failed | 300 | n/a | 1.00 |
| pctorrent | public | generic | 0 | 24 | 0 | n/a | n/a |
| pctorrent | public | rss | 24 | 24 | 24 | 1.00 | 1.00 |
| plugintorrent | public | generic | 0 | 30 | 0 | n/a | n/a |
| plugintorrent | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| pornotorrent | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| pornotorrent | public | rss | 100 | 100 | 100 | 1.00 | 1.00 |
| pornrips | public | generic | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| pornrips | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| pornxlab | public | generic | 60 | 60 | 60 | 1.00 | 1.00 |
| pornxlab | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| postman | public | movie | err:indexer | err:search_failed | err:connection_failed | n/a | n/a |
| postman | public | rss | err:indexer | err:search_failed | err:connection_failed | n/a | n/a |
| rintornet | public | generic | 10 | 10 | 10 | 1.00 | 1.00 |
| rintornet | public | rss | 10 | 10 | 10 | 1.00 | 1.00 |
| rutor | public | movie | 100 | 100 | 100 | 0.87 | 1.00 |
| rutor | public | rss | 128 | 128 | 128 | 0.86 | 1.00 |
| sexypics | public | generic | err:indexer | err:search_failed | err:search_failed | n/a | n/a |
| sexypics | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| shanaproject | public | tv | 50 | 50 | 50 | 0.85 | 1.00 |
| shanaproject | public | rss | 50 | 50 | 50 | 0.85 | 1.00 |
| showrss-yml | public | tv | err:indexer | 100 | 0 | n/a | n/a |
| showrss-yml | public | rss | err:indexer | 100 | 100 | n/a | n/a |
| skidrowrepack | public | generic | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| skidrowrepack | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| sosulki | public | generic | 0 | 0 | 0 | n/a | n/a |
| sosulki | public | rss | 34 | 34 | 34 | 1.00 | 1.00 |
| sukebeinyaasi | public | generic | 75 | 75 | 75 | 1.00 | 1.00 |
| sukebeinyaasi | public | rss | 75 | 75 | 75 | 1.00 | 1.00 |
| thepiratebay | public | movie | 100 | 100 | 100 | 1.00 | 1.00 |
| thepiratebay | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| tokyotosho | public | tv | 0 | 48 | 45 | n/a | n/a |
| tokyotosho | public | rss | err:prowlarr | 74 | 75 | n/a | n/a |
| torrent-pirat | public | generic | 25 | 25 | 25 | 1.00 | 1.00 |
| torrent-pirat | public | rss | 23 | 23 | 23 | 1.00 | 1.00 |
| torrent9 | public | movie | err:indexer | 20 | 20 | n/a | n/a |
| torrent9 | public | rss | err:indexer | 105 | 105 | n/a | n/a |
| torrentby | public | movie | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| torrentby | public | rss | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| torrentbyte | public | movie | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| torrentbyte | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| torrentcore | public | movie | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| torrentcore | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| torrentdownload | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| torrentdownload | public | rss | 66 | 70 | 66 | 0.94 | 1.00 |
| torrentdownloads | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| torrentdownloads | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| torrentkitty | public | movie | 20 | 20 | 20 | 1.00 | 1.00 |
| torrentkitty | public | rss | 20 | 20 | 20 | 1.00 | 1.00 |
| torrentproject2 | public | movie | err:indexer | err:connection_failed | err:timeout | n/a | n/a |
| torrentproject2 | public | rss | err:indexer | err:connection_failed | err:connection_failed | n/a | n/a |
| torrentsome | public | movie | err:indexer | 0 | err:search_failed | n/a | n/a |
| torrentsome | public | rss | err:indexer | 20 | err:search_failed | n/a | n/a |
| torrenttip | public | movie | err:indexer | err:search_failed | 0 | n/a | n/a |
| torrenttip | public | rss | err:indexer | err:search_failed | 0 | n/a | n/a |
| u3c3 | public | movie | 1 | 60 | 1 | 0.02 | 1.00 |
| u3c3 | public | rss | 60 | 60 | 60 | 1.00 | 1.00 |
| uindex | public | movie | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| uindex | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| vsthouse | public | generic | err:indexer | err:connection_failed | 0 | n/a | n/a |
| vsthouse | public | rss | err:indexer | err:connection_failed | 0 | n/a | n/a |
| vstorrent | public | generic | 19 | 30 | 19 | 0.63 | 1.00 |
| vstorrent | public | rss | 30 | 30 | 30 | 1.00 | 1.00 |
| vsttorrents | public | generic | 12 | 12 | 12 | 1.00 | 1.00 |
| vsttorrents | public | rss | 12 | 12 | 12 | 1.00 | 1.00 |
| world-torrent | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| world-torrent | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| xxxclub | public | generic | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| xxxclub | public | rss | err:indexer | err:connection_failed | err:search_failed | n/a | n/a |
| xxxtor | public | generic | 50 | 50 | 50 | 1.00 | 1.00 |
| xxxtor | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
| yts | public | movie | 0 | 0 | 0 | n/a | n/a |
| yts | public | rss | 105 | 105 | 105 | 1.00 | 1.00 |
| zamundalife | public | movie | 50 | 50 | 50 | 1.00 | 1.00 |
| zamundalife | public | rss | 50 | 50 | 50 | 1.00 | 1.00 |
