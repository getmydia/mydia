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
        active={@active_tab == :duplicates}
        to="/admin/config/duplicates"
        icon="hero-document-duplicate"
      >
        Duplicates
      </.tab_link>
      <.tab_link
        active={@active_tab == :trash}
        to="/admin/config/trash"
        icon="hero-trash"
      >
        Trash
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
      <%= if @player_enabled do %>
        <.tab_link
          active={@active_tab == :remote_access}
          to="/admin/config/remote-access"
          icon="hero-signal"
        >
          Remote Access
        </.tab_link>
      <% end %>
      <.tab_link active={@active_tab == :api_keys} to="/admin/config/api-keys" icon="hero-key">
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
