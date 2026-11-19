# Linux HDR output: mpv gpu-next in a Wayland subsurface, Flatpak only

Spec 5 of the HDR roadmap in
`design/specs/2026-11-17-player-hdr-foundation-design.md` (spec 1). Spec 1
makes HDR color correct everywhere by tonemapping. This spec makes HDR files
show as HDR on a Linux desktop whose Wayland compositor does color management.

It builds on spec 2, `design/specs/2026-11-17-player-apple-hdr-output-design.md`,
which is in flight on its own branch. The Flutter side of spec 2 (the surface
widget, chrome without `VideoState`, Flutter-drawn subtitles, panscan, the
fallback, the stats rows) is reused here. Spec 2 merges first.

## Why

The Linux player renders mpv into a Flutter texture through media_kit's
`VideoController`. The texture is 8-bit SDR, so an HDR file is at best
tonemapped down, and Dolby Vision's RPU is ignored by `vo=gpu`.

On Wayland, mpv's `vo=gpu-next` renders through libplacebo and describes its
surface to the compositor with `wp_color_manager_v1` (PQ or HLG, BT.2020,
mastering luminances). A compositor in HDR mode then shows highlights above
SDR white, and composites the SDR UI next to it. That needs mpv to render into
a Wayland surface, which the texture path cannot give it.

## Spike findings (2026-11-17)

Run on raider: Pantheon (Gala 8.6.2 on Mutter 48.7, Wayland), AMD RX 6650 XT
(RADV, Mesa 26.3.0), a GBT M34WQ at 3440x1440 144 Hz in HDR mode. All checks
were made from logs and protocol traces; nobody looked at the screen (see
"Unverified" below).

- **The HDR chain works on raider.** Gala advertises `wp_color_manager_v1`
  with parametric descriptions, `set_luminances` and the `st2084_pq` transfer
  function, and its preferred description is PQ, BT.2020, reference white
  406 nits. Stock mpv 0.42 with gpu-next picks a passthrough swapchain
  (`R16G16B16A16_SFLOAT` + `PASS_THROUGH_EXT`) and sets a PQ image
  description on its surface. VAAPI decode works with Vulkan interop, and
  libplacebo compiles shaders with shaderc.
- **mpv 0.42, not 0.41.** mpv 0.42 sets the surface's image description
  itself for every gpu-next context. mpv 0.41 binds the color surface only for
  `vo=dmabuf-wayland` and leaves Vulkan to the driver's WSI, which makes HDR
  depend on the Mesa or NVIDIA version inside the Flatpak runtime. The
  Flatpak moves to mpv 0.42.
- **Stock libmpv cannot be embedded on Wayland.** `wid` is read by the X11,
  Windows and Android backends only. The Wayland backend always opens its own
  connection and its own `xdg_toplevel`. The render API offers OpenGL, D3D11
  and software only.
- **A 174-line patch to mpv 0.42 embeds it** (`video/out/wayland_common.c`,
  `wayland_common.h`, `vulkan/context_wayland.c`, `options/`). With it, a GTK3
  window that creates a subsurface below itself and hands it to mpv got:
  gpu-next rendering into the subsurface with `video-target-params/gamma=pq`,
  VAAPI decode, a resize driven by a new `wayland-surface-size` option
  (swapchain 1692x1378, then 800x450), `vid=no` with the output gone,
  `vid=auto` re-attaching to the same surface, then `mpv_terminate_destroy`,
  all with zero protocol errors and GTK presenting about 120 frames a second
  throughout.
- **mpv's own teardown order is a fatal protocol error under Mutter.**
  `vo_wayland_uninit` destroys each `wl_surface` before its `wl_subsurface`,
  and Mutter answers with `invalid object`. Stock mpv never notices because
  it disconnects next. On a shared connection the error kills the host app.
  The patch destroys subsurfaces first.
- **Mesa's WSI and mpv do not fight over color.** Mesa creates a
  `wp_color_management_surface_v1` on the surface, then destroys it before
  mpv creates its own, so mpv's is the only one when it sets the description.
