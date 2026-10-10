defmodule Mydia.Media.Calendar do
  @moduledoc """
  Calendar queries: episodes by air date and movies by release date.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Episode, MediaItem, Restrictions}
  alias Mydia.Media.Structs.CalendarEntry

  ## Calendar

  @doc """
  Returns episodes with air dates in the specified date range.
  Only returns episodes for monitored media items by default.

  ## Options
    - `:preload` - List of associations to preload
    - `:monitored` - Filter by media item monitored status (default: true, nil for all)
  """
  @spec list_episodes_by_air_date(Scope.t(), Date.t(), Date.t(), keyword()) :: [CalendarEntry.t()]
  def list_episodes_by_air_date(%Scope{} = scope, start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      Episode
      |> join(:inner, [e], m in MediaItem, on: e.media_item_id == m.id)
      |> where([e, m], not is_nil(e.air_date))
      |> where([e, m], e.air_date >= ^start_date and e.air_date <= ^end_date)
      |> Restrictions.apply_to_episodes(scope)

    query =
      if is_nil(monitored) do
        query
      else
        where(query, [e, m], m.monitored == ^monitored)
      end

    query
    |> select([e, m], %{
      id: e.id,
      air_date: e.air_date,
      title: e.title,
      season_number: e.season_number,
      episode_number: e.episode_number,
      show: m,
      has_files:
        type(
          fragment(
            "CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = ? AND trashed_at IS NULL AND extra_kind IS NULL) THEN true ELSE false END",
            e.id
          ),
          :boolean
        ),
      has_downloads:
        type(
          fragment(
            "CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE episode_id = ?) THEN true ELSE false END",
            e.id
          ),
          :boolean
        )
    })
    |> order_by([e, m], asc: e.air_date, asc: m.title)
    |> Repo.all()
    |> Enum.map(fn entry ->
      CalendarEntry.new_episode(
        id: entry.id,
        air_date: entry.air_date,
        title: entry.title,
        season_number: entry.season_number,
        episode_number: entry.episode_number,
        media_item_id: entry.show.id,
        media_item_title: entry.show.title,
        media_item_type: entry.show.type,
        has_files: entry.has_files,
        has_downloads: entry.has_downloads,
        poster_path: entry.show.metadata && entry.show.metadata.poster_path,
        backdrop_path: entry.show.metadata && entry.show.metadata.backdrop_path
      )
    end)
  end

  @doc """
  Returns monitored movies with release dates in the specified date range from metadata.
  Movies must have a release_date in their metadata field.

  ## Options
    - `:monitored` - Filter by monitored status (default: true, nil for all)
  """
  @spec list_movies_by_release_date(Scope.t(), Date.t(), Date.t(), keyword()) :: [
          CalendarEntry.t()
        ]
  def list_movies_by_release_date(%Scope{} = scope, start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      MediaItem
      |> Restrictions.apply(scope)
      |> where([m], m.type == "movie")
      |> where(^Mydia.DB.json_date_between(:metadata, "$.release_date", start_date, end_date))

    query =
      if is_nil(monitored) do
        query
      else
        where(query, [m], m.monitored == ^monitored)
      end

    query
    |> select([m], %{
      item: m,
      has_files:
        type(
          fragment(
            "CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE media_item_id = ? AND trashed_at IS NULL) THEN true ELSE false END",
            m.id
          ),
          :boolean
        ),
      has_downloads:
        type(
          fragment(
            "CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE media_item_id = ?) THEN true ELSE false END",
            m.id
          ),
          :boolean
        )
    })
    |> order_by([m], asc: m.title)
    |> Repo.all()
    |> Enum.map(fn %{item: item, has_files: has_files, has_downloads: has_downloads} ->
      CalendarEntry.new_movie(
        id: item.id,
        air_date: item.metadata.release_date,
        title: item.title,
        media_item_id: item.id,
        media_item_title: item.title,
        media_item_type: item.type,
        has_files: has_files,
        has_downloads: has_downloads,
        poster_path: item.metadata.poster_path,
        backdrop_path: item.metadata.backdrop_path
      )
    end)
  end
end
