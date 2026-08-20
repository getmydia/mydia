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

  attr :active_tab, :atom, required: true

  defp tab_nav(assigns) do
    remote_access_enabled =
      Application.get_env(:mydia, :features, [])
      |> Keyword.get(:remote_access_enabled, false)

    assigns = assign(assigns, :remote_access_enabled, remote_access_enabled)

    ~H"""
    <div role="tablist" class="tabs tabs-border mb-6">
      <.tab_link
        active={@active_tab == :dashboard}
        to="/admin/dashboard"
        icon="hero-chart-bar"
      >
        Dashboard
      </.tab_link>
      <.tab_link active={@active_tab == :status} to="/admin/config/status" icon="hero-server">
        Status
      </.tab_link>
      <.tab_link
        active={@active_tab == :settings}
        to="/admin/config/settings"
        icon="hero-cog-6-tooth"
      >
        Settings
      </.tab_link>
      <.tab_link
        active={@active_tab == :quality}
        to="/admin/config/quality"
        icon="hero-sparkles"
      >
        Quality
      </.tab_link>
      <.tab_link
        active={@active_tab == :custom_formats}
        to="/admin/config/custom-formats"
        icon="hero-language"
      >
        Custom Formats
      </.tab_link>
      <.tab_link
        active={@active_tab == :clients}
        to="/admin/config/clients"
        icon="hero-arrow-down-tray"
      >
        Clients
      </.tab_link>
      <.tab_link
        active={@active_tab == :indexers}
        to="/admin/config/indexers"
        icon="hero-magnifying-glass"
      >
        Indexers
      </.tab_link>
      <.tab_link
        active={@active_tab == :library_paths}
        to="/admin/config/library-paths"
        icon="hero-folder"
      >
        Library
      </.tab_link>
      <.tab_link
        active={@active_tab == :prune}
        to="/admin/config/prune"
        icon="hero-document-duplicate"
      >
        Prune duplicates
      </.tab_link>
      <.tab_link
        active={@active_tab == :media_servers}
        to="/admin/config/media-servers"
        icon="hero-server-stack"
      >
        Media Servers
      </.tab_link>
      <.tab_link
        active={@active_tab == :plugins}
        to="/admin/config/plugins"
        icon="hero-puzzle-piece"
      >
        Plugins
      </.tab_link>
      <.tab_link
        active={@active_tab == :path_mappings}
        to="/admin/config/path-mappings"
        icon="hero-arrows-right-left"
      >
        Path Mappings
      </.tab_link>
      <%= if @remote_access_enabled do %>
        <.tab_link
          active={@active_tab == :remote_access}
          to="/admin/config/remote-access"
          icon="hero-signal"
        >
          Remote Access
        </.tab_link>
      <% end %>
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
