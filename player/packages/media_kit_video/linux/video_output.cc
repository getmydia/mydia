// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "include/media_kit_video/video_output.h"
#include "include/media_kit_video/texture_gl.h"
#include "include/media_kit_video/texture_sw.h"

#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gdk/gdkwayland.h>
#include <gdk/gdkx.h>

struct _VideoOutput {
  GObject parent_instance;
  TextureGL* texture_gl;
  EGLDisplay egl_display; /* EGL display for mpv rendering (shared with flutter). */
  EGLContext egl_context; /* Isolated EGL context (non-shared). */
  EGLSurface egl_surface; /* Place holder surface for activating egl context */
  guint8* pixel_buffer;
  TextureSW* texture_sw;
  GMutex mutex; /* Only used in S/W rendering. */
  mpv_handle* handle;
  mpv_render_context* render_context;
  gint64 width;
  gint64 height;
  VideoOutputConfiguration configuration;
  TextureUpdateCallback texture_update_callback;
  gpointer texture_update_callback_context;
  FlTextureRegistrar* texture_registrar;
  gboolean destroyed;
};

G_DEFINE_TYPE(VideoOutput, video_output, G_TYPE_OBJECT)

// MYDIA PATCH (see player/packages/media_kit_video/MYDIA_PATCHES.md).
//
// Flutter 3.50's Linux embedder owns its EGL contexts (FlOpenGLManager) and
// no longer leaves one current on the GTK thread, so eglGetCurrentDisplay()
// returns EGL_NO_DISPLAY when a VideoOutput is created there and upstream
// fell back to S/W rendering. Resolve the display the way FlOpenGLManager
// does instead: eglGetPlatformDisplayEXT returns the same EGLDisplay handle
// for the same platform and native display, so the EGLImage that TextureGL
// shares with Flutter's raster context stays valid.
static EGLDisplay video_output_platform_egl_display() {
  GdkDisplay* display = gdk_display_get_default();
  EGLDisplay egl_display = EGL_NO_DISPLAY;
  if (GDK_IS_WAYLAND_DISPLAY(display)) {
    egl_display = eglGetPlatformDisplayEXT(
        EGL_PLATFORM_WAYLAND_EXT, gdk_wayland_display_get_wl_display(display),
        NULL);
  } else if (GDK_IS_X11_DISPLAY(display)) {
    egl_display = eglGetPlatformDisplayEXT(
        EGL_PLATFORM_X11_EXT, gdk_x11_display_get_xdisplay(display), NULL);
  }
  if (egl_display != EGL_NO_DISPLAY &&
      !eglInitialize(egl_display, NULL, NULL)) {
    g_printerr("media_kit: VideoOutput: eglInitialize failed. Error: 0x%x\n",
               eglGetError());
    return EGL_NO_DISPLAY;
  }
  return egl_display;
}

// The attributes FlOpenGLManager chooses its config with.
static EGLConfig video_output_choose_egl_config(EGLDisplay egl_display) {
  const EGLint attributes[] = {EGL_RED_SIZE,   8, EGL_GREEN_SIZE,   8,
                               EGL_BLUE_SIZE,  8, EGL_ALPHA_SIZE,   8,
                               EGL_DEPTH_SIZE, 8, EGL_STENCIL_SIZE, 8,
                               EGL_NONE};
  EGLConfig config = NULL;
  EGLint num_configs = 0;
  if (!eglChooseConfig(egl_display, attributes, &config, 1, &num_configs) ||
      num_configs < 1) {
    return NULL;
  }
  return config;
}

// Puts back whatever was current before media_kit borrowed the thread for
// its own context. When nothing was, the isolated context is released: an
// EGL context can be current on one thread only, and TextureGL makes it
// current on Flutter's raster thread for every frame.
static void video_output_restore_egl_context(VideoOutput* self,
                                             EGLDisplay display,
                                             EGLSurface draw,
                                             EGLSurface read,
                                             EGLContext context) {
  if (context != EGL_NO_CONTEXT) {
    eglMakeCurrent(display, draw, read, context);
  } else {
    eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
  }
}

