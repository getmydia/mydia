defmodule Mydia.MediaServer.Client.Jellyfin do
  @moduledoc """
  Jellyfin media server adapter.
  """

  @behaviour Mydia.MediaServer.Client

  alias Mydia.MediaServer.Error

  require Logger

  @impl true
  def test_connection(config) do
    # Jellyfin system info: /System/Info

    url = build_url(config, "/System/Info")

    case Req.get(url, headers: headers(config)) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, Error.auth("HTTP #{status}")}

      {:ok, %{status: status}} ->
        {:error, Error.unexpected("Connection failed: HTTP #{status}")}

      {:error, exception} ->
        {:error, Error.unexpected("Connection failed: #{Exception.message(exception)}")}
    end
  end

  @impl true
  def update_library(config, _opts \\ []) do
    # Jellyfin refresh library: POST /Library/Refresh
    # We can't easily scan by path without knowing the library layout, so trigger full scan for now.

    url = build_url(config, "/Library/Refresh")

    Logger.info("Triggering Jellyfin library scan", server: config.name)

    case Req.post(url, headers: headers(config)) do
      # 204 No Content is success
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, Error.auth("HTTP #{status}")}

      {:ok, %{status: status}} ->
        {:error, Error.unexpected("Scan failed: HTTP #{status}")}

      {:error, exception} ->
        {:error, Error.unexpected("Scan failed: #{Exception.message(exception)}")}
    end
  end

  defp build_url(config, path) do
    base = String.trim_trailing(config.url, "/")
    "#{base}#{path}"
  end

  defp headers(config) do
    [
      {"X-Emby-Token", config.token},
      {"Authorization", "MediaBrowser Token=\"#{config.token}\""},
      {"Accept", "application/json"}
    ]
  end
end
