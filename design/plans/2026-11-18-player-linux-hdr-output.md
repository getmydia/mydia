# Linux HDR Output (Flatpak, Wayland) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the Flatpak on a Wayland session, play every file through mpv `vo=gpu-next` in a Wayland subsurface under the Flutter view, so HDR shows as HDR on a color-managed compositor and Dolby Vision gets its RPU applied, with the texture path as the fallback everywhere else.

**Architecture:** The Flatpak builds mpv 0.42 with a patch that lets libmpv render into a host-owned `wl_surface` on the host's own connection. A C plugin in the Linux runner (`mpv_surface/`) creates a subsurface below GTK's window surface, hands it to mpv, positions and sizes it from Dart, and serves spec 2's `mydia/mpv-surface` channel. The Dart side reuses spec 2's surface widget, binding, fallback and stats, with a Linux branch that replaces the `AppKitView` with a transparent box reporting its geometry.

**Tech Stack:** Flutter 3.47 Linux embedder (GTK3, FlView), media_kit 1.2.6, C (GLib, GDK Wayland, wayland-client), libmpv 0.42 + libplacebo (Vulkan, shaderc), Flatpak (GNOME 50 runtime), weston/sway headless for checks.

**Spec:** `design/specs/2026-11-17-player-linux-hdr-output-design.md`. It builds on spec 2, `design/specs/2026-11-17-player-apple-hdr-output-design.md` (merged in #1444), and its plan `design/plans/2026-11-17-player-apple-hdr-output.md`.

## Global Constraints

- Flatpak on a Wayland session only. X11 sessions (including the Flatpak's `--socket=fallback-x11`), the AppImage and the tarball keep media_kit's `Video` and spec 1's tonemapping, with no message.
- mpv `v0.42.0`, commit `b0841e8c4d156b8403dc1876c4cbd9011eb583f3`, plus `player/flatpak/patches/mpv-wayland-embed.patch`. No fork, no extra CI job.
- Embed struct: `struct mpv_wayland_embed { uint32_t magic; struct wl_display *display; struct wl_surface *surface; }`, magic `0x6d707665`. `wid` is the struct's address as a decimal integer string.
- Attach order on Linux: `wid`, `vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=waylandvk`, `target-colorspace-hint=yes`, `hwdec=auto-safe`, spec 2's quality options (`scale=lanczos`, `dscale=hermite`, `dither=fruit`, `correct-downscaling=yes`, `linear-downscaling=yes`, `sigmoid-upscaling=yes`, `hdr-compute-peak=auto`), `wayland-surface-size=WxH` (buffer pixels), then `vid=auto` last.
- Subsurface: `place_below(parent)`, `set_desync`, empty input region. Position in the window surface's logical coordinates (FlView offset in the toplevel, CSD shadow included); size is the rect times the device pixel ratio, rounded, minimum 1.
- Threads: every mpv call on one serial worker thread, in arrival order, replying to Dart asynchronously. Every Wayland and GTK call on the GTK main thread.
- Timeouts: output start check 2 s after `vid=auto`; detach waits up to 3 s for `current-vo` to read empty. A detach that times out never destroys the surface or frees the embed struct (mpv may still use both).
- Start failures follow spec 2's rules, which the spec's "as on macOS" points to: only `failed` (mpv deselected the video track) records a failure for the app version; `timedOut` falls back for that playback only.
- Teardown order: subsurface before its surface. The host's `wl_display` is flushed, never disconnected.
- Window frame: `window.mydia-frame` stays black; while any surface is attached the window also has the `mydia-video` style class, whose background is `transparent`.
- `LC_NUMERIC=C` before any `mpv_create`.
- Escape hatch: one setting for macOS and Linux, storage key `debug.legacyVideoOutput`, migrating `legacy_mac_video_output`. Failure record key `mac_surface_failed_version` is reused unchanged on Linux.
- Claims on the Linux surface path: `hdr10+`, `hdr10`, `hlg`, and `dolby_vision` only when `linuxDolbyVisionVerified` is true, which needs Task 3's profile 5 pass.
- Stats HDR row on Linux: `HDR output, PQ, peak N nits` (or HLG) when the target gamma is PQ or HLG; `tonemapped by player (libplacebo)` otherwise; `RPU applied` when `video-params/colormatrix` is `dolbyvision`.
- No real titles in fixtures, tests or code. Fixtures come from `scripts/generate-hdr-fixtures.sh` and are never committed. The profile 5 file in Task 3 is the user's and stays outside the repo.
- No em dashes in docs or comments. Commits use the author email `arsfeld@gmail.com`. Commit with plain `git commit -F <msgfile>` from the worktree (the worktree guard refuses `devenv shell -- git`).
- Raider (this machine) is the hardware for every gate: Pantheon (Gala 8.6.2 on Mutter 48.7, Wayland), RX 6650 XT, GBT M34WQ in HDR mode.

## Review Focus

1. **Resizing, maximizing or fullscreening the window while a video plays.** The video follows the box in the same frame or the next, never sits at the old size or offset. Owned by Task 9 (`geometryFollowsResizeOnce`) and Task 5 (`set_geometry_queues_parent_redraw`); seen for real in Task 12's checklist.
2. **A HiDPI screen (scale 2) or fractional scaling (1.25).** Position stays in logical pixels, size goes to buffer pixels, and rounding never yields a 0 dimension. Owned by Task 4 (`size_string_scales_and_rounds`, `size_string_never_zero`).
3. **Quitting the app or closing the window during playback.** GTK unrealizes the window while mpv still renders: every attachment detaches first, no protocol error kills the app, and quitting takes at most 3 s more than it does now. Owned by Task 4 (`detach_all_runs_every_attachment`) and Task 6 (the smoke sequence's "destroy the window while attached" step).
4. **mpv stuck during detach** (the core stops answering): after 3 s the plugin replies, Dart disposes the player, and the subsurface and embed struct are leaked rather than destroyed under mpv. Owned by Task 4 (`detach_timeout_leaks_surface_and_embed`).
5. **The compositor reports `max-luma` as PQ's ceiling.** The spike read `video-target-params/max-luma=10000` on raider, where the screen's reference white is 406 nits. The row must not print "peak 10000 nits" as if it were the screen's: at 10000 or above it drops the peak. Owned by Task 11 (`peakAtPqCeilingIsOmitted`).

---

### Task 1: Gate 1, libmpv 0.42 with the patch inside the Flatpak

No product code. This decides whether the sandbox can run gpu-next at all.

**Files:**
- Modify: `player/flatpak/dev.mydia.player.yml` (mpv module)
- Already committed: `player/flatpak/patches/mpv-wayland-embed.patch` (the spike's patch), `player/flatpak/mpv-tools/spike-harness.c` (the spike's harness)
- Create: `player/flatpak/mpv-tools/mydia_mpv_check.c` (from the spike harness, `git mv`), `player/flatpak/mpv-tools/meson.build`
- Create: `player/flatpak/hdr-probe.sh`

**Interfaces:**
- Produces: `/app/bin/mydia-mpv-check` in the Flatpak, mode `probe <clip>`: plays the clip in mpv's own Wayland window (no `wid`) with the Linux attach options, waits 4 s, prints one line `probe: vo=<current-vo> hwdec=<hwdec-current> gamma=<video-target-params/gamma> max-luma=<...> colormatrix=<video-params/colormatrix> surface-size-option=<yes|no>` and exits 0. `surface-size-option` reads `option-info/wayland-surface-size/name`. Task 6 adds the `embed` mode.
- Produces: `player/flatpak/hdr-probe.sh <clip> [--expect-dv]` runs the probe through `flatpak run --command=mydia-mpv-check dev.mydia.player//<branch>` and asserts the values below.

- [ ] **Step 1: Move the manifest's `mpv` module** to tag `v0.42.0`, commit `b0841e8c4d156b8403dc1876c4cbd9011eb583f3`, and add `- type: patch` / `path: patches/mpv-wayland-embed.patch`. Add a module `mydia-mpv-tools` (meson, after `mpv`) that builds `mydia_mpv_check.c` against `mpv`, `gtk+-3.0` and `wayland-client` and installs it to `/app/bin`.
- [ ] **Step 2: Turn the spike harness into `mydia_mpv_check.c`** with the `probe` mode only: no screenshots, no D-Bus, `setlocale(LC_NUMERIC, "C")` before `mpv_create`.
- [ ] **Step 3: Build and install.** `./dev player flatpak build && ./dev player flatpak install`. Expected: the build log shows the patch applied to mpv, and the export succeeds.
- [ ] **Step 4: Generate fixtures and probe.** `scripts/generate-hdr-fixtures.sh /tmp/hdrfx-linux`, then `player/flatpak/hdr-probe.sh /tmp/hdrfx-linux/levels_hdr10.mp4` on raider's Gala session. Expected: `vo=gpu-next hwdec=vaapi gamma=pq surface-size-option=yes`. Then `levels_dv81.mp4 --expect-dv`: `colormatrix=dolbyvision`.
- [ ] **Step 5: If a check fails, fix the manifest.** The likely gaps: no shaderc or glslang for libplacebo (add a `shaderc` module before `libplacebo`), no Vulkan ICD (check `flatpak run --command=vulkaninfo`), no VAAPI driver. Re-run Step 4 until it passes. If gpu-next cannot open a Vulkan device in the sandbox at all, stop and bring the log to the user: the spec's premise fails.
- [ ] **Step 6: Record the result** in this plan's "Gate log" section (end of file): versions, the probe lines, the manifest fixes. Delete `spike-harness.c` in this commit.
- [ ] **Step 7: Commit.** `build(player): Flatpak libmpv 0.42 with the Wayland embed patch`.

### Task 2: Gate 2, FlView composites over a subsurface

No product code, nothing committed but the gate log. Decides whether a transparent FlView shows a subsurface placed below it, and whether the nixpkgs-Flutter realize hang applies to the Flatpak's Flutter.

- [ ] **Step 1: Build a throwaway app in the scratchpad.** `flutter create` with the Flutter version `player/flatpak/build.sh` downloads, built inside `org.gnome.Sdk//50` exactly the way `build.sh` builds the player. Its Dart draws a transparent page with an opaque red 200x100 box at (40, 40). Its runner copies `my_application.cc`'s FlView setup (transparent background, `mydia-frame` CSS) and, 1 s after the first frame, creates a subsurface below the window surface the way the spike harness does, filled with a magenta `wl_shm` buffer covering the whole view, and adds the `mydia-video` class.
- [ ] **Step 2: Run it under a headless compositor with screencopy.** `nix shell nixpkgs#sway nixpkgs#grim`, `WLR_BACKENDS=headless sway` with a 1280x720 output, the app run via `flatpak run --socket=wayland --device=dri` against that `WAYLAND_DISPLAY`, then `grim`. Expected pixels: the red box is red, a point outside it inside the view is magenta, and the app reached its first frame (no realize hang).
- [ ] **Step 3: Repeat on raider's Gala session** through the screenshot portal, once its permission is granted for the app (ask the user to click through the dialog). Same expected pixels. If the portal still never answers, record that and rely on Step 2.
- [ ] **Step 4: Record the result** in the gate log, including `WAYLAND_DEBUG=1` evidence that GTK set no opaque region on the window while `mydia-video` was on. If the subsurface does not show through, stop and bring the evidence to the user before any product task.

### Task 3: Gate 3, Dolby Vision profile 5 on raider

No product code. Decides `linuxDolbyVisionVerified`.

- [ ] **Step 1: Ask the user for a real profile 5 file** from their library (it stays outside the repo and its title stays out of every log committed). Confirm with `ffprobe` that the stream reports DOVI configuration profile 5.
- [ ] **Step 2: Probe it.** `player/flatpak/hdr-probe.sh <file> --expect-dv`. Expected: `colormatrix=dolbyvision`, `gamma=pq`.
- [ ] **Step 3: Visual check by the user** on raider's HDR screen, with the probe's window: skin tones natural, no green or purple cast (the profile 5 failure), highlights brighter than the desktop's white. Ask the user for the verdict.
- [ ] **Step 4: Record the verdict** in the gate log. Task 11 sets `linuxDolbyVisionVerified` from it.

### Task 4: Native core and its GLib tests

**Files:**
- Create: `player/linux/runner/mpv_surface/mpv_api.h`, `mpv_api_live.c`
- Create: `player/linux/runner/mpv_surface/mpv_surface_core.h`, `mpv_surface_core.c`
- Create: `player/linux/runner/mpv_surface/wayland_ops.h`
- Create: `player/linux/runner/mpv_surface/mpv_surface_host.h`, `mpv_surface_host.c`
- Create: `player/linux/runner/mpv_surface/CMakeLists.txt` (standalone project for the tests), `test/mpv_surface_test.c`, `run-tests.sh`
- Modify: `.github/workflows/ci-player.yml` (Linux leg of `build`, the one producing `mydia-player-linux-bundle`: a step running `run-tests.sh` after "Install Linux dependencies")

**Interfaces:**
- Produces `mpv_api.h`:
  ```c
  typedef struct {
    int (*set_property)(void* mpv, const char* name, const char* value); /* mpv error code, 0 ok */
    char* (*get_property)(void* mpv, const char* name);                  /* NULL when unset */
    void (*free)(void* data);
    void* (*create)(void);
    void (*destroy)(void* mpv);
  } MpvApi;
  const MpvApi* mpv_api_live(void); /* dlopen("libmpv.so.2", RTLD_NOW) + dlsym; NULL if absent */
  typedef struct { int64_t (*now_us)(void); void (*sleep_us)(int64_t us); } MpvSurfaceClock;
  ```
- Produces `mpv_surface_core.h` (worker thread only):
  - `int mpv_surface_core_attach(const MpvApi*, void* mpv, const void* embed, const char* const* options, const char* size)`: `options` is a NULL-terminated name, value, name, value list. Writes `wid`, the options, `wayland-surface-size=size`, `vid=auto`. Returns 0, or the error of a failed `wid` or `vid` write (other failures are logged and skipped, as on macOS).
  - `typedef enum { MPV_SURFACE_STARTED, MPV_SURFACE_FAILED, MPV_SURFACE_TIMED_OUT } MpvSurfaceStart;` and `MpvSurfaceStart mpv_surface_core_await_output(const MpvApi*, void* mpv, const MpvSurfaceClock*, int64_t timeout_us)`, the macOS rules: `current-vo` set or no video track listed is started; `vid` reading `no` or no selected video track is failed; neither by the timeout, or no tracks listed, is timed out. Tracks through `track-list/count`, `track-list/N/type`, `track-list/N/selected`.
  - `bool mpv_surface_core_detach(const MpvApi*, void* mpv, const MpvSurfaceClock*, int64_t timeout_us)`: `vid=no`, then polls `current-vo` every 20 ms; true once it reads empty.
  - `char* mpv_surface_core_size_string(double width, double height, double scale)`: `"%dx%d"` of `lround(dim * scale)`, each at least 1. Caller `g_free`s.
  - `bool mpv_surface_core_option_supported(const MpvApi*)`: a temporary handle from `create`, `option-info/wayland-surface-size/name` non-NULL, then `destroy`.
- Produces `wayland_ops.h` (main thread only):
  ```c
  typedef struct MpvSurfaceWindow MpvSurfaceWindow; /* opaque: the live ops' GTK window */
  typedef struct {
    bool (*is_wayland)(MpvSurfaceWindow*);
    bool (*has_subcompositor)(MpvSurfaceWindow*);
    void* (*create_subsurface)(MpvSurfaceWindow*, void** out_wl_surface, void** out_wl_display); /* returns the wl_subsurface */
    void (*set_position)(MpvSurfaceWindow*, void* subsurface, int x, int y);   /* FlView offset added by the live ops */
    void (*destroy)(MpvSurfaceWindow*, void* subsurface, void* wl_surface);    /* subsurface first */
    void (*set_video_class)(MpvSurfaceWindow*, bool on);
    void (*queue_parent_redraw)(MpvSurfaceWindow*);
  } WaylandOps;
  ```
- Produces `mpv_surface_host.h`: `MpvSurfaceHost* mpv_surface_host_new(const MpvApi*, const WaylandOps*, MpvSurfaceWindow*, const MpvSurfaceClock*)` and, keyed by the mpv handle (`gint64`):
  - `bool mpv_surface_host_available(MpvSurfaceHost*)` (Wayland, subcompositor, option supported; computed once and cached);
  - `const void* mpv_surface_host_prepare(MpvSurfaceHost*, gint64 handle, double x, double y)` (main: creates the subsurface, positions it, sets the video class, allocates the embed struct with the magic; returns it, NULL on failure);
  - `void mpv_surface_host_set_position(MpvSurfaceHost*, gint64 handle, double x, double y)` (main: position plus parent redraw);
  - `void mpv_surface_host_finish_detach(MpvSurfaceHost*, gint64 handle, bool output_gone)` (main: when gone, destroys the subsurface then the surface and frees the embed; when not, leaks both and logs; clears the video class once no attachment is left);
  - `void mpv_surface_host_detach_all(MpvSurfaceHost*)` (main, synchronous: for each attachment, `mpv_surface_core_detach` with 3 s, then `finish_detach`).
  The `MpvSurfaceWindow` live implementation lives in Task 5; the tests pass a fake.

- [ ] **Step 1: Write the failing tests** in `test/mpv_surface_test.c` with a recording fake `MpvApi` (one shared event log of `set name=value`, `get name`), a fake `WaylandOps` writing to the same log, and a fake clock that advances on `sleep_us`:
  - `attach_writes_wid_and_options_before_vid_auto`: the log's sets are exactly `wid=<decimal embed address>`, the given options in order, `wayland-surface-size=1692x1378`, `vid=auto`.
  - `attach_stops_when_wid_is_refused`: `wid` returns -5; no further set, the call returns -5.
  - `embed_struct_has_magic_and_host_pointers`: `prepare` returns a struct with magic `0x6d707665` and the fake's display and surface.
  - `await_output_started_failed_timed_out`: three cases with the macOS rules; timed out after exactly 2 s of fake time.
  - `detach_waits_for_current_vo_before_destroy`: `current-vo` reads `gpu-next` twice then empty; the log shows `vid=no`, the polls, then `destroy subsurface` before `destroy surface`.
  - `detach_timeout_leaks_surface_and_embed`: `current-vo` never empties; after 3 s `finish_detach(false)` logs no destroy, and the embed struct stays readable (magic intact).
  - `reattach_creates_fresh_surface`: attach, detach, attach on the same handle creates a second subsurface.
  - `detach_all_runs_every_attachment`: two handles attached; `detach_all` sets `vid=no` on both, destroys both, clears the video class once.
  - `video_class_follows_attachments`: on at the first prepare, off after the last finish.
  - `size_string_scales_and_rounds`: `(846, 689, 2.0)` is `1692x1378`; `(1280.4, 720.6, 1.25)` is `1601x901`.
  - `size_string_never_zero`: `(0.2, 0, 1.0)` is `1x1`.
  - `unavailable_on_x11`, `unavailable_without_subcompositor`, `unavailable_when_option_missing` (the fake's `get option-info/...` returns NULL), and `available_is_computed_once`.
- [ ] **Step 2: Run them to see them fail.** `nix shell nixpkgs#cmake nixpkgs#pkg-config nixpkgs#glib nixpkgs#gcc --command player/linux/runner/mpv_surface/run-tests.sh`. `run-tests.sh` configures `player/linux/runner/mpv_surface` into a temp build dir, builds, and runs `ctest --output-on-failure`. Expected: link errors for the missing functions.
- [ ] **Step 3: Implement** `mpv_api_live.c`, `mpv_surface_core.c` and `mpv_surface_host.c` to the interfaces above. The CMake project builds them as a static library `mpv_surface_core` (only `glib-2.0` and `dl`), and the test when `PROJECT_IS_TOP_LEVEL`. The live MpvApi has no test; it is exercised by Task 6.
- [ ] **Step 4: Run the tests.** Same command. Expected: all pass.
- [ ] **Step 5: Add the CI step**, then commit. `feat(player): Linux mpv surface core with GLib tests`.

### Task 5: The runner plugin

**Files:**
- Create: `player/linux/runner/mpv_surface/wayland_ops_live.c` (the `MpvSurfaceWindow` and `WaylandOps` for a GTK window)
- Create: `player/linux/runner/mpv_surface/mpv_surface_plugin.h`, `mpv_surface_plugin.c`
- Modify: `player/linux/runner/CMakeLists.txt` (`enable_language(C)`, the sources from Tasks 4 and 5, `pkg_check_modules(WAYLAND REQUIRED IMPORTED_TARGET wayland-client)`, link `dl`)
- Modify: `player/linux/runner/my_application.cc` (register the plugin; the `mydia-video` CSS rule)
- Test: `player/linux/runner/mpv_surface/test/mpv_surface_test.c` (one more test)

**Interfaces:**
- Consumes: Task 4's host and core.
- Produces: `void mpv_surface_plugin_register(FlBinaryMessenger* messenger, GtkWindow* window, FlView* view)`. Channel `mydia/mpv-surface`, standard codec, methods:
  - `available` → bool;
  - `attach {handle, options: [[name, value]...], geometry: {x, y, width, height, scale}}` → null, or error `attach-failed`;
  - `awaitVideoOutput {handle}` → `{started: bool, failed: bool}`;
  - `setOption {handle, name, value}` → null, or error `set-failed`;
  - `setGeometry {handle, x, y, width, height, scale}` → null;
  - `detach {handle}` → null, after the wait and the main-thread teardown.
  No event channel on Linux.

- [ ] **Step 1: Write the failing test** `set_geometry_queues_parent_redraw`: `mpv_surface_host_set_position` logs `set_position` then `queue_parent_redraw`, in that order.
- [ ] **Step 2: Run it to see it fail** (`run-tests.sh`).
- [ ] **Step 3: Implement `wayland_ops_live.c`**: globals bound through a display wrapper on its own `wl_event_queue` (the spike's `start()`), the subsurface with `place_below`, `set_desync` and an empty input region, the position offset from `gtk_widget_translate_coordinates(view, window, 0, 0, ...)`, `gtk_widget_queue_draw(window)` for the redraw, and the `mydia-video` class on the window's style context.
- [ ] **Step 4: Implement `mpv_surface_plugin.c`.** A `GThreadPool` with one thread and `exclusive = TRUE` is the serial worker. `attach` runs `prepare` on the main thread, then on the worker `mpv_surface_core_attach` with the size from the geometry; a failed attach is answered `attach-failed` and the attachment stays for `detach`. `setGeometry` sets the position on the main thread and queues `wayland-surface-size` on the worker. `detach` runs `mpv_surface_core_detach` (3 s) on the worker, then `finish_detach` on the main thread through `g_main_context_invoke`, then replies. The window's `unrealize` signal calls `mpv_surface_host_detach_all` after draining the worker (`g_thread_pool_free(pool, FALSE, TRUE)` and a new pool).
- [ ] **Step 5: Register it in `my_application.cc`** after the window frame channel, and add `"window.mydia-frame.mydia-video { background-color: transparent; }\n"` to `kFrameCss` after the black rule.
- [ ] **Step 6: Build the Linux runner.** `cd player && flutter build linux --debug` in the devenv shell. Expected: it builds with no warnings from the new C files (`-Wall -Werror` applies through `apply_standard_settings`). Run Task 4's tests again: all pass.
- [ ] **Step 7: Commit.** `feat(player): Linux runner plugin hosting mpv in a Wayland subsurface`.

### Task 6: The Flatpak embed smoke check

**Files:**
- Modify: `player/flatpak/mpv-tools/mydia_mpv_check.c` (add the `embed` mode)
- Create: `player/flatpak/embed-smoke.sh`
- Modify: `player/flatpak/smoke-test.sh` (call it), `.github/workflows/ci-player.yml` (`flatpak-build` job: install `weston`), `dev` (no change if `smoke` still calls `smoke-test.sh`; otherwise resolve `weston` through `nix shell nixpkgs#weston` the way it resolves `xvfb-run`)

**Interfaces:**
- Consumes: Task 1's tool and patched libmpv.
- Produces: `mydia-mpv-check embed <clip>`: the spike harness's GTK window and subsurface, then attach (all Global Constraints options), wait for `current-vo`, resize (`wayland-surface-size=800x450` plus a new position), `vid=no` and wait for empty `current-vo`, `vid=auto` and wait, destroy the GTK window while attached (Review Focus 3), `mpv_terminate_destroy`, then 1 s of GTK frames. After every step it asserts `wl_display_get_error(display) == 0`. Exit 0 only when every step passed; prints `embed: PASS` or `embed: FAIL <step> <reason>`.

- [ ] **Step 1: Add the `embed` mode** from the spike harness's `tick()` sequence plus the window-destroy step, with no screenshots.
- [ ] **Step 2: Write `embed-smoke.sh <branch>`**: starts `weston --backend=headless --socket=mydia-smoke-$$ --width=1280 --height=720`, runs `WAYLAND_DISPLAY=mydia-smoke-$$ flatpak run --command=mydia-mpv-check --socket=wayland dev.mydia.player//<branch> embed av://lavfi:testsrc2=size=1280x720:rate=24`, kills weston, exits with the tool's status. The clip is mpv's own lavfi source, so CI needs no fixture or ffmpeg. It first asserts the bundled libmpv accepts `wayland-surface-size` (the `probe` mode's `surface-size-option=yes`).
- [ ] **Step 3: Run it on raider.** Expected: `embed: PASS`. gpu-next on weston headless uses the runtime's lavapipe; if lavapipe cannot start gpu-next there, the tool's `vid=auto` step fails with `current-vo` empty: then run it against `WLR_BACKENDS=headless sway` instead, and record which compositor the check uses in the gate log.
- [ ] **Step 4: Break it on purpose.** Temporarily revert the patch's teardown hunk (subsurfaces destroyed first), rebuild, run: expected `embed: FAIL` at the destroy step. Restore the hunk.
- [ ] **Step 5: Wire it** into `smoke-test.sh` after the Xvfb launch check, and install `weston` in the CI job.
- [ ] **Step 6: Commit.** `test(player): Flatpak smoke runs the Wayland embed sequence`.

### Task 7: The channel on Linux

**Files:**
- Modify: `player/lib/core/player/mpv_surface_channel.dart`, `player/lib/core/player/surface_attach_options.dart`
- Test: `player/test/core/player/mpv_surface_channel_test.dart`, `player/test/core/player/surface_attach_options_test.dart`; update the fakes in `player/test/presentation/screens/player/player_screen_mac_surface_test.dart` and `player/test/presentation/widgets/video_surface/mpv_surface_binding_test.dart` for the new members

**Interfaces:**
- Produces in `mpv_surface_channel.dart`:
  - `typedef SurfaceGeometry = ({Rect rect, double scale});`
  - `MpvSurface.available()` → `Future<bool>`;
  - `MpvSurface.attach(int handle, {int? viewId, SurfaceGeometry? geometry})` (macOS passes `viewId`, Linux `geometry`);
  - `MpvSurface.setGeometry(int handle, SurfaceGeometry geometry)`;
  - `MpvSurfaceChannel.display` is `const Stream.empty()` on Linux.
  Argument maps as in Task 5's Interfaces.
- Produces in `surface_attach_options.dart`: `List<(String, String)> surfaceAttachOptions(TargetPlatform platform)`: macOS unchanged; Linux `waylandvk` and `hwdec=auto-safe` in place of `macvk` and `videotoolbox`, same quality options.

- [ ] **Step 1: Write the failing tests:** `surface_attach_options_test.dart` asserts the full Linux list in order (Global Constraints) and that macOS's list is unchanged; `mpv_surface_channel_test.dart` asserts, through a mock method channel handler, that a Linux `attach` sends `geometry: {x, y, width, height, scale}` and no `viewId`, that `setGeometry` sends the five numbers, that `available` maps a `true` reply, and that `display` on Linux emits nothing and never calls the event channel.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement**, with `MpvSurfaceChannel` taking `TargetPlatform? platform` (default `defaultTargetPlatform`) for the tests.
- [ ] **Step 4: Run** the two files and the two updated fake files. Expected: pass.
- [ ] **Step 5: Commit.** `feat(player): mpv surface channel speaks geometry for Linux`.

### Task 8: Output path, hatch and availability in Dart

**Files:**
- Rename: `player/lib/core/player/mac_video_output.dart` → `video_output_path.dart`; `player/lib/core/settings/legacy_mac_video_output_setting.dart` → `legacy_video_output_setting.dart` (regenerate `.g.dart`)
- Modify: `player/lib/core/settings/settings_service.dart`, `player/lib/core/player/device_profile_provider.dart`, `player/lib/presentation/screens/settings/diagnostics_screen.dart`, `player/lib/l10n/app_en.arb` (the hatch's two descriptions say macOS and Linux)
- Create: `player/lib/core/player/mpv_surface_availability.dart`
- Test: `player/test/core/player/mac_video_output_test.dart` → `video_output_path_test.dart`; `player/test/core/settings/settings_service_mac_video_output_test.dart` → `settings_service_video_output_test.dart`; `legacy_mac_video_output_setting_test.dart` → `legacy_video_output_setting_test.dart`; `player/test/presentation/screens/settings/diagnostics_screen_test.dart`

**Interfaces:**
- Produces in `video_output_path.dart`: `typedef VideoOutputChoice = ({VideoOutputPath path, bool failedEarlier});` and
  `VideoOutputPath chooseVideoOutputPath({required TargetPlatform platform, required bool isWeb, required bool legacyHatch, required String? failedVersion, required String appVersion, required bool surfaceAvailable})`: eligible on macOS, and on Linux only when `surfaceAvailable`; `surfaceAvailable` is ignored on macOS.
  `Future<VideoOutputChoice> resolveVideoOutputChoice({required readLegacyHatch, required readFailedVersion, required Future<bool> Function() readSurfaceAvailable, required String appVersion, TargetPlatform? platform, bool? isWeb})`: a throwing availability read counts as false.
- Produces in `settings_service.dart`: `getLegacyVideoOutput()` / `setLegacyVideoOutput(bool)` on key `debug.legacyVideoOutput`; a read finding no new key but `legacy_mac_video_output` returns its value, writes it under the new key and deletes the old one. `getSurfaceFailedVersion()` / `setSurfaceFailedVersion(String)` on the unchanged key `mac_surface_failed_version`. The old method names go.
- Produces: provider `legacyVideoOutputProvider` (the renamed notifier), and in `mpv_surface_availability.dart` `final mpvSurfaceAvailableProvider = FutureProvider<bool>` (keep-alive, one read per app run): false off Linux or on web; on Linux `MpvSurfaceChannel().available()` from Task 7, false on any error.
- Renames in `player_video_surface.dart`: `resolveMacVideoOutput` to `resolveVideoOutput(WidgetRef)` and `recordMacSurfaceFailure` to `recordSurfaceFailure(WidgetRef)`, platform check `macOS || linux`.

- [ ] **Step 1: Write the failing tests:**
  - `video_output_path_test.dart`: Linux with `surfaceAvailable: true`, hatch off, no failure is surface; Linux unavailable is texture; Linux hatch on is texture; Linux failure on this version is texture; Linux failure on an older version is surface; macOS ignores `surfaceAvailable: false`; Windows is texture; `resolveVideoOutputChoice` with a throwing availability read is texture with `failedEarlier: false`.
  - `settings_service_video_output_test.dart`: `setLegacyVideoOutput(true)` stores `{'debug.legacyVideoOutput': 'true'}`; `migratesTheMacKey`: storage holding `legacy_mac_video_output: 'true'` reads true and afterwards holds only `debug.legacyVideoOutput: 'true'`; the failure version keeps `mac_surface_failed_version`.
  - `diagnostics_screen_test.dart`: on Linux (`debugDefaultTargetPlatformOverride`) with availability true, the hatch row and the output line `gpu-next` show; with availability false, the line reads `texture`; on Windows neither shows.
- [ ] **Step 2: Run them to see them fail.** `cd player && flutter test test/core/player/video_output_path_test.dart test/core/settings test/presentation/screens/settings/diagnostics_screen_test.dart`.
- [ ] **Step 3: Implement**, update every caller (`grep -rn "MacVideoOutput\|MacSurfaceFailed\|resolveMacVideoOutput\|recordMacSurfaceFailure" lib test`), run `dart run build_runner build --delete-conflicting-outputs`, and pass `mpvSurfaceAvailableProvider` into the device profile's resolver and the diagnostics rows (`_macVideoOutputRows` becomes `_videoOutputRows`, shown on macOS or Linux).
- [ ] **Step 4: Run the tests** above plus `flutter test test/presentation/screens/player`. Expected: all pass.
- [ ] **Step 5: Commit.** `refactor(player): one video output choice and hatch for macOS and Linux`.

### Task 9: `PlayerVideoSurface` on Linux

**Files:**
- Create: `player/lib/presentation/widgets/video_surface/surface_geometry_reporter.dart`
- Modify: `player/lib/presentation/widgets/video_surface/player_video_surface.dart`
- Test: `player/test/presentation/widgets/video_surface/surface_geometry_reporter_test.dart`, `mpv_surface_binding_test.dart`

**Interfaces:**
- Consumes: Task 7's `SurfaceGeometry`, `attach(geometry:)`, `setGeometry`.
- Produces: `SurfaceGeometryReporter({required void Function(SurfaceGeometry) onChanged, Widget? child})`, a single-child render object widget that, after each paint, compares its global rect (`localToGlobal(Offset.zero) & size`) and `View.of(context).devicePixelRatio` with the last report and calls `onChanged` once from a post-frame callback when either differs.
- Produces: `MpvSurfaceBinding({required Player player, required MpvSurface surface, TargetPlatform? platform})`. On Linux `attach()` waits for the first geometry (the same 5 s timeout and message as the view) instead of a view id; later geometries go to `setGeometry` while attached, and the latest one is sent right after attach if it changed during the call.

- [ ] **Step 1: Write the failing tests:**
  - `geometryFollowsResizeOnce`: a reporter inside a `SizedBox` resized from 800x450 to 1280x720 calls `onChanged` exactly once per change, with the new rect; a rebuild with no change calls nothing.
  - `geometryFollowsPixelRatio`: changing `tester.view.devicePixelRatio` from 1 to 2 calls `onChanged` once with scale 2.
  - In `mpv_surface_binding_test.dart` (Linux platform): `attachWaitsForFirstGeometry` (attach is called with that geometry and no view id); `geometryAfterAttachGoesToSetGeometry`; `noGeometryWithinTimeoutFailsAttach`; `noSetGeometryAfterDetach`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.** On Linux the widget's base layer is `SurfaceGeometryReporter` over a transparent `SizedBox.expand()` (no `ColoredBox`, no `AppKitView`); subtitles, chrome and overlay are unchanged.
- [ ] **Step 4: Run** `flutter test test/presentation/widgets/video_surface`. Expected: pass, the macOS tests included.
- [ ] **Step 5: Commit.** `feat(player): Linux video surface reports its geometry`.

### Task 10: The player screen on Linux

**Files:**
- Modify: `player/lib/presentation/screens/player/player_screen.dart`
- Create: `player/test/presentation/screens/player/player_screen_linux_surface_test.dart` (reusing `player_screen_mac_surface_test.dart`'s fake surface and harness: move the fake into `player_screen_test_harness.dart` if both need it)

**Interfaces:**
- Consumes: Tasks 7 to 9.
- Produces: `PlayerScreen.playerFrame({required Widget child, bool transparent = false})`: `Colors.transparent` scaffold background when `transparent`. The screen passes `transparent: true` while `_surfaceBinding != null` on Linux.

- [ ] **Step 1: Write the failing tests** with `debugDefaultTargetPlatformOverride = TargetPlatform.linux`, the fake reporting `available: true`:
  - `linuxSurfaceAttachesWithGeometryBeforeOpen`: the fake's `attach` sees the video box's geometry; `open` runs after it replies.
  - `nothingOpaquePaintsUnderTheVideoBox`: while playing, no ancestor of the reporter is a `ColoredBox` with alpha above 0, a `Scaffold` with an opaque background, or a `Material` of type `canvas` with an opaque color. Ancestors up to the `MaterialApp`.
  - `linuxSurfaceStartFailureFallsBackToTexture` (`failed` from `awaitVideoOutput`): texture `Video` is built, the failure is recorded for this version, the frame is opaque again.
  - `nextSourceDetachesOldHandleBeforeAttachingNew` on Linux.
  - `unavailableSurfaceUsesTextureSilently`: `available: false` builds `Video`, records nothing, and the stats Why row is empty.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.** Thread `transparent` through `playerFrame`; find and clear any other opaque painter the `nothingOpaque...` test reports (the app shell and `DesktopWindowChrome` paint per screen). Loading, error and cast views keep replacing the surface as on macOS.
- [ ] **Step 4: Run** `flutter test test/presentation/screens/player`. Expected: pass, macOS tests included.
- [ ] **Step 5: Commit.** `feat(player): play through the mpv surface on Linux`.

### Task 11: Linux claims and stats

**Files:**
- Rename: `player/lib/core/player/mac_hdr_claims.dart` → `surface_hdr_claims.dart` (and its test)
- Modify: `player/lib/core/player/device_profile_native.dart`, `device_profile.dart`, `device_profile_web.dart`, `device_profile_provider.dart`
- Modify: `player/lib/core/playback/health_sample.dart`, `frame_stats_sampler_native.dart`, `stats/playback_stats.dart`, `stats/playback_stats_collector.dart`, `stats/stats_report.dart`, `player/lib/presentation/screens/player/stats_context_builder.dart`, `player_screen.dart`, `player/lib/l10n/app_en.arb`, `player/lib/l10n/formatters.dart`
- Test: `surface_hdr_claims_test.dart`, `player/test/core/playback/stats/stats_report_test.dart`, `player/test/l10n/formatters_test.dart`, `player/test/presentation/screens/player/stats_context_builder_test.dart`

**Interfaces:**
- Produces: `const bool linuxDolbyVisionVerified` (set from Task 3's verdict); `List<String> surfaceHdrFormats(VideoOutputPath path, {required bool dolbyVisionVerified})`; `Future<List<String>> nativeProfileHdrFormats({required TargetPlatform platform, Future<VideoOutputPath> Function()? resolvePath})`, which applies to macOS (`macDolbyVisionVerified`) and Linux (`linuxDolbyVisionVerified`) and returns `nativeHdrFormats` elsewhere. `detectDeviceProfile({resolveOutputPath})` replaces `resolveMacOutputPath`.
- Produces: `FrameStats.targetPeakNits` and `StatsSample.targetPeakNits` (`double?`, from `video-target-params/max-luma` when `hdr`); `StatsContext.waylandSurface` (bool); `StatsHdr.peakNits`; `StatsWhyKind.linuxSurfaceFallback`.
- Produces l10n: `statsHdrOutputPeak` = `"HDR output, {transfer}, peak {nits} nits"`, `statsHdrOutputPlain` = `"HDR output, {transfer}"`, `statsWhyLinuxSurfaceFallback` = `"Using the standard video output: the HDR renderer could not start on this computer"`.

- [ ] **Step 1: Write the failing tests:**
  - Claims: Linux surface with the flag false is `['hdr10+', 'hdr10', 'hlg']`; with it true, `dolby_vision` first; Linux texture is `nativeHdrFormats`; a throwing resolver is `nativeHdrFormats`; macOS results unchanged.
  - `statsHdrFor` with `waylandSurface: true`, `by: player`: gamma `pq`, peak 1000 gives `edr`, transfer `PQ`, `peakNits: 1000`; gamma `hlg` gives `HLG`; gamma `srgb` gives `playerLibplacebo`; `dolbyvision` sets `rpuApplied`; a server transcode stays `server`.
  - Formatter: `HDR10, HDR output, PQ, peak 1000 nits`; `peakAtPqCeilingIsOmitted`: `peakNits: 10000` formats `HDR10, HDR output, PQ`; null peak formats the same; macOS headroom wording unchanged.
  - Stats context: `videoOutputFellBack` on Linux gives `linuxSurfaceFallback`, on macOS still `macSurfaceFallback`.
- [ ] **Step 2: Run them to see them fail.**
- [ ] **Step 3: Implement.** `statsHdrFor` takes the Linux branch when `context.waylandSurface` (no headroom needed); peaks at or above 10000 are dropped. The player screen sets `waylandSurface` when `_surfaceBinding != null` on Linux. If `linuxDolbyVisionVerified` is true, the claim must follow the output each playback actually uses (see the `mac_hdr_claims.dart` header): re-run `detectDeviceProfile` and `applyDetectedProfile` after `recordSurfaceFailure` and after the hatch changes.
- [ ] **Step 4: Run** `flutter test test/core test/l10n test/presentation/screens/player`, then `flutter gen-l10n` and the l10n catalog check the repo runs in CI. Expected: pass.
- [ ] **Step 5: Commit.** `feat(player): Linux HDR claims and the stats HDR row`.

### Task 12: Release pass on raider, docs

**Files:**
- Modify: `player/docs/playback.md` (the Linux surface: availability, the hatch, the smoke check, how to read the HDR row), `player/flatpak/` README or header comments touched in Task 1
- Modify: this plan's gate log

- [ ] **Step 1: Build and install the Flatpak** (`./dev player flatpak build && ./dev player flatpak install && ./dev player flatpak smoke`). Expected: `PASS: smoke test clean` and `embed: PASS`.
- [ ] **Step 2: Play the fixtures** in the real player on raider's Gala session (`./dev player flatpak run`), with the stats panel on: `levels_hdr10` reads `HDR10, HDR output, PQ...`, `levels_dv81` adds `RPU applied`, `sdr_testsrc` has no HDR row; Diagnostics says `gpu-next`.
- [ ] **Step 3: Walk the checklist** and record each result in the gate log: window resize, maximize, fullscreen and back (video follows, Review Focus 1); chrome, subtitles and the track sheet draw over the video; seek, pause, next episode; quit during playback (no hang, no crash, Review Focus 3); the hatch on (texture, next playback) and off; the screen's HDR mode off (row says libplacebo); `flatpak run --socket=x11 --nosocket=wayland` (texture, no message).
- [ ] **Step 4: Ask the user to look at the screen** for steps 2 and 3, since the pixel check from Task 2 proves compositing, not brightness.
- [ ] **Step 5: Docs**, then `cd player && flutter analyze && flutter test`. Expected: no issues, all pass. Commit. `docs(player): Linux HDR output`.

---

## Gate log

Filled in by Tasks 1, 2, 3, 6 and 12. Each entry: date, what ran, the evidence, the decision.