static void video_output_dispose(GObject* object) {
  VideoOutput* self = VIDEO_OUTPUT(object);
  // MYDIA PATCH: a queued S/W redraw holds a reference (see the update
  // callback below), so a redraw queued while this runs keeps the object
  // alive past it and dispose runs again when that redraw lets go. Only the
  // first run releases anything.
  if (self->destroyed) {
    G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
    return;
  }
  self->destroyed = TRUE;
  
  // Make sure that no more callbacks are invoked from mpv.
  if (self->render_context) {
    mpv_render_context_set_update_callback(self->render_context, NULL, NULL);
  }

  // H/W
  if (self->texture_gl) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_gl));
    
    // Save Flutter's current context before cleanup
    EGLDisplay current_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);
    
    // Free mpv_render_context with our own isolated EGL context
    if (self->render_context != NULL) {
      if (self->egl_context != EGL_NO_CONTEXT) {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, self->egl_context);
      }
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
      
      // Restore Flutter's context (MYDIA PATCH: or release ours)
      video_output_restore_egl_context(self, current_display,
                                       flutter_draw_surface,
                                       flutter_read_surface, flutter_context);
    }
    
    // Clean up EGL resources
    if (self->egl_context != EGL_NO_CONTEXT) {
      eglDestroyContext(self->egl_display, self->egl_context);
      self->egl_context = EGL_NO_CONTEXT;
    }
    
    g_object_unref(self->texture_gl);
  }
  // S/W
  if (self->texture_sw) {
    fl_texture_registrar_unregister_texture(self->texture_registrar,
                                            FL_TEXTURE(self->texture_sw));
    g_free(self->pixel_buffer);
    g_object_unref(self->texture_sw);
    if (self->render_context != NULL) {
      mpv_render_context_free(self->render_context);
      self->render_context = NULL;
    }
  }
  
  G_OBJECT_CLASS(video_output_parent_class)->dispose(object);
}

// MYDIA PATCH: the mutex outlives dispose, since a queued S/W redraw may
// still run after it (it returns at once on |destroyed|).
static void video_output_finalize(GObject* object) {
  g_mutex_clear(&VIDEO_OUTPUT(object)->mutex);
  G_OBJECT_CLASS(video_output_parent_class)->finalize(object);
}

static void video_output_class_init(VideoOutputClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = video_output_dispose;
  G_OBJECT_CLASS(klass)->finalize = video_output_finalize;
}

static void video_output_init(VideoOutput* self) {
  self->texture_gl = NULL;
  self->egl_display = EGL_NO_DISPLAY;
  self->egl_context = EGL_NO_CONTEXT;
  self->egl_surface = EGL_NO_SURFACE;
  self->texture_sw = NULL;
  self->pixel_buffer = NULL;
  self->handle = NULL;
  self->render_context = NULL;
  self->width = 0;
  self->height = 0;
  self->configuration = VideoOutputConfiguration{};
  self->texture_update_callback = NULL;
  self->texture_update_callback_context = NULL;
  self->texture_registrar = NULL;
  self->destroyed = FALSE;
  g_mutex_init(&self->mutex);
}

