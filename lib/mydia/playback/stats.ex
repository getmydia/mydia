defmodule Mydia.Playback.Stats do
  @moduledoc """
  Aggregate playback reporting for the admin dashboard.

  Separate from `Mydia.Playback`, which is already large and is about the write
  path, and from `Mydia.Events`, which is a generic event store that should not
  grow playback-specific reporting.
  """

  import Ecto.Query

  alias Mydia.Events.Event
  alias Mydia.Repo

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
end
