#include "my_application.h"

#include <flutter_linux/flutter_linux.h>

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  FlMethodChannel* window_chrome_channel;
  FlMethodChannel* window_frame_channel;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// The window chrome channel. Shared with macOS, whose AppDelegate.swift
// answers `setTrafficLightsHidden` on the same name.
static constexpr char kWindowChromeChannel[] = "dev.mydia.player/window_chrome";

// The window state channel: maximized, tiled and fullscreen, which Dart uses
// to square the corners it clips to. Separate from kWindowChromeChannel
// because Dart's DecorationLayoutSource owns that channel's only handler.
static constexpr char kWindowFrameChannel[] = "dev.mydia.player/window_frame";

// Corner radius for the floating window's frame, shadow and background.
// 15px is libadwaita's --window-radius (GNOME 50 runtime), so the player
// matches native GNOME apps. Must equal kLinuxWindowCornerRadius in
// lib/core/layout/window_chrome_inset.dart, which clips the Flutter view to
// the same curve.
//
// The last rule recolours the `.solid-csd` ring GTK draws when the screen
// has no compositor (GTK's resize grip in that state, since there is no
// shadow margin to grab). Extracted from GTK 3.24.52's own
// gtk-contained.css (`gresource extract ... /org/gtk/libgtk/theme/Adwaita/
// gtk-contained.css`): `.solid-csd decoration` paints that ring with
// `background-color`/`border`, both Adwaita's light headerbar tone, inside a
// `padding: 4px` box; `box-shadow` there only adds a white inner highlight,
// not the ring's fill. Overriding `background-color`/`border-color` to
// black (and dropping the highlight, which would read as a stray white line
// against it) recolours the ring; `padding` is left untouched so its width
// stays GTK's own.
static constexpr char kFrameCss[] =
    "window.mydia-frame { background-color: #000000; }\n"
    "window.mydia-frame.csd,\n"
    "window.mydia-frame.csd decoration { border-radius: 15px; }\n"
    "window.mydia-frame.maximized, window.mydia-frame.maximized decoration,\n"
    "window.mydia-frame.fullscreen, window.mydia-frame.fullscreen decoration,\n"
    "window.mydia-frame.tiled, window.mydia-frame.tiled decoration,\n"
    "window.mydia-frame.tiled-top, window.mydia-frame.tiled-top decoration,\n"
    "window.mydia-frame.tiled-bottom, window.mydia-frame.tiled-bottom decoration,\n"
    "window.mydia-frame.tiled-left, window.mydia-frame.tiled-left decoration,\n"
    "window.mydia-frame.tiled-right, window.mydia-frame.tiled-right decoration,\n"
    "window.mydia-frame.solid-csd, window.mydia-frame.solid-csd decoration\n"
    "{ border-radius: 0; }\n"
    "window.mydia-frame.solid-csd decoration {\n"
    "  background-color: #000000;\n"
    "  border-color: #000000;\n"
    "  box-shadow: none;\n"
    "}\n";

// A titlebar that takes no space.
//
// Handing GTK a custom titlebar keeps the window client-side decorated, so
// GTK still draws the drop shadow, puts invisible resize borders in the
// shadow margin, and tells the Wayland compositor the window's geometry
// without the shadow (which is what GNOME's snapping and tiling read).
// gtk_window_set_decorated(FALSE) threw all of that away.
//
// The size vfuncs are overridden rather than styled: theme CSS (min-height,
// padding) cannot reach a widget that answers its own size request, which
// is why hiding or CSS-shrinking an ordinary widget left five to six pixels
// of frame above the content when this was first tried. Same idea as
// libhandy's HdyNothing, without the dependency: the GNOME 51 runtime no
// longer ships libhandy.
G_DECLARE_FINAL_TYPE(MydiaNoTitlebar, mydia_no_titlebar, MYDIA, NO_TITLEBAR,
                     GtkWidget)

struct _MydiaNoTitlebar {
  GtkWidget parent_instance;
};

G_DEFINE_TYPE(MydiaNoTitlebar, mydia_no_titlebar, GTK_TYPE_WIDGET)

