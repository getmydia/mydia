defmodule MydiaWeb.Api.MediaController do
  @moduledoc """
  REST API controller for media item management.

  Provides endpoints for managing media items, including manual metadata matching overrides.
  """

  use MydiaWeb, :controller

  alias Mydia.{Media, Metadata, Repo}
  alias Mydia.Library.MetadataEnricher
  require Logger

  @doc """
  Gets a specific media item.

  GET /api/v1/media/:id

  Returns:
    - 200: Media item details
    - 404: Media item not found
  """
  def show(conn, %{"id" => id}) do
    case Media.get_media_item!(id, preload: [:library_path, :episodes]) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media item not found"})

      media_item ->
        json(conn, %{data: serialize_media_item(media_item)})
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Media item not found"})
  end

  @doc """
  Manually matches a media item to a specific provider ID (TMDB/TVDB).

  This allows users to override automatic matching when it fails or selects
  the wrong match. The media item will be updated with metadata from the
  specified provider ID.

  POST /api/v1/media/:id/match

  Body:
    {
      "provider_id": "603",              # Required: TMDB or TVDB ID
      "provider_type": "tmdb",           # Optional: tmdb|tvdb (default: tmdb)
      "fetch_episodes": true             # Optional: for TV shows, re-fetch episodes (default: true)
    }

  Returns:
    - 200: Media item successfully matched and updated
    - 400: Invalid request (missing provider_id, invalid provider_type)
    - 404: Media item not found
    - 422: Metadata fetch failed or update failed
  """
  def match(conn, %{"id" => id} = params) do
    provider_id = params["provider_id"]
    provider_type = parse_provider_type(params["provider_type"])
    fetch_episodes = Map.get(params, "fetch_episodes", true)

    cond do
      is_nil(provider_id) or provider_id == "" ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "provider_id is required"})

      is_nil(provider_type) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid provider_type, must be 'tmdb' or 'tvdb'"})

      true ->
        case Media.get_media_item!(id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Media item not found"})

          media_item ->
            perform_manual_match(conn, media_item, provider_id, provider_type, fetch_episodes)
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Media item not found"})
  end

  ## Private Functions

  defp parse_provider_type(nil), do: :tmdb
  defp parse_provider_type("tmdb"), do: :tmdb
  defp parse_provider_type("tvdb"), do: :tvdb
  defp parse_provider_type(:tmdb), do: :tmdb
  defp parse_provider_type(:tvdb), do: :tvdb
  defp parse_provider_type(_), do: nil

  defp parse_media_type("movie"), do: :movie
  defp parse_media_type("tv_show"), do: :tv_show
  defp parse_media_type(:movie), do: :movie
  defp parse_media_type(:tv_show), do: :tv_show
  defp parse_media_type(_), do: :movie

  defp perform_manual_match(conn, media_item, provider_id, provider_type, fetch_episodes) do
    config = Metadata.default_relay_config()
    media_type = parse_media_type(media_item.type)

    Logger.info("Performing manual metadata match override",
      media_item_id: media_item.id,
      provider_id: provider_id,
      provider_type: provider_type,
      media_type: media_type
    )

    # Fetch metadata from provider
    case Metadata.fetch_by_id(config, provider_id, media_type: media_type) do
      {:ok, metadata} ->
        # Build match result for enricher
        match_result = %{
          provider_id: provider_id,
          provider_type: provider_type,
          title: metadata[:title] || metadata[:name],
          year: extract_year(metadata),
          match_confidence: 1.0,
          # Manual match always has 100% confidence
          metadata: metadata
        }

        # Update media item with new metadata
        case update_media_with_metadata(media_item, match_result, config, fetch_episodes) do
          {:ok, updated_media_item} ->
            Logger.info("Manual match successful",
              media_item_id: media_item.id,
              provider_id: provider_id,
              title: match_result.title
            )

            # Reload with preloads for response
            media_item = Media.get_media_item!(updated_media_item.id, preload: [:library_path, :episodes])

            conn
            |> put_status(:ok)
            |> json(%{
              message: "Media item successfully matched and updated",
              data: serialize_media_item(media_item)
            })

          {:error, reason} ->
            Logger.error("Failed to update media item with manual match",
              media_item_id: media_item.id,
              provider_id: provider_id,
              reason: inspect(reason)
            )

            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Failed to update media item: #{inspect(reason)}"})
        end

      {:error, reason} ->
        Logger.error("Failed to fetch metadata for manual match",
          provider_id: provider_id,
          provider_type: provider_type,
          reason: inspect(reason)
        )

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to fetch metadata from provider: #{inspect(reason)}"})
    end
  end

  defp update_media_with_metadata(media_item, match_result, config, fetch_episodes) do
    metadata = match_result.metadata

    # Extract relevant fields from metadata
    attrs =
      %{
        title: metadata[:title] || metadata[:name],
        tmdb_id: match_result.provider_id,
        metadata: metadata,
        year: extract_year(metadata),
        overview: metadata[:overview],
        poster_url: metadata[:poster_path],
        backdrop_url: metadata[:backdrop_path],
        genres: extract_genres(metadata),
        runtime: metadata[:runtime],
        status: metadata[:status]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    Repo.transaction(fn ->
      # Update the media item
      case Media.update_media_item(media_item, attrs) do
        {:ok, updated_media_item} ->
          # For TV shows, refresh episodes if requested
          if media_item.type == "tv_show" and fetch_episodes do
            case Media.refresh_episodes_for_tv_show(updated_media_item, config: config) do
              {:ok, _episodes} ->
                updated_media_item

              {:error, reason} ->
                Logger.warning("Failed to refresh episodes during manual match",
                  media_item_id: media_item.id,
                  reason: inspect(reason)
                )

                # Don't fail the whole operation if episode refresh fails
                updated_media_item
            end
          else
            updated_media_item
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  defp extract_year(metadata) do
    cond do
      metadata[:release_date] ->
        case Date.from_iso8601(metadata[:release_date]) do
          {:ok, date} -> date.year
          _ -> nil
        end

      metadata[:first_air_date] ->
        case Date.from_iso8601(metadata[:first_air_date]) do
          {:ok, date} -> date.year
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp extract_genres(metadata) do
    case metadata[:genres] do
      genres when is_list(genres) ->
        Enum.map(genres, fn
          %{name: name} -> name
          genre when is_binary(genre) -> genre
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp serialize_media_item(media_item) do
    %{
      id: media_item.id,
      title: media_item.title,
      type: media_item.type,
      year: media_item.year,
      tmdb_id: media_item.tmdb_id,
      overview: media_item.overview,
      poster_url: media_item.poster_url,
      backdrop_url: media_item.backdrop_url,
      genres: media_item.genres,
      runtime: media_item.runtime,
      status: media_item.status,
      monitored: media_item.monitored,
      library_path_id: media_item.library_path_id,
      quality_profile_id: media_item.quality_profile_id,
      metadata: media_item.metadata,
      inserted_at: media_item.inserted_at,
      updated_at: media_item.updated_at,
      # Include associations if preloaded
      episodes: serialize_episodes(media_item.episodes)
    }
  end

  defp serialize_episodes(%Ecto.Association.NotLoaded{}), do: nil

  defp serialize_episodes(episodes) when is_list(episodes) do
    Enum.map(episodes, fn episode ->
      %{
        id: episode.id,
        season_number: episode.season_number,
        episode_number: episode.episode_number,
        title: episode.title,
        overview: episode.overview,
        air_date: episode.air_date,
        still_url: episode.still_url
      }
    end)
  end

  defp serialize_episodes(_), do: nil
end
