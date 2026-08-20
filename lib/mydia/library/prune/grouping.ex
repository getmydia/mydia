defmodule Mydia.Library.Prune.Grouping do
  @moduledoc """
  Finds media items that hold more than one active file.

  Two separate queries, because a TV `media_file` carries `episode_id` with
  `media_item_id` NULL. A single join from `media_items` would silently return
  nothing for shows.
  """

  import Ecto.Query

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune.Group
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo

  @doc """
  Every group in the library, episodes and movies together.

  Files come back with `:library_path` preloaded so `MediaFile.absolute_path/1`
  resolves without a second query per file.
  """
  @spec list_groups() :: [Group.t()]
  def list_groups do
    episode_groups() ++ movie_groups()
  end

  defp episode_groups do
    ids = multi_file_ids(:episode_id)

    if ids == [] do
      []
    else
      episodes =
        Episode
        |> where([e], e.id in ^ids)
        |> preload(media_item: [:episodes, :quality_profile])
        |> Repo.all()

      files_by_subject = files_for(:episode_id, ids)

      for episode <- episodes, files = Map.get(files_by_subject, episode.id, []), files != [] do
        %Group{
          subject_type: :episode,
          subject_id: episode.id,
          subject: episode,
          media_item: episode.media_item,
          files: files
        }
      end
    end
  end

  defp movie_groups do
    ids = multi_file_ids(:media_item_id)

    if ids == [] do
      []
    else
      items =
        MediaItem
        |> where([m], m.id in ^ids)
        |> preload([:episodes, :quality_profile])
        |> Repo.all()

      files_by_subject = files_for(:media_item_id, ids)

      for item <- items, files = Map.get(files_by_subject, item.id, []), files != [] do
        %Group{
          subject_type: :movie,
          subject_id: item.id,
          subject: item,
          media_item: item,
          files: files
        }
      end
    end
  end

  # `count(mf.id)` rather than `count()` over a boolean or a nullable column:
  # boolean aggregates pass on SQLite and crash on PostgreSQL.
  defp multi_file_ids(field) do
    MediaFile
    |> where([mf], is_nil(mf.trashed_at) and not is_nil(field(mf, ^field)))
    |> group_by([mf], field(mf, ^field))
    |> having([mf], count(mf.id) > 1)
    |> select([mf], field(mf, ^field))
    |> Repo.all()
  end

  defp files_for(field, ids) do
    MediaFile
    |> where([mf], is_nil(mf.trashed_at) and field(mf, ^field) in ^ids)
    |> preload([:library_path])
    |> Repo.all()
    |> Enum.group_by(&Map.fetch!(&1, field))
  end
end
