// THROWAWAY spike harness: GTK3 window, Wayland subsurface below it, patched
// libmpv rendering gpu-next into the subsurface, opaque "chrome" drawn by GTK
// on top of a transparent window. Takes compositor screenshots at fixed points.
#include <gtk/gtk.h>
#include <gdk/gdkwayland.h>
#include <wayland-client.h>
#include <mpv/client.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>

#define MPV_WAYLAND_EMBED_MAGIC 0x6d707665u
struct mpv_wayland_embed {
  uint32_t magic;
  struct wl_display* display;
  struct wl_surface* surface;
};

static GtkWidget* window;
static GtkWidget* area;
static struct wl_compositor* compositor;
static struct wl_subcompositor* subcompositor;
static struct wl_surface* video_surface;
static struct wl_subsurface* video_subsurface;
static struct mpv_wayland_embed embed;
static mpv_handle* mpv;
static const char* outdir;
static const char* clip;
static int frame_count;
static int step;

static void reg_add(void* data, struct wl_registry* r, uint32_t id, const char* iface, uint32_t ver) {
  if (!strcmp(iface, wl_compositor_interface.name))
    compositor = wl_registry_bind(r, id, &wl_compositor_interface, 4);
  if (!strcmp(iface, wl_subcompositor_interface.name))
    subcompositor = wl_registry_bind(r, id, &wl_subcompositor_interface, 1);
}
static void reg_remove(void* d, struct wl_registry* r, uint32_t id) {}
static const struct wl_registry_listener reg_listener = {reg_add, reg_remove};

static gboolean draw(GtkWidget* w, cairo_t* cr, gpointer d) {
  // Transparent everywhere, so the video subsurface below shows through.
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0, 0, 0, 0);
  cairo_paint(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
  // Opaque "chrome" over the video: pure red block, top left.
  cairo_set_source_rgba(cr, 1, 0, 0, 1);
  cairo_rectangle(cr, 40, 40, 200, 100);
  cairo_fill(cr);
  // Half-transparent control bar along the bottom.
  int h = gtk_widget_get_allocated_height(w);
  int wd = gtk_widget_get_allocated_width(w);
  cairo_set_source_rgba(cr, 0, 0, 0, 0.5);
  cairo_rectangle(cr, 0, h - 60, wd, 60);
  cairo_fill(cr);
  return FALSE;
}

static void place_video(void) {
  int x = 0, y = 0;
  gtk_widget_translate_coordinates(area, window, 0, 0, &x, &y);
  int w = gtk_widget_get_allocated_width(area);
  int h = gtk_widget_get_allocated_height(area);
  int scale = gtk_widget_get_scale_factor(area);
  wl_subsurface_set_position(video_subsurface, x, y);
  char size[64];
  snprintf(size, sizeof size, "%dx%d", w * scale, h * scale);
  if (mpv) mpv_set_property_string(mpv, "wayland-surface-size", size);
  fprintf(stderr, "[harness] video at %d,%d size %s (scale %d)\n", x, y, size, scale);
  // Subsurface position applies on the parent's next commit.
  gtk_widget_queue_draw(window);
}

static void screenshot(const char* name) {
  char path[1024];
  snprintf(path, sizeof path, "%s/%s.png", outdir, name);
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, NULL);
  GError* err = NULL;
  GVariant* r = g_dbus_connection_call_sync(
      bus, "org.gnome.Shell.Screenshot", "/org/gnome/Shell/Screenshot",
      "org.gnome.Shell.Screenshot", "ScreenshotWindow",
      g_variant_new("(bbbs)", FALSE, FALSE, FALSE, path), NULL,
      G_DBUS_CALL_FLAGS_NONE, 5000, NULL, &err);
  if (err) {
    fprintf(stderr, "[harness] screenshot %s failed: %s\n", name, err->message);
    g_error_free(err);
  } else {
    fprintf(stderr, "[harness] screenshot %s -> %s\n", name, path);
    g_variant_unref(r);
  }
}

static void report_mpv(const char* tag) {
  char* vo = mpv_get_property_string(mpv, "current-vo");
  char* gamma = mpv_get_property_string(mpv, "video-target-params/gamma");
  char* prim = mpv_get_property_string(mpv, "video-target-params/primaries");
  char* peak = mpv_get_property_string(mpv, "video-target-params/max-luma");
  char* hw = mpv_get_property_string(mpv, "hwdec-current");
  char* drop = mpv_get_property_string(mpv, "frame-drop-count");
  char* osd = mpv_get_property_string(mpv, "osd-dimensions/w");
  fprintf(stderr, "[harness] %s: vo=%s target gamma=%s prim=%s max-luma=%s hwdec=%s drops=%s osd-w=%s gtk-frames=%d\n",
          tag, vo, gamma, prim, peak, hw, drop, osd, frame_count);
  mpv_free(vo); mpv_free(gamma); mpv_free(prim); mpv_free(peak); mpv_free(hw); mpv_free(drop); mpv_free(osd);
}