- **Layering, from the protocol.** The subsurface is placed below GTK's
  surface and desynced. GTK's surface carries ARGB buffers and set no opaque
  region in either harness variant, so Mutter must blend it over the video.
- **mpv needs `LC_NUMERIC=C`.** `gtk_init` sets the user's locale and
  `mpv_create` then returns NULL. media_kit already resets it on Linux.
- **Frame drops are not embedding's.** Stock mpv in its own window dropped
  about 13 frames a second at 1692x1378 on raider. The embedded output
  dropped about 50 frames while each output started, then none.
- **Unverified.**
  - *Pixels.* Gala allows screenshots only from its own app and the portal,
    and the portal's non-interactive call never answered (it likely waits on
    a permission dialog). Whether HDR highlights look brighter than SDR white
    on raider is inferred from the image description, not seen.
  - *FlView.* A Flutter app built with nixpkgs' Flutter 3.47.4 hangs inside
    `gtk_widget_realize(view)` on raider's Wayland session, before any spike
    code runs, so FlView over the subsurface was not run. The harness used a
    cairo-drawn GTK window instead.
  - *The Flatpak sandbox.* Vulkan ICDs, shaderc and VAAPI were exercised on
    the host, not inside the GNOME 50 runtime.

  The plan's first tasks close all three (Testing, "Plan gates").

## Goal

- In the Flatpak on a Wayland session, every file plays through gpu-next in a
  subsurface under the Flutter view. HDR files show as HDR on a compositor and
  screen in HDR mode, and are tonemapped by libplacebo otherwise.
- Dolby Vision, including profile 5, plays with its RPU applied.
- Nothing about tracks, subtitles, chrome, stats, casting or the HLS and p2p
  plumbing changes for the viewer, apart from the picture.
- Any session where the surface cannot start still plays, on the texture
  path.

## Non-goals

- X11 sessions, the AppImage and the tarball. They link a system or stock
  libmpv and stay on the texture path with spec 1's tonemapping.
