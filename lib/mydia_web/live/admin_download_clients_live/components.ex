defmodule MydiaWeb.AdminDownloadClientsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings

  @doc """
  Renders the Download Clients tab content.
  """
  attr :download_clients, :list, required: true
  attr :client_health, :map, required: true

  def download_clients_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.admin_list id="download-clients" items={@download_clients}>
        <:empty>
          No download clients configured yet. Add qBittorrent or Transmission to get started.
        </:empty>
        <:row :let={client}>
          <.download_client_row
            client={client}
            health={Map.get(@client_health, client.id, %{status: :unknown})}
            runtime?={Settings.runtime_config?(client)}
          />
        </:row>
      </.admin_list>
    </div>
    """
  end

  attr :client, :map, required: true
  attr :health, :map, required: true
  attr :runtime?, :boolean, required: true

  defp download_client_row(assigns) do
    ~H"""
    <.admin_row id={"download-client-#{@client.id}"}>
      <:title>
        {@client.name} <.env_lock_badge :if={@runtime?} />
      </:title>
      <:descriptor>
        <span class="font-mono">{endpoint_label(@client)}</span>
        <span :if={@client.category} class="ml-2">Category: {@client.category}</span>
        <%!-- Only when the operator changed it. :auto is the
              default and says nothing worth a row of chrome. --%>
        <span :if={@client.external_torrents && @client.external_torrents != :auto} class="ml-2">
          External: {@client.external_torrents}
        </span>
      </:descriptor>
      <:badges>
        <span class="badge badge-sm badge-outline">{@client.type}</span>
        <span
          :if={client_remote_fetch_enabled?(@client)}
          class="badge badge-sm badge-outline gap-1"
          title="Pulls completed torrents from a remote seedbox over SFTP"
        >
          <.icon name="hero-cloud-arrow-down" class="w-3 h-3" /> Seedbox
        </span>
        <span class={[
          "badge badge-sm",
          if(@client.enabled, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @client.enabled, do: "Enabled", else: "Disabled"}
        </span>
        <span class={"badge badge-sm #{health_status_badge_class(@health.status)}"}>
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
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"test-download-client-#{@client.id}"}
            icon="hero-signal"
            title="Test connection"
            phx-click="test_download_client"
            phx-value-id={@client.id}
          />
          <.row_action
            id={"edit-download-client-#{@client.id}"}
            icon="hero-pencil"
            title="Edit"
            disabled={@runtime?}
            disabled_reason={@runtime? && "Cannot edit runtime-configured clients"}
            phx-click="edit_download_client"
            phx-value-id={@client.id}
          />
          <.row_action
            id={"delete-download-client-#{@client.id}"}
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@runtime?}
            disabled_reason={@runtime? && "Cannot delete runtime-configured clients"}
            phx-click="confirm_delete_download_client"
            phx-value-id={@client.id}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button id="new-download-client" class="btn btn-sm btn-primary" phx-click="new_download_client">
      <.icon name="hero-plus" class="w-4 h-4" /> New
    </button>
    """
  end

  @doc """
  Renders the delete-confirmation modal for a download client, warning the
  operator how many downloads are still waiting on it.

  The count comes from `Mydia.Downloads.count_downloads_for_client/1` and
  excludes imported downloads, which keep their row as history and are
  untouched by the delete. The copy is hedged about where the rest end up
  because not all of them land in Issues: a row that is downloaded but not yet
  imported, or one that was never matched, never enters the missing handler
  that writes the Issues-tab error.
  """
  attr :client, :map, required: true
  attr :count, :integer, default: 0

  def delete_download_client_modal(assigns) do
    ~H"""
    <.admin_modal
      id="delete-download-client-modal"
      tone={:error}
      icon="hero-trash"
      title={"Delete '#{@client.name}'?"}
      on_close="close_delete_download_client_modal"
    >
      <p :if={@count > 0} class="py-2">
        {@count} {if @count == 1, do: "download is", else: "downloads are"} still waiting on
        this client. Deleting it will not stop them in the client itself, and the ones still
        in flight move to the Issues tab where you can clear them. If you re-add a client
        holding these same torrents, Mydia picks them back up automatically.
      </p>

      <p :if={@count == 0} class="py-2">
        No downloads are waiting on this client.
      </p>

      <:actions>
        <button
          id="cancel-delete-download-client"
          class="btn btn-ghost"
          phx-click="close_delete_download_client_modal"
        >
          Cancel
        </button>
        <button
          id="confirm-delete-download-client"
          class="btn btn-error"
          phx-click="delete_download_client"
          phx-disable-with="Deleting..."
        >
          Delete client
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp endpoint_label(%{type: :blackhole} = client) do
    get_in(client.connection_settings || %{}, ["watch_folder"]) || "No watch folder"
  end

  defp endpoint_label(%{type: :debrid} = client), do: debrid_provider_label(client)

  defp endpoint_label(client) do
    "#{if client.use_ssl, do: "https://", else: "http://"}#{client.host}:#{client.port}"
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

  # Renders a short summary string for a debrid client row in the list.
  # Surfaces the provider's human-readable label (e.g., "Real-Debrid"); the
  # debrid type itself isn't routed by host/port so the host/port fallback
  # used by other clients would render an empty "http://:" string.
  defp debrid_provider_label(client) do
    case get_in(client.connection_settings || %{}, ["provider"]) do
      provider when is_binary(provider) ->
        Mydia.Downloads.Client.Debrid.Provider.label_for(provider)

      _ ->
        "No provider"
    end
  end

  # Whether a client's saved connection_settings has remote_fetch enabled,
  # for the row-level "Seedbox" badge in the list. `enabled` is stored as
  # whatever the form submitted — HTML checkboxes send the string "true",
  # not the boolean — so both forms are accepted here, mirroring
  # `DownloadClientConfig.validate_remote_fetch_config/1`.
  defp client_remote_fetch_enabled?(client) do
    case get_in(client.connection_settings || %{}, ["remote_fetch", "enabled"]) do
      enabled when enabled in [true, "true"] -> true
      _ -> false
    end
  end
end
