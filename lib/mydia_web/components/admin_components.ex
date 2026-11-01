defmodule MydiaWeb.AdminComponents do
  @moduledoc """
  Admin chrome: the sidebar's Admin hub links (`admin_nav/1`), the header every
  admin page renders (`admin_page/1`), and the config source badge. The two
  navigation components read `MydiaWeb.AdminNav`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

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
          label: AdminNav.hub_label(hub.key),
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
  defp source_label(_source), do: gettext("Default")

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :eyebrow, :string, default: nil, doc: "small label above the title (the hub)"
  attr :count, :integer, default: nil, doc: "item count shown beside the title"
  slot :actions, doc: "header buttons, right-aligned from the md breakpoint up"

  @doc """
  A standalone page header: title, description, count and actions. For an admin
  page outside the `MydiaWeb.AdminNav` hubs (Import Lists); hub pages use
  `admin_page/1`, whose title is the hub.
  """
  def admin_header(assigns) do
    ~H"""
    <div
      id="admin-page-header"
      class="flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6"
    >
      <div>
        <p
          :if={@eyebrow}
          id="admin-page-hub"
          class="text-xs uppercase tracking-wide text-base-content/60"
        >
          {@eyebrow}
        </p>
        <h1 id="admin-page-title" class="text-3xl font-bold flex items-center gap-3">
          {@title}
          <span :if={@count} id="admin-page-count" class="badge badge-neutral">{@count}</span>
        </h1>
        <p :if={@description} id="admin-page-description" class="text-base-content/70 mt-1">
          {@description}
        </p>
      </div>
      <div :if={@actions != []} id="admin-page-actions" class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :page, :atom,
    required: true,
    values: AdminNav.keys(),
    doc: "the `MydiaWeb.AdminNav` key of the page, passed as a literal"

  attr :count, :integer, default: nil, doc: "item count shown beside the title"

  slot :actions, doc: "header buttons, right-aligned from the md breakpoint up"
  slot :inner_block, required: true

  @doc """
  The chrome every hub page renders: the hub as the `<h1>`, optional header
  actions, the hub's pages as lifted tabs (a lifted switcher tab below `xl`), and
  a bordered panel holding the page's description and body.

  Pass `page` as a literal (`<.admin_page page={:trash}>`) so a mistyped key
  fails the build.
  """
  def admin_page(assigns) do
    nav_page = AdminNav.fetch!(assigns.page)
    tabs = AdminNav.visible_pages(nav_page.hub)

    assigns =
      assign(assigns,
        nav_page: nav_page,
        hub_label: AdminNav.hub_label(nav_page.hub),
        tabs: tabs
      )

    ~H"""
    <%!-- relative z-[25] lifts header action menus (Export on Library Paths)
          over the tab strip (z-10) and the switcher (z-20) that follow it,
          while staying under the sticky mobile header (z-30). #1317 --%>
    <div
      id="admin-page-header"
      class="relative z-[25] flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6"
    >
      <h1 id="admin-page-title" class="text-3xl font-bold">{@hub_label}</h1>
      <div :if={@actions != []} id="admin-page-actions" class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>

    <%!-- Measured 2026-10-23: Configuration's nine tabs need 842px as labels and
          1080px with icons, against 960px beside the sidebar at xl and 1216px at
          2xl. Lifted tabs that wrap look broken, so the strip starts at xl and
          its icons at 2xl. The strip and the switcher both overlap the panel's top
          border by 1px (-mb-px), so the active tab's fill covers it and the inactive
          tabs' bottom borders coincide with it. --%>
    <nav
      id="admin-page-tabs"
      aria-label={gettext("%{hub} pages", hub: @hub_label)}
      class="tabs tabs-lift relative z-10 -mb-px max-xl:hidden"
    >
      <.link
        :for={tab <- @tabs}
        id={"admin-tab-#{tab.key}"}
        navigate={tab.path}
        aria-current={tab.key == @nav_page.key && "page"}
        class={["tab gap-1.5 whitespace-nowrap", tab.key == @nav_page.key && "tab-active"]}
      >
        <.icon name={tab.icon} class="size-4 hidden 2xl:inline-block" />
        {AdminNav.page_label(tab)}
        <span
          :if={@count && tab.key == @nav_page.key}
          id="admin-page-count"
          class="badge badge-sm tabular-nums"
        >
          {@count}
        </span>
      </.link>
    </nav>

    <%!-- Below xl the current page is one lifted tab that opens the hub's pages.
          A plain btn here blended into the page in every theme (#1188). --%>
    <nav
      id="admin-page-switcher"
      aria-label={gettext("%{hub} pages", hub: @hub_label)}
      class="flex xl:hidden"
    >
      <div class="dropdown z-20 -mb-px">
        <div
          id="admin-page-switcher-trigger"
          tabindex="0"
          role="button"
          class="flex items-center gap-2 h-10 px-4 font-medium cursor-pointer bg-base-100 border border-base-300 border-b-0 rounded-t-box focus-visible:outline-2 focus-visible:outline-primary"
        >
          <.icon name={@nav_page.icon} class="size-4" />
          {AdminNav.page_label(@nav_page)}
          <span :if={@count} id="admin-switcher-count" class="badge badge-sm tabular-nums">
            {@count}
          </span>
          <.icon name="hero-chevron-down" class="size-4 opacity-60" />
        </div>
        <ul
          tabindex="-1"
          class="dropdown-content menu w-64 mt-1 p-2 shadow-lg bg-base-200 border border-base-300 rounded-box"
        >
          <li :for={tab <- @tabs}>
            <.link
              id={"admin-switcher-#{tab.key}"}
              navigate={tab.path}
              aria-current={tab.key == @nav_page.key && "page"}
              class={[tab.key == @nav_page.key && "menu-active"]}
            >
              <.icon name={tab.icon} class="w-4 h-4 opacity-60" />
              {AdminNav.page_label(tab)}
            </.link>
          </li>
        </ul>
      </div>
    </nav>

    <div
      id="admin-page-body"
      class="bg-base-100 border border-base-300 rounded-box rounded-tl-none p-3 sm:p-4 xl:p-6 space-y-4"
    >
      <p id="admin-page-description" class="text-base-content/70">
        {AdminNav.page_description(@nav_page)}
      </p>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