- Contributing the patch upstream.
- Picture tuning beyond mpv's defaults.
- Fractional and mixed-scale output beyond what the host passes in
  `wayland-surface-size` (the patch takes the host's buffer size as given).

## 1. The libmpv build

### mpv 0.42 and the patch

The Flatpak manifest's `mpv` module moves from v0.41.0 to v0.42.0 and gains a
`patches:` source, `player/flatpak/patches/mpv-wayland-embed.patch`. No fork,
no extra CI job: the Flatpak build applies it.

What the patch does:

- **`wid` on Wayland.** When `wid` is set, the Wayland backend reads it as a
  pointer to

  ```c
  struct mpv_wayland_embed {
      uint32_t magic;            /* 0x6d707665, "mpve" */
      struct wl_display *display;
      struct wl_surface *surface;
  };
  ```

  and refuses a struct with the wrong magic.
- **A private event queue.** mpv uses the host's `wl_display`, binds its
  globals from a display wrapper on its own `wl_event_queue`, and every
  dispatch, roundtrip and `prepare_read` in the backend goes to that queue.
  It never runs the host's event handlers.
- **A surface wrapper.** mpv works on a proxy wrapper of the host's surface,
  on its own queue, so frame callbacks, viewports and feedback objects land on
  that queue, and the host's proxy never carries an mpv listener that would
  dangle after uninit. Vulkan gets the host's real surface.
- **No window of its own.** No `xdg_surface`, `xdg_toplevel`, decorations,
  activation or session. No seats: a seat's pointer would receive the host's
  enter events and fight it over the cursor. `vo_wayland_control` answers
  only events, option changes and display queries when embedded, and
  `VO_NOTIMPL` to the rest (fullscreen, title, cursor, clipboard,
  screensaver).
- **Size from the host.** A new option, `wayland-surface-size=WxH`, in buffer
  pixels, sets mpv's window size. Changing it resizes the swapchain.
- **Teardown.** Subsurfaces are destroyed before their surfaces. The host's
  connection is flushed, never disconnected, and only mpv's wrapper and queue
  are freed.

The spike's patch is the starting point. Re-applying it on a later mpv is a
manual rebase, caught by the smoke check in Testing.

### What the runtime must provide

The GNOME 50 runtime supplies Mesa's Vulkan ICDs and VAAPI drivers through the
GL extension, and the manifest already builds libplacebo with
`-Dvulkan=enabled`. The plan's first task confirms, inside the sandbox, that
libplacebo finds shaderc or glslang, that a Vulkan device opens under
`--device=dri`, and that `hwdec-current` reads `vaapi`. A missing piece is
added to the manifest.

## 2. The runner surface plugin

`MpvSurfacePlugin` lives in `player/linux/runner/mpv_surface/`, in C, and is
registered in `my_application.cc` next to the existing window channels. It
serves the same `mydia/mpv-surface` method channel as spec 2's macOS plugin.

### available

True when the GDK display is Wayland, the compositor has `wl_subcompositor`,
and the bundled libmpv accepts `wayland-surface-size` (an unpatched libmpv
answers `MPV_ERROR_OPTION_NOT_FOUND`). Dart reads it once per app run.

### attach(handle)

1. Binds `wl_compositor` and `wl_subcompositor` through its own display
   wrapper and queue, as the spike did.
2. Creates a `wl_surface` and a `wl_subsurface` of the GTK window's surface,
   `place_below(parent)`, `set_desync`, and an empty input region so GTK keeps
   every pointer event.
3. Switches the window to its video frame (below).
4. Writes, in order: `wid` (the embed struct), `vo=gpu-next`,
   `gpu-api=vulkan`, `gpu-context=waylandvk`, `target-colorspace-hint=yes`,
   `hwdec=auto-safe`, spec 2's restored quality options,
   `wayland-surface-size`, then `vid=auto`.

### setGeometry(rect, scale)

Dart sends the video box's rect in logical pixels and the device pixel ratio.
The plugin translates it into the window surface's coordinates (adding the
FlView's offset inside the toplevel, which includes the CSD shadow margin),
calls `wl_subsurface_set_position`, sets `wayland-surface-size` to the rect
times the scale, and queues a redraw of the window so GTK commits the parent,
which is when a subsurface's position applies.

### detach(handle)

Sets `vid=no` and waits, up to 3 seconds, for `current-vo` to read empty, then
destroys the subsurface and its surface and restores the window frame. The
player screen calls it before `player.dispose()`. GTK's `unrealize` of the
window runs it too.

### The window frame

The runner paints the window black (`window.mydia-frame { background-color:
#000000 }`) under the transparent FlView, which would cover the video. While a
surface is attached the window gets a `mydia-video` style class whose
background is transparent; detach removes it. The rounded-corner and tiling
rules stay as they are.

### Threading

mpv writes run on one worker thread in arrival order and reply to Dart
asynchronously, which keeps spec 2's contract. The Wayland calls the plugin
makes itself (surface, subsurface, position) run on the GTK main thread,
where GDK's surface lives.

## 3. The Flutter side

Spec 2's `PlayerVideoSurface` gains a Linux branch.

- **No platform view.** The Flutter Linux embedder has none. The surface is a
  transparent box over the video area, then `MydiaSubtitleView`, then the
  chrome, exactly as on macOS minus the `AppKitView`. A `RenderBox` listener
  sends `setGeometry` when the box's global rect or the pixel ratio changes.
- **Every screen above the player must stay transparent where the video
  is.** The player screen already paints its own background; on the surface
  path it paints none behind the video box. Loading, error and cast views
  replace the surface as they replace `Video` today.
- **Generalized from spec 2:** `MpvSurface.attach` takes an optional
  `viewId`; `chooseVideoOutputPath` accepts Linux when `available` is true;
  the escape hatch becomes one `debug.legacyVideoOutput` for both platforms,
  migrating the macOS key.
- Chrome without `VideoState`, subtitles, panscan for fit and fill, the
  fallback timer and the per-version failure record are reused unchanged.

## 4. Claims, stats, failures

### Capability claims

| Client | Claims |
| --- | --- |
| Linux, surface path | `hdr10+`, `hdr10`, `hlg`, and `dolby_vision` once verified (below) |
| Linux, texture path | spec 1's native claims |

The meaning is spec 1's: the client plays the format with correct color,
whatever the screen. `dolby_vision` covers profile 5, so Linux claims it only
after a real profile 5 file passes the plan's check on raider.

### Stats for nerds

The HDR row reads mpv's `video-target-params`:

- `HDR output, PQ, peak N nits` when the target gamma is PQ or HLG;
- `tonemapped by player (libplacebo)` otherwise;
- `RPU applied` on the source label when mpv reports the `dolbyvision`
  matrix, as on macOS.

No display event channel is needed: the compositor's preferred description
already reaches mpv.

### Failures

- **gpu-next does not start** (no Vulkan device, shaderc missing, the
  compositor refuses the surface): `current-vo` still empty 2 seconds after
  `vid=auto`. The screen detaches, rebuilds on the texture path and records
  the failure for the app version, as on macOS.
- **No color management, or an SDR screen:** the surface path stays, and
  libplacebo tonemaps. DV keeps its RPU.
- **A protocol error from mpv kills the app**, because the connection is
  shared. The patch's teardown order fixes the one the spike found; the
  smoke check below runs attach, resize, detach, re-attach and destroy on
  every Flatpak build so a new one is caught before release.
- **X11, AppImage, tarball:** `available` is false; the texture path, with no
  message.

## Testing

**Plan gates (first tasks, before any product code)**

1. Build the Flatpak with mpv 0.42 and the patch. Inside it, run a headless
   probe that plays the calibrated HDR10 clip and asserts `current-vo` is
   `gpu-next`, `hwdec-current` is `vaapi` and the target gamma is `pq`.
2. Run the patched Flatpak player on raider with a scripted playback and
   prove FlView composites over the subsurface. Pixels are read through the
   screenshot portal once its permission is granted for the app, or the
   check is moved to a compositor that allows headless capture (Mutter's
   `--headless` with a virtual monitor, or a wlroots compositor with
   `screencopy`). This also explains or works around the nixpkgs-Flutter
   realize hang.
3. Play a real Dolby Vision profile 5 file on raider before Linux claims
   `dolby_vision`.

**Dart**

- `chooseVideoOutputPath` for Linux: Wayland or X11, `available` or not,
  hatch on or off, failure recorded.
- Geometry reporting: rect and ratio changes send one `setGeometry`.
- The Linux claims and the stats labels from `video-target-params`.
- The fallback flow with a fake plugin.

**Native**

The plugin reaches mpv through a table of function pointers, so a GLib test
with a fake table checks that `wid` and the options precede `vid=auto`, that
`detach` waits for `current-vo`, and that unrealize detaches. If wiring a test
target into `player/linux/CMakeLists.txt` costs more than the plugin, the plan
says so and relies on the smoke check.

**Flatpak smoke check**

`./dev player flatpak smoke` asserts the bundled libmpv accepts
`wayland-surface-size`, then runs the spike harness's sequence (attach,
resize, `vid=no`, re-attach, destroy) against a nested Wayland compositor and
fails on any protocol error.

**Fixtures**

Spec 2's `scripts/generate-hdr-fixtures.sh` (calibrated 203, 1,000 and
4,000-nit patches, DV 8.1 with an RPU). No real titles.

## Risks

- **Patch drift.** The backend changes often upstream. The smoke check
  catches a broken rebase; the patch stays small by touching only the
  connection, the surface, the control filter and teardown.
- **Shared-connection fragility.** Any new protocol misuse in mpv's Wayland
  code becomes a crash of the whole app, not of the video. The smoke check is
  the guard.
- **Compositor spread.** Verified on Mutter 48 (Gala) only. KWin and wlroots
  compositors implement the same protocol but may differ in how they treat a
  subsurface below its parent. The fallback covers a surface that never
  starts; a surface that starts but is hidden would not be caught.
- **NVIDIA.** mpv 0.42 sets the description itself, so HDR no longer depends
  on the driver's WSI, but VAAPI is absent on NVIDIA and decode falls to
  NVDEC or software.
- **Flatpak size.** Unchanged in kind: libplacebo with Vulkan is already
  bundled.
