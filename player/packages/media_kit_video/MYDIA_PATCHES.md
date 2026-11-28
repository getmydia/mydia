# media_kit_video 2.0.1, vendored

The pub.dev archive of `media_kit_video` 2.0.1 (sha256
`afaa509e7b7e0bf247557a3a740cde903a52c34ace9810f94500e127bd7b043d`), minus
`example/`, wired in through `dependency_overrides` in `player/pubspec.yaml`.
The first commit that added this directory is the untouched archive, so
`git log -p -- player/packages/media_kit_video` shows every local change.
Each change is marked `MYDIA PATCH` in the source.

## Linux: hardware rendering under Flutter 3.50

`linux/video_output.cc` picked its rendering path by asking EGL for the
context current on the GTK thread when the video output is created, and
reused that context's display. Through Flutter 3.47 one was current there. Flutter 3.50's embedder creates its own EGL contexts
(`FlOpenGLManager`) and leaves none current on the GTK thread, so the check
failed every time and upstream fell back to software rendering:

```
media_kit: VideoOutput: EGL display or context is invalid.
media_kit: VideoOutput: S/W rendering.
```

In software mode mpv renders each frame on the CPU, converts it to RGB with
swscale's C path, and copies it into a pixel buffer on the GTK thread, which
is also Flutter's UI thread. Playback stutters, and the output is capped at
1920x1080. mpv's drop counters stay near zero because the frames arrive late
rather than being dropped.

The patch resolves the display the way `FlOpenGLManager` does when no context
is current: `eglGetPlatformDisplayEXT` on the GDK Wayland or X11 display,
chosen with the same config attributes. EGL returns the same handle for the
same platform and native display, so the `EGLImage` that `TextureGL` shares
between mpv's context and Flutter's raster context is still valid. After
initialising, the patch releases mpv's isolated context from the GTK thread
instead of "restoring" a context that was never current. An EGL context can
be current on only one thread at a time, and `TextureGL` makes it current on
the raster thread for every frame.

When a context *is* current (older embedders), the upstream path runs
unchanged.

`analysis_options.yaml` excludes the whole package from analysis. It is
upstream code, and no `pub get` runs in this directory.

## Linux: a software redraw queued past dispose

In software mode mpv's update callback queues each redraw on the GTK thread
with `gdk_threads_add_idle`, passing the bare `VideoOutput` pointer. Disposing
the output stops new callbacks but leaves queued redraws in place, and the
object is freed before they run. A late redraw then reads `destroyed` from
freed memory; when that memory has been reused it reads false and locks a
mutex that no longer exists, and the GTK thread blocks on it forever. The
whole UI freezes.

Closing the player within a moment of opening it is enough: the screen is
gone while mpv is still delivering its first frames. The playback E2E found
it, with this on the GTK thread of the frozen app:

```
#1  g_mutex_lock_slowpath ()
#2  video_output_new(...)::{lambda(void*)#1}::operator() at video_output.cc:374
#4  gdk_threads_dispatch ()
```

The patch queues each redraw with a reference that the idle source drops once
it has run, so the object outlives every redraw queued for it. mpv invokes
the update callback under the lock that
`mpv_render_context_set_update_callback(NULL)` takes in dispose, so no
callback can take a reference after dispose has passed that call. A redraw
queued while dispose runs keeps the object alive past it, so dispose is now
safe to run twice (only the first run releases anything), and the mutex is
cleared in `finalize` instead. The hardware path marks frames straight from
mpv's callback and queues nothing, so it is unchanged.

### Dispose runs at removal

With a redraw still queued, removing the output from
`VideoOutputManager`'s table no longer drops the last reference, so dispose
would wait for the GTK main loop to run that redraw. `mpv_render_context_free`
would then happen after `VideoOutputManager.Dispose` had returned, and
nothing would order it before media_kit destroys the mpv core, which the mpv
render API forbids. So `video_output_manager_dispose`
(`linux/video_output_manager.cc`) runs dispose explicitly with
`g_object_run_dispose` before it removes the output: the render context is
freed inside `VideoOutputManager.Dispose`, as it was upstream. That call and
the redraws both run on the GTK thread, so a redraw that runs afterwards finds
`destroyed` set and returns without touching mpv. Its reference now keeps only
the object's memory (and the mutex it checks) alive, and the final unref runs
dispose a second time, which does nothing.

One window is upstream's and stays: media_kit 1.2.6's `NativePlayer.dispose`
(`lib/src/player/native/player/real.dart`) calls `mpv_terminate_destroy` 5
seconds after it stops playback, so a `VideoController` disposed more than 5
seconds after its `Player` frees its render context after the core is gone.

### Known hazard this patch leaves alone

`TextureSW` (`linux/texture_sw.cc`) keeps a bare `VideoOutput*` and, in
`texture_sw_copy_pixels`, reads the output's size and pixel buffer on
Flutter's raster thread, without the mutex the GTK-thread redraw holds while
it writes that buffer. Dispose unregisters the texture (the engine does that
on the raster thread, asynchronously) and then frees the pixel buffer, so a
copy already in flight can read freed memory. The patch neither causes nor
fixes this.

Retire this with the rest of the directory, after checking that the upstream
release no longer queues software redraws with a bare pointer.

## Retiring it

Remove the directory and the override once a `media_kit_video` release finds
an EGL display without a current context. Check by playing a video in the
Linux build and looking for `H/W rendering with isolated EGL context.` on
stdout (it is printed with `g_print`; the fallback messages go to stderr).
