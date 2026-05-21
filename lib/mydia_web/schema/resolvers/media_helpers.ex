defmodule MydiaWeb.Schema.Resolvers.MediaHelpers do
  @moduledoc """
  Shared helper functions for media-related resolvers.
  """

  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Metadata.ImageUrl

  def map_external_to_search_result(item, type) do
    # Use global ID format with tmdb/tvdb prefix
    id =
      cond do
        item[:tmdb_id] -> "tmdb:#{item.tmdb_id}"
        item[:provider_id] && type in [:movie, "movie"] -> "tmdb:#{item.provider_id}"
        item[:provider_id] && type in [:tv_show, "tv_show"] -> "tmdb:#{item.provider_id}"
        true -> "ext:#{item[:provider_id] || item[:id]}"
      end

    %{
      id: id,
      type: normalize_type(type),
      title: item.title,
      year: item.year,
      artwork: %{
        poster_url: ImageUrl.poster_url(item.poster_path),
        backdrop_url: ImageUrl.backdrop_url(item.backdrop_path),
        thumbnail_url: nil
      },
      score: item[:popularity] || item[:score] || 0.0
    }
  end

  def build_artwork(%{metadata: nil}), do: nil

  def build_artwork(%{metadata: metadata}) do
    poster_path = MetadataAccess.get(metadata, :poster_path)
    backdrop_path = MetadataAccess.get(metadata, :backdrop_path)

    %{
      poster_url: ImageUrl.poster_url(poster_path),
      backdrop_url: ImageUrl.backdrop_url(backdrop_path),
      thumbnail_url: nil
    }
  end

  def build_artwork(_), do: nil

  @doc """
  Format a Playback.Progress struct into the GraphQL `:progress` shape.
  Centralized here so MediaResolver and DiscoveryResolver don't duplicate it.
  """
  def format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end

  defp normalize_type(type) when is_atom(type), do: type
  defp normalize_type("movie"), do: :movie
  defp normalize_type("tv_show"), do: :tv_show
  defp normalize_type(_), do: :movie
end
