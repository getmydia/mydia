defmodule Mydia.Downloads.PriorAttempts do
  @moduledoc """
  Finds which of a set of search results were tried before and failed, or are
  blacklisted, so the manual search modal can say so.

  `for_results/3` runs one query per source (failed downloads, blacklist) for
  the whole result list. A blacklist entry wins over a failed download for the
  same URL, since it is the stronger statement.
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.PriorAttempt
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  require Logger

  @doc """
  Returns `{:ok, %{download_url => %PriorAttempt{}}}` for the results that have
  a prior attempt. `context` uses the manual search shapes: `%{type: :episode,
  episode_id: id}`, `%{type: :season, season_number: n}`, or anything else for
  the whole item. Never raises; on error it logs and returns `{:error, reason}`,
  so callers can tell a failed lookup from an empty one and retry.
  """
  @spec for_results([struct()], MediaItem.t(), term()) ::
          {:ok, %{String.t() => PriorAttempt.t()}} | {:error, Exception.t()}
  def for_results(results, %MediaItem{} = media_item, context) do
    results = Enum.filter(results, &is_binary(&1.download_url))

    if results == [] do
      {:ok, %{}}
    else
      {:ok,
       Map.merge(
         failed_attempts(results, media_item, context),
         blacklisted_attempts(results)
       )}
    end
  rescue
    error ->
      Logger.warning("Prior attempts lookup failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp failed_attempts(results, media_item, context) do
    urls = results |> Enum.map(& &1.download_url) |> Enum.uniq()

    Download
    |> where([d], d.download_url in ^urls and not is_nil(d.error_message))
    |> scope(media_item, context)
    |> order_by([d], desc: d.updated_at)
    |> Repo.all()
    |> Enum.uniq_by(& &1.download_url)
    |> Map.new(fn d ->
      {d.download_url,
       %PriorAttempt{kind: :failed, reason: d.error_message, at: as_utc(d.updated_at)}}
    end)
  end

  defp scope(query, _media_item, %{type: :episode, episode_id: episode_id})
       when not is_nil(episode_id),
       do: where(query, [d], d.episode_id == ^episode_id)

  defp scope(query, media_item, %{type: :season, season_number: season_number})
       when not is_nil(season_number) do
    query
    |> where([d], d.media_item_id == ^media_item.id)
    |> where([d], ^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
    |> where([d], ^Mydia.DB.json_integer_equals(:metadata, "$.season_number", season_number))
  end

  defp scope(query, media_item, _context),
    do: where(query, [d], d.media_item_id == ^media_item.id)

  defp blacklisted_attempts(results) do
    keyed =
      Enum.map(results, fn result ->
        {result.download_url, ReleaseBlacklist.normalize_indexer(result.indexer),
         Blacklists.release_guid(result), Blacklists.info_hash_from_url(result.download_url)}
      end)

    indexers = keyed |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    guids = keyed |> Enum.map(&elem(&1, 2)) |> Enum.uniq()
    hashes = keyed |> Enum.map(&elem(&1, 3)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    now = DateTime.utc_now()

    rows =
      ReleaseBlacklist
      |> where([b], is_nil(b.expires_at) or b.expires_at > ^now)
      |> where(
        [b],
        (b.indexer in ^indexers and b.guid in ^guids) or b.info_hash in ^hashes
      )
      |> order_by([b], desc: b.inserted_at)
      |> Repo.all()

    by_key = Enum.reduce(Enum.reverse(rows), %{}, &Map.put(&2, {&1.indexer, &1.guid}, &1))

    by_hash =
      rows
      |> Enum.filter(& &1.info_hash)
      |> Enum.reverse()
      |> Enum.reduce(%{}, &Map.put(&2, &1.info_hash, &1))

    Enum.reduce(keyed, %{}, fn {url, indexer, guid, hash}, acc ->
      case Map.get(by_key, {indexer, guid}) || (hash && Map.get(by_hash, hash)) do
        nil ->
          acc

        row ->
          Map.put(acc, url, %PriorAttempt{
            kind: :blacklisted,
            reason: row.failure_reason,
            at: as_utc(row.inserted_at)
          })
      end
    end)
  end

  defp as_utc(%DateTime{} = dt), do: dt
  defp as_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")
end
