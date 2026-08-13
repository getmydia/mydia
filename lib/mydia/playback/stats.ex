defmodule Mydia.Playback.Stats do
  @moduledoc """
  Aggregate playback reporting for the admin dashboard.

  Separate from `Mydia.Playback`, which is already large and is about the write
  path, and from `Mydia.Events`, which is a generic event store that should not
  grow playback-specific reporting.
  """

  import Ecto.Query

  alias Mydia.Accounts.User
  alias Mydia.Events.Event
  alias Mydia.Media.Episode
  alias Mydia.Media.MediaItem
  alias Mydia.Playback.Progress
  alias Mydia.Repo

  # Filtering and de-duplication both shrink the scanned set, so read more rows
  # than asked for. Bounded so a server with a long history does not load its
  # whole play log to render twenty lines.
  @scan_factor 5
  @scan_ceiling 200

  @doc """
  Plays per local day, split into movies and episodes.

  Returns a dense list oldest first, one entry per day in the window, so a day
  with no plays renders as a zero bar rather than being skipped.

  Bucketing happens in Elixir rather than SQL on purpose: SQLite spells day
  truncation `strftime` and PostgreSQL spells it `date_trunc`, and this is the
  only place the query would need to know which adapter it is on. Thirty days
  of plays on a self-hosted server is a few hundred rows.
  """
  @spec plays_by_day(pos_integer()) :: [
          %{date: Date.t(), movies: non_neg_integer(), episodes: non_neg_integer()}
        ]
  def plays_by_day(days \\ 30) when is_integer(days) and days > 0 do
    offset = local_utc_offset()
    today = local_today(offset)
    first_day = Date.add(today, -(days - 1))

    counts =
      first_day
      |> fetch_events(today, offset)
      |> Enum.reduce(%{}, fn {at, resource_type}, acc ->
        date = bucket_date(at, offset)

        if within?(date, first_day, today) do
          Map.update(acc, {date, resource_type}, 1, &(&1 + 1))
        else
          acc
        end
      end)

    Enum.map(0..(days - 1), fn index ->
      date = Date.add(first_day, index)

      %{
        date: date,
        movies: Map.get(counts, {date, "media_item"}, 0),
        episodes: Map.get(counts, {date, "episode"}, 0)
      }
    end)
  end

  @doc """
  Today's date in the host's local time.
  """
  @spec local_today(integer() | nil) :: Date.t()
  def local_today(offset \\ nil) do
    offset = offset || local_utc_offset()
    DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.to_date()
  end

  @doc """
  The local calendar date a UTC timestamp falls on, given a UTC offset in seconds.
  """
  @spec bucket_date(DateTime.t(), integer()) :: Date.t()
  def bucket_date(%DateTime{} = at, offset) do
    at |> DateTime.add(offset, :second) |> DateTime.to_date()
  end

  # Named-zone conversion needs a tz database, which this project does not
  # carry and should not add for one chart. The gap between the VM's local and
  # universal time is the host's current UTC offset, which honours the
  # container's TZ variable and falls back to 0 when it is unset.
  #
  # Sampled once and applied across the window, so a DST transition inside the
  # window shifts one day boundary by an hour. That is an acceptable trade for
  # not carrying tzdata.
  @spec local_utc_offset() :: integer()
  def local_utc_offset do
    local = NaiveDateTime.from_erl!(:calendar.local_time())
    universal = NaiveDateTime.from_erl!(:calendar.universal_time())

    NaiveDateTime.diff(local, universal, :second)
  end

  # Widen the UTC window by a day on each end so a local-evening play under a
  # negative offset, which lands on the following UTC day, is still fetched.
  # The bucketing pass above discards whatever falls outside the local window.
  defp fetch_events(first_day, today, offset) do
    from_utc =
      first_day
      |> Date.add(-1)
      |> DateTime.new!(~T[00:00:00])
      |> DateTime.add(-offset, :second)

    to_utc =
      today
      |> Date.add(2)
      |> DateTime.new!(~T[00:00:00])
      |> DateTime.add(-offset, :second)

    Event
    |> where([e], e.type == "playback.started")
    |> where([e], e.inserted_at >= ^from_utc and e.inserted_at < ^to_utc)
    |> select([e], {e.inserted_at, e.resource_type})
    |> Repo.all()
  end

  defp within?(date, first_day, today) do
    Date.compare(date, first_day) != :lt and Date.compare(date, today) != :gt
  end

  @doc """
  Recent plays that happened on this server, newest first.

  Sourced from `playback.started` events, which only a real streaming session
  emits, rather than from playback progress rows. A media-server sync writes
  progress for watches that happened on somebody else's box, and stamps
  `last_watched_at` with the sync time whenever the remote carries no timestamp
  (`Mydia.WatchSync.Engine.apply_local/5`), so ordering progress by that column
  buried every local play under a wall of imported history. This is the same
  rule `Mydia.Streaming.emit_playback_started/2` already documents for the
  plays-per-day chart.

  Returns unsaved `Progress` structs used purely as a view model: they carry the
  viewer and the resolved episode or media item, so `progress_title/1` and
  `progress_poster_path/1` render a play exactly as they render a history row.
  `last_watched_at` is the moment playback started.

  Plays whose content has since been deleted are dropped rather than rendered
  as "Unknown Media".
  """
  @spec recent_plays(pos_integer()) :: [Progress.t()]
  def recent_plays(limit \\ 20) when is_integer(limit) and limit > 0 do
    limit
    |> fetch_recent_starts()
    |> Enum.uniq_by(&{&1.actor_id, &1.resource_type, &1.resource_id})
    |> Enum.take(limit)
    |> resolve_plays()
  end

  defp fetch_recent_starts(limit) do
    scan = min(limit * @scan_factor, @scan_ceiling)

    Event
    |> where([e], e.type == "playback.started")
    # `inserted_at` is second-granularity, so a stable tiebreak is needed or two
    # plays in the same second could swap places between renders.
    |> order_by([e], desc: e.inserted_at, desc: e.id)
    |> limit(^scan)
    |> Repo.all()
  end

  defp resolve_plays([]), do: []

  defp resolve_plays(events) do
    episodes = load_by_id(Episode, events, "episode", preload: :media_item)
    items = load_by_id(MediaItem, events, "media_item")
    users = load_users(events)

    Enum.flat_map(events, fn event ->
      case play_content(event, episodes, items) do
        nil ->
          []

        content ->
          play = %Progress{
            user: Map.get(users, event.actor_id),
            last_watched_at: event.inserted_at
          }

          [struct(play, content)]
      end
    end)
  end

  defp play_content(%{resource_type: "episode", resource_id: id}, episodes, _items) do
    case Map.fetch(episodes, id) do
      {:ok, episode} -> %{episode: episode, episode_id: id}
      :error -> nil
    end
  end

  defp play_content(%{resource_type: "media_item", resource_id: id}, _episodes, items) do
    case Map.fetch(items, id) do
      {:ok, item} -> %{media_item: item, media_item_id: id}
      :error -> nil
    end
  end

  defp play_content(_event, _episodes, _items), do: nil

  defp load_by_id(schema, events, resource_type, opts \\ []) do
    ids =
      for event <- events, event.resource_type == resource_type, do: event.resource_id

    case Enum.uniq(ids) do
      [] ->
        %{}

      ids ->
        schema
        |> where([r], r.id in ^ids)
        |> preload(^Keyword.get(opts, :preload, []))
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  # `actor_id` is a string column, since system actors are not UUIDs. Anything
  # that is not a user id simply finds no row and renders without a name.
  defp load_users(events) do
    ids = events |> Enum.map(& &1.actor_id) |> Enum.uniq() |> Enum.reject(&is_nil/1)

    case ids do
      [] -> %{}
      ids -> User |> where([u], u.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    end
  end
end
