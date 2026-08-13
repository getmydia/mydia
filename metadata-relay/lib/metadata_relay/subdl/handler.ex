defmodule MetadataRelay.SubDL.Handler do
  @moduledoc """
  Translates between the relay's subtitle contract and SubDL's API.

  The emitted shape is the one the relay has always emitted, which was
  originally derived from OpenSubtitles. Keeping it means Mydia installs already
  in the field switch to SubDL without an upgrade, so the field names here are
  deliberately not SubDL's.
  """

  require Logger

  alias MetadataRelay.SubDL.Client
  alias MetadataRelay.SubDL.FileId
  alias MetadataRelay.Subtitles.Archive

  @subs_per_page 30

  @spec search(map()) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def search(params) do
    with {:ok, query} <- build_query(params) do
      case Client.search(query) do
        {:ok, response} ->
          case response do
            %{"subtitles" => subtitles} when is_map(response) and is_list(subtitles) ->
              feature = feature_context(Map.get(response, "results", []))
              {:ok, %{"subtitles" => Enum.map(subtitles, &transform_subtitle(&1, feature))}}

            # SubDL answers a miss with status false and an error string rather than
            # an empty list.
            %{"status" => false} when is_map(response) ->
              {:ok, %{"subtitles" => []}}

            # Anything else is an upstream anomaly, not a search that found
            # nothing, and the two must not answer alike. The relay caches
            # successful searches for days, so reporting an anomaly as an empty
            # result would pin "this title has no subtitles" on every install
            # for as long as the entry lives, with nothing to invalidate it. An
            # error tuple leaves as a 5xx, which the cache skips.
            _ when is_map(response) ->
              Logger.warning(
                "Unexpected SubDL search response: top-level keys: #{Enum.map_join(Map.keys(response), ", ", & &1)}"
              )

              {:error, :unexpected_upstream_response}

            # Non-map response (e.g. HTML error page, binary body from captcha or CDN block)
            _ ->
              Logger.warning(
                "Unexpected non-JSON SubDL response: #{inspect_type_and_size(response)}"
              )

              {:error, :unexpected_upstream_response}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Returns a download URL for an id from a search result.

  The URL points back at this relay, not at SubDL. SubDL serves ZIP archives and
  the clients on the other end of this contract expect plain subtitle bytes,
  with no archive handling of their own, so the unwrapping has to happen here.
  """
  @spec get_download_url(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_download_url(id, relay_base_url) do
    with {:ok, path} <- FileId.decode(id) do
      {:ok,
       %{
         "download_url" => "#{relay_base_url}/api/v1/subtitles/download/#{id}",
         "file_name" => path |> Path.basename() |> String.replace_suffix(".zip", ".srt"),
         # SubDL publishes no quota headers. Reporting null is honest; reporting
         # a number would be invention.
         "requests_used" => nil,
         "requests_remaining" => nil
       }}
    end
  end

  @doc """
  Fetches a SubDL archive and returns the subtitle inside it.
  """
  @spec download(String.t()) :: {:ok, %{name: String.t(), content: binary()}} | {:error, term()}
  def download(id) do
    with {:ok, path} <- FileId.decode(id),
         {:ok, archive} <- Client.fetch_archive(path),
         {:ok, %{name: name, content: content}} <- Archive.extract_subtitle(archive) do
      {:ok, %{name: safe_name(name), content: content}}
    end
  end

  ## Private

  # The entry name comes from an archive built by a stranger and is echoed in a
  # content-disposition header, so anything outside this set is dropped rather
  # than escaped. Dropping cannot go wrong; escaping can.
  defp safe_name(name) do
    cleaned =
      name
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]/, "_")

    if cleaned == "", do: "subtitle.srt", else: cleaned
  end

  defp build_query(params) do
    case identity(params) do
      nil ->
        {:error, :insufficient_search_criteria}

      identity ->
        {:ok,
         [languages: languages(params), subs_per_page: @subs_per_page] ++
           identity ++ type_params(params)}
    end
  end

  # SubDL accepts one identity per search. A tmdb id is preferred because it is
  # unambiguous for both films and series; a free-text film name is the last
  # resort. A file hash is ignored: SubDL has no hash search at all.
  defp identity(params) do
    cond do
      present?(params[:tmdb_id]) -> [tmdb_id: to_string(params[:tmdb_id])]
      present?(params[:imdb_id]) -> [imdb_id: imdb_with_prefix(params[:imdb_id])]
      present?(params[:query]) -> [film_name: to_string(params[:query])]
      true -> nil
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

  defp languages(params) do
    params
    |> Map.get(:languages, "en")
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map_join(",", &(&1 |> String.trim() |> String.upcase()))
  end

  defp imdb_with_prefix("tt" <> _rest = id), do: id
  defp imdb_with_prefix(id), do: "tt" <> to_string(id)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  # `format` is emitted as srt because SubDL does not state it in search results
  # and the real extension only becomes visible when the archive is unwrapped,
  # two requests later. Mydia already treats this field as a default.
  # `rating` and `download_count` have no SubDL equivalent, so they are null:
  # "not reported" rather than "reported as zero", which is what a 0 claims.
  # Both read the same way in Mydia's scoring, whose rating and popularity
  # branches are guarded by is_number/is_integer and skip a null, so a
  # relay-backed result carries neither bonus either way.
  defp transform_subtitle(subtitle, feature) do
    %{
      "id" => FileId.encode(subtitle["url"] || ""),
      "language" => normalize_language(subtitle["language"] || subtitle["lang"]),
      "format" => "srt",
      "rating" => nil,
      "download_count" => nil,
      "release" => subtitle["release_name"] || "",
      "uploader" => subtitle["author"] || "",
      "hearing_impaired" => subtitle["hi"] || false,
      "foreign_parts_only" => false,
      "moviehash_match" => false,
      "season" => subtitle["season"],
      "episode" => subtitle["episode"],
      "feature_type" => feature["feature_type"],
      "title" => feature["title"],
      "year" => feature["year"],
      "imdb_id" => feature["imdb_id"],
      "tmdb_id" => feature["tmdb_id"]
    }
  end

  defp feature_context([]), do: empty_feature()

  defp feature_context(nil), do: empty_feature()

  defp feature_context([result | _]) when is_map(result) do
    %{
      "feature_type" => result["type"],
      "title" => result["name"],
      "year" => result["year"],
      "imdb_id" => result["imdb_id"],
      "tmdb_id" => result["tmdb_id"]
    }
  end

  defp feature_context(_), do: empty_feature()

  defp empty_feature do
    %{
      "feature_type" => nil,
      "title" => nil,
      "year" => nil,
      "imdb_id" => nil,
      "tmdb_id" => nil
    }
  end

  defp inspect_type_and_size(response) when is_binary(response) do
    "binary (#{byte_size(response)} bytes)"
  end

  defp inspect_type_and_size(response) do
    "#{inspect(response, limit: 20)}"
  end

  defp normalize_language(nil), do: "en"

  defp normalize_language(language) do
    language
    |> to_string()
    |> String.slice(0, 2)
    |> String.downcase()
  end
end