static void mydia_no_titlebar_get_preferred_size(GtkWidget* widget,
                                                 gint* minimum,
                                                 gint* natural) {
  *minimum = 0;
  *natural = 0;
}

static void mydia_no_titlebar_get_preferred_size_for(GtkWidget* widget,
                                                     gint for_size,
                                                     gint* minimum,
                                                     gint* natural) {
  *minimum = 0;
  *natural = 0;
}

static void mydia_no_titlebar_class_init(MydiaNoTitlebarClass* klass) {
  GtkWidgetClass* widget_class = GTK_WIDGET_CLASS(klass);
  widget_class->get_preferred_width = mydia_no_titlebar_get_preferred_size;
  widget_class->get_preferred_height = mydia_no_titlebar_get_preferred_size;
  widget_class->get_preferred_width_for_height =
      mydia_no_titlebar_get_preferred_size_for;
  widget_class->get_preferred_height_for_width =
      mydia_no_titlebar_get_preferred_size_for;
}

static void mydia_no_titlebar_init(MydiaNoTitlebar* self) {
  gtk_widget_set_has_window(GTK_WIDGET(self), FALSE);
}

// Reads GTK's button layout, e.g. "appmenu:minimize,maximize,close".
//
// Caller owns the result. Returns nullptr when there is no default
// GtkSettings, which happens only if GTK failed to initialise; Dart falls
// back to its own default in that case.
static gchar* get_decoration_layout() {
  GtkSettings* settings = gtk_settings_get_default();
  if (settings == nullptr) {
    return nullptr;
  }
  gchar* layout = nullptr;
  g_object_get(settings, "gtk-decoration-layout", &layout, nullptr);
  return layout;
}

// Pushes the new layout to Dart so switching GTK themes reorders the window
// buttons without a restart.
static void decoration_layout_changed_cb(GtkSettings* settings,
                                         GParamSpec* pspec,
                                         gpointer user_data) {
  FlMethodChannel* channel = FL_METHOD_CHANNEL(user_data);
  g_autofree gchar* layout = get_decoration_layout();
  g_autoptr(FlValue) value = fl_value_new_string(layout != nullptr ? layout : "");
  fl_method_channel_invoke_method(channel, "onDecorationLayoutChanged", value,
                                  nullptr, nullptr, nullptr);
}

static void window_chrome_method_call_cb(FlMethodChannel* channel,
                                         FlMethodCall* method_call,
                                         gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "getDecorationLayout") == 0) {
    g_autofree gchar* layout = get_decoration_layout();
    g_autoptr(FlValue) result =
        fl_value_new_string(layout != nullptr ? layout : "");
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond on %s: %s", kWindowChromeChannel,
              error->message);
  }
}

// {maximized, tiled, fullscreen, solidFrame} for Dart. `tiled` is any of
// GTK's tiled flags: GNOME reports a half-screen snap through the per-edge
// ones. `solidFrame` needs `widget` (not just `state`): it reads GTK's own
// `.solid-csd` style class rather than re-deriving the decision.
//
// It is not simply `!gdk_screen_is_composited(screen)`: GTK's own
// gtk_window_supports_client_shadow() (gtkwindow.c) also requires the
// _GTK_FRAME_EXTENTS window-manager hint and an RGBA visual. Under XWayland
// behind a Wayland compositor without that hint, the screen reports
// composited but GTK still falls back to solid-csd, so the negated-composited
// check reported solidFrame=false on a window GTK was drawing as solid-csd.
// Reading the class GTK itself added tracks its real decision regardless of
// which of its criteria failed.
static FlValue* window_state_value(GdkWindowState state, GtkWidget* widget) {
  const GdkWindowState tiled_mask = static_cast<GdkWindowState>(
      GDK_WINDOW_STATE_TILED | GDK_WINDOW_STATE_TOP_TILED |
      GDK_WINDOW_STATE_RIGHT_TILED | GDK_WINDOW_STATE_BOTTOM_TILED |
      GDK_WINDOW_STATE_LEFT_TILED);
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(
      map, "maximized",
      fl_value_new_bool((state & GDK_WINDOW_STATE_MAXIMIZED) != 0));
  fl_value_set_string_take(map, "tiled",
                           fl_value_new_bool((state & tiled_mask) != 0));
  fl_value_set_string_take(
      map, "fullscreen",
      fl_value_new_bool((state & GDK_WINDOW_STATE_FULLSCREEN) != 0));
  fl_value_set_string_take(
      map, "solidFrame",
      fl_value_new_bool(gtk_style_context_has_class(
          gtk_widget_get_style_context(widget), "solid-csd")));
  return map;
}

