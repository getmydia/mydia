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

## Retiring it

Remove the directory and the override once a `media_kit_video` release finds
an EGL display without a current context. Check by playing a video in the
Linux build and looking for `H/W rendering with isolated EGL context.` on
stderr.
