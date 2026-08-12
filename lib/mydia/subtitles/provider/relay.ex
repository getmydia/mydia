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
        {:ok, Enum.map(subtitles, &(&1 |> normalize_subtitle() |> SearchResult.from_map()))}

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

      {:error, {:http_error, 406, _body}} ->
        {:error, :quota_exceeded}

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

  # Translates metadata-relay's OpenSubtitles wire format (see
  # MetadataRelay.OpenSubtitles.Handler.transform_subtitle/1 in the
  # metadata-relay service) into the keys SearchResult.from_map/1 expects.
  # The relay emits "id", not "file_id"; "release", not "file_name"; and
  # never emits "subtitle_hash" or "moviehash_match" at all. Each provider
  # adapter owns its own translation here rather than SearchResult growing
  # provider-specific clauses, since Task 6's direct OpenSubtitles adapter
  # has yet another wire format.
  defp normalize_subtitle(subtitle) do
    file_id = Map.get(subtitle, "id")
    language = Map.get(subtitle, "language")

    subtitle
    |> Map.put("file_id", file_id)
    |> Map.put("file_name", Map.get(subtitle, "release"))
    |> Map.put("subtitle_hash", synthesize_subtitle_hash(file_id, language))
  end

  # The relay never returns a subtitle_hash, so synthesize a deterministic
  # one from (file_id, language). Same formula as
  # Mydia.Subtitles.generate_subtitle_hash/1 (subtitles.ex is off limits for
  # this task, so this mirrors rather than calls it): stable across repeated
  # searches for the same subtitle, which is what dedup-by-subtitle_hash
  # needs, but it is NOT a hash of the file's contents. Two different
  # subtitle files that happen to share (file_id, language) would collide;
  # in practice file_id is the provider's unique identifier for one file, so
  # this does not happen in the relay's real data.
  defp synthesize_subtitle_hash(file_id, language) do
    :crypto.hash(:sha256, "#{file_id}-#{language}")
    |> Base.encode16(case: :lower)
  end

  # The relay hands back a temporary download URL (see
  # MetadataRelay.get_download_url/2); the Provider behaviour's download/2
  # callback contract requires the raw file content, so fetch it here.
  defp fetch_content(url) do
    headers = [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}]

    # decode_body: false keeps the response as a raw binary regardless of
    # its content-type. download/2 promises {:ok, binary()}; without this,
    # Req would auto-decode a JSON-served subtitle into a map and silently
    # break that contract.
    case Req.get(url, headers: headers, decode_body: false) do
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
