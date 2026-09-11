defmodule MydiaWeb.LibrarySchema.Loaders do
  @moduledoc """
  Loads what a mutation's arguments name, or the `UserError` to report instead.

  Every mutation that takes an id needs the same three answers (malformed, names
  nothing, found) and the same preloads before `MediaItemView.item_map/1` can
  run, so they live here once.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias MydiaWeb.LibrarySchema.MediaItemView
  alias MydiaWeb.LibrarySchema.UserError

  @doc "The media item `id` names, preloaded for `MediaItemView.item_map/1`."
  @spec item(term(), [String.t()]) :: {:ok, MediaItem.t()} | {:error, UserError.t()}
  def item(id, field) do
    with {:ok, id} <- UserError.cast_id(id, field) do
      case load(id) do
        nil -> {:error, UserError.not_found("media item", field)}
        item -> {:ok, item}
      end
    end
  end

  @doc """
  The GraphQL map for a freshly reloaded item, or nil when it is gone.

  Reloaded rather than reusing a struct a context function returned: the payload
  must carry the preloads `item_map/1` reads, and updates do not return them.
  """
  @spec item_map(Ecto.UUID.t()) :: map() | nil
  def item_map(id) do
    case load(id) do
      nil -> nil
      item -> MediaItemView.item_map(item)
    end
  end

  @doc """
  The episode `id` names, with the media files `hasFile` reads.

  `get_episode!/2` is the context's only single-episode getter, hence the rescue.
  """
  @spec episode(term(), [String.t()]) :: {:ok, Episode.t()} | {:error, UserError.t()}
  def episode(id, field) do
    with {:ok, id} <- UserError.cast_id(id, field) do
      try do
        {:ok, Media.get_episode!(id, preload: [media_files: MediaFile.versions()])}
      rescue
        Ecto.NoResultsError -> {:error, UserError.not_found("episode", field)}
      end
    end
  end

  @doc "Refuses anything but a TV show, for season and episode operations."
  @spec require_show(MediaItem.t(), [String.t()]) :: :ok | {:error, UserError.t()}
  def require_show(%MediaItem{type: "tv_show"}, _field), do: :ok

  def require_show(%MediaItem{}, field),
    do: {:error, UserError.new(:invalid_input, "Only TV shows have seasons and episodes", field)}

  defp load(id) do
    case Media.list_media_items(ids: [id], preload: MediaItemView.preloads()) do
      [item | _] -> item
      [] -> nil
    end
  end
end
