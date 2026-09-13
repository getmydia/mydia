defmodule MydiaWeb.AdminComponents do
  @moduledoc """
  Shared components for admin configuration pages.
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

  attr :active_tab, :atom, required: true

  defp tab_nav(assigns) do
    assigns = assign(assigns, :player_enabled, Mydia.Player.enabled?())

    ~H"""
    <div role="tablist" class="tabs tabs-border mb-6">
      <%= if @player_enabled do %>
        <.tab_link
          active={@active_tab == :dashboard}
          to="/admin/dashboard"
          icon="hero-chart-bar"
        >
          Dashboard
        </.tab_link>
      <% end %>
      <.tab_link active={@active_tab == :status} to="/admin/status" icon="hero-server">
        Status
      </.tab_link>
      <.tab_link
        active={@active_tab == :settings}
        to="/admin/settings"
        icon="hero-cog-6-tooth"
      >
        Settings
      </.tab_link>
      <.tab_link
        active={@active_tab == :quality}
        to="/admin/quality"
        icon="hero-sparkles"
      >
        Quality
      </.tab_link>
      <.tab_link
        active={@active_tab == :custom_formats}
        to="/admin/custom-formats"
        icon="hero-language"
      >
        Custom Formats
      </.tab_link>
      <.tab_link
        active={@active_tab == :clients}
        to="/admin/clients"
        icon="hero-arrow-down-tray"
      >
        Clients
      </.tab_link>
      <.tab_link
        active={@active_tab == :indexers}
        to="/admin/indexers"
        icon="hero-magnifying-glass"
      >
        Indexers
      </.tab_link>
      <.tab_link
        active={@active_tab == :library_paths}
        to="/admin/library-paths"
        icon="hero-folder"
      >
        Library
      </.tab_link>
      <.tab_link
        active={@active_tab == :duplicates}
        to="/admin/duplicates"
        icon="hero-document-duplicate"
      >
        Duplicates
      </.tab_link>
      <.tab_link
        active={@active_tab == :trash}
        to="/admin/trash"
        icon="hero-trash"
      >
        Trash
      </.tab_link>
      <.tab_link
        active={@active_tab == :media_servers}
        to="/admin/media-servers"
        icon="hero-server-stack"
      >
        Media Servers
      </.tab_link>
      <.tab_link
        active={@active_tab == :plugins}
        to="/admin/plugins"
        icon="hero-puzzle-piece"
      >
        Plugins
      </.tab_link>
      <.tab_link
        active={@active_tab == :path_mappings}
        to="/admin/path-mappings"
        icon="hero-arrows-right-left"
      >
        Path Mappings
      </.tab_link>
      <%= if @player_enabled do %>
        <.tab_link
          active={@active_tab == :remote_access}
          to="/admin/remote-access"
          icon="hero-signal"
        >
          Remote Access
        </.tab_link>
      <% end %>
      <.tab_link active={@active_tab == :api_keys} to="/admin/api-keys" icon="hero-key">
        API Keys
      </.tab_link>
    </div>
    """
  end

  attr :active_tab, :atom, required: true
  slot :inner_block, required: true

  def admin_page(assigns) do
    ~H"""
    <div class="flex flex-col md:flex-row md:items-center md:justify-between gap-4 mb-6">
      <div>
        <h1 class="text-3xl font-bold">Configuration</h1>
        <p class="text-base-content/70 mt-1">
          System status, application settings, and configuration management
        </p>
      </div>
    </div>

    <.tab_nav active_tab={@active_tab} />

    <div class="bg-base-100">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :active, :boolean, required: true
  attr :to, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link navigate={@to} role="tab" class={["tab gap-2", @active && "tab-active"]}>
      <.icon name={@icon} class="w-4 h-4" />{render_slot(@inner_block)}
    </.link>
    """
  end
end
