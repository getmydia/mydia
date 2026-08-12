defmodule Mydia.Subtitles.Provider.Relay do
  @moduledoc """
  Subtitle provider backed by the Mydia metadata-relay service.

  This is the zero-configuration default: it needs no credentials because the
  relay holds the OpenSubtitles account. That account is shared across every
  Mydia install, so a heavy user is better served adding their own via
  `Mydia.Subtitles.Provider.OpenSubtitles`.
  """

  @behaviour Mydia.Subtitles.Provider

  alias Mydia.Subtitles.Client.MetadataRelay
  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @impl true
  def search(_provider, params) do
    case MetadataRelay.search(params) do
      {:ok, %{"subtitles" => subtitles}} when is_list(subtitles) ->
        {:ok, Enum.map(subtitles, &SearchResult.from_map/1)}

      {:ok, _unexpected} ->
        {:error, :invalid_search_response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def download(_provider, %{file_id: file_id}) do
    case MetadataRelay.get_download_url(file_id) do
      {:ok, %{"download_url" => url}} -> fetch_subtitle_body(url)
      {:ok, _unexpected} -> {:error, :invalid_download_response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def validate_config(config), do: {:ok, config}

  @impl true
  def quota_info(_provider), do: {:ok, QuotaInfo.unlimited(:relay)}

  @impl true
  def capabilities do
    %{
      media_types: [:movie, :episode],
      search_keys: [:file_hash, :imdb_id, :tmdb_id, :query],
      requires_credentials: false,
      quota: :unlimited
    }
  end

  defp fetch_subtitle_body(url) do
    case Req.get(url, decode_body: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
