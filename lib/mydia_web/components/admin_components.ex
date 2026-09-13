defmodule MydiaWeb.AdminComponents do
  @moduledoc """
  Admin chrome: the sidebar's Admin section (`admin_nav/1`), the header every
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
    doc: "the request path; picks the open hub and the active link"

  attr :pending_requests_count, :integer,
    default: 0,
    doc: "shown on the Administration hub and on Requests when above zero"

  @doc """
  The sidebar's Admin section: one collapsible group per `MydiaWeb.AdminNav` hub,
  listing the pages whose feature gate is on.

  The group holding the current page renders open and the others closed. Live
  navigation re-renders this from the server, so a group opened by hand closes
  again on the next page.
  """
  def admin_nav(assigns) do
    current = AdminNav.page_for_path(assigns.current_path)

    groups =
      for hub <- AdminNav.hubs() do
        Map.merge(hub, %{
          open?: not is_nil(current) and current.hub == hub.key,
          pages: AdminNav.visible_pages(hub.key)
        })
      end

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <li :for={group <- @groups}>
      <details id={"admin-nav-#{group.key}"} open={group.open?}>
        <summary>
          <.icon name={group.icon} class="w-5 h-5" /> {group.label}
          <span
            :if={group.key == :administration and @pending_requests_count > 0}
            class="badge badge-primary badge-sm"
          >
            {@pending_requests_count}
          </span>
        </summary>
        <ul>
          <li :for={page <- group.pages}>
            <.link
              id={"admin-nav-link-#{page.key}"}
              navigate={page.path}
              class={page.path == @current_path && "active"}
            >
              <.icon name={page.icon} class="w-5 h-5" /> {page.label}
              <span
                :if={page.key == :requests and @pending_requests_count > 0}
                class="badge badge-primary badge-sm"
              >
                {@pending_requests_count}
              </span>
            </.link>
          </li>
        </ul>
      </details>
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
  The header every admin page renders: its hub, its `<h1>` and its one-line
  description, all from `MydiaWeb.AdminNav`, plus optional header actions.

  Pass `page` as a literal (`<.admin_page page={:trash}>`) so a mistyped key
  fails the build.
  """
  def admin_page(assigns) do
    nav_page = AdminNav.fetch!(assigns.page)
    assigns = assign(assigns, nav_page: nav_page, hub_label: hub_label(nav_page.hub))

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

    <div class="bg-base-100">
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp hub_label(hub_key) do
    AdminNav.hubs()
    |> Enum.find(&(&1.key == hub_key))
    |> Map.fetch!(:label)
  end
end