VideoOutput* video_output_new(FlTextureRegistrar* texture_registrar,
                              FlView* view,
                              gint64 handle,
                              VideoOutputConfiguration configuration) {
  VideoOutput* self = VIDEO_OUTPUT(g_object_new(video_output_get_type(), NULL));
  self->texture_registrar = texture_registrar;
  self->handle = (mpv_handle*)handle;
  self->width = configuration.width;
  self->height = configuration.height;
  self->configuration = configuration;
#ifndef MPV_RENDER_API_TYPE_SW
  // MPV_RENDER_API_TYPE_SW must be available for S/W rendering.
  if (!self->configuration.enable_hardware_acceleration) {
    g_printerr("media_kit: VideoOutput: S/W rendering is not supported.\n");
  }
  self->configuration.enable_hardware_acceleration = TRUE;
#endif
  mpv_set_option_string(self->handle, "video-sync", "audio");
  // Causes frame drops with `pulse` audio output. (SlotSun/dart_simple_live#42)
  // mpv_set_option_string(self->handle, "video-timing-offset", "0");
  gboolean hardware_acceleration_supported = FALSE;
  if (self->configuration.enable_hardware_acceleration) {
    // Get Flutter's current EGL display (DO NOT share context)
    EGLDisplay flutter_display = eglGetCurrentDisplay();
    EGLContext flutter_context = eglGetCurrentContext();
    EGLSurface flutter_draw_surface = eglGetCurrentSurface(EGL_DRAW);
    EGLSurface flutter_read_surface = eglGetCurrentSurface(EGL_READ);
    
    // MYDIA PATCH: no current context is the normal case on Flutter 3.50.
    gboolean flutter_context_current =
        flutter_display != EGL_NO_DISPLAY && flutter_context != EGL_NO_CONTEXT;
    EGLDisplay egl_display = flutter_context_current
                                 ? flutter_display
                                 : video_output_platform_egl_display();

    if (egl_display != EGL_NO_DISPLAY) {
      self->egl_display = egl_display;

      // Bind OpenGL ES API (Flutter uses OpenGL ES on Linux)
      eglBindAPI(EGL_OPENGL_ES_API);

      // Query Flutter's EGL config and reuse it for compatibility
      EGLConfig config = NULL;
      EGLint config_id = 0;

      if (!flutter_context_current) {
        config = video_output_choose_egl_config(self->egl_display);
        if (config != NULL) {
          g_print("media_kit: VideoOutput: Using the platform EGL display.\n");
        }
      } else if (eglQueryContext(self->egl_display, flutter_context, EGL_CONFIG_ID, &config_id)) {
        g_print("media_kit: VideoOutput: Flutter's EGL config ID: %d\n", config_id);
        
        // Get Flutter's exact config
        EGLint num_configs = 0;
        EGLint config_attribs[] = { EGL_CONFIG_ID, config_id, EGL_NONE };
        
        if (eglChooseConfig(self->egl_display, config_attribs, &config, 1, &num_configs) && num_configs > 0) {
          g_print("media_kit: VideoOutput: Using Flutter's EGL config.\n");
        } else {
          g_printerr("media_kit: VideoOutput: Failed to get Flutter's EGL config by ID.\n");
          config = NULL;
        }
      } else {
        g_printerr("media_kit: VideoOutput: Failed to query Flutter's EGL config ID.\n");
      }
      
      if (config != NULL) {        
        // Create an isolated EGL context (NOT shared with Flutter)
        // This prevents OpenGL state pollution and resource contention
        EGLint context_attribs[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE,
        };
        
        self->egl_context = eglCreateContext(self->egl_display, config, 
                                             EGL_NO_CONTEXT, context_attribs);
        
        if (self->egl_context != EGL_NO_CONTEXT) {
          // Make our isolated context current for initialization (surfaceless)
          if (eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE, self->egl_context)) {
            // Create texture with our isolated context
            self->texture_gl = texture_gl_new(self);
            
            if (fl_texture_registrar_register_texture(
                    texture_registrar, FL_TEXTURE(self->texture_gl))) {
              // Initialize mpv with our isolated EGL context
              mpv_opengl_init_params gl_init_params{
                  [](auto, auto name) {
                    return (void*)eglGetProcAddress(name);
                  },
                  NULL,
              };
              
              mpv_render_param params[] = {
                  {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_OPENGL},
                  {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, (void*)&gl_init_params},
                  {MPV_RENDER_PARAM_INVALID, (void*)0},
                  {MPV_RENDER_PARAM_INVALID, (void*)0},
              };
              
              // VAAPI acceleration requires passing X11/Wayland display
              GdkDisplay* display = gdk_display_get_default();
              if (GDK_IS_WAYLAND_DISPLAY(display)) {
                params[2].type = MPV_RENDER_PARAM_WL_DISPLAY;
                params[2].data = gdk_wayland_display_get_wl_display(display);
              } else if (GDK_IS_X11_DISPLAY(display)) {
                params[2].type = MPV_RENDER_PARAM_X11_DISPLAY;
                params[2].data = gdk_x11_display_get_xdisplay(display);
              }
              
              if (mpv_render_context_create(&self->render_context, self->handle, params) == 0) {
                mpv_render_context_set_update_callback(
                    self->render_context,
                    [](void* data) {
                      VideoOutput* self = (VideoOutput*)data;
                      if (self->destroyed) {
                        return;
                      }
                      fl_texture_registrar_mark_texture_frame_available(
                          self->texture_registrar, FL_TEXTURE(self->texture_gl));
                    },
                    self);
                hardware_acceleration_supported = TRUE;
                g_print("media_kit: VideoOutput: H/W rendering with isolated EGL context.\n");
              } else {
                g_printerr("media_kit: VideoOutput: Failed to create mpv_render_context.\n");
              }
            } else {
              g_printerr("media_kit: VideoOutput: Failed to register texture.\n");
            }
            
            // Restore Flutter's context (MYDIA PATCH: or release ours)
            video_output_restore_egl_context(self, flutter_display,
                                             flutter_draw_surface,
                                             flutter_read_surface,
                                             flutter_context);
          } else {
            g_printerr("media_kit: VideoOutput: Failed to make isolated EGL context current. Error: 0x%x\n", eglGetError());
          }
        } else {
          g_printerr("media_kit: VideoOutput: Failed to create isolated EGL context. Error: 0x%x\n", eglGetError());
        }
      } else {
        g_printerr("media_kit: VideoOutput: Could not obtain Flutter's EGL config.\n");
      }
    } else {
      g_printerr("media_kit: VideoOutput: EGL display or context is invalid.\n");
    }
  }
