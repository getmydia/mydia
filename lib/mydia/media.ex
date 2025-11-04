defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Media.{MediaItem, Episode}

  ## Media Items

  @doc """
  Returns the list of media items.

  ## Options
    - `:type` - Filter by type ("movie" or "tv_show")
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  def list_media_items(opts \\ []) do
    MediaItem
    |> apply_media_item_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single media item.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the media item does not exist.
  """
  def get_media_item!(id, opts \\ []) do
    MediaItem
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single media item by TMDB ID.
  """
  def get_media_item_by_tmdb(tmdb_id, opts \\ []) do
    MediaItem
    |> where([m], m.tmdb_id == ^tmdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a media item.
  """
  def create_media_item(attrs \\ %{}) do
    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a media item.
  """
  def update_media_item(%MediaItem{} = media_item, attrs) do
    media_item
    |> MediaItem.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a media item.
  """
  def delete_media_item(%MediaItem{} = media_item) do
    Repo.delete(media_item)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  ## Episodes

  @doc """
  Returns the list of episodes for a media item.

  ## Options
    - `:season` - Filter by season number
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  def list_episodes(media_item_id, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> apply_episode_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([e], asc: e.season_number, asc: e.episode_number)
    |> Repo.all()
  end

  @doc """
  Gets a single episode.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the episode does not exist.
  """
  def get_episode!(id, opts \\ []) do
    Episode
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single episode by media item ID, season, and episode number.
  """
  def get_episode_by_number(media_item_id, season_number, episode_number, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates an episode.
  """
  def create_episode(attrs \\ %{}) do
    %Episode{}
    |> Episode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an episode.
  """
  def update_episode(%Episode{} = episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an episode.
  """
  def delete_episode(%Episode{} = episode) do
    Repo.delete(episode)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking episode changes.
  """
  def change_episode(%Episode{} = episode, attrs \\ %{}) do
    Episode.changeset(episode, attrs)
  end

  ## Private Functions

  defp apply_media_item_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:type, type}, query ->
        where(query, [m], m.type == ^type)

      {:monitored, monitored}, query ->
        where(query, [m], m.monitored == ^monitored)

      _other, query ->
        query
    end)
  end

  defp apply_episode_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:season, season}, query ->
        where(query, [e], e.season_number == ^season)

      {:monitored, monitored}, query ->
        where(query, [e], e.monitored == ^monitored)

      _other, query ->
        query
    end)
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