static gboolean window_state_event_cb(GtkWidget* widget,
                                      GdkEventWindowState* event,
                                      gpointer user_data) {
  FlMethodChannel* channel = FL_METHOD_CHANNEL(user_data);
  g_autoptr(FlValue) value =
      window_state_value(event->new_window_state, widget);
  fl_method_channel_invoke_method(channel, "onWindowStateChanged", value,
                                  nullptr, nullptr, nullptr);
  return FALSE;
}

static void window_frame_method_call_cb(FlMethodChannel* channel,
                                        FlMethodCall* method_call,
                                        gpointer user_data) {
  GtkWidget* window = GTK_WIDGET(user_data);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(fl_method_call_get_name(method_call), "getWindowState") == 0) {
    // Not yet realized means not yet shown: report the floating state.
    GdkWindow* gdk_window = gtk_widget_get_window(window);
    GdkWindowState state = gdk_window != nullptr
                               ? gdk_window_get_state(gdk_window)
                               : static_cast<GdkWindowState>(0);
    g_autoptr(FlValue) result = window_state_value(state, window);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond on %s: %s", kWindowFrameChannel,
              error->message);
  }
}

// Fires when the screen gains or loses a compositor. `user_data` is the
// frame channel itself (see the "mydia-window" data below for why that is
// enough to also reach the window).
//
// GTK 3.24.52's own handler for this signal (gtk_window_on_composited_changed
// in gtkwindow.c) only queues a redraw and propagates "composited-changed"
// down the widget tree; it does not touch the "solid-csd"/"csd" style
// classes. Checked against the GTK source (`gtk-3.24.52.tar.xz` in the nix
// store) rather than assumed: GTK decides CSD vs solid-csd exactly once, in
// gtk_window_set_titlebar() (this app calls it before realizing the window),
// and never revisits it afterwards for a window that is already client
// decorated, which ours is from that first call. So this push is unlikely to
// ever carry a changed `solidFrame` in practice. Kept anyway as a cheap,
// harmless safety net -- Dart dedups identical pushes -- in case a future
// GTK version, or a code path this reading missed, does revisit it.
static void composited_changed_cb(GdkScreen* screen, gpointer user_data) {
  FlMethodChannel* channel = FL_METHOD_CHANNEL(user_data);
  GtkWidget* window =
      GTK_WIDGET(g_object_get_data(G_OBJECT(channel), "mydia-window"));
  GdkWindow* gdk_window = gtk_widget_get_window(window);
  GdkWindowState state = gdk_window != nullptr
                             ? gdk_window_get_state(gdk_window)
                             : static_cast<GdkWindowState>(0);
  g_autoptr(FlValue) value = window_state_value(state, window);
  fl_method_channel_invoke_method(channel, "onWindowStateChanged", value,
                                  nullptr, nullptr, nullptr);
}

