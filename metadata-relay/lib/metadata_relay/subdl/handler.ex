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

  @subs_per_page 30

  @spec search(map()) :: {:ok, %{String.t() => [map()]}} | {:error, term()}
  def search(params) do
    with {:ok, query} <- build_query(params) do
      case Client.search(query) do
        {:ok, %{"subtitles" => subtitles}} when is_list(subtitles) ->
          {:ok, %{"subtitles" => Enum.map(subtitles, &transform_subtitle/1)}}

        # SubDL answers a miss with status false and an error string rather than
        # an empty list.
        {:ok, %{"status" => false}} ->
          {:ok, %{"subtitles" => []}}

        {:ok, unexpected} ->
          Logger.warning("Unexpected SubDL search response: #{inspect(unexpected)}")
          {:ok, %{"subtitles" => []}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## Private

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
  # `rating` and `download_count` have no SubDL equivalent; emitting 0 keeps
  # them out of the client's scoring rather than inventing a ranking.
  defp transform_subtitle(subtitle) do
    %{
      "id" => FileId.encode(subtitle["url"] || ""),
      "language" => subtitle |> Map.get("language", "") |> to_string() |> String.downcase(),
      "format" => "srt",
      "rating" => 0,
      "download_count" => 0,
      "release" => subtitle["release_name"] || "",
      "uploader" => subtitle["author"] || "",
      "hearing_impaired" => subtitle["hi"] || false,
      "foreign_parts_only" => false,
      "moviehash_match" => false,
      "season" => subtitle["season"],
      "episode" => subtitle["episode"]
    }
  end
end
