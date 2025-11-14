defmodule MydiaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MydiaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app
        flash={@flash}
        movie_count={@movie_count}
        tv_show_count={@tv_show_count}
        downloads_count={@downloads_count}
        pending_requests_count={@pending_requests_count}
      >
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_user, :map, default: nil, doc: "the currently authenticated user"
  attr :movie_count, :integer, default: 0, doc: "number of movies in library"
  attr :tv_show_count, :integer, default: 0, doc: "number of TV shows in library"
  attr :downloads_count, :integer, default: 0, doc: "number of active downloads"
  attr :pending_requests_count, :integer, default: 0, doc: "number of pending requests"

  slot :inner_block, required: true

  def app(assigns) do
    # Navigation counts are loaded by the :load_navigation_data on_mount hook
    # in the LiveView session (see router.ex and user_auth.ex) and passed as attributes
    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="main-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col">
        <!-- Mobile header with menu button -->
        <header class="lg:hidden navbar bg-base-300 border-b border-base-content/10">
          <div class="flex-none">
            <label for="main-drawer" class="btn btn-square btn-ghost">
              <.icon name="hero-bars-3" class="w-6 h-6" />
            </label>
          </div>
          <div class="flex-1">
            <h1 class="text-xl font-bold">Mydia</h1>
          </div>
          <div class="flex-none">
            <.theme_toggle />
          </div>
        </header>
        
    <!-- Main content area -->
        <main class="flex-1 overflow-y-auto p-3 sm:p-4 md:p-6 lg:p-8 pb-20 lg:pb-8">
          {render_slot(@inner_block)}
        </main>
        
    <!-- Mobile dock navigation -->
        <.mobile_dock current_user={@current_user} />
      </div>
      
    <!-- Sidebar -->
      <div class="drawer-side z-40 min-h-screen">
        <label for="main-drawer" aria-label="close sidebar" class="drawer-overlay"></label>

        <aside class="flex flex-col w-64 min-h-full bg-base-300">
          <!-- Logo and branding -->
          <div class="p-4 border-b border-base-300">
            <div class="flex items-center gap-2">
              <.icon name="hero-film" class="w-8 h-8 text-primary" />
              <h1 class="text-2xl font-bold">Mydia</h1>
            </div>
          </div>
          
    <!-- Navigation menu -->
          <nav class="flex-1 overflow-y-auto">
            <ul class="menu w-full space-y-1 px-2 py-4">
              <li>
                <a href="/" class="active">
                  <.icon name="hero-home" class="w-5 h-5" /> Dashboard
                </a>
              </li>
              <li>
                <a href="/movies">
                  <.icon name="hero-film" class="w-5 h-5" /> Movies
                  <span class="badge badge-sm">{@movie_count}</span>
                </a>
              </li>
              <li>
                <a href="/tv">
                  <.icon name="hero-tv" class="w-5 h-5" /> TV Shows
                  <span class="badge badge-sm">{@tv_show_count}</span>
                </a>
              </li>

              <li class="menu-title mt-4">
                <span>Management</span>
              </li>

              <li>
                <a href="/downloads">
                  <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Downloads
                  <span class="badge badge-primary badge-sm">{@downloads_count}</span>
                </a>
              </li>
              <li>
                <a href="/calendar">
                  <.icon name="hero-calendar" class="w-5 h-5" /> Calendar
                </a>
              </li>
              <li>
                <a href="/search">
                  <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Search
                </a>
              </li>
              <li>
                <a href="/activity">
                  <.icon name="hero-clock" class="w-5 h-5" /> Activity
                </a>
              </li>

              <%= if @current_user && @current_user.role == "admin" do %>
                <li class="menu-title mt-4">
                  <span>Administration</span>
                </li>

                <li>
                  <a href="/admin">
                    <.icon name="hero-server" class="w-5 h-5" /> System Status
                  </a>
                </li>
                <li>
                  <a href="/admin/users">
                    <.icon name="hero-users" class="w-5 h-5" /> Users
                  </a>
                </li>
                <li>
                  <a href="/admin/config">
                    <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> Configuration
                  </a>
                </li>
                <li>
                  <a href="/admin/jobs">
                    <.icon name="hero-queue-list" class="w-5 h-5" /> Background Jobs
                  </a>
                </li>
                <li>
                  <a href="/admin/requests">
                    <.icon name="hero-inbox-stack" class="w-5 h-5" /> Requests
                    <%= if @pending_requests_count > 0 do %>
                      <span class="badge badge-primary badge-sm">{@pending_requests_count}</span>
                    <% end %>
                  </a>
                </li>
              <% end %>

              <%= if @current_user && @current_user.role == "guest" do %>
                <li class="menu-title mt-4">
                  <span>Requests</span>
                </li>

                <li>
                  <a href="/request/movie">
                    <.icon name="hero-film" class="w-5 h-5" /> Request Movie
                  </a>
                </li>
                <li>
                  <a href="/request/series">
                    <.icon name="hero-tv" class="w-5 h-5" /> Request Series
                  </a>
                </li>
                <li>
                  <a href="/requests">
                    <.icon name="hero-queue-list" class="w-5 h-5" /> My Requests
                  </a>
                </li>
              <% end %>
            </ul>
          </nav>
          
    <!-- User menu at bottom -->
          <div class="p-4 border-t border-base-300">
            <div class="dropdown dropdown-top dropdown-end w-full">
              <label tabindex="0" class="btn btn-ghost w-full justify-start">
                <div class="avatar placeholder">
                  <div class="bg-neutral text-neutral-content rounded-full w-8">
                    <span class="text-xs">
                      <%= if @current_user do %>
                        {String.upcase(
                          String.slice(@current_user.username || @current_user.email || "U", 0..1)
                        )}
                      <% else %>
                        U
                      <% end %>
                    </span>
                  </div>
                </div>
                <div class="flex-1 text-left">
                  <%= if @current_user do %>
                    <div class="text-sm font-medium">
                      {@current_user.username || @current_user.email}
                    </div>
                    <div class="text-xs opacity-60 capitalize">{@current_user.role}</div>
                  <% else %>
                    <span>Guest</span>
                  <% end %>
                </div>
                <.icon name="hero-chevron-up" class="w-4 h-4" />
              </label>
              <ul
                tabindex="0"
                class="dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52 mb-2"
              >
                <li>
                  <a href="/profile">
                    <.icon name="hero-user" class="w-4 h-4" /> Profile
                  </a>
                </li>
                <li>
                  <a href="/preferences">
                    <.icon name="hero-adjustments-horizontal" class="w-4 h-4" /> Preferences
                  </a>
                </li>
                <li class="mt-2 border-t border-base-300 pt-2">
                  <a href="/auth/logout" class="text-error">
                    <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" /> Logout
                  </a>
                </li>
              </ul>
            </div>
            
    <!-- Theme toggle (desktop only) -->
            <div class="hidden lg:flex mt-2 justify-center">
              <.theme_toggle id="theme-toggle-sidebar" />
            </div>
          </div>
        </aside>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  attr :id, :string, default: "theme-toggle"

  def theme_toggle(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
      phx-hook="ThemeToggle"
    >
      <div
        class="theme-indicator absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-[left] duration-200"
        style="left: 0"
      />

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center z-10"
        onclick="window.mydiaTheme.setTheme(window.mydiaTheme.THEMES.SYSTEM)"
        title="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center z-10"
        onclick="window.mydiaTheme.setTheme(window.mydiaTheme.THEMES.LIGHT)"
        title="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative flex p-2 cursor-pointer w-1/3 justify-center z-10"
        onclick="window.mydiaTheme.setTheme(window.mydiaTheme.THEMES.DARK)"
        title="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  @doc """
  Mobile navigation dock that appears at the bottom of the screen on mobile devices.

  Provides quick access to primary navigation items with smooth transitions.
  Hidden on desktop/tablet screen sizes.
  """
  attr :current_user, :map, default: nil, doc: "the currently authenticated user"

  def mobile_dock(assigns) do
    ~H"""
    <nav
      id="mobile-dock"
      class="lg:hidden fixed bottom-0 left-0 right-0 z-50 transition-transform duration-300 ease-in-out"
    >
      <div class="backdrop-blur-md bg-base-200/90 border-t border-base-300 shadow-lg">
        <div class="flex justify-around items-center px-2 py-3">
          <.link
            navigate="/"
            class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
          >
            <.icon name="hero-home" class="w-6 h-6" />
            <span class="text-xs mt-1">Home</span>
          </.link>

          <%= if @current_user && @current_user.role == "guest" do %>
            <%!-- Guest users see request options --%>
            <.link
              navigate="/request/movie"
              class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-film" class="w-6 h-6" />
              <span class="text-xs mt-1">Request</span>
            </.link>

            <.link
              navigate="/requests"
              class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-queue-list" class="w-6 h-6" />
              <span class="text-xs mt-1">Requests</span>
            </.link>
          <% else %>
            <%!-- Admin users see library navigation --%>
            <.link
              navigate="/movies"
              class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-film" class="w-6 h-6" />
              <span class="text-xs mt-1">Movies</span>
            </.link>

            <.link
              navigate="/tv"
              class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-tv" class="w-6 h-6" />
              <span class="text-xs mt-1">TV</span>
            </.link>

            <.link
              navigate="/downloads"
              class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-arrow-down-tray" class="w-6 h-6" />
              <span class="text-xs mt-1">Downloads</span>
            </.link>
          <% end %>

          <.link
            navigate="/activity"
            class="flex flex-col items-center justify-center min-w-[60px] min-h-[60px] rounded-lg hover:bg-base-300 transition-colors"
          >
            <.icon name="hero-clock" class="w-6 h-6" />
            <span class="text-xs mt-1">Activity</span>
          </.link>
        </div>
      </div>
    </nav>
    """
  end
end
