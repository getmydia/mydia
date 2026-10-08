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
      <%= if @download_clients == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            No download clients configured yet. Add qBittorrent or Transmission to get started.
          </span>
        </div>
      <% else %>
        <div class="bg-base-200 rounded-box divide-y divide-base-300">
          <%= for client <- @download_clients do %>
            <% health = Map.get(@client_health, client.id, %{status: :unknown}) %>
            <% is_runtime = Settings.runtime_config?(client) %>

            <div class="p-3 sm:p-4">
              <%!-- Mobile: stacked, Desktop: flex row --%>
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <%!-- Client Info --%>
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2 flex-wrap">
                    {client.name}
                    <%= if is_runtime do %>
                      <span
                        class="badge badge-primary badge-xs tooltip"
                        data-tip="Configured via environment variables (read-only)"
                      >
                        <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
                      </span>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-60 mt-1 truncate">
                    <span class="font-mono">
                      <%= cond do %>
                        <% client.type == :blackhole -> %>
                          {get_in(client.connection_settings || %{}, ["watch_folder"]) ||
                            "No watch folder"}
                        <% client.type == :debrid -> %>
                          {debrid_provider_label(client)}
                        <% true -> %>
                          {if client.use_ssl, do: "https://", else: "http://"}{client.host}:{client.port}
                      <% end %>
                    </span>
                    <%= if client.category do %>
                      <span class="ml-2">Category: {client.category}</span>
                    <% end %>
                    <%!-- Only when the operator changed it. :auto is the
                          default and says nothing worth a row of chrome. --%>
                    <%= if client.external_torrents && client.external_torrents != :auto do %>
                      <span class="ml-2">External: {client.external_torrents}</span>
                    <% end %>
                  </div>
                </div>

                <%!-- Status Badges + Actions row --%>
                <div class="flex flex-wrap items-center gap-2">
                  <%!-- Status Badges --%>
                  <span class="badge badge-sm badge-outline">{client.type}</span>
                  <span
                    :if={client_remote_fetch_enabled?(client)}
                    class="badge badge-sm badge-outline gap-1"
                    title="Pulls completed torrents from a remote seedbox over SFTP"
                  >
                    <.icon name="hero-cloud-arrow-down" class="w-3 h-3" /> Seedbox
                  </span>
                  <span class={[
                    "badge badge-sm",
                    if(client.enabled, do: "badge-success", else: "badge-ghost")
                  ]}>
                    {if client.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                  <span class={"badge badge-sm #{health_status_badge_class(health.status)}"}>
                    <.icon name={health_status_icon(health.status)} class="w-3 h-3 mr-1" />
                    {health_status_label(health.status)}
                  </span>
                  <%= if health.status == :unhealthy and health[:error] do %>
                    <div class="tooltip tooltip-left" data-tip={health.error}>
                      <.icon name="hero-information-circle" class="w-4 h-4 text-error" />
                    </div>
                  <% end %>
                  <%= if health.status == :healthy and health[:details] && Map.get(health.details, :version) do %>
                    <div
                      class="tooltip tooltip-left"
                      data-tip={"Version: #{health.details.version}"}
                    >
                      <.icon name="hero-information-circle" class="w-4 h-4 text-success" />
                    </div>
                  <% end %>

                  <%!-- Actions --%>
                  <div class="join ml-auto sm:ml-2">
                    <button
                      class="btn btn-sm btn-ghost join-item"
                      phx-click="test_download_client"
                      phx-value-id={client.id}
                      title="Test Connection"
                    >
                      <.icon name="hero-signal" class="w-4 h-4" />
                    </button>
                    <%= if is_runtime do %>
                      <div class="tooltip" data-tip="Cannot edit runtime-configured clients">
                        <button class="btn btn-sm btn-ghost join-item" disabled>
                          <.icon name="hero-pencil" class="w-4 h-4 opacity-30" />
                        </button>
                      </div>
                      <div class="tooltip" data-tip="Cannot delete runtime-configured clients">
                        <button class="btn btn-sm btn-ghost join-item" disabled>
                          <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                        </button>
                      </div>
                    <% else %>
                      <button
                        class="btn btn-sm btn-ghost join-item"
                        phx-click="edit_download_client"
                        phx-value-id={client.id}
                        title="Edit"
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        id={"delete-download-client-#{client.id}"}
                        class="btn btn-sm btn-ghost join-item text-error"
                        phx-click="confirm_delete_download_client"
                        phx-value-id={client.id}
                        title="Delete"
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc "The page header's New button."
  def header_actions(assigns) do
    ~H"""
    <button class="btn btn-sm btn-primary" phx-click="new_download_client">
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
  attr :client, :map, default: nil
  attr :count, :integer, default: 0

  def delete_download_client_modal(assigns) do
    ~H"""
    <div :if={@client} id="delete-download-client-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Delete '{@client.name}'?</h3>

        <p :if={@count > 0} class="py-2">
          {@count} {if @count == 1, do: "download is", else: "downloads are"} still waiting on
          this client. Deleting it will not stop them in the client itself, and the ones still
          in flight move to the Issues tab where you can clear them. If you re-add a client
          holding these same torrents, Mydia picks them back up automatically.
        </p>

        <p :if={@count == 0} class="py-2">
          No downloads are waiting on this client.
        </p>

        <div class="modal-action">
          <button
            id="cancel-delete-download-client"
            class="btn btn-ghost"
            phx-click="cancel_delete_download_client"
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
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_delete_download_client"></div>
    </div>
    """
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

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
