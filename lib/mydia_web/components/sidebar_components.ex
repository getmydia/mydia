defmodule MydiaWeb.SidebarComponents do
  @moduledoc """
  The sidebar's building blocks: a nav link (`nav_item/1`), a section heading
  (`nav_title/1`), the admin running-jobs card (`running_jobs/1`) and the footer
  account chip (`account_menu/1`). `MydiaWeb.Layouts.app/1` composes them and
  decides which sections each role sees.

  Badges mean "needs attention" and render only above zero. Library totals are
  plain muted numbers, not badges.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  @doc """
  Whether `path` is the current page. With `exact` only the path itself counts;
  otherwise any sub-path does too, so `/movies/42` highlights Movies.
  """
  @spec nav_active?(String.t() | nil, String.t(), boolean()) :: boolean()
  def nav_active?(nil, _path, _exact), do: false
  def nav_active?(current, path, true), do: current == path

  def nav_active?(current, path, false),
    do: current == path || String.starts_with?(current, path <> "/")

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current_path, :string, default: nil
  attr :exact, :boolean, default: false, doc: "highlight only on the path itself"
  attr :id, :string, default: nil
  attr :badge, :integer, default: nil, doc: "needs-attention count, rendered only above 0"
  attr :badge_id, :string, default: nil
  attr :count, :integer, default: nil, doc: "informational total, rendered muted"
  attr :count_id, :string, default: nil

  @doc "One sidebar link."
  def nav_item(assigns) do
    ~H"""
    <li>
      <.link
        id={@id}
        navigate={@path}
        class={[nav_active?(@current_path, @path, @exact) && "menu-active"]}
      >
        <.icon name={@icon} class="w-5 h-5" />
        <span>{@label}</span>
        <span :if={@badge && @badge > 0} id={@badge_id} class="badge badge-primary badge-sm">
          {@badge}
        </span>
        <span :if={@count} id={@count_id} class="text-xs tabular-nums text-base-content/50">
          {@count}
        </span>
      </.link>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :action, doc: "a small control on the right of the heading"

  @doc "A sidebar section heading."
  def nav_title(assigns) do
    ~H"""
    <li id={@id} class="menu-title mt-4 flex flex-row items-center justify-between">
      <span>{@label}</span>
      {render_slot(@action)}
    </li>
    """
  end

  attr :executing_jobs, :list, required: true, doc: "maps with a :worker_name"

  @doc "The admin card listing jobs executing right now, linked to Background Jobs."
  def running_jobs(assigns) do
    ~H"""
    <div :if={@executing_jobs != []} class="px-4 py-2 border-t border-base-content/10">
      <.link
        id="sidebar-running-jobs"
        navigate={~p"/admin/jobs"}
        class="block bg-base-200 rounded-lg p-2 hover:bg-base-100 transition-colors"
      >
        <div class="flex items-center gap-2 text-sm font-medium mb-1">
          <span class="loading loading-spinner loading-xs text-primary"></span>
          <span>Running Jobs</span>
          <span class="badge badge-primary badge-xs">{length(@executing_jobs)}</span>
        </div>
        <ul class="text-xs opacity-70 space-y-0.5 pl-5">
          <li :for={job <- Enum.take(@executing_jobs, 3)} class="truncate">{job.worker_name}</li>
          <li :if={length(@executing_jobs) > 3} class="text-primary">
            +{length(@executing_jobs) - 3} more...
          </li>
        </ul>
      </.link>
    </div>
    """
  end

  attr :current_user, :map, required: true
  attr :current_path, :string, default: nil
  attr :feedback_enabled?, :boolean, default: false
  attr :changelog_notice, :map, default: nil, doc: "set while release notes are unread"

  @doc """
  The account chip pinned to the bottom of the sidebar. Its menu opens upward
  and holds the personal pages, the theme switcher, What's new, Send feedback
  and Log out.
  """
  def account_menu(assigns) do
    ~H"""
    <div
      id="sidebar-account"
      class="px-2 pt-2 pb-[calc(0.5rem+env(safe-area-inset-bottom,0px))] border-t border-base-content/10"
    >
      <div class="dropdown dropdown-top w-full">
        <div
          id="sidebar-user-menu"
          tabindex="0"
          role="button"
          aria-label="Account menu"
          class="btn btn-ghost w-full justify-start gap-3 h-auto py-2"
        >
          <div class="avatar avatar-placeholder">
            <div class="bg-neutral text-neutral-content rounded-full w-8 overflow-hidden">
              <img
                :if={@current_user.avatar_url}
                src={@current_user.avatar_url}
                alt="Avatar"
                class="w-full h-full object-cover"
              />
              <span :if={!@current_user.avatar_url} class="text-xs">
                {initials(@current_user)}
              </span>
            </div>
          </div>
          <div class="flex-1 min-w-0 text-left">
            <div class="text-sm font-medium truncate">{display_name(@current_user)}</div>
            <div class="text-xs opacity-60 capitalize">{@current_user.role}</div>
          </div>
          <.icon name="hero-chevron-up-down" class="w-4 h-4 opacity-60" />
        </div>

        <div
          tabindex="0"
          class="dropdown-content z-50 mb-2 w-full rounded-box bg-base-200 p-2 shadow-lg"
        >
          <div class="px-3 py-2">
            <div class="text-sm font-semibold truncate">{display_name(@current_user)}</div>
            <div :if={@current_user.email} class="text-xs text-base-content/60 truncate">
              {@current_user.email}
            </div>
          </div>

          <ul class="menu w-full p-0">
            <li>
              <.link
                id="user-menu-profile"
                navigate={~p"/profile"}
                class={[nav_active?(@current_path, "/profile", false) && "menu-active"]}
              >
                <.icon name="hero-user-circle" class="w-4 h-4" /> Profile
              </.link>
            </li>
            <li>
              <.link
                id="user-menu-integrations"
                navigate={~p"/integrations"}
                class={[nav_active?(@current_path, "/integrations", false) && "menu-active"]}
              >
                <.icon name="hero-puzzle-piece" class="w-4 h-4" /> Integrations
              </.link>
            </li>
            <li :if={Mydia.Player.enabled?()}>
              <.link
                id="user-menu-devices"
                navigate={~p"/devices"}
                class={[nav_active?(@current_path, "/devices", false) && "menu-active"]}
              >
                <.icon name="hero-device-phone-mobile" class="w-4 h-4" /> Devices
              </.link>
            </li>
          </ul>

          <div class="my-1 border-t border-base-content/10"></div>

          <div class="flex items-center justify-between gap-2 px-3 py-1.5">
            <span class="text-sm">Theme</span>
            <MydiaWeb.Layouts.theme_toggle id="theme-toggle-account" />
          </div>

          <ul class="menu w-full p-0">
            <li>
              <.link id="user-menu-changelog" navigate={~p"/changelog"}>
                <.icon name="hero-sparkles" class="w-4 h-4" /> What's new
                <span :if={@changelog_notice} class="badge badge-primary badge-xs">New</span>
              </.link>
            </li>
            <li :if={@feedback_enabled?}>
              <button type="button" id="user-menu-feedback" phx-click="open_feedback_modal">
                <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> Send feedback
              </button>
            </li>
          </ul>

          <div class="my-1 border-t border-base-content/10"></div>

          <ul class="menu w-full p-0">
            <li>
              <a href="/auth/logout" class="text-error">
                <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4" /> Log out
              </a>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp display_name(user), do: Mydia.Accounts.User.label(user)

  defp initials(user) do
    user
    |> display_name()
    |> String.slice(0..1)
    |> String.upcase()
  end
end
