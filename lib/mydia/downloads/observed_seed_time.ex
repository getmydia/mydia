defmodule Mydia.Downloads.ObservedSeedTime do
  @moduledoc """
  Seed time Mydia counts itself, for clients that do not report their own
  (rTorrent, rqbit).

  Each `Mydia.Jobs.DownloadMonitor` pass calls `record/2` with the polled
  rows. For a download under a seeding goal whose client reports no seed
  time, the time between two consecutive passes that both saw the torrent
  seeding is added to a running total in `Download.metadata`:

      "observed_seeding" => %{"seconds" => 5400, "last_seen_at" => "2031-05-10T12:00:00Z"}

  A gap between passes longer than `@max_step_seconds` (three cron
  intervals) credits nothing: Mydia was down or the client unreachable, and
  the torrent may have stopped in between. A pass that sees the torrent not
  seeding, or only a stale snapshot of it, clears `last_seen_at` and adds
  nothing, so a stopped torrent keeps what it seeded and paused time is not
  counted. Recording never fails the monitor's poll.

  `seconds/1` feeds the total to `Mydia.Downloads.SeedingGoal` as the
  reported seed time. No migration: the total lives in the metadata JSON.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.DB
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
        gap = DateTime.diff(now, last, :second)
        if gap in 0..@max_step_seconds, do: gap, else: 0

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
    |> Enum.each(&write(&1.id, SeedingGoal.currently_seeding?(&1), now))
  rescue
    exception ->
      Logger.error("Recording observed seed time failed; the poll continues",
        error: Exception.message(exception)
      )

      :ok
  end

  defp tracked?(row) do
    is_nil(Map.get(row, :seeding_time)) and SeedingGoal.applies?(SeedingGoal.terms(row)) and
      (SeedingGoal.currently_seeding?(row) or Map.has_key?(row.metadata, @key))
  end

  # The step is computed from the metadata read under the same transaction
  # that writes it (locked on PostgreSQL, serialized writes on SQLite, as in
  # `Mydia.Downloads.Removal`), so another writer's keys are kept. A plain
  # update_all: this runs every poll, and update_download/2 would broadcast a
  # Downloads page reload each time.
  defp write(id, seeding?, now) do
    Repo.transaction(fn -> id |> locked_row() |> Repo.one() |> step_row(seeding?, now) end)
  end

  defp locked_row(id) do
    query = where(Download, [d], d.id == ^id)
    if DB.postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  defp step_row(nil, _seeding?, _now), do: :ok

  defp step_row(%Download{id: id, metadata: metadata}, seeding?, now) do
    metadata = metadata || %{}
    previous = Map.get(metadata, @key)
    entry = step(previous, seeding?, now)
    if entry != previous, do: update_metadata(id, Map.put(metadata, @key, entry))
  end

  defp update_metadata(id, metadata),
    do: Repo.update_all(where(Download, [d], d.id == ^id), set: [metadata: metadata])
end