#ifdef MPV_RENDER_API_TYPE_SW
  if (!hardware_acceleration_supported) {
    g_printerr("media_kit: VideoOutput: S/W rendering.\n");
    // H/W rendering failed. Fallback to S/W rendering.
    self->pixel_buffer = g_new0(guint8, SW_RENDERING_PIXEL_BUFFER_SIZE);
    // MYDIA PATCH: release a half-built H/W backend (texture registered, but
    // mpv_render_context_create failed) instead of leaking it. Upstream only
    // reached this rarely; resolving the platform display makes the H/W
    // attempt the norm.
    if (self->texture_gl != NULL) {
      fl_texture_registrar_unregister_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_gl));
      g_object_unref(self->texture_gl);
    }
    if (self->egl_context != EGL_NO_CONTEXT) {
      // texture_gl_dispose makes it current and cannot restore "nothing".
      if (eglGetCurrentContext() == self->egl_context) {
        eglMakeCurrent(self->egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
      }
      eglDestroyContext(self->egl_display, self->egl_context);
      self->egl_context = EGL_NO_CONTEXT;
    }
    self->texture_gl = NULL;
    self->texture_sw = texture_sw_new(self);
    if (fl_texture_registrar_register_texture(texture_registrar,
                                              FL_TEXTURE(self->texture_sw))) {
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, (void*)MPV_RENDER_API_TYPE_SW},
          {MPV_RENDER_PARAM_INVALID, (void*)0},
      };
      if (mpv_render_context_create(&self->render_context, self->handle,
                                    params) == 0) {
        mpv_render_context_set_update_callback(
            self->render_context,
            [](void* data) {
              // MYDIA PATCH: upstream queued the redraw with a bare pointer,
              // so one still queued when the output was disposed ran on
              // freed memory: it read |destroyed| from there and could lock
              // a freed mutex, freezing the GTK thread for good (closing the
              // player just after opening it hit this). The redraw now owns a
              // reference until it has run. mpv calls this under the lock
              // that dispose's mpv_render_context_set_update_callback(NULL)
              // takes, so it never runs once dispose is past that call.
              gdk_threads_add_idle_full(
                  G_PRIORITY_DEFAULT_IDLE,
                  [](gpointer data) -> gboolean {
                    VideoOutput* self = (VideoOutput*)data;
                    if (self->destroyed) {
                      return FALSE;
                    }
                    g_mutex_lock(&self->mutex);
                    gint64 width = video_output_get_width(self);
                    gint64 height = video_output_get_height(self);
                    if (width > 0 && height > 0) {
                      gint32 size[]{(gint32)width, (gint32)height};
                      gint32 pitch = 4 * (gint32)width;
                      mpv_render_param params[]{
                          {MPV_RENDER_PARAM_SW_SIZE, size},
                          {MPV_RENDER_PARAM_SW_FORMAT, (void*)"rgb0"},
                          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
                          {MPV_RENDER_PARAM_SW_POINTER, self->pixel_buffer},
                          {MPV_RENDER_PARAM_INVALID, (void*)0},
                      };
                      mpv_render_context_render(self->render_context, params);
                      fl_texture_registrar_mark_texture_frame_available(
                          self->texture_registrar,
                          FL_TEXTURE(self->texture_sw));
                    }
                    g_mutex_unlock(&self->mutex);
                    return FALSE;
                  },
                  g_object_ref(data), g_object_unref);
            },
            self);
      }
    }
  }
#endif
  // MYDIA PATCH: tells the app which path won, so a silent fallback to S/W
  // rendering shows up in its stats panel instead of only as stutter.
  // `user-data/` properties are free for clients to set (mpv 0.36+).
  mpv_set_property_string(self->handle, "user-data/media-kit/render",
                          hardware_acceleration_supported ? "hw" : "sw");
  return self;
}