static gboolean tick(gpointer d) {
  step++;
  switch (step) {
    case 1:  // 4 s in: playing at the initial size
      report_mpv("initial");
      screenshot("1-initial");
      break;
    case 2:  // resize the window, then the video follows
      // Gala keeps the window size; drive the surface size directly.
      mpv_set_property_string(mpv, "wayland-surface-size", "800x450");
      wl_subsurface_set_position(video_subsurface, 100, 100);
      gtk_widget_queue_draw(window);
      break;
    case 3:
      report_mpv("resized");
      screenshot("2-resized");
      break;
    case 4:  // tear the output down while the window stays
      mpv_set_property_string(mpv, "vid", "no");
      break;
    case 5: {
      char* vo = mpv_get_property_string(mpv, "current-vo");
      fprintf(stderr, "[harness] after vid=no current-vo=%s gtk-frames=%d\n", vo ? vo : "(none)", frame_count);
      mpv_free(vo);
      screenshot("3-detached");
      break;
    }
    case 6:  // re-attach to the same surface
      mpv_set_property_string(mpv, "vid", "auto");
      break;
    case 7:
      report_mpv("reattached");
      screenshot("4-reattached");
      break;
    case 8: {
      mpv_set_property_string(mpv, "vid", "no");
      mpv_terminate_destroy(mpv);
      mpv = NULL;
      wl_subsurface_destroy(video_subsurface);
      wl_surface_destroy(video_surface);
      gtk_widget_queue_draw(window);
      fprintf(stderr, "[harness] mpv destroyed, gtk still alive frames=%d\n", frame_count);
      break;
    }
    case 9:
      fprintf(stderr, "[harness] done frames=%d\n", frame_count);
      gtk_main_quit();
      return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

static gboolean frame_tick(GtkWidget* w, GdkFrameClock* c, gpointer d) {
  frame_count++;
  return G_SOURCE_CONTINUE;
}

static void on_size(GtkWidget* w, GdkRectangle* a, gpointer d) {
  if (video_subsurface) place_video();
}

static gboolean start(gpointer d) {
  GdkDisplay* gd = gdk_display_get_default();
  struct wl_display* display = gdk_wayland_display_get_wl_display(gd);
  struct wl_surface* parent = gdk_wayland_window_get_wl_surface(gtk_widget_get_window(window));

  // Globals on a private queue so this never dispatches GDK's events.
  struct wl_event_queue* q = wl_display_create_queue(display);
  struct wl_display* wrap = wl_proxy_create_wrapper(display);
  wl_proxy_set_queue((struct wl_proxy*)wrap, q);
  struct wl_registry* reg = wl_display_get_registry(wrap);
  wl_registry_add_listener(reg, &reg_listener, NULL);
  wl_display_roundtrip_queue(display, q);
  wl_proxy_wrapper_destroy(wrap);
  if (!compositor || !subcompositor) { fprintf(stderr, "no compositor\n"); exit(2); }

  video_surface = wl_compositor_create_surface(compositor);
  video_subsurface = wl_subcompositor_get_subsurface(subcompositor, video_surface, parent);
  wl_subsurface_place_below(video_subsurface, parent);
  wl_subsurface_set_desync(video_subsurface);
  // Video never takes input: GTK keeps every pointer event.
  struct wl_region* empty = wl_compositor_create_region(compositor);
  wl_surface_set_input_region(video_surface, empty);
  wl_region_destroy(empty);

  embed = (struct mpv_wayland_embed){MPV_WAYLAND_EMBED_MAGIC, display, video_surface};

  mpv = mpv_create();
  char wid[32];
  snprintf(wid, sizeof wid, "%lld", (long long)(intptr_t)&embed);
  char log[1024];
  snprintf(log, sizeof log, "%s/mpv.log", outdir);
  mpv_set_option_string(mpv, "log-file", log);
  mpv_set_option_string(mpv, "msg-level", "all=v");
  mpv_set_option_string(mpv, "vo", "gpu-next");
  mpv_set_option_string(mpv, "gpu-api", "vulkan");
  mpv_set_option_string(mpv, "gpu-context", "waylandvk");
  mpv_set_option_string(mpv, "target-colorspace-hint", "yes");
  mpv_set_option_string(mpv, "hwdec", "auto-safe");
  mpv_set_option_string(mpv, "loop-file", "inf");
  mpv_set_option_string(mpv, "vid", "no");  // like media_kit
  if (mpv_initialize(mpv) < 0) { fprintf(stderr, "mpv init failed\n"); exit(3); }
  // Runtime, before the output exists, as the plugin will do it.
  int r1 = mpv_set_property_string(mpv, "wid", wid);
  place_video();
  const char* cmd[] = {"loadfile", clip, NULL};
  mpv_command(mpv, cmd);
  int r2 = mpv_set_property_string(mpv, "vid", "auto");
  fprintf(stderr, "[harness] wid set=%d vid=auto=%d\n", r1, r2);

  g_timeout_add_seconds(4, tick, NULL);
  return G_SOURCE_REMOVE;
}

int main(int argc, char** argv) {
  if (argc < 3) { fprintf(stderr, "usage: harness <clip> <outdir>\n"); return 2; }
  clip = argv[1];
  outdir = argv[2];
  gtk_init(&argc, &argv);
  setlocale(LC_NUMERIC, "C");
  if (!GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default())) { fprintf(stderr, "not wayland\n"); return 2; }
  window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), "mydia-hdr-spike");
  GdkVisual* rgba = gdk_screen_get_rgba_visual(gtk_widget_get_screen(window));
  gtk_widget_set_visual(window, rgba);
  gtk_widget_set_app_paintable(window, TRUE);
  gtk_window_set_default_size(GTK_WINDOW(window), 1280, 720);
  area = gtk_drawing_area_new();
  g_signal_connect(area, "draw", G_CALLBACK(draw), NULL);
  g_signal_connect(area, "size-allocate", G_CALLBACK(on_size), NULL);
  gtk_container_add(GTK_CONTAINER(window), area);
  // Transparent window background (GTK paints the CSD frame itself).
  GtkCssProvider* css = gtk_css_provider_new();
  gtk_css_provider_load_from_data(css, "window, window.background { background: transparent; }", -1, NULL);
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(css),
                                            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
  g_signal_connect(window, "destroy", G_CALLBACK(gtk_main_quit), NULL);
  gtk_widget_show_all(window);
  gtk_widget_add_tick_callback(window, frame_tick, NULL, NULL);
  g_timeout_add(500, start, NULL);
  gtk_main();
  return 0;
}
