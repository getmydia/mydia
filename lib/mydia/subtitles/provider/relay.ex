defmodule Mydia.Subtitles.Provider.Relay do
  @moduledoc """
  Subtitle provider backed by the Mydia metadata-relay service.

  This is the zero-configuration default: it needs no credentials because the
  relay holds the OpenSubtitles account. That account is shared across every
  Mydia install, so a heavy user is better served adding their own via a
  direct provider adapter.
  """

  @behaviour Mydia.Subtitles.Provider

  require Logger

  alias Mydia.Subtitles.Client.MetadataRelay
  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @impl true
  def search(_provider, params) do
    case MetadataRelay.search(params) do
      {:ok, %{"subtitles" => subtitles}} when is_list(subtitles) ->
        {:ok, Enum.map(subtitles, &SearchResult.from_map/1)}

      {:ok, unexpected} ->
        {:error, {:invalid_search_response, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def download(_provider, %{file_id: file_id}) do
    case MetadataRelay.get_download_url(file_id) do
      {:ok, %{"download_url" => url}} when is_binary(url) ->
        fetch_content(url)

      {:ok, unexpected} ->
        {:error, {:invalid_download_response, unexpected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def validate_config(config), do: {:ok, config}

  @impl true
  def quota_info(_provider), do: {:ok, QuotaInfo.unlimited(:relay)}

  ## Private functions

  # The relay hands back a temporary download URL (see
  # MetadataRelay.get_download_url/2); the Provider behaviour's download/2
  # callback contract requires the raw file content, so fetch it here.
  defp fetch_content(url) do
    headers = [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Relay subtitle content fetch failed", status: status)
        {:error, {:http_error, status, body}}

      {:error, %{reason: reason}} ->
        {:error, {:network_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
