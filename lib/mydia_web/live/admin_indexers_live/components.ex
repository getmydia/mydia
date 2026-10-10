defmodule MydiaWeb.AdminIndexersLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings
  alias MydiaWeb.AdminIndexersLive.FlareSolverrComponents
  alias MydiaWeb.IndexerComponents

  @doc """
  Renders the Indexers tab content.
  Shows both configured indexers (Prowlarr/Jackett) and enabled library indexers.
  """
  attr :indexers, :list, required: true
  attr :indexer_health, :map, required: true
  attr :library_indexers, :list, required: true
  attr :library_indexer_stats, :map, required: true
  attr :cardigann_enabled, :boolean, required: true
  attr :recently_disabled_indexer, :any, default: nil
  attr :flaresolverr, :map, default: %{enabled: false, url: nil, configured: false, env?: false}
  attr :flaresolverr_status, :map, default: %{configured: false, status: :loading}
  attr :retesting_paused, :any, default: MapSet.new()

  def indexers_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <FlareSolverrComponents.flaresolverr_row
        flaresolverr={@flaresolverr}
        flaresolverr_status={@flaresolverr_status}
      />

      <%= if @indexers == [] and @library_indexers == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No indexers configured yet. Add a Prowlarr/Jackett connection or browse the indexer library to get started.
          </span>
        </div>
      <% else %>
        <.admin_section
          :if={@indexers != []}
          id="indexer-connections-section"
          title="Indexer Connections"
          icon="hero-server"
          count={length(@indexers)}
        >
          <.admin_list id="indexer-connections" items={@indexers}>
            <:row :let={indexer}>
              <.indexer_row
                indexer={indexer}
                health={Map.get(@indexer_health, indexer.id, %{status: :unknown})}
                retesting={MapSet.member?(@retesting_paused, indexer.id)}
              />
            </:row>
            <:empty>No indexer connections.</:empty>
          </.admin_list>
        </.admin_section>

        <.admin_section
          :if={@library_indexers != [] or @recently_disabled_indexer}
          id="library-indexers-section"
          title="Library Indexers"
          icon="hero-book-open"
          count={length(@library_indexers)}
        >
          <div class="flex justify-end">
            <button
              id="add-more-library-indexers"
              phx-click="show_indexer_library"
              class="btn btn-xs btn-ghost text-primary"
              title="Browse and add more indexers from the library"
            >
              <.icon name="hero-plus" class="w-3 h-3" /> Add More
            </button>
          </div>
          <%!-- Undo Banner for Recently Disabled Indexer --%>
          <%= if @recently_disabled_indexer do %>
            <div id="undo-disabled-indexer" class="alert alert-warning shadow-sm">
              <.icon name="hero-arrow-uturn-left" class="w-5 h-5" />
              <span>
                <strong>{@recently_disabled_indexer.name}</strong> was disabled
              </span>
              <div class="flex gap-2">
                <button class="btn btn-sm btn-ghost" phx-click="undo_disable_library_indexer">
                  Undo
                </button>
                <button
                  class="btn btn-sm btn-ghost btn-circle"
                  phx-click="dismiss_undo_banner"
                  title="Dismiss"
                >
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
            </div>
          <% end %>
          <.admin_list id="library-indexers" items={@library_indexers}>
            <:row :let={indexer}>
              <.library_indexer_row
                indexer={indexer}
                flaresolverr_available={
                  @flaresolverr_status.configured and @flaresolverr_status.status != :disabled
                }
              />
            </:row>
            <:empty>No enabled library indexers.</:empty>
          </.admin_list>
        </.admin_section>
      <% end %>
    </div>
    """
  end

  attr :indexer, :any, required: true
  attr :health, :map, required: true
  attr :retesting, :boolean, default: false

  defp indexer_row(assigns) do
    assigns =
      assigns
      |> assign(:runtime?, Settings.runtime_config?(assigns.indexer))
      |> assign(:paused, paused_indexers(assigns.health))

    ~H"""
    <.admin_row id={"indexer-#{@indexer.id}"}>
      <:title>
        {@indexer.name}
        <.env_lock_badge :if={@runtime?} />
      </:title>
      <:descriptor><span class="font-mono">{@indexer.base_url}</span></:descriptor>
      <:details :if={@paused != []}>
        <div
          id={"indexer-paused-#{@indexer.id}"}
          class="flex flex-wrap items-center gap-2 text-warning"
        >
          <.icon name="hero-pause-circle" class="w-4 h-4 shrink-0" />
          <span>
            {IndexerComponents.paused_heading(length(@paused))}: {IndexerComponents.paused_list(
              @paused
            )}
          </span>
          <button
            type="button"
            id={"indexer-retest-paused-#{@indexer.id}"}
            class="btn btn-ghost btn-xs"
            phx-click="retest_paused"
            phx-value-id={@indexer.id}
            disabled={@retesting}
          >
            <span :if={@retesting} class="loading loading-spinner loading-xs"></span> Retest
          </button>
        </div>
      </:details>
      <:badges>
        <span class="badge badge-sm badge-outline">{format_indexer_type(@indexer.type)}</span>
        <span class={[
          "badge badge-sm badge-outline",
          if(@indexer.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @indexer.enabled, do: "Enabled", else: "Disabled"}
        </span>
        <span class={"badge badge-sm badge-outline #{health_status_badge_class(@health.status)}"}>
          <.icon name={health_status_icon(@health.status)} class="w-3 h-3 mr-1" />
          {health_status_label(@health.status)}
        </span>
        <%= if @health.status == :unhealthy and @health[:error] do %>
          <div class="tooltip tooltip-left" data-tip={@health.error}>
            <.icon name="hero-information-circle" class="w-4 h-4 text-error" />
          </div>
        <% end %>
        <%= if @health.status == :healthy and @health[:details] && Map.get(@health.details, :version) do %>
          <div class="tooltip tooltip-left" data-tip={"Version: #{@health.details.version}"}>
            <.icon name="hero-information-circle" class="w-4 h-4 text-success" />
          </div>
        <% end %>
        <%= if @health[:consecutive_failures] && @health.consecutive_failures > 0 do %>
          <div
            class="tooltip tooltip-left"
            data-tip={"#{@health.consecutive_failures} consecutive failures"}
          >
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
          </div>
        <% end %>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"test-indexer-#{@indexer.id}"}
            icon="hero-signal"
            title="Test Connection"
            phx-click="test_indexer"
            phx-value-id={@indexer.id}
          />
          <%!-- Edit stays enabled on env rows: it converts them to database-managed. --%>
          <.row_action
            id={"edit-indexer-#{@indexer.id}"}
            icon="hero-pencil"
            title={if @runtime?, do: "Convert to database-managed", else: "Edit"}
            phx-click="edit_indexer"
            phx-value-id={@indexer.id}
          />
          <.row_action
            id={"delete-indexer-#{@indexer.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@runtime?}
            disabled_reason={if(@runtime?, do: "Cannot delete runtime-configured indexers")}
            phx-click="delete_indexer"
            phx-value-id={@indexer.id}
            data-confirm="Are you sure you want to delete this indexer?"
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :indexer, :any, required: true
  attr :flaresolverr_available, :boolean, required: true

  defp library_indexer_row(assigns) do
    ~H"""
    <.admin_row id={"library-indexer-#{@indexer.id}"}>
      <:title>
        {@indexer.name}
        <span class={"badge badge-xs #{library_indexer_type_badge_class(@indexer.type)}"}>
          {@indexer.type}
        </span>
        <span :if={@indexer.language} class="badge badge-xs badge-ghost">{@indexer.language}</span>
      </:title>
      <:descriptor :if={@indexer.description}>{@indexer.description}</:descriptor>
      <:badges>
        <%= if @indexer.health_status not in [nil, "unknown"] do %>
          <span class={"badge badge-sm badge-outline #{library_health_status_badge_class(@indexer.health_status)}"}>
            {library_health_status_label(@indexer.health_status)}
          </span>
        <% end %>
        <%= if needs_library_config?(@indexer) do %>
          <div class="tooltip" data-tip="This indexer requires configuration">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning" />
          </div>
        <% end %>

        <%!-- Toggles, not actions: they stay inline beside the badges. --%>
        <div class="tooltip" data-tip={if @indexer.enabled, do: "Disable", else: "Enable"}>
          <input
            type="checkbox"
            class="toggle toggle-success toggle-sm"
            checked={@indexer.enabled}
            phx-click="toggle_library_indexer"
            phx-value-id={@indexer.id}
            aria-label={"#{if @indexer.enabled, do: "Disable", else: "Enable"} #{@indexer.name}"}
          />
        </div>

        <%= if @flaresolverr_available do %>
          <div
            class="tooltip tooltip-left"
            data-tip={
              if @indexer.flaresolverr_required,
                do: "Cloudflare bypass (recommended for this indexer)",
                else: "Enable Cloudflare bypass via FlareSolverr"
            }
          >
            <label class="flex items-center gap-1.5 cursor-pointer">
              <.icon
                name="hero-shield-check"
                class={"w-4 h-4 #{if(@indexer.flaresolverr_enabled, do: "text-warning", else: "text-base-content/30")}"}
              />
              <span class="text-xs text-base-content/60 hidden sm:inline">CF</span>
              <input
                type="checkbox"
                class={[
                  "toggle toggle-xs",
                  if(@indexer.flaresolverr_required, do: "toggle-warning", else: "toggle-info")
                ]}
                checked={@indexer.flaresolverr_enabled}
                phx-click="toggle_library_flaresolverr"
                phx-value-id={@indexer.id}
                aria-label={"#{if @indexer.flaresolverr_enabled, do: "Disable", else: "Enable"} Cloudflare bypass for #{@indexer.name}"}
              />
            </label>
          </div>
        <% end %>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"configure-library-indexer-#{@indexer.id}"}
            icon="hero-cog-6-tooth"
            title="Configure"
            phx-click="configure_library_indexer"
            phx-value-id={@indexer.id}
          />
          <.row_action
            id={"test-library-indexer-#{@indexer.id}"}
            icon="hero-signal"
            title="Test"
            phx-click="test_library_indexer"
            phx-value-id={@indexer.id}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  @doc "The page header's Add Indexer menu."
  attr :cardigann_enabled, :boolean, required: true
  attr :library_indexer_stats, :map, required: true

  def header_actions(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="btn btn-sm btn-primary">
        <.icon name="hero-plus" class="w-4 h-4" /> Add Indexer
        <.icon name="hero-chevron-down" class="w-3 h-3" />
      </div>
      <ul tabindex="0" class="dropdown-content z-[1] menu p-2 shadow bg-base-200 rounded-box w-64">
        <li>
          <button phx-click="new_indexer" class="flex items-start gap-3">
            <.icon name="hero-server" class="w-5 h-5 mt-0.5 opacity-60" />
            <div class="text-left">
              <div class="font-medium">Connect to Prowlarr/Jackett</div>
              <div class="text-xs text-base-content/60">
                Use an existing indexer aggregator
              </div>
            </div>
          </button>
        </li>
        <%= if @cardigann_enabled do %>
          <li>
            <button phx-click="show_indexer_library" class="flex items-start gap-3">
              <.icon name="hero-book-open" class="w-5 h-5 mt-0.5 opacity-60" />
              <div class="text-left">
                <div class="font-medium">Browse Indexer Library</div>
                <div class="text-xs text-base-content/60">
                  {@library_indexer_stats.total} indexers available
                </div>
              </div>
            </button>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  # Display helpers shared with the library modals (LibraryConfigComponents,
  # LibraryBrowserComponents).

  @doc false
  def library_indexer_type_badge_class("public"), do: "badge-success"
  def library_indexer_type_badge_class("private"), do: "badge-error"
  def library_indexer_type_badge_class("semi-private"), do: "badge-warning"
  def library_indexer_type_badge_class(_), do: "badge-ghost"

  @doc false
  def library_health_status_badge_class("healthy"), do: "badge-success"
  def library_health_status_badge_class("degraded"), do: "badge-warning"
  def library_health_status_badge_class("unhealthy"), do: "badge-error"
  def library_health_status_badge_class(_), do: "badge-ghost"

  @doc false
  def library_health_status_label("healthy"), do: "Healthy"
  def library_health_status_label("degraded"), do: "Degraded"
  def library_health_status_label("unhealthy"), do: "Unhealthy"
  def library_health_status_label(_), do: "Unknown"

  @doc false
  def needs_library_config?(%{type: "public"}), do: false

  def needs_library_config?(%{type: type, config: nil})
      when type in ["private", "semi-private"],
      do: true

  def needs_library_config?(%{type: type, config: config})
      when type in ["private", "semi-private"] and config == %{},
      do: true

  def needs_library_config?(_), do: false

  defp paused_indexers(health) do
    details = Map.get(health, :details) || %{}
    Map.get(details, :paused_indexers, [])
  end

  defp health_status_badge_class(:healthy), do: "badge-success"
  defp health_status_badge_class(:unhealthy), do: "badge-error"
  defp health_status_badge_class(:unknown), do: "badge-ghost"

  defp health_status_icon(:healthy), do: "hero-check-circle"
  defp health_status_icon(:unhealthy), do: "hero-x-circle"
  defp health_status_icon(:unknown), do: "hero-question-mark-circle"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:unhealthy), do: "Unhealthy"
  defp health_status_label(:unknown), do: "Unknown"

  defp format_indexer_type(type) when is_atom(type) do
    type |> to_string() |> String.capitalize()
  end

  defp format_indexer_type(type), do: to_string(type)
end
