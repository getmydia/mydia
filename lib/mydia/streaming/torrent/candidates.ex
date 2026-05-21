defmodule Mydia.Streaming.Torrent.Candidates do
  @moduledoc """
  Logic for discovering and ranking torrent candidates for instant streaming.
  """

  require Logger
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult

  defmodule Candidate do
    @moduledoc """
    A torrent candidate returned to the picker UI.
    """

    @enforce_keys [:title, :size, :magnet_link, :indexer, :health_score]
    defstruct [
      :title,
      :size,
      :seeders,
      :leechers,
      :magnet_link,
      :indexer,
      :quality,
      :health_score
    ]

    @type t :: %__MODULE__{
            title: String.t(),
            size: non_neg_integer(),
            seeders: non_neg_integer() | nil,
            leechers: non_neg_integer() | nil,
            magnet_link: String.t(),
            indexer: String.t(),
            quality: String.t() | nil,
            health_score: float()
          }
  end

  @doc """
  Discovers and ranks torrent candidates for a media item.
  """
  def list_candidates(content_type, id) do
    with query when is_binary(query) <- build_search_query(content_type, id) do
      perform_search(query)
    else
      nil -> {:error, :not_found}
      :error -> {:error, :invalid_content_type}
    end
  end

  @doc """
  Discovers and ranks torrent candidates for an external media item.
  """
  def list_candidates_by_external_id(content_type, _provider, provider_id, opts \\ []) do
    with {:ok, media_type} <- normalize_external_media_type(content_type) do
      config = Mydia.Metadata.default_relay_config()

      case Mydia.Metadata.fetch_by_id_cached(config, to_string(provider_id),
             media_type: media_type
           ) do
        {:ok, metadata} ->
          query =
            if content_type == "episode" do
              season = opts[:season]
              episode = opts[:episode]

              if season && episode do
                "#{metadata.title} S#{pad(season)}E#{pad(episode)}"
              else
                "#{metadata.title}"
              end
            else
              build_search_query_from_metadata(content_type, metadata)
            end

          perform_search(query)

        _ ->
          {:error, :not_found}
      end
    end
  end

  # Safe mapping from caller-supplied content_type strings to atoms.
  # Avoids String.to_existing_atom/1 on untrusted input (per AGENTS.md).
  defp normalize_external_media_type("movie"), do: {:ok, :movie}
  defp normalize_external_media_type("tv_show"), do: {:ok, :tv_show}
  defp normalize_external_media_type("episode"), do: {:ok, :tv_show}
  defp normalize_external_media_type(_), do: {:error, :invalid_content_type}

  defp perform_search(query) do
    # Perform search across all indexers
    # We use a lower max_results for instant streaming to keep it snappy
    case Indexers.search_all(query, max_results: 20) do
      {:ok, %{results: results}} ->
        # Filter for torrents only (in case some indexers return NZBs)
        candidates =
          results
          |> Enum.filter(fn r ->
            # Only include results with magnet links (or torrent URLs we can use)
            String.starts_with?(r.download_url, "magnet:") or
              String.ends_with?(r.download_url, ".torrent")
          end)
          |> Enum.map(&to_candidate_map/1)
          |> sort_candidates()

        {:ok, candidates}

      {:error, reason} ->
        Logger.warning("Indexer search failed for torrent candidates: #{inspect(reason)}")
        {:error, {:indexer_search_failed, reason}}
    end
  end

  defp build_search_query_from_metadata("movie", metadata) do
    "#{metadata.title} #{metadata.year}"
  end

  defp build_search_query_from_metadata("episode", metadata) do
    # For external episodes, we'd need season/episode number which
    # might not be in the base metadata. This needs more work for TV shows.
    "#{metadata.title}"
  end

  defp build_search_query("movie", id) do
    case Mydia.Repo.get(Mydia.Media.MediaItem, id) do
      nil -> nil
      movie -> "#{movie.title} #{movie.year}"
    end
  end

  defp build_search_query("episode", id) do
    case Mydia.Repo.get(Mydia.Media.Episode, id) |> Mydia.Repo.preload([:media_item]) do
      nil ->
        nil

      episode ->
        "#{episode.media_item.title} S#{pad(episode.season_number)}E#{pad(episode.episode_number)}"
    end
  end

  defp build_search_query(_, _), do: :error

  defp pad(number), do: String.pad_leading("#{number}", 2, "0")

  defp to_candidate_map(%SearchResult{} = result) do
    %Candidate{
      title: result.title,
      size: result.size,
      seeders: result.seeders,
      leechers: result.leechers,
      magnet_link: result.download_url,
      indexer: result.indexer,
      quality: SearchResult.quality_description(result),
      health_score: SearchResult.health_score(result)
    }
  end

  defp sort_candidates(candidates) do
    # Sort by health score (seeders/leechers) first, then size (prefer larger/higher quality)
    Enum.sort_by(
      candidates,
      fn c ->
        {c.health_score, c.size}
      end,
      :desc
    )
  end
end
