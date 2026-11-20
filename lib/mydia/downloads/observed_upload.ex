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

      "observed_upload" => %{"bytes" => 5368709120, "session" => 1073741824}

  `bytes` is the running total, `session` the client's counter as last
  recorded. `step/2` moves it on:

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

  alias Mydia.Downloads.Structs.DownloadStatus

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

  @doc "The total after this counter, without recording it."
  @spec total(map() | nil, non_neg_integer()) :: non_neg_integer()
  def total(entry, live), do: step(entry, live)["bytes"]

  @doc """
  A row with `uploaded` and `ratio` read from the kept total. Only a row whose
  client counts per session, that is in the client, and whose status is live
  (no `status_as_of`) changes. The ratio is left as reported when `size` is
  unknown or 0.
  """
  @spec overlay(map()) :: map()
  def overlay(row) do
    if tracked?(row),
      do: overlaid(row, entry(row.metadata), live(row.live_uploaded), row.size),
      else: row
  end

  @doc "The same as `overlay/1`, for a `DownloadStatus` and its download's metadata."
  @spec overlay_status(DownloadStatus.t(), map() | nil) :: DownloadStatus.t()
  def overlay_status(%DownloadStatus{uploaded_session_only?: true} = status, metadata),
    do: overlaid(status, entry(metadata), live(status.uploaded), status.size)

  def overlay_status(status, _metadata), do: status

  defp overlaid(row, entry, live, size) do
    uploaded = total(entry, live)
    ratio = if is_integer(size) and size > 0, do: uploaded / size, else: row.ratio
    %{row | uploaded: uploaded, ratio: ratio}
  end

  defp live(uploaded) when is_integer(uploaded) and uploaded >= 0, do: uploaded
  defp live(_unknown), do: 0

  defp tracked?(row) do
    Map.get(row, :uploaded_session_only?) == true and Map.get(row, :in_client?) == true and
      is_nil(Map.get(row, :status_as_of))
  end
end
