defmodule Mydia.Jobs.MetadataRefresh do
  @moduledoc """
  Background job for refreshing media metadata.

  This job:
  - Fetches the latest metadata from providers
  - Updates media items with fresh data
  - For TV shows, updates episode information
  - Can be triggered manually or scheduled
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Media, Metadata}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"media_item_id" => media_item_id} = args}) do
    start_time = System.monotonic_time(:millisecond)
    fetch_episodes = Map.get(args, "fetch_episodes", true)
    config = Metadata.default_relay_config()

    Logger.info("Starting metadata refresh", media_item_id: media_item_id)

    result =
      case Media.get_media_item!(media_item_id) do
        nil ->
          Logger.error("Media item not found", media_item_id: media_item_id)
          {:error, :not_found}

        media_item ->
          refresh_media_item(media_item, config, fetch_episodes)
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Metadata refresh completed",
          duration_ms: duration,
          media_item_id: media_item_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Metadata refresh failed",
          error: inspect(reason),
          duration_ms: duration,
          media_item_id: media_item_id
        )

        {:error, reason}
    end
  rescue
    e in Ecto.NoResultsError ->
      Logger.error("Media item not found", media_item_id: media_item_id)
      {:error, :not_found}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"refresh_all" => true}}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting metadata refresh for all media items")

    result = refresh_all_media()
    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, count} ->
        Logger.info("Metadata refresh all completed",
          duration_ms: duration,
          items_processed: count
        )

        :ok

      :ok ->
        Logger.info("Metadata refresh all completed", duration_ms: duration)
        :ok

      {:error, reason} ->
        Logger.error("Metadata refresh all failed",
          error: inspect(reason),
          duration_ms: duration
        )

        {:error, reason}
    end
  end

  ## Private Functions

  defp refresh_media_item(media_item, config, fetch_episodes) do
    if media_item.tmdb_id do
      Logger.info("Refreshing metadata",
        media_item_id: media_item.id,
        title: media_item.title,
        tmdb_id: media_item.tmdb_id
      )

      media_type = parse_media_type(media_item.type)

      case fetch_updated_metadata(media_item.tmdb_id, media_type, config) do
        {:ok, metadata} ->
          attrs = build_update_attrs(metadata, media_type)

          case Media.update_media_item(media_item, attrs) do
            {:ok, updated_item} ->
              Logger.info("Successfully refreshed metadata",
                media_item_id: updated_item.id,
                title: updated_item.title
              )

              # For TV shows, optionally refresh episodes
              if media_type == :tv_show and fetch_episodes do
                Media.refresh_episodes_for_tv_show(updated_item)
              end

              :ok

            {:error, changeset} ->
              Logger.error("Failed to update media item",
                media_item_id: media_item.id,
                errors: inspect(changeset.errors)
              )

              {:error, :update_failed}
          end

        {:error, reason} ->
          Logger.error("Failed to fetch updated metadata",
            media_item_id: media_item.id,
            tmdb_id: media_item.tmdb_id,
            reason: reason
          )

          {:error, reason}
      end
    else
      Logger.warning("Media item has no TMDB ID, cannot refresh",
        media_item_id: media_item.id
      )

      {:error, :no_tmdb_id}
    end
  end

  defp refresh_all_media do
    media_items = Media.list_media_items(monitored: true)

    Logger.info("Refreshing metadata for #{length(media_items)} media items")

    results =
      Enum.map(media_items, fn media_item ->
        config = Metadata.default_relay_config()
        refresh_media_item(media_item, config, false)
      end)

    successful = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Metadata refresh completed",
      total: length(results),
      successful: successful,
      failed: failed
    )

    {:ok, successful}
  end

  defp parse_media_type("movie"), do: :movie
  defp parse_media_type("tv_show"), do: :tv_show
  defp parse_media_type(_), do: :movie

  defp fetch_updated_metadata(tmdb_id, media_type, config) do
    fetch_opts = [
      media_type: media_type,
      append_to_response: ["credits", "images", "videos", "keywords"]
    ]

    Metadata.fetch_by_id(config, to_string(tmdb_id), fetch_opts)
  end

  defp build_update_attrs(metadata, media_type) do
    %{
      title: metadata.title || metadata.name,
      original_title: metadata.original_title || metadata.original_name,
      year: extract_year(metadata),
      imdb_id: metadata.imdb_id,
      metadata: metadata
    }
  end

  defp extract_year(metadata) do
    cond do
      metadata.release_date && is_binary(metadata.release_date) ->
        metadata.release_date
        |> String.slice(0..3)
        |> String.to_integer()

      metadata.first_air_date && is_binary(metadata.first_air_date) ->
        metadata.first_air_date
        |> String.slice(0..3)
        |> String.to_integer()

      true ->
        nil
    end
  rescue
    _ -> nil
  end
end
