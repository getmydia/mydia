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
  alias Mydia.Media
  alias Mydia.Media.RecentlyAdded
  alias Mydia.Metadata.Structs.MediaMetadata
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

  # The options that filter the items query itself. Everything else is applied
  # in memory, and :search in particular must stay out: Media's own :search
  # filter matches titles only, while the listing also matches original title,
  # year and overview.
  @filter_keys [:base_query, :exclude_categories, :type, :monitored]

  # Sort sentinels. Air dates are Dates, so these stay Dates: sorting a mix of
  # Date and NaiveDateTime raises.
  @never_aired ~D[1970-01-01]
  @no_upcoming_airing ~D[2999-12-31]

  @type page :: %{
          rows: [LibraryRow.t()],
          has_more?: boolean(),
          visible_ids: MapSet.t(binary()),
          empty?: boolean()
        }

  @doc """
  One page of a listing.

  `rows` is the page, with `user_id`'s playback progress. `visible_ids` covers
  every row the search and filters match, not only the page, so select-all can
  use it. `limit: 0` skips the progress query when only `visible_ids` is needed.

  Filter options go to `Mydia.Media.media_items_query/1`: `:base_query`,
  `:exclude_categories`, `:type`, `:monitored`. Applied in memory: `:search`,
  `:quality`, `:progress`, `:sort_by`, then `:offset` (default 0) and `:limit`.
  """
  @spec page(keyword()) :: page()
  def page(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    limit = Keyword.fetch!(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      opts
      |> Keyword.take(@filter_keys)
      |> Media.media_items_query()
      |> build_rows()
      |> search(Keyword.get(opts, :search) || "")
      |> filter_quality(Keyword.get(opts, :quality))
      |> filter_progress(Keyword.get(opts, :progress))
      |> sort(Keyword.get(opts, :sort_by))

    %{
      rows: rows |> Enum.drop(offset) |> Enum.take(limit) |> put_progress(user_id),
      has_more?: length(rows) > offset + limit,
      visible_ids: MapSet.new(rows, & &1.id),
      empty?: rows == []
    }
  end

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

  defp search(rows, ""), do: rows

  defp search(rows, query) do
    query = String.downcase(query)

    Enum.filter(rows, fn %LibraryRow{item: item} ->
      contains?(item.title, query) or contains?(item.original_title, query) or
        contains?(item.year && to_string(item.year), query) or
        contains?(overview(item.metadata), query)
    end)
  end

  defp contains?(nil, _query), do: false
  defp contains?(text, query), do: String.contains?(String.downcase(text), query)

  defp overview(%MediaMetadata{overview: overview}) when is_binary(overview), do: overview
  defp overview(_metadata), do: nil

  defp filter_quality(rows, nil), do: rows
  defp filter_quality(rows, quality), do: Enum.filter(rows, &(quality in &1.resolutions))

  defp filter_progress(rows, nil), do: rows
  defp filter_progress(rows, state), do: Enum.filter(rows, &(&1.status.state == state))

  defp sort(rows, "title_desc"), do: Enum.sort_by(rows, &title_key/1, :desc)
  defp sort(rows, "year_asc"), do: Enum.sort_by(rows, &(&1.item.year || 0), :asc)
  defp sort(rows, "year_desc"), do: Enum.sort_by(rows, &(&1.item.year || 0), :desc)
  defp sort(rows, "added_asc"), do: sort_by_added(rows, :asc)
  defp sort(rows, "added_desc"), do: sort_by_added(rows, :desc)
  defp sort(rows, "rating_asc"), do: Enum.sort_by(rows, &rating/1, :asc)
  defp sort(rows, "rating_desc"), do: Enum.sort_by(rows, &rating/1, :desc)

  defp sort(rows, "last_aired_asc"),
    do: Enum.sort_by(rows, &(&1.last_air_date || @never_aired), {:asc, Date})

  defp sort(rows, "last_aired_desc"),
    do: Enum.sort_by(rows, &(&1.last_air_date || @never_aired), {:desc, Date})

  defp sort(rows, "next_aired_asc"),
    do: Enum.sort_by(rows, &(&1.next_air_date || @no_upcoming_airing), {:asc, Date})

  defp sort(rows, "next_aired_desc"),
    do: Enum.sort_by(rows, &(&1.next_air_date || @no_upcoming_airing), {:desc, Date})

  defp sort(rows, "episode_count_asc"), do: Enum.sort_by(rows, & &1.episode_count, :asc)
  defp sort(rows, "episode_count_desc"), do: Enum.sort_by(rows, & &1.episode_count, :desc)

  # "title_asc", and anything unrecognised.
  defp sort(rows, _sort_by), do: Enum.sort_by(rows, &title_key/1, :asc)

  defp title_key(%LibraryRow{item: item}), do: String.downcase(item.title || "")

  defp rating(%LibraryRow{item: %MediaItem{metadata: %MediaMetadata{vote_average: rating}}})
       when is_number(rating),
       do: rating

  defp rating(_row), do: 0

  # A wanted item with no files has no content arrival time. Its own
  # inserted_at is then the only meaningful answer for "when was this added",
  # and it keeps the sort total.
  defp sort_by_added(rows, direction) do
    added_at = RecentlyAdded.added_at_map(ids: Enum.map(rows, & &1.id))

    Enum.sort_by(
      rows,
      &(Map.get(added_at, &1.id) || &1.item.inserted_at),
      {direction, DateTime}
    )
  end
end