void video_output_set_texture_update_callback(
    VideoOutput* self,
    TextureUpdateCallback texture_update_callback,
    gpointer texture_update_callback_context) {
  self->texture_update_callback = texture_update_callback;
  self->texture_update_callback_context = texture_update_callback_context;
  // Notify initial dimensions as (1, 1) if |width| & |height| are 0 i.e.
  // texture & video frame size is based on playing file's resolution. This
  // will make sure that `Texture` widget on Flutter's widget tree is actually
  // mounted & |fl_texture_registrar_mark_texture_frame_available| actually
  // invokes the |TextureGL| or |TextureSW| callbacks. Otherwise it will be a
  // never ending deadlock where no video frames are ever rendered.
  gint64 texture_id = video_output_get_texture_id(self);
  if (self->width == 0 || self->height == 0) {
    self->texture_update_callback(texture_id, 1, 1,
                                  self->texture_update_callback_context);
  } else {
    self->texture_update_callback(texture_id, self->width, self->height,
                                  self->texture_update_callback_context);
  }
}

void video_output_set_size(VideoOutput* self, gint64 width, gint64 height) {
  // Ideally, a mutex should be used here & |video_output_get_width| +
  // |video_output_get_height|. However, that is throwing everything into a
  // deadlock. Flutter itself seems to have some synchronization mechanism in
  // rendering & platform channels AFAIK.

  // H/W
  if (self->texture_gl) {
    self->width = width;
    self->height = height;
  }
  // S/W
  if (self->texture_sw) {
    self->width = CLAMP(width, 0, SW_RENDERING_MAX_WIDTH);
    self->height = CLAMP(height, 0, SW_RENDERING_MAX_HEIGHT);
  }
}

mpv_render_context* video_output_get_render_context(VideoOutput* self) {
  return self->render_context;
}

EGLDisplay video_output_get_egl_display(VideoOutput* self) {
  return self->egl_display;
}

EGLContext video_output_get_egl_context(VideoOutput* self) {
  return self->egl_context;
}

EGLSurface video_output_get_egl_surface(VideoOutput* self) {
  return self->egl_surface;
}

guint8* video_output_get_pixel_buffer(VideoOutput* self) {
  return self->pixel_buffer;
}

gint64 video_output_get_width(VideoOutput* self) {
  // Fixed width.
  if (self->width) {
    return self->width;
  }

  // Video resolution dependent width.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return width / height * SW_RENDERING_MAX_HEIGHT;
    }
  }

  return width;
}

gint64 video_output_get_height(VideoOutput* self) {
  // Fixed height.
  if (self->width) {
    return self->height;
  }

  // Video resolution dependent height.
  gint64 width = 0;
  gint64 height = 0;

  mpv_node params;
  mpv_get_property(self->handle, "video-out-params", MPV_FORMAT_NODE, &params);

  int64_t dw = 0, dh = 0, rotate = 0;
  if (params.format == MPV_FORMAT_NODE_MAP) {
    for (int32_t i = 0; i < params.u.list->num; i++) {
      char* key = params.u.list->keys[i];
      auto value = params.u.list->values[i];
      if (value.format == MPV_FORMAT_INT64) {
        if (strcmp(key, "dw") == 0) {
          dw = value.u.int64;
        }
        if (strcmp(key, "dh") == 0) {
          dh = value.u.int64;
        }
        if (strcmp(key, "rotate") == 0) {
          rotate = value.u.int64;
        }
      }
    }
    mpv_free_node_contents(&params);
  }

  width = rotate == 0 || rotate == 180 ? dw : dh;
  height = rotate == 0 || rotate == 180 ? dh : dw;

  if (self->texture_sw != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return height / width * SW_RENDERING_MAX_WIDTH;
    }
  }

  return height;
}

gint64 video_output_get_texture_id(VideoOutput* self) {
  // H/W
  if (self->texture_gl) {
    return (gint64)self->texture_gl;
  }
  // S/W
  if (self->texture_sw) {
    return (gint64)self->texture_sw;
  }
  g_assert_not_reached();
  return -1;
}

void video_output_notify_texture_update(VideoOutput* self) {
  gint64 id = video_output_get_texture_id(self);
  gint64 width = video_output_get_width(self);
  gint64 height = video_output_get_height(self);
  gpointer context = self->texture_update_callback_context;
  if (self->texture_update_callback != NULL) {
    self->texture_update_callback(id, width, height, context);
  }
}
