defmodule Mydia.Library.Export do
  @moduledoc """
  Builds a portable catalog of the library: one row per media item, as JSON or
  CSV. Served by `MydiaWeb.Api.LibraryExportController`.

  File counts come from `MediaFile.versions/0` (untrashed, not extras). An
  episode's file carries `episode_id` with `media_item_id` NULL, so a file's
  owner is `coalesce(mf.media_item_id, episode.media_item_id)`. Episodes with
  files are counted through `media_file_episodes`, because `episode_id` only
  names a multi-episode file's first episode.

  The JSON envelope uses the `items` key that
  `Mydia.ImportLists.Provider.CustomURL` reads, so a hosted export is a valid
  import list feed.
  """

  import Ecto.Query

  alias Mydia.Library.{MediaFile, MediaFileEpisode}
  alias Mydia.Library.Export.Row
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo
  alias Mydia.Settings.{LibraryPath, QualityProfile}

  @doc "Every media item as an export row, sorted by type, title, year."
  @spec rows() :: [Row.t()]
  def rows do
    files = file_totals()
    episodes = episode_totals()
    covered = covered_episode_totals()

    items_query()
    |> Repo.all()
    |> Enum.map(&to_row(&1, files, episodes, covered))
    |> Enum.sort_by(&{&1.type, String.downcase(&1.title), &1.year})
  end

  defp items_query do
    from(m in MediaItem,
      left_join: qp in QualityProfile,
      on: qp.id == m.quality_profile_id,
      left_join: lp in LibraryPath,
      on: lp.id == m.library_path_id,
      select: %{item: m, quality_profile: qp.name, library_path: lp.path}
    )
  end

  # %{media_item_id => {file_count, size_bytes}}
  defp file_totals do
    from(mf in MediaFile.versions(),
      left_join: e in Episode,
      on: e.id == mf.episode_id,
      where: not is_nil(coalesce(mf.media_item_id, e.media_item_id)),
      group_by: coalesce(mf.media_item_id, e.media_item_id),
      select:
        {coalesce(mf.media_item_id, e.media_item_id), count(mf.id), sum(coalesce(mf.size, 0))}
    )
    |> Repo.all()
    |> Map.new(fn {id, count, size} -> {id, {count, to_int(size)}} end)
  end

  # %{media_item_id => episode_count}
  defp episode_totals do
    from(e in Episode, group_by: e.media_item_id, select: {e.media_item_id, count(e.id)})
    |> Repo.all()
    |> Map.new()
  end

  # %{media_item_id => episodes_with_files}
  defp covered_episode_totals do
    from(link in MediaFileEpisode,
      join: mf in subquery(MediaFile.versions()),
      on: mf.id == link.media_file_id,
      join: e in Episode,
      on: e.id == link.episode_id,
      group_by: e.media_item_id,
      select: {e.media_item_id, count(e.id, :distinct)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp to_row(%{item: m} = r, files, episodes, covered) do
    {file_count, size_bytes} = Map.get(files, m.id, {0, 0})
    tv? = m.type == "tv_show"

    %Row{
      type: m.type,
      title: m.title,
      original_title: m.original_title,
      year: m.year,
      tmdb_id: m.tmdb_id,
      tvdb_id: m.tvdb_id,
      imdb_id: m.imdb_id,
      metadata_source: m.metadata_source && Atom.to_string(m.metadata_source),
      category: m.category,
      monitored: m.monitored,
      quality_profile: r.quality_profile,
      library_path: r.library_path,
      file_count: file_count,
      size_bytes: size_bytes,
      episode_count: if(tv?, do: Map.get(episodes, m.id, 0)),
      episodes_with_files: if(tv?, do: Map.get(covered, m.id, 0)),
      added_at: m.inserted_at
    }
  end

  # PostgreSQL returns sum/1 as Decimal, SQLite as integer.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
