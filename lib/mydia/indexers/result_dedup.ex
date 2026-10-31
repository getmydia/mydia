defmodule Mydia.Indexers.ResultDedup do
  @moduledoc """
  Merges duplicate releases returned by different indexers, keeping the best
  copy of each (same info hash or same normalized title).
  """

  alias Mydia.Indexers.SearchResult

  @spec deduplicate([SearchResult.t()]) :: [SearchResult.t()]
  def deduplicate(results) do
    # Group results by normalized title and hash
    results
    |> Enum.group_by(&dedup_key/1)
    |> Enum.map(fn {_key, group} ->
      # For each group, merge duplicates by taking the best one
      merge_duplicates(group)
    end)
  end

  defp dedup_key(result) do
    # Extract hash from magnet link if available
    hash = extract_hash_from_url(result.download_url)
    normalized_title = normalize_title(result.title)

    {hash, normalized_title}
  end

  defp extract_hash_from_url(url) when is_binary(url) do
    case Regex.run(~r/urn:btih:([a-f0-9]{40})/i, url) do
      [_, hash] -> String.downcase(hash)
      nil -> nil
    end
  end

  defp extract_hash_from_url(nil), do: nil

  defp normalize_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "")
  end

  defp normalize_title(nil), do: ""

  defp merge_duplicates([single]), do: single

  defp merge_duplicates(duplicates) do
    # When we have duplicates, prefer:
    # 1. Results with more seeders
    # 2. Results from more reliable sources (if we had source ranking)
    # 3. Results with complete metadata
    best =
      Enum.max_by(duplicates, fn result ->
        # NZB results have nil seeders; treat as 0 for ordering only.
        {result.seeders || 0, has_complete_metadata?(result)}
      end)

    # The manual search indexer filter matches any tracker that returned the
    # release, and the indexer badge links each tracker's own page, so every
    # copy's indexer and info URL is kept, one per tracker.
    sources =
      duplicates
      |> Enum.flat_map(&SearchResult.sources/1)
      |> Enum.group_by(& &1.indexer)
      |> Enum.map(fn {_indexer, [first | _] = copies} ->
        Enum.find(copies, first, &SearchResult.usable_info_url(&1.info_url))
      end)
      |> Enum.sort_by(& &1.indexer)

    %{best | sources: sources}
  end

  defp has_complete_metadata?(%SearchResult{quality: quality}) do
    quality != nil && quality.resolution != nil && quality.source != nil
  end
end