// Fires on any style re-computation of the window's own style context
// (theme change, provider added, state change...). Same "cheap safety net"
// reasoning as composited_changed_cb above: nothing found while reading
// gtkwindow.c re-adds or removes "solid-csd" from here either, but a style
// pass is the closest thing to an event GTK fires near where such a change,
// if one ever happens, would show up.
static void style_updated_cb(GtkWidget* widget, gpointer user_data) {
  FlMethodChannel* channel = FL_METHOD_CHANNEL(user_data);
  GdkWindow* gdk_window = gtk_widget_get_window(widget);
  GdkWindowState state = gdk_window != nullptr
                             ? gdk_window_get_state(gdk_window)
                             : static_cast<GdkWindowState>(0);
  g_autoptr(FlValue) value = window_state_value(state, widget);
  fl_method_channel_invoke_method(channel, "onWindowStateChanged", value,
                                  nullptr, nullptr, nullptr);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Flutter draws its own buttons and drag band. See
  // `lib/presentation/widgets/window_chrome/desktop_window_chrome.dart`.
  //
  // The window stays client-side decorated with a titlebar that takes no
  // space (MydiaNoTitlebar, above), so GTK keeps the drop shadow, rounded
  // corners and resize borders while the Flutter view starts at the top
  // edge of the frame. Set at construction rather than from Dart so no
  // decorated frame flashes while the engine starts.
  GtkWidget* titlebar = GTK_WIDGET(g_object_new(mydia_no_titlebar_get_type(),
                                                nullptr));
  gtk_widget_show(titlebar);
  gtk_window_set_titlebar(window, titlebar);

  gtk_style_context_add_class(gtk_widget_get_style_context(GTK_WIDGET(window)),
                              "mydia-frame");
  g_autoptr(GtkCssProvider) frame_css = gtk_css_provider_new();
  gtk_css_provider_load_from_data(frame_css, kFrameCss, -1, nullptr);
  gtk_style_context_add_provider_for_screen(
      gtk_window_get_screen(window), GTK_STYLE_PROVIDER(frame_css),
      GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);

  // Set regardless of decoration, so alt-tab, window lists and taskbars
  // still have a name for this window.
  gtk_window_set_title(window, "Mydia Player");

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Transparent so the corners Flutter clips away (DesktopWindowChrome) show
  // GTK's rounded frame instead of square black pixels. Every screen paints
  // its own opaque background.
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->window_chrome_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kWindowChromeChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->window_chrome_channel, window_chrome_method_call_cb, self, nullptr);

  self->window_frame_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      kWindowFrameChannel, FL_METHOD_CODEC(codec));
  // The channel (owned by self) can outlive the activate() call's local
  // `window`, so the handler takes its own reference and releases it when
  // the channel replaces or drops the handler.
  fl_method_channel_set_method_call_handler(
      self->window_frame_channel, window_frame_method_call_cb,
      g_object_ref(window), g_object_unref);
  // A second, independent reference: composited_changed_cb needs to reach
  // the window from the signal's user_data, which is the channel (so the
  // signal's own lifetime, below, can tie to the channel like every other
  // signal here). g_object_set_data_full drops this ref when the channel is
  // finalized.
  g_object_set_data_full(G_OBJECT(self->window_frame_channel), "mydia-window",
                         g_object_ref(window), g_object_unref);
  // Tied to the channel's lifetime for the same reason as the
  // decoration-layout signal below.
  g_signal_connect_object(window, "window-state-event",
                          G_CALLBACK(window_state_event_cb),
                          self->window_frame_channel, G_CONNECT_DEFAULT);
  // Compositing can come and go without any GdkWindowState change (e.g. a
  // compositor crashing). See composited_changed_cb's comment for why this
  // is a safety net rather than a confirmed source of `solidFrame` changes.
  g_signal_connect_object(gtk_widget_get_screen(GTK_WIDGET(window)),
                          "composited-changed",
                          G_CALLBACK(composited_changed_cb),
                          self->window_frame_channel, G_CONNECT_DEFAULT);
  // Same safety-net reasoning as composited_changed_cb; see style_updated_cb.
  g_signal_connect_object(window, "style-updated",
                          G_CALLBACK(style_updated_cb),
                          self->window_frame_channel, G_CONNECT_DEFAULT);

  GtkSettings* settings = gtk_settings_get_default();
  if (settings != nullptr) {
    // g_signal_connect_object (not the plain g_signal_connect) ties the
    // signal's lifetime to window_chrome_channel: GLib disconnects it
    // automatically when the channel is finalized, so a notification firing
    // after my_application_dispose can't reach a dangling channel pointer.
    g_signal_connect_object(settings, "notify::gtk-decoration-layout",
                            G_CALLBACK(decoration_layout_changed_cb),
                            self->window_chrome_channel, G_CONNECT_DEFAULT);
  }

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->window_chrome_channel);
  g_clear_object(&self->window_frame_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
