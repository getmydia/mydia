defmodule Mydia.MediaServer.Notifier do
  @moduledoc """
  Handles notifications to native media servers (Jellyfin) after successful imports.
  Plugin media servers react to the media_file.imported event instead.

  This module is responsible for notifying all enabled media servers to scan
  their libraries when new content has been imported into the library.

  Notifications are fire-and-forget (async) to avoid blocking the import process.
  """

  require Logger

  alias Mydia.Settings
  alias Mydia.MediaServer.Client

  @doc """
  Notify all enabled media servers to scan their libraries.

  This function is fire-and-forget - it spawns async tasks to notify each
  media server and does not wait for results. Failures are logged but do
  not affect the calling process.

  ## Options

  - `:path` - Optional path hint for the media server (if supported)

  ## Examples

      # Basic notification after import
      Mydia.MediaServer.Notifier.notify_all()

      # With path hint
      Mydia.MediaServer.Notifier.notify_all(path: "/media/movies/Inception (2010)")

  """
  @spec notify_all(keyword()) :: :ok
  def notify_all(opts \\ []) do
    media_servers = Settings.list_media_server_configs()

    enabled_servers = Enum.filter(media_servers, & &1.enabled)

    if enabled_servers == [] do
      Logger.debug("No enabled media servers to notify")
    else
      Logger.info("Notifying #{length(enabled_servers)} media server(s) to refresh libraries")

      # Spawn async tasks for each server - fire and forget
      Enum.each(enabled_servers, fn server ->
        Task.start(fn ->
          notify_server(server, opts)
        end)
      end)
    end

    :ok
  end

  @doc """
  Notify a specific media server to scan its library.

  Returns `:ok` on success, `{:error, reason}` on failure.
  """
  @spec notify_server(struct(), keyword()) :: :ok | {:error, term()}
  def notify_server(server, opts \\ []) do
    adapter = Client.adapter_for(server)

    Logger.debug("Notifying media server",
      server_name: server.name,
      server_type: server.type,
      adapter: adapter
    )

    case adapter.update_library(server, opts) do
      :ok ->
        Logger.info("Successfully notified media server",
          server_name: server.name,
          server_type: server.type
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to notify media server",
          server_name: server.name,
          server_type: server.type,
          error: reason
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Exception while notifying media server",
        server_name: server.name,
        server_type: server.type,
        error: Exception.message(e)
      )

      {:error, Exception.message(e)}
  end
end
