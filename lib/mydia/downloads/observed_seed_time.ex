defmodule Mydia.Downloads.ObservedSeedTime do
  @moduledoc """
  Seed time Mydia counts itself, for clients that do not report their own
  (rTorrent, rqbit).

  Each `Mydia.Jobs.DownloadMonitor` pass calls `record/2` with the polled
  rows. For a download under a seeding goal whose client reports no seed
  time, the time between two consecutive passes that both saw the torrent
  seeding is added to a running total in `Download.metadata`:

      "observed_seeding" => %{"seconds" => 5400, "last_seen_at" => "2031-05-10T12:00:00Z"}

  One step is capped at `@max_step_seconds` (three cron intervals), so time
  Mydia was down or the client unreachable is never counted. A pass that sees
  the torrent not seeding clears `last_seen_at` and adds nothing, so a
  stopped torrent keeps what it seeded and paused time is not counted.

  `seconds/1` feeds the total to `Mydia.Downloads.SeedingGoal` as the
  reported seed time. No migration: the total lives in the metadata JSON.
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.{Download, SeedingGoal}
  alias Mydia.Repo

  @key "observed_seeding"
  @max_step_seconds 360

  @doc "Seconds Mydia has seen the download seeding, or nil when it never counted."
  @spec seconds(map()) :: non_neg_integer() | nil
  def seconds(%{metadata: %{@key => %{"seconds" => seconds}}})
      when is_integer(seconds) and seconds >= 0,
      do: seconds

  def seconds(_download), do: nil

  @doc """
  The next tracking entry, given the previous one (or nil), whether the
  client reports the torrent seeding now, and the time of this pass.
  """
  @spec step(map() | nil, boolean(), DateTime.t()) :: map()
  def step(entry, seeding?, now) do
    entry = entry || %{"seconds" => 0, "last_seen_at" => nil}
    seconds = Map.get(entry, "seconds", 0)

    if seeding? do
      %{"seconds" => seconds + elapsed(entry["last_seen_at"], now), "last_seen_at" => iso(now)}
    else
      %{"seconds" => seconds, "last_seen_at" => nil}
    end
  end

  defp elapsed(last_seen_at, now) when is_binary(last_seen_at) do
    case DateTime.from_iso8601(last_seen_at) do
      {:ok, last, _offset} ->
        DateTime.diff(now, last, :second) |> max(0) |> min(@max_step_seconds)

      _invalid ->
        0
    end
  end

  defp elapsed(_never_seen, _now), do: 0

  defp iso(now), do: now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc """
  Updates the running totals for the polled rows (enriched downloads) that
  need one. A row is tracked when its frozen terms set a seeding goal and its
  client reports no seed time. Writes only rows whose entry changed.
  """
  @spec record([map()], DateTime.t()) :: :ok
  def record(rows, now \\ DateTime.utc_now()) do
    rows
    |> Enum.filter(&tracked?/1)
    |> Enum.each(&record_row(&1, now))
  end

  defp tracked?(row) do
    is_nil(Map.get(row, :seeding_time)) and SeedingGoal.applies?(SeedingGoal.terms(row)) and
      (row.status == "seeding" or Map.has_key?(row.metadata, @key))
  end

  defp record_row(row, now) do
    previous = Map.get(row.metadata, @key)
    entry = step(previous, row.status == "seeding", now)

    if entry != previous, do: write(row.id, entry)
  end

  # Re-read the metadata right before writing so another writer's keys are
  # kept. A plain update_all: this runs every poll, and update_download/2
  # would broadcast a Downloads page reload each time.
  defp write(id, entry) do
    case Repo.get(Download, id) do
      nil ->
        :ok

      %Download{metadata: metadata} ->
        metadata = Map.put(metadata || %{}, @key, entry)
        Repo.update_all(where(Download, [d], d.id == ^id), set: [metadata: metadata])
    end
  end
end
