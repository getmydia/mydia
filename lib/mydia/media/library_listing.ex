defmodule Mydia.Media.LibraryListing do
  @moduledoc """
  The rows behind the `/movies`, `/tv` and section listings.

  A listing card needs a few per-item facts: availability, the resolutions on
  disk, total size, episode count and air dates. Each is an aggregate over the
  item's episodes, files and downloads, so they are computed in SQL and no
  episode, file or download row is loaded. A show with 400 episodes costs the
  same as a show with 4.

  Availability goes through `AvailabilityStatus.for_movie/3` and
  `AvailabilityStatus.for_series/3`, the functions `Media.get_media_status/1`
  also uses, so a row's badge agrees with every other place that reports an
  item's status.

  Files are `MediaFile.versions/0` throughout: trashed rows and extras never
  count as content.
  """

  import Ecto.Query

  alias Mydia.Downloads.Download
  alias Mydia.Library.MediaFile
  alias Mydia.Library.MediaFileEpisode
  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.Episode
  alias Mydia.Media.LibraryRow
  alias Mydia.Media.MediaItem
  alias Mydia.Playback.Progress
  alias Mydia.Repo

  @no_episodes %{total: 0, downloaded: 0, downloading: 0, upcoming: 0}
  @no_series %{
    all: @no_episodes,
    monitored: @no_episodes,
    last_air_date: nil,
    next_air_date: nil
  }
  @no_files %{file_count: 0, resolutions: [], total_size: 0}

  @doc """
  The row for one item, with `user_id`'s playback progress, or nil if the item
  does not exist. Used to refresh a single card after it changes.
  """
  @spec row(binary(), binary()) :: LibraryRow.t() | nil
  def row(id, user_id) do
    from(m in MediaItem, where: m.id == ^id)
    |> build_rows()
    |> put_progress(user_id)
    |> List.first()
  end

  # Loads the items, then scopes every aggregate to the same query, so a
  # smart-section base query is evaluated identically each time.
  defp build_rows(items_query) do
    case Repo.all(items_query) do
      [] ->
        []

      items ->
        ids = from(m in items_query, select: m.id)
        series = series_counts(ids)
        files = file_counts(ids)
        downloading = downloading_item_ids(ids)

        Enum.map(items, &to_row(&1, series, files, downloading))
    end
  end

  defp to_row(%MediaItem{type: "movie"} = item, _series, files, downloading) do
    files = Map.get(files, item.id, @no_files)

    %LibraryRow{
      id: item.id,
      item: item,
      status:
        AvailabilityStatus.for_movie(
          files.file_count,
          MapSet.member?(downloading, item.id),
          item.monitored
        ),
      resolutions: files.resolutions,
      total_size: files.total_size
    }
  end

  defp to_row(%MediaItem{type: "tv_show"} = item, series, files, _downloading) do
    files = Map.get(files, item.id, @no_files)
    series = Map.get(series, item.id, @no_series)

    %LibraryRow{
      id: item.id,
      item: item,
      status: AvailabilityStatus.for_series(series.all, series.monitored, item.monitored),
      resolutions: files.resolutions,
      total_size: files.total_size,
      episode_count: series.all.total,
      last_air_date: series.last_air_date,
      next_air_date: series.next_air_date
    }
  end

  # Per show: episode counts over every episode and over the monitored ones,
  # the latest air date (future episodes included, as the listing always
  # sorted) and the next air date after today.
  defp series_counts(ids) do
    today = Date.utc_today()

    files_by_episode =
      from mf in MediaFile.versions(),
        join: mfe in MediaFileEpisode,
        on: mfe.media_file_id == mf.id,
        join: e in Episode,
        on: e.id == mfe.episode_id,
        where: e.media_item_id in subquery(ids),
        group_by: mfe.episode_id,
        select: %{episode_id: mfe.episode_id}

    downloading_by_episode =
      from d in active_downloads(),
        join: e in Episode,
        on: e.id == d.episode_id,
        where: e.media_item_id in subquery(ids),
        group_by: d.episode_id,
        select: %{episode_id: d.episode_id}

    from(e in Episode,
      left_join: f in subquery(files_by_episode),
      on: f.episode_id == e.id,
      left_join: d in subquery(downloading_by_episode),
      on: d.episode_id == e.id,
      where: e.media_item_id in subquery(ids),
      group_by: e.media_item_id,
      select: {
        e.media_item_id,
        count(e.id),
        count(f.episode_id),
        count(d.episode_id),
        filter(count(e.id), e.air_date > ^today),
        filter(count(e.id), e.monitored),
        filter(count(f.episode_id), e.monitored),
        filter(count(d.episode_id), e.monitored),
        filter(count(e.id), e.monitored and e.air_date > ^today),
        # Explicit casts, as RecentlyAdded does for its timestamps: SQLite
        # returns an aggregate over a TEXT date column as a string otherwise.
        type(max(e.air_date), :date),
        type(filter(min(e.air_date), e.air_date > ^today), :date)
      }
    )
    |> Repo.all()
    |> Map.new(fn {id, total, downloaded, downloading, upcoming, monitored_total,
                   monitored_downloaded, monitored_downloading, monitored_upcoming, last_air_date,
                   next_air_date} ->
      {id,
       %{
         all: %{
           total: total,
           downloaded: downloaded,
           downloading: downloading,
           upcoming: upcoming
         },
         monitored: %{
           total: monitored_total,
           downloaded: monitored_downloaded,
           downloading: monitored_downloading,
           upcoming: monitored_upcoming
         },
         last_air_date: last_air_date,
         next_air_date: next_air_date
       }}
    end)
  end

  # Per item: the count of its own version files (a movie's), and the
  # resolutions and summed size of those files plus every episode's files, one
  # row per (episode, file) link, which is how the listing always summed them.
  defp file_counts(ids) do
    own_files =
      from(mf in MediaFile.versions(),
        where: mf.media_item_id in subquery(ids),
        group_by: [mf.media_item_id, mf.resolution],
        select: {mf.media_item_id, mf.resolution, count(mf.id), type(sum(mf.size), :integer)}
      )
      |> Repo.all()

    episode_files =
      from(mf in MediaFile.versions(),
        join: mfe in MediaFileEpisode,
        on: mfe.media_file_id == mf.id,
        join: e in Episode,
        on: e.id == mfe.episode_id,
        where: e.media_item_id in subquery(ids),
        group_by: [e.media_item_id, mf.resolution],
        select: {e.media_item_id, mf.resolution, type(sum(mf.size), :integer)}
      )
      |> Repo.all()
      # An episode's file is not one of the item's own files, so it adds
      # nothing to file_count.
      |> Enum.map(fn {id, resolution, size} -> {id, resolution, 0, size} end)

    Enum.reduce(own_files ++ episode_files, %{}, fn {id, resolution, count, size}, acc ->
      entry = Map.get(acc, id, @no_files)

      Map.put(acc, id, %{
        file_count: entry.file_count + count,
        resolutions:
          if(resolution, do: Enum.uniq([resolution | entry.resolutions]), else: entry.resolutions),
        total_size: entry.total_size + (size || 0)
      })
    end)
  end

  defp downloading_item_ids(ids) do
    from(d in active_downloads(),
      where: d.media_item_id in subquery(ids),
      distinct: true,
      select: d.media_item_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # Mydia.Media.download_active?/1 in SQL. Change the two together.
  defp active_downloads do
    from d in Download, where: is_nil(d.completed_at) and is_nil(d.error_message)
  end

  defp put_progress([], _user_id), do: []

  # Only for rows about to render. The first row per item wins, as the
  # unordered has_many preload this replaces did.
  defp put_progress(rows, user_id) do
    ids = Enum.map(rows, & &1.id)

    progress =
      from(p in Progress, where: p.user_id == ^user_id and p.media_item_id in ^ids)
      |> Repo.all()
      |> Enum.group_by(& &1.media_item_id)

    Enum.map(rows, fn row ->
      case Map.get(progress, row.id) do
        [first | _] -> %LibraryRow{row | progress: first}
        nil -> row
      end
    end)
  end
end
