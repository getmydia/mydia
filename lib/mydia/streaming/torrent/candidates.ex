defmodule Mydia.Streaming.Torrent.Candidates do
  @moduledoc """
  Logic for discovering and ranking torrent candidates for instant streaming.
  """

  require Logger
  alias Mydia.Indexers
  alias Mydia.Indexers.SearchResult

  @doc """
  Discovers and ranks torrent candidates for a media item.
  """
  def list_candidates(content_type, id) do
    with query when is_binary(query) <- build_search_query(content_type, id) do
      # Perform search across all indexers
      # We use a lower max_results for instant streaming to keep it snappy
      {:ok, %{results: results}} = Indexers.search_all(query, max_results: 20)

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
    else
      nil -> {:error, :not_found}
      :error -> {:error, :invalid_content_type}
    end
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
    %{
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
