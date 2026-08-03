defmodule MydiaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MydiaWeb, :html

  alias MydiaWeb.FeedbackComponents

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

  Navigation counts (movie_count, tv_show_count, downloads_count, pending_requests_count)
  are automatically loaded by the :load_navigation_data on_mount hook in all authenticated LiveViews.
  Templates should pass these through to the layout component.

  ## Examples

      <Layouts.app {assigns}>
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

  attr :configured_library_types, :any,
    default: MapSet.new(),
    doc: "set of library types that have configured paths"

  attr :adult_count, :integer, default: 0, doc: "number of adult items in library"
  attr :music_count, :integer, default: 0, doc: "number of music albums in library"
  attr :books_count, :integer, default: 0, doc: "number of books in library"
  attr :executing_jobs, :list, default: [], doc: "list of currently executing background jobs"
  attr :feedback_enabled?, :boolean, default: false, doc: "whether to render feedback UI"
  attr :show_feedback_modal, :boolean, default: false, doc: "whether the feedback modal is open"
  attr :feedback_form, :any, default: nil, doc: "feedback form state"

  attr :changelog_notice, :map,
    default: nil,
    doc: "unread release notes, as %{version: String.t(), older_count: non_neg_integer()}"

  attr :current_path, :string,
    default: nil,
    doc: "the current request path for active nav highlighting"

  slot :inner_block, required: true

  def app(assigns) do
    # Navigation counts are loaded by the :load_navigation_data on_mount hook
    # in the LiveView session (see router.ex and user_auth.ex)

    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="main-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col">
        <!-- Mobile header with menu button -->
        <header class="lg:hidden sticky top-0 z-30 navbar bg-base-300/95 backdrop-blur border-b border-base-content/10">
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
        <main class="flex-1 p-3 sm:p-4 md:p-6 lg:p-8 pb-20 lg:pb-8">
          <div
            :if={@changelog_notice}
            id="changelog-banner"
            class="alert alert-info mb-4 sm:mb-6 flex flex-col sm:flex-row sm:items-center gap-3"
          >
            <div class="flex items-center gap-2 flex-1">
              <.icon name="hero-sparkles" class="w-5 h-5 shrink-0" />
              <span>
                New in Mydia v{@changelog_notice.version}
                <span :if={@changelog_notice.older_count > 0} class="opacity-70">
                  {earlier_releases_label(@changelog_notice.older_count)}
                </span>
              </span>
            </div>
            <div class="flex items-center gap-2">
              <.link navigate="/changelog" class="btn btn-sm btn-primary">
                See what's new
              </.link>
              <button
                id="changelog-dismiss"
                type="button"
                phx-click="dismiss_changelog"
                class="btn btn-sm btn-ghost btn-square"
                aria-label="Dismiss"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>
          {render_slot(@inner_block)}
        </main>
        <.mobile_dock current_user={@current_user} current_path={@current_path} />
      </div>

      <!-- Sidebar -->
      <div class="drawer-side z-40 min-h-screen">
        <label for="main-drawer" aria-label="close sidebar" class="drawer-overlay"></label>

        <aside class="flex flex-col w-64 min-h-full bg-base-300">
          <!-- Logo and branding -->
          <div class="p-4 border-b border-base-300">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <img src={~p"/images/logo.svg"} alt="Mydia" class="w-8 h-8" />
                <h1 class="text-2xl font-bold">Mydia</h1>
              </div>
              <a
                href="/player"
                class="btn btn-primary btn-sm gap-1.5 rounded-full shadow-sm hover:shadow-md transition-shadow"
                title="Open Player"
              >
                <.icon name="hero-play-solid" class="w-4 h-4" />
                <span class="text-sm font-semibold">Player</span>
              </a>
            </div>
          </div>

          <!-- Navigation menu -->
          <nav class="flex-1 overflow-y-auto">
            <ul class="menu w-full space-y-1 px-2 py-4">
              <li>
                <.link navigate="/" class={nav_active?(@current_path, "/", true) && "active"}>
                  <.icon name="hero-home" class="w-5 h-5" /> Dashboard
                </.link>
              </li>
              <li>
                <.link
                  navigate="/discover"
                  class={nav_active?(@current_path, "/discover", false) && "active"}
                >
                  <.icon name="hero-sparkles" class="w-5 h-5" /> Discover
                </.link>
              </li>
              <li>
                <.link
                  navigate="/movies"
                  class={nav_active?(@current_path, "/movies", false) && "active"}
                >
                  <.icon name="hero-film" class="w-5 h-5" /> Movies
                  <span class="badge badge-sm">{@movie_count}</span>
                </.link>
              </li>
              <li>
                <.link navigate="/tv" class={nav_active?(@current_path, "/tv", false) && "active"}>
                  <.icon name="hero-tv" class="w-5 h-5" /> TV Shows
                  <span class="badge badge-sm">{@tv_show_count}</span>
                </.link>
              </li>
              <%= if MapSet.member?(@configured_library_types, :music) do %>
                <li>
                  <.link
                    navigate="/music"
                    class={nav_active?(@current_path, "/music", false) && "active"}
                  >
                    <.icon name="hero-musical-note" class="w-5 h-5" /> Music
                    <span class="badge badge-sm">{@music_count}</span>
                  </.link>
                </li>
              <% end %>
              <%= if MapSet.member?(@configured_library_types, :books) do %>
                <li>
                  <.link
                    navigate="/books"
                    class={nav_active?(@current_path, "/books", false) && "active"}
                  >
                    <.icon name="hero-book-open" class="w-5 h-5" /> Books
                    <span class="badge badge-sm">{@books_count}</span>
                  </.link>
                </li>
              <% end %>
              <%= if MapSet.member?(@configured_library_types, :adult) do %>
                <li>
                  <.link
                    navigate="/adult"
                    class={nav_active?(@current_path, "/adult", false) && "active"}
                  >
                    <.icon name="hero-eye-slash" class="w-5 h-5" /> Adult
                    <span class="badge badge-sm">{@adult_count}</span>
                  </.link>
                </li>
              <% end %>

              <li class="menu-title mt-4">
                <span>Management</span>
              </li>

              <li>
                <.link
                  navigate="/downloads"
                  class={nav_active?(@current_path, "/downloads", false) && "active"}
                >
                  <.icon name="hero-arrow-down-tray" class="w-5 h-5" /> Downloads
                  <span class="badge badge-primary badge-sm">{@downloads_count}</span>
                </.link>
              </li>
              <li>
                <.link
                  navigate="/calendar"
                  class={nav_active?(@current_path, "/calendar", false) && "active"}
                >
                  <.icon name="hero-calendar" class="w-5 h-5" /> Calendar
                </.link>
              </li>
              <li>
                <.link
                  navigate="/search"
                  class={nav_active?(@current_path, "/search", false) && "active"}
                >
                  <.icon name="hero-magnifying-glass" class="w-5 h-5" /> Search
                </.link>
              </li>
              <li>
                <.link
                  navigate="/activity"
                  class={nav_active?(@current_path, "/activity", false) && "active"}
                >
                  <.icon name="hero-clock" class="w-5 h-5" /> Activity
                </.link>
              </li>
              <li>
                <.link
                  navigate="/collections"
                  class={nav_active?(@current_path, "/collections", false) && "active"}
                >
                  <.icon name="hero-folder" class="w-5 h-5" /> Collections
                </.link>
              </li>
              <li>
                <.link
                  navigate="/integrations"
                  class={nav_active?(@current_path, "/integrations", false) && "active"}
                >
                  <.icon name="hero-puzzle-piece" class="w-5 h-5" /> Integrations
                </.link>
              </li>
              <%= if @current_user && @current_user.role == "admin" do %>
                <li class="menu-title mt-4">
                  <span>Administration</span>
                </li>

                <li>
                  <.link
                    navigate="/admin/users"
                    class={nav_active?(@current_path, "/admin/users", false) && "active"}
                  >
                    <.icon name="hero-users" class="w-5 h-5" /> Users
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/admin/config"
                    class={nav_active?(@current_path, "/admin/config", false) && "active"}
                  >
                    <.icon name="hero-cog-6-tooth" class="w-5 h-5" /> Configuration
                  </.link>
                </li>
                <%= if Mydia.ImportLists.FeatureFlags.enabled?() do %>
                  <li>
                    <.link
                      navigate="/admin/import-lists"
                      class={nav_active?(@current_path, "/admin/import-lists", false) && "active"}
                    >
                      <.icon name="hero-arrow-down-on-square-stack" class="w-5 h-5" /> Import Lists
                    </.link>
                  </li>
                <% end %>
                <li>
                  <.link
                    navigate="/admin/jobs"
                    class={nav_active?(@current_path, "/admin/jobs", false) && "active"}
                  >
                    <.icon name="hero-queue-list" class="w-5 h-5" /> Background Jobs
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/admin/release-blacklist"
                    class={nav_active?(@current_path, "/admin/release-blacklist", false) && "active"}
                  >
                    <.icon name="hero-no-symbol" class="w-5 h-5" /> Release Blacklist
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/admin/requests"
                    class={nav_active?(@current_path, "/admin/requests", false) && "active"}
                  >
                    <.icon name="hero-inbox-stack" class="w-5 h-5" /> Requests
                    <%= if @pending_requests_count > 0 do %>
                      <span class="badge badge-primary badge-sm">{@pending_requests_count}</span>
                    <% end %>
                  </.link>
                </li>
              <% end %>

              <%= if @current_user && @current_user.role == "guest" do %>
                <li class="menu-title mt-4">
                  <span>Requests</span>
                </li>

                <li>
                  <.link
                    navigate="/request/movie"
                    class={nav_active?(@current_path, "/request/movie", false) && "active"}
                  >
                    <.icon name="hero-film" class="w-5 h-5" /> Request Movie
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/request/series"
                    class={nav_active?(@current_path, "/request/series", false) && "active"}
                  >
                    <.icon name="hero-tv" class="w-5 h-5" /> Request Series
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/requests"
                    class={nav_active?(@current_path, "/requests", true) && "active"}
                  >
                    <.icon name="hero-queue-list" class="w-5 h-5" /> My Requests
                  </.link>
                </li>
              <% end %>
            </ul>
          </nav>

          <!-- Running jobs status -->
          <%= if @executing_jobs != [] do %>
            <div class="px-4 py-2 border-t border-base-content/10">
              <div class="bg-base-200 rounded-lg p-2">
                <div class="flex items-center gap-2 text-sm font-medium mb-1">
                  <span class="loading loading-spinner loading-xs text-primary"></span>
                  <span>Running Jobs</span>
                  <span class="badge badge-primary badge-xs">{length(@executing_jobs)}</span>
                </div>
                <ul class="text-xs opacity-70 space-y-0.5 pl-5">
                  <%= for job <- Enum.take(@executing_jobs, 3) do %>
                    <li class="truncate">{job.worker_name}</li>
                  <% end %>
                  <%= if length(@executing_jobs) > 3 do %>
                    <li class="text-primary">+{length(@executing_jobs) - 3} more...</li>
                  <% end %>
                </ul>
              </div>
            </div>
          <% end %>

          <!-- User menu at bottom -->
          <div class="space-y-3 p-4 border-t border-base-300">
            <button
              :if={@feedback_enabled?}
              type="button"
              id="sidebar-send-feedback"
              phx-click="open_feedback_modal"
              class="btn btn-primary h-auto w-full justify-start gap-3 rounded-2xl px-4 py-4 text-left shadow-sm transition-all hover:-translate-y-0.5 hover:shadow-md"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-5 shrink-0" />
              <span class="min-w-0 flex-1">
                <span class="block text-sm font-semibold leading-tight">Send feedback</span>
                <span class="mt-1 block text-xs text-primary-content/80">
                  Report bugs, request features, or share ideas.
                </span>
              </span>
            </button>

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
                    <.icon name="hero-cog-6-tooth" class="w-4 h-4" /> Settings
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
            <div class="hidden lg:flex justify-center">
              <.theme_toggle id="theme-toggle-sidebar" />
            </div>
          </div>
        </aside>
      </div>
    </div>

    <FeedbackComponents.feedback_modal
      :if={@feedback_enabled? && @feedback_form}
      id="feedback-modal"
      form={@feedback_form}
      show={@show_feedback_modal}
    />

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
  attr :current_path, :string, default: nil, doc: "the current request path"

  def mobile_dock(assigns) do
    ~H"""
    <nav
      id="mobile-dock"
      phx-hook="DockNav"
      class={[
        "lg:hidden fixed z-50 left-3 right-3",
        "bottom-[calc(0.75rem+env(safe-area-inset-bottom,0px))]",
        "flex items-center justify-around",
        "rounded-2xl px-2 py-2",
        "bg-base-100/60 backdrop-blur-3xl backdrop-saturate-150",
        "border border-white/20",
        "shadow-[0_8px_32px_rgba(0,0,0,0.12),inset_0_1px_0_rgba(255,255,255,0.2)]"
      ]}
    >
      <div
        id="dock-indicator"
        class="fixed rounded-xl bg-primary/10 pointer-events-none transition-all duration-300 ease-in-out"
        style="opacity:0"
      >
      </div>

      <.dock_link path="/" current_path={@current_path} icon="hero-home" label="Home" exact />
      <.dock_link
        path="/discover"
        current_path={@current_path}
        icon="hero-sparkles"
        label="Discover"
      />

      <%= if @current_user && @current_user.role == "guest" do %>
        <.dock_link
          path="/request/movie"
          current_path={@current_path}
          icon="hero-film"
          label="Request"
        />
        <.dock_link
          path="/requests"
          current_path={@current_path}
          icon="hero-queue-list"
          label="Requests"
        />
      <% else %>
        <.dock_link
          path="/movies"
          current_path={@current_path}
          icon="hero-film"
          label="Movies"
        />
        <.dock_link path="/tv" current_path={@current_path} icon="hero-tv" label="TV" />
        <.dock_link
          path="/downloads"
          current_path={@current_path}
          icon="hero-arrow-down-tray"
          label="Downloads"
        />
        <a
          href="/player"
          data-dock-link
          class="flex flex-col items-center justify-center min-w-[52px] py-1.5 rounded-xl text-primary hover:bg-primary/10 transition-[color,opacity] duration-300 ease-in-out relative z-10"
        >
          <.icon name="hero-play-circle-solid" class="size-5" />
          <span class="text-[10px] mt-0.5 opacity-70">Player</span>
        </a>
      <% end %>
    </nav>
    """
  end

  attr :path, :string, required: true
  attr :current_path, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :exact, :boolean, default: false

  defp dock_link(assigns) do
    assigns =
      assign(assigns, :active?, nav_active?(assigns.current_path, assigns.path, assigns.exact))

    ~H"""
    <.link
      navigate={@path}
      data-dock-link
      data-active={@active? && "true"}
      class={[
        "flex flex-col items-center justify-center min-w-[52px] py-1.5 rounded-xl",
        "transition-[color,opacity] duration-300 ease-in-out relative z-10",
        if(@active?,
          do: "text-primary opacity-100",
          else: "opacity-50 hover:opacity-80"
        )
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span class="text-[10px] mt-0.5">{@label}</span>
    </.link>
    """
  end

  defp nav_active?(nil, _path, _exact), do: false
  defp nav_active?(current, path, true), do: current == path

  defp nav_active?(current, path, false),
    do: current == path || String.starts_with?(current, path <> "/")

  defp earlier_releases_label(1), do: "and 1 earlier release"
  defp earlier_releases_label(count), do: "and #{count} earlier releases"
end
