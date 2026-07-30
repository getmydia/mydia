defmodule Mydia.Jobs.TvdbIdBackfill do
  @moduledoc """
  Background job for backfilling TVDB IDs on existing TV shows.

  Queries all media_items where type = "tv_show" and tvdb_id IS NULL,
  then searches TVDB by title + year to find and store the TVDB ID.

  Items are processed in batches with delays to avoid rate limiting.
  The job is idempotent and can be re-run safely.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: 86_400,
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Mydia.{Media, Metadata, Repo}
  alias Mydia.Media.MediaItem

  import Ecto.Query

  # Delay between batches to avoid rate limiting (ms)
  @batch_delay_ms 2_000

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[TvdbIdBackfill] Starting TVDB ID backfill for existing TV shows")

    # Query all TV shows missing tvdb_id
    tv_shows =
      from(m in MediaItem,
        where: m.type == "tv_show" and is_nil(m.tvdb_id),
        order_by: [asc: m.title]
      )
      |> Repo.all()

    total = length(tv_shows)
    Logger.info("[TvdbIdBackfill] Found #{total} TV shows without TVDB ID")

    if total == 0 do
      :ok
    else
      config = Metadata.default_relay_config()

      # Process in batches of 10
      results =
        tv_shows
        |> Enum.chunk_every(10)
        |> Enum.with_index()
        |> Enum.flat_map(fn {batch, batch_index} ->
          if batch_index > 0 do
            Process.sleep(@batch_delay_ms)
          end

          Logger.info("[TvdbIdBackfill] Processing batch #{batch_index + 1}/#{ceil(total / 10)}")

          Enum.map(batch, fn show ->
            backfill_single(show, config)
          end)
        end)

      matched = Enum.count(results, &(&1 == :matched))
      not_found = Enum.count(results, &(&1 == :not_found))
      failed = Enum.count(results, &(&1 == :failed))

      Logger.info("[TvdbIdBackfill] Backfill complete",
        total: total,
        matched: matched,
        not_found: not_found,
        failed: failed
      )

      :ok
    end
  end

  defp backfill_single(show, config) do
    search_opts =
      if show.year do
        [media_type: :tv_show, year: show.year]
      else
        [media_type: :tv_show]
      end

    case Metadata.search(config, show.title, search_opts) do
      {:ok, []} ->
        # Retry without year
        if show.year do
          case Metadata.search(config, show.title, media_type: :tv_show) do
            {:ok, results} when results != [] ->
              try_match(show, results)

            _ ->
              Logger.info("[TvdbIdBackfill] No TVDB match found for: #{show.title}")
              :not_found
          end
        else
          Logger.info("[TvdbIdBackfill] No TVDB match found for: #{show.title}")
          :not_found
        end

      {:ok, results} ->
        try_match(show, results)

      {:error, reason} ->
        Logger.warning("[TvdbIdBackfill] Search failed for #{show.title}: #{inspect(reason)}")
        :failed
    end
  end

  defp try_match(show, results) do
    # Score results by title similarity and year match
    scored =
      Enum.map(results, fn result ->
        score = calculate_match_score(show, result)
        {result, score}
      end)

    case Enum.max_by(scored, fn {_r, s} -> s end, fn -> nil end) do
      {result, score} when score >= 0.7 ->
        case Integer.parse(result.provider_id) do
          {tvdb_id, ""} ->
            case Media.update_media_item(show, %{tvdb_id: tvdb_id}, reason: "TVDB ID backfill") do
              {:ok, _updated} ->
                Logger.info(
                  "[TvdbIdBackfill] Matched: #{show.title} -> TVDB #{tvdb_id} (score: #{Float.round(score, 2)})"
                )

                :matched

              {:error, _changeset} ->
                Logger.warning(
                  "[TvdbIdBackfill] Failed to update #{show.title} with TVDB ID #{tvdb_id}"
                )

                :failed
            end

          _ ->
            Logger.warning(
              "[TvdbIdBackfill] Invalid provider_id for #{show.title}: #{result.provider_id}"
            )

            :failed
        end

      _ ->
        Logger.info("[TvdbIdBackfill] No confident match for: #{show.title} (best score < 0.7)")
        :not_found
    end
  end

  defp calculate_match_score(show, result) do
    title_score = title_similarity(show.title, result.title)

    year_bonus =
      cond do
        is_nil(show.year) or is_nil(result.year) -> 0.0
        show.year == result.year -> 0.2
        abs(show.year - result.year) <= 1 -> 0.1
        true -> -0.1
      end

    title_score + year_bonus
  end

  defp title_similarity(a, b) when is_binary(a) and is_binary(b) do
    na = normalize_title(a)
    nb = normalize_title(b)

    cond do
      na == nb -> 1.0
      String.contains?(na, nb) or String.contains?(nb, na) -> 0.8
      true -> String.jaro_distance(na, nb)
    end
  end

  defp title_similarity(_, _), do: 0.0

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
