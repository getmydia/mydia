defmodule Mydia.Downloads.ObservedUpload do
  @moduledoc """
  Upload totals Mydia keeps itself, for clients whose counter covers only the
  current session (`DownloadStatus.uploaded_session_only?`, set by rqbit).

  rqbit 9.0.1 reports `uploaded_bytes` only while a torrent is live: it reads
  0 once the torrent is paused and restarts from 0 after a client restart.
  Without a kept total the ratio drops to 0.00 after
  `Mydia.Downloads.BuiltIn.SeedingPolicy` pauses a torrent, and ratio-based
  seeding goals start over on every pause.

  Each `Mydia.Jobs.DownloadMonitor` pass calls `record/2`, which banks the
  client's counter into `Download.metadata`:

      "observed_upload" => %{"bytes" => 5368709120, "session" => 1073741824,
                             "seen_at" => "2031-05-10T12:00:00Z"}

  `bytes` is the running total, `session` the client's counter as last
  recorded, `seen_at` when the counter that last changed them was read
  (`step/3` ignores an older read from an overlapping pass). `step/2` moves
  it on:

  - no entry (or a malformed one): `bytes` and `session` are the counter, so
    the current session counts in full on first sight. Uploads from sessions
    that ended before Mydia first saw the torrent are lost.
  - counter at or above `session`: the growth is added.
  - counter below `session`: the client reset (pause or restart), and the
    whole counter is new uploads.

  A pause or restart between two passes loses at most one interval's
  uploads: the total undercounts, which errs toward seeding longer. The
  policies run after `record/2` in the same pass, so their own pause loses
  nothing.

  `overlay/1` replaces `uploaded` and `ratio` on an enriched row with the
  total (`Mydia.Downloads.History` applies it to every row it builds), and
  `overlay_status/2` does the same for a fresh `DownloadStatus`
  (`Mydia.Downloads.ClientRemoval`). No migration: the total lives in the
  metadata JSON.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.DB
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Repo

  @key "observed_upload"

  @doc "The stored entry when well formed, else nil."
  @spec entry(map() | nil) :: map() | nil
  def entry(%{@key => %{"bytes" => bytes, "session" => session} = entry})
      when is_integer(bytes) and bytes >= 0 and is_integer(session) and session >= 0,
      do: entry

  def entry(_metadata), do: nil

  @doc "The next entry, given the previous one (or nil) and the client's live counter."
  @spec step(map() | nil, non_neg_integer()) :: map()
  def step(entry, live) do
    case entry(%{@key => entry}) do
      nil ->
        %{"bytes" => live, "session" => live}

      %{"bytes" => bytes, "session" => session} when live >= session ->
        next(bytes + live - session, live)

      %{"bytes" => bytes} ->
        next(bytes + live, live)
    end
  end

  defp next(bytes, live), do: %{"bytes" => bytes, "session" => live}

  @doc """
  `step/2` for a counter read at `now`. A change is stamped `"seen_at"`; an
  entry the counter leaves as it was is returned untouched, so a quiet
  torrent costs no write. A counter read no later than `"seen_at"` is older
  than the one that last changed the entry (overlapping monitor passes): it
  would read as a reset and be added in full, so it changes nothing.
  """
  @spec step(map() | nil, non_neg_integer(), DateTime.t()) :: map()
  def step(entry, live, now) do
    stepped = step(entry, live)
    valid = entry(%{@key => entry})

    cond do
      valid && out_of_order?(valid, now) -> valid
      valid && Map.take(valid, ["bytes", "session"]) == stepped -> valid
      # Full precision: two passes in the same second must still be ordered.
      true -> Map.put(stepped, "seen_at", DateTime.to_iso8601(now))
    end
  end

  defp out_of_order?(%{"seen_at" => seen_at}, now) when is_binary(seen_at) do
    case DateTime.from_iso8601(seen_at) do
      {:ok, seen, _offset} -> DateTime.compare(now, seen) != :gt
      _invalid -> false
    end
  end

  defp out_of_order?(_entry, _now), do: false

  @doc "The total after this counter, without recording it."
  @spec total(map() | nil, non_neg_integer()) :: non_neg_integer()
  def total(entry, live), do: step(entry, live)["bytes"]

  @doc """
  A row with `uploaded` and `ratio` read from the kept total. Only a row whose
  client counts per session and that is in the client changes. A stale row
  (`status_as_of` set, a cached counter) adds only growth past the stored
  session, and nothing when it was read no later than the stored entry: a
  counter older than the stored one is not a reset, and a snapshot from
  before the entry holds uploads already counted. The ratio is left as
  reported when `size` is unknown or 0.
  """
  @spec overlay(map()) :: map()
  def overlay(row) do
    cond do
      not overlaid?(row) ->
        row

      is_nil(Map.get(row, :status_as_of)) ->
        overlaid(row, entry(row.metadata), live(row.live_uploaded), row.size)

      true ->
        read_at = read_at(row, row.status_as_of)
        uploaded = stale_total(entry(row.metadata), live(row.live_uploaded), read_at)
        with_total(row, uploaded, row.size)
    end
  end

  defp stale_total(nil, live, _read_at), do: live

  defp stale_total(%{"bytes" => bytes, "session" => session} = entry, live, read_at) do
    if out_of_order?(entry, read_at), do: bytes, else: bytes + max(live - session, 0)
  end

  @doc """
  Sets an enriched row's upload fields from the client's status:
  `live_uploaded` and `uploaded_session_only?` as reported, and `uploaded`
  and `ratio` through `overlay/1`.
  """
  @spec put_upload(map(), DownloadStatus.t() | map()) :: map()
  def put_upload(row, status) do
    overlay(%{
      row
      | uploaded: status.uploaded,
        ratio: status.ratio,
        live_uploaded: status.uploaded,
        live_uploaded_at: Map.get(status, :observed_at),
        uploaded_session_only?: Map.get(status, :uploaded_session_only?) == true
    })
  end

  @doc "The same as `overlay/1`, for a `DownloadStatus` and its download's metadata."
  @spec overlay_status(DownloadStatus.t(), map() | nil) :: DownloadStatus.t()
  def overlay_status(%DownloadStatus{uploaded_session_only?: true} = status, metadata),
    do: overlaid(status, entry(metadata), live(status.uploaded), status.size)

  def overlay_status(status, _metadata), do: status

  defp overlaid(row, entry, live, size), do: with_total(row, total(entry, live), size)

  defp with_total(row, uploaded, size) do
    ratio = if is_integer(size) and size > 0, do: uploaded / size, else: row.ratio
    %{row | uploaded: uploaded, ratio: ratio}
  end

  defp live(uploaded) when is_integer(uploaded) and uploaded >= 0, do: uploaded
  defp live(_unknown), do: 0

  @doc """
  Banks the client's counter (`live_uploaded`) for each polled row (enriched
  download) that `overlay/1` applies to, writing only entries that changed.
  Steps from `live_uploaded`, never from the overlaid `uploaded`, so a row
  recorded twice counts once.

  Returns the rows, each recorded one carrying its new entry in `metadata`
  and overlaid from it, so the policies on the same pass see the total. A
  row whose write failed is returned as it was.

  Overlapping passes are ordered (`step/3`) by when each read its counter:
  the row's `live_uploaded_at` (`DownloadStatus.observed_at`), else `now`,
  the pass's clock. A pass that starts later can read the client earlier, so
  the pass's start alone would not order them.
  """
  @spec record([map()], DateTime.t()) :: [map()]
  def record(rows, now \\ DateTime.utc_now()) do
    Enum.map(rows, fn row -> if tracked?(row), do: record_row(row, now), else: row end)
  end

  defp read_at(%{live_uploaded_at: %DateTime{} = read_at}, _now), do: read_at
  defp read_at(_row, now), do: now

  # Each row on its own: one failing row must not skip the rest, nor fail the
  # monitor's poll.
  defp record_row(row, now) do
    case write(row.id, live(row.live_uploaded), read_at(row, now)) do
      # The stored total, not this pass's counter stepped again: a rejected
      # (out-of-order) counter would read as a reset against the newer entry.
      {:ok, %{"bytes" => bytes} = entry} ->
        with_total(%{row | metadata: Map.put(row.metadata || %{}, @key, entry)}, bytes, row.size)

      _not_written ->
        row
    end
  rescue
    exception ->
      Logger.error("Recording observed upload failed; the poll continues",
        download_id: row.id,
        error: Exception.message(exception)
      )

      row
  end

  # Read and written under one transaction (locked on PostgreSQL, serialized
  # writes on SQLite), as in `Mydia.Downloads.ObservedSeedTime`, so another
  # writer's keys are kept. A plain update_all: this runs every poll, and
  # update_download/2 would broadcast a Downloads page reload each time.
  defp write(id, live, now) do
    Repo.transaction(fn -> id |> locked_row() |> Repo.one() |> step_row(live, now) end)
  end

  defp locked_row(id) do
    query = where(Download, [d], d.id == ^id)
    if DB.postgres?(), do: lock(query, "FOR UPDATE"), else: query
  end

  # The stored entry after this pass, or nil for a row deleted meanwhile.
  defp step_row(nil, _live, _now), do: nil

  defp step_row(%Download{id: id, metadata: metadata}, live, now) do
    metadata = metadata || %{}
    previous = Map.get(metadata, @key)
    entry = step(previous, live, now)

    if entry != previous,
      do:
        Repo.update_all(where(Download, [d], d.id == ^id),
          set: [metadata: Map.put(metadata, @key, entry)]
        )

    entry
  end

  # A row whose client counts per session and that is in the client.
  defp overlaid?(row),
    do: Map.get(row, :uploaded_session_only?) == true and Map.get(row, :in_client?) == true

  # Recorded only from a live answer, never from a cached counter.
  defp tracked?(row), do: overlaid?(row) and is_nil(Map.get(row, :status_as_of))
end
