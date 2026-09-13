defmodule MydiaWeb.AdminComponents do
  @moduledoc """
  Admin chrome: the sidebar's Admin hub links (`admin_nav/1`), the header every
  admin page renders (`admin_page/1`), and the config source badge. The two
  navigation components read `MydiaWeb.AdminNav`.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: MydiaWeb.Endpoint,
    router: MydiaWeb.Router,
    statics: MydiaWeb.static_paths()

  alias MydiaWeb.AdminNav

  attr :current_path, :string,
    default: nil,
    doc: "the request path; picks the active hub"

  attr :pending_requests_count, :integer,
    default: 0,
    doc: "shown on the Administration hub when above zero"

  @doc """
  The sidebar's Admin section: one link per `MydiaWeb.AdminNav` hub, opening the
  hub's first page. The hub holding the current page is active. Pages within a
  hub are reached through the tab strip `admin_page/1` renders.
  """
  def admin_nav(assigns) do
    current = AdminNav.page_for_path(assigns.current_path)

    hubs =
      for hub <- AdminNav.hubs() do
        Map.merge(hub, %{
          active?: not is_nil(current) and current.hub == hub.key,
          path: AdminNav.hub_landing_path(hub.key)
        })
      end

    assigns = assign(assigns, :hubs, hubs)

    ~H"""
    <li :for={hub <- @hubs}>
      <.link id={"admin-nav-#{hub.key}"} navigate={hub.path} class={[hub.active? && "menu-active"]}>
        <.icon name={hub.icon} class="w-5 h-5" /> {hub.label}
        <span
          :if={hub.key == :administration and @pending_requests_count > 0}
          class="badge badge-primary badge-sm"
        >
          {@pending_requests_count}
        </span>
      </.link>
    </li>
    """
  end

  attr :source, :atom,
    required: true,
    doc: "where the value came from: :env, :database, :yaml or :default"

  attr :size, :string, default: "sm", values: ["sm", "xs"]

  @doc "The ENV / DB / YAML / Default badge beside a configurable value."
  def config_source_badge(assigns) do
    ~H"""
    <span class={["badge", badge_size(@size), source_class(@source)]}>{source_label(@source)}</span>
    """
  end

  defp badge_size("xs"), do: "badge-xs"
  defp badge_size(_size), do: "badge-sm"

  defp source_class(:env), do: "badge-info"
  defp source_class(:database), do: "badge-primary"
  defp source_class(:yaml), do: "badge-secondary"
  defp source_class(_source), do: "badge-ghost"

  defp source_label(:env), do: "ENV"
  defp source_label(:database), do: "DB"
  defp source_label(:yaml), do: "YAML"
  defp source_label(_source), do: "Default"

  attr :page, :atom,
    required: true,
    values: AdminNav.keys(),
    doc: "the `MydiaWeb.AdminNav` key of the page, passed as a literal"

  slot :actions, doc: "header buttons, right-aligned from the md breakpoint up"
  slot :inner_block, required: true

  @doc """
  The chrome every admin page renders: its hub, its `<h1>` and one-line
  description from `MydiaWeb.AdminNav`, optional header actions, and a tab
  strip of the hub's pages.

  Pass `page` as a literal (`<.admin_page page={:trash}>`) so a mistyped key
  fails the build.
  """
  def admin_page(assigns) do
    nav_page = AdminNav.fetch!(assigns.page)

    assigns =
      assign(assigns,
        nav_page: nav_page,
        hub_label: AdminNav.hub_label(nav_page.hub),
        tabs: AdminNav.visible_pages(nav_page.hub)
      )

    ~H"""
    <div
      id="admin-page-header"
      class="flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6"
    >
      <div>
        <p id="admin-page-hub" class="text-xs uppercase tracking-wide text-base-content/60">
          {@hub_label}
        </p>
        <h1 id="admin-page-title" class="text-3xl font-bold">{@nav_page.label}</h1>
        <p id="admin-page-description" class="text-base-content/70 mt-1">
          {@nav_page.description}
        </p>
      </div>
      <div :if={@actions != []} id="admin-page-actions" class="flex items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>

    <div
      id="admin-page-tabs"
      role="tablist"
      class="tabs tabs-border flex-nowrap overflow-x-auto mb-6"
    >
      <.link
        :for={tab <- @tabs}
        id={"admin-tab-#{tab.key}"}
        navigate={tab.path}
        role="tab"
        aria-selected={to_string(tab.key == @nav_page.key)}
        class={["tab whitespace-nowrap", tab.key == @nav_page.key && "tab-active"]}
      >
        {tab.label}
      </.link>
    </div>

    <div class="bg-base-100">
      {render_slot(@inner_block)}
    </div>
    """
  end
end
