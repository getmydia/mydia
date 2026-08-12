defmodule Mydia.Subtitles.Provider.SubDL do
  @moduledoc """
  Subtitle provider backed by api.subdl.com, using the operator's own API key.

  Keys are free from the SubDL account panel and allow 2000 requests a day. It
  covers both movies and television and is a genuinely separate upstream, so it
  keeps working when OpenSubtitles does not.

  Downloads arrive as ZIP archives rather than plain files. `download/2` fetches
  the archive and returns the subtitle inside it, because the behaviour's
  contract is content and every other adapter honours that. Unwrapping belongs
  here rather than in the downloader: the wire format is this provider's
  business, and a caller that had to ask "is this one of the zip providers?"
  would be the wrong shape. The guards against oversized and path-escaping
  entries stay in `Mydia.Subtitles.Archive`, shared by any future provider that
  also ships archives.
  """

  @behaviour Mydia.Subtitles.Provider

  require Logger

  alias Mydia.Subtitles.Archive
  alias Mydia.Subtitles.Provider.QuotaInfo
  alias Mydia.Subtitles.Provider.SearchResult

  @default_base_url "https://api.subdl.com"
  @default_download_host "https://dl.subdl.com"
  @timeout 10_000

  @impl true
  def search(config, params) do
    with {:ok, query} <- build_query(config, params) do
      case get(config, "/api/v1/subtitles", query) do
        {:ok, %{"subtitles" => subtitles}} when is_list(subtitles) ->
          {:ok, Enum.map(subtitles, &to_search_result/1)}

        # SubDL answers a miss with status false and an error string rather than
        # an empty list, which is a successful search finding nothing.
        {:ok, %{"status" => false}} ->
          {:ok, []}

        {:ok, _unexpected} ->
          {:error, :invalid_search_response}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def download(config, %{file_id: file_id}) do
    with {:ok, body} <- fetch_body(absolute_download_url(config, to_string(file_id))) do
      unwrap(body)
    end
  end

  # A provider is free to serve a bare subtitle even when it usually zips, so
  # decide from the bytes rather than from the file extension.
  defp unwrap(body) do
    if Archive.zip?(body) do
      with {:ok, %{content: content}} <- Archive.extract_subtitle(body), do: {:ok, content}
    else
      {:ok, body}
    end
  end

  defp fetch_body(url) do
    case Req.get(url,
           decode_body: false,
           headers: [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}],
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, %{reason: reason}} -> {:error, {:transport, reason}}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  end

  @impl true
  def validate_config(%{api_key: key} = config) when is_binary(key) and key != "" do
    {:ok, config}
  end

  def validate_config(_config), do: {:error, "SubDL requires an API key"}

  @impl true
  def quota_info(_config) do
    # SubDL publishes a 2000 request per day allowance but returns no quota
    # headers, so reporting a specific remaining count would be invention. The
    # UI renders a nil remaining as unknown rather than as zero.
    {:ok,
     %QuotaInfo{
       type: :limited,
       provider_type: :subdl,
       remaining: nil,
       total: nil,
       reset_at: nil,
       vip: false
     }}
  end

  @impl true
  def capabilities do
    %{
      media_types: [:movie, :episode],
      search_keys: [:imdb_id, :tmdb_id, :query],
      requires_credentials: true,
      quota: :limited
    }
  end

  ## Private

  defp base_url(config), do: Map.get(config, :base_url) || @default_base_url

  # Search and download live on different hosts, so the download host is
  # overridable independently. Tests need both pointed at one Bypass.
  defp download_host(config), do: Map.get(config, :download_host) || @default_download_host

  defp absolute_download_url(_config, "http" <> _rest = url), do: url
  defp absolute_download_url(config, "/" <> _rest = path), do: download_host(config) <> path
  defp absolute_download_url(config, path), do: download_host(config) <> "/" <> path

  defp build_query(config, params) do
    base = [
      api_key: Map.get(config, :api_key),
      languages: subdl_languages(params),
      subs_per_page: 30
    ]

    identity =
      cond do
        present?(params[:tmdb_id]) -> [tmdb_id: to_string(params[:tmdb_id])]
        present?(params[:imdb_id]) -> [imdb_id: imdb_with_prefix(params[:imdb_id])]
        present?(params[:query]) -> [film_name: params[:query]]
        true -> nil
      end

    case identity do
      nil -> {:error, :insufficient_search_criteria}
      identity -> {:ok, base ++ identity ++ type_params(params)}
    end
  end

  defp type_params(params) do
    case Map.get(params, :media_type) do
      "episode" ->
        [
          type: "tv",
          season_number: Map.get(params, :season_number),
          episode_number: Map.get(params, :episode_number)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      "movie" ->
        [type: "movie"]

      _ ->
        []
    end
  end

  # SubDL expects uppercase two-letter codes.
  defp subdl_languages(params) do
    params
    |> Map.get(:languages, "en")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.upcase()))
    |> Enum.join(",")
  end

  defp imdb_with_prefix("tt" <> _rest = id), do: id
  defp imdb_with_prefix(id), do: "tt" <> to_string(id)

  defp to_search_result(subtitle) do
    url = subtitle["url"] || ""

    %SearchResult{
      # The archive path is the only stable identifier SubDL returns, so it is
      # both the id and the hash. Downloads resolve it back to a URL.
      file_id: url,
      language: normalize_language(subtitle["language"] || subtitle["lang"]),
      format: "srt",
      subtitle_hash: url,
      file_name: subtitle["release_name"] || subtitle["name"],
      rating: nil,
      download_count: nil,
      hearing_impaired: subtitle["hi"] || false,
      moviehash_match: false
    }
  end

  defp normalize_language(nil), do: "en"

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.slice(0, 2)
    |> String.downcase()
  end

  defp present?(value), do: not is_nil(value) and value != ""

  defp get(config, path, query) do
    url = base_url(config) <> path

    case Req.get(url,
           params: query,
           headers: [{"user-agent", Mydia.Metadata.Provider.HTTP.user_agent()}],
           receive_timeout: @timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        Jason.decode(body)

      {:ok, %{status: 401}} ->
        {:error, :invalid_credentials}

      {:ok, %{status: 403}} ->
        {:error, :invalid_credentials}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end
end
