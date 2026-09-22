defmodule MetadataRelay.PlayerLogs do
  @moduledoc """
  Logs uploaded by Mydia players, for investigating problems that are not
  crashes.

  A player sends batches while its user has chosen to share logs, and one
  report on demand. Each batch becomes a gzipped NDJSON file under
  `player_logs.dir` (see `MetadataRelay.PlayerLogs.Store`) and a row in
  `player_log_chunks`. Log lines are never rows: they would grow the shared
  SQLite database by gigabytes, and deleting files is a cheaper retention
  sweep than deleting millions of rows.

  `POST /player-logs` (`MetadataRelay.PlayerLogs.Handler`) writes here;
  `GET /logs/raw` and the `/logs` dashboard read.
  """

  import Ecto.Query

  require Logger

  alias MetadataRelay.PlayerLogs.{Batch, Chunk, Device, Meta, Report, SessionSummary, Store}
  alias MetadataRelay.Repo

  @daily_quota_bytes 50 * 1024 * 1024
  @report_follow_up_seconds 600
  @code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @stream_retention_seconds 14 * 86_400
  @report_retention_seconds 90 * 86_400
  @device_retention_seconds 90 * 86_400
  @orphan_age_seconds 3_600
  @sweep_batch 500
  @evict_batch 200
  # A drain loop stops here even if a batch keeps coming back full, so one
  # pathological sweep (a stream of devices with far more than @sweep_batch
  # expired chunks between them) cannot run forever. 200 * @sweep_batch is
  # 100k chunks per sweep; anything past that finishes on the next hourly run.
  @drain_ceiling 200

  @type ingest_result ::
          {:ok, :stream}
          | {:ok, {:report, String.t()}}
          | {:error, {:quota_exceeded, pos_integer()}}
          | {:error, :unknown_report}
          | {:error, {:storage, term()}}

  @doc """
  Stores one decoded batch: charges the device's daily quota, resolves or
  creates its report, writes the file, then indexes it and applies the disk
  cap.

  Charging comes first now, not last. `charge_quota/3` and the guard that
  rejects an over-quota device are the same SQL statement (see
  `charge_today_query/4`), so two uploads that each read "room left" a
  moment apart can no longer both pass and both land -- the database
  decides, against the live row, not Elixir against a value read earlier.
  If resolving the report or writing the chunk then fails, `refund_quota/3`
  gives the bytes back, so a batch that was never actually stored never
  leaves the device billed for it.

  This does leave one gap: a hard crash between the charge and the refund
  (not a handled error -- those refund) leaves the device over-billed by up
  to this batch's size until the day rolls over. That is the right way
  round. The alternative -- charging after the write, as an earlier version
  did -- is exactly the race this replaces, letting concurrent uploads blow
  through the quota outright rather than merely over-count it briefly.
  """
  @spec ingest(Batch.t(), DateTime.t()) :: ingest_result()
  def ingest(%Batch{meta: meta} = batch, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with :ok <- charge_quota(meta, batch.size, now) do
      case resolve_and_store(batch, now) do
        {:ok, _} = ok ->
          enforce_cap()
          ok

        {:error, _} = error ->
          refund_quota(meta, batch.size, now)
          error
      end
    end
  end

  defp resolve_and_store(%Batch{meta: meta} = batch, now) do
    with {:ok, code} <- resolve_report(meta, now),
         {:ok, _chunk} <- store_chunk(batch, code, now) do
      {:ok, if(code, do: {:report, code}, else: :stream)}
    end
  end

  @spec chunks_for_report(String.t()) :: [Chunk.t()]
  def chunks_for_report(code) do
    Repo.all(
      from(c in Chunk, where: c.report_code == ^code, order_by: [asc: c.first_t, asc: c.id])
    )
  end

  @spec get_device(String.t()) :: Device.t() | nil
  def get_device(device_id) when is_binary(device_id), do: Repo.get(Device, device_id)

  @spec get_report(String.t()) :: Report.t() | nil
  def get_report(code) when is_binary(code), do: Repo.get(Report, code)

  @doc "Devices whose name matches exactly, ignoring case, most recently seen first."
  @spec find_devices_by_name(String.t()) :: [Device.t()]
  def find_devices_by_name(name) do
    lowered = String.downcase(name)

    Repo.all(
      from(d in Device,
        where: fragment("lower(?)", d.name) == ^lowered,
        order_by: [desc: d.last_seen_at]
      )
    )
  end

  @doc "A device by ID, or by a name only one device carries."
  @spec resolve_device(String.t()) ::
          {:ok, Device.t()} | {:error, :not_found | {:ambiguous, [Device.t()]}}
  def resolve_device(value) do
    by_id =
      case Ecto.UUID.cast(value) do
        {:ok, id} -> Repo.get(Device, id)
        :error -> nil
      end

    case by_id || find_devices_by_name(value) do
      %Device{} = device -> {:ok, device}
      [] -> {:error, :not_found}
      [device] -> {:ok, device}
      devices -> {:error, {:ambiguous, devices}}
    end
  end

  @doc "A device's chunks that can hold records between `since_ms` and `until_ms`."
  @spec chunks_for_device(String.t(), integer(), integer() | nil) :: [Chunk.t()]
  def chunks_for_device(device_id, since_ms, until_ms) do
    Chunk
    |> where([c], c.device_id == ^device_id and c.last_t >= ^since_ms)
    |> then(fn query ->
      if until_ms, do: where(query, [c], c.first_t <= ^until_ms), else: query
    end)
    |> order_by([c], asc: c.first_t, asc: c.id)
    |> Repo.all()
  end

  @spec list_devices() :: [Device.t()]
  def list_devices, do: Repo.all(from(d in Device, order_by: [desc: d.last_seen_at]))

  @spec list_recent_reports(pos_integer()) :: [Report.t()]
  def list_recent_reports(limit \\ 50) do
    Repo.all(from(r in Report, order_by: [desc: r.inserted_at], limit: ^limit))
  end

  @doc "IDs of the devices that sent a stream batch since `since`."
  @spec active_device_ids(DateTime.t()) :: MapSet.t(String.t())
  def active_device_ids(since) do
    since = DateTime.truncate(since, :second)

    from(c in Chunk,
      where: c.kind == "stream" and c.inserted_at > ^since,
      distinct: true,
      select: c.device_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "A device's sessions across its newest `limit` chunks, newest first."
  @spec device_sessions(String.t(), pos_integer()) :: [SessionSummary.t()]
  def device_sessions(device_id, limit \\ 500) do
    from(c in Chunk,
      where: c.device_id == ^device_id,
      order_by: [desc: c.last_t],
      limit: ^limit,
      select: c.sessions
    )
    |> Repo.all()
    |> Enum.flat_map(&Jason.decode!/1)
    |> Enum.group_by(& &1["sid"])
    |> Enum.map(fn {sid, parts} ->
      %SessionSummary{
        sid: sid,
        first_t: parts |> Enum.map(& &1["first"]) |> Enum.min(),
        last_t: parts |> Enum.map(& &1["last"]) |> Enum.max(),
        lines: parts |> Enum.map(& &1["n"]) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(& &1.last_t, :desc)
  end

  @spec new_report_code() :: String.t()
  def new_report_code do
    suffix =
      for <<byte <- :crypto.strong_rand_bytes(6)>>, into: "" do
        <<Enum.at(@code_alphabet, rem(byte, 32))>>
      end

    "LOG-" <> suffix
  end

  @doc """
  The hourly retention pass: expired stream chunks, expired reports with
  their chunks, idle devices with nothing left, orphaned files, then the disk
  cap. Files go before rows, so a crash in between leaves an orphan row the
  raw endpoint skips rather than an orphan file nothing will ever find.
  """
  @spec sweep(DateTime.t()) :: :ok
  def sweep(now \\ DateTime.utc_now()) do
    drain_batches("expired stream chunks", fn ->
      Repo.all(
        from(c in Chunk,
          where: c.kind == "stream" and c.inserted_at < ^ago(now, @stream_retention_seconds),
          order_by: c.id,
          limit: @sweep_batch
        )
      )
    end)

    expire_reports(now)
    delete_idle_devices(now)
    remove_orphans(now)
    enforce_cap()
  end

  @doc """
  When the stored files add up to more than `player_logs.max_bytes`, deletes
  the oldest stream chunks, then the oldest report chunks, until they are
  under 90% of it.
  """
  @spec enforce_cap() :: :ok
  def enforce_cap do
    max = config(:max_bytes)
    total = total_bytes()

    if total > max do
      target = trunc(max * 0.9)
      total = evict("stream", total, target)
      _total = evict("report", total, target)
    end

    :ok
  end

  @spec total_bytes() :: non_neg_integer()
  def total_bytes, do: Repo.aggregate(Chunk, :sum, :bytes) || 0

  defp ago(now, seconds), do: now |> DateTime.add(-seconds) |> DateTime.truncate(:second)

  defp delete_chunks([]), do: :ok

  defp delete_chunks(chunks) do
    Enum.each(chunks, &Store.delete(&1.path))
    ids = Enum.map(chunks, & &1.id)
    Repo.delete_all(from(c in Chunk, where: c.id in ^ids))
    :ok
  end

  # Fetches and deletes one bounded batch at a time (`fetch` must return at
  # most @sweep_batch rows, ordered so a repeat fetch after a delete makes
  # progress) until a batch comes back short, so no single sweep issues an
  # unbounded delete. @drain_ceiling stops a pathological case from running
  # forever; the rest finishes on the next hourly sweep.
  defp drain_batches(label, fetch, iteration \\ 1)

  defp drain_batches(label, _fetch, iteration) when iteration > @drain_ceiling do
    Logger.warning(
      "[PlayerLogs] #{label}: hit the #{@drain_ceiling}-batch drain ceiling, " <>
        "continuing on the next sweep"
    )

    :ok
  end

  defp drain_batches(label, fetch, iteration) do
    batch = fetch.()
    delete_chunks(batch)

    if length(batch) == @sweep_batch do
      drain_batches(label, fetch, iteration + 1)
    else
      :ok
    end
  end

  defp expire_reports(now) do
    codes =
      Repo.all(
        from(r in Report,
          where: r.inserted_at < ^ago(now, @report_retention_seconds),
          select: r.code,
          limit: @sweep_batch
        )
      )

    if codes != [] do
      drain_batches("expired report chunks", fn ->
        Repo.all(from(c in Chunk, where: c.report_code in ^codes, limit: @sweep_batch))
      end)

      remaining_codes =
        Repo.all(
          from(c in Chunk,
            where: c.report_code in ^codes,
            select: c.report_code,
            distinct: true
          )
        )

      finished_codes = codes -- remaining_codes

      if finished_codes != [] do
        Repo.delete_all(from(r in Report, where: r.code in ^finished_codes))
      end
    end
  end

  defp delete_idle_devices(now) do
    Repo.delete_all(
      from(d in Device,
        as: :device,
        where:
          d.last_seen_at < ^ago(now, @device_retention_seconds) and
            not exists(
              from(c in Chunk, where: c.device_id == parent_as(:device).device_id, select: 1)
            )
      )
    )
  end

  defp remove_orphans(now) do
    known = MapSet.new(Repo.all(from(c in Chunk, select: c.path)))

    (DateTime.to_unix(now) - @orphan_age_seconds)
    |> Store.files_older_than()
    |> Enum.reject(&MapSet.member?(known, &1))
    |> Enum.take(@sweep_batch)
    |> Enum.each(&Store.delete/1)
  end

  defp evict(_kind, total, target) when total <= target, do: total

  defp evict(kind, total, target) do
    oldest =
      Repo.all(
        from(c in Chunk,
          where: c.kind == ^kind,
          order_by: [asc: c.inserted_at, asc: c.id],
          limit: @evict_batch
        )
      )

    {victims, remaining} =
      Enum.reduce_while(oldest, {[], total}, fn chunk, {acc, bytes} ->
        if bytes <= target,
          do: {:halt, {acc, bytes}},
          else: {:cont, {[chunk | acc], bytes - chunk.bytes}}
      end)

    case victims do
      [] ->
        total

      _ ->
        delete_chunks(victims)
        evict(kind, remaining, target)
    end
  end

  @doc false
  def config(key), do: Application.fetch_env!(:metadata_relay, :player_logs) |> Keyword.get(key)

  # How many times charge_quota/3 retries when it lands in charge_fresh/4 and
  # loses a race to create or reset the device row (see charge_fresh/4). Each
  # retry re-reads the row, so this only needs to cover genuine contention on
  # a brand new device or the exact instant a day rolls over, not sustained
  # load.
  @quota_charge_attempts 5

  # Charges `size` bytes against the device's daily quota, or rejects
  # without touching the row when that would exceed it. Which branch a
  # device is in (already charged today vs. a new device or day) is decided
  # by a plain read, but the charge itself is never based on that read: it
  # is a single guarded SQL statement (charge_today_query/4, or a static
  # `size <= quota` comparison for a fresh day) evaluated against the row's
  # live value, so two concurrent charges can't both see "room left" and
  # both land. See `ingest/2`'s moduledoc for the trade-off this creates.
  defp charge_quota(meta, size, now), do: charge_quota(meta, size, now, @quota_charge_attempts)

  defp charge_quota(_meta, _size, now, 0) do
    Logger.error(
      "[PlayerLogs] Gave up charging the daily quota after #{@quota_charge_attempts} attempts under contention"
    )

    {:error, {:quota_exceeded, seconds_until_midnight(now)}}
  end

  defp charge_quota(%Meta{device_id: device_id} = meta, size, now, attempts) do
    today = DateTime.to_date(now)

    case Repo.get(Device, device_id) do
      %Device{bytes_day: ^today} -> charge_today(meta, size, today, now)
      _ -> charge_fresh(meta, size, today, now, attempts)
    end
  end

  # The device already has a row for today: the only way to charge it is to
  # add to that row, and the only atomic way to decide "does this fit" is to
  # make the addition and the guard the same UPDATE. Zero rows changed can
  # only mean the guard failed -- the row's `device_id` and `bytes_day`
  # trivially still match what we just read -- so it means the quota is
  # spent, not a race to retry.
  defp charge_today(%Meta{} = meta, size, today, now) do
    {count, _} = Repo.update_all(charge_today_query(meta, size, today, now), [])
    if count == 1, do: :ok, else: {:error, {:quota_exceeded, seconds_until_midnight(now)}}
  end

  defp charge_today_query(%Meta{device_id: device_id} = meta, size, today, now) do
    from(d in Device,
      where:
        d.device_id == ^device_id and d.bytes_day == ^today and
          d.bytes_today + ^size <= ^@daily_quota_bytes,
      update: [
        set: [
          last_seen_at: ^now,
          name: fragment("COALESCE(?, ?)", ^meta.device_name, d.name),
          platform: fragment("COALESCE(?, ?)", ^meta.platform, d.platform),
          os_version: fragment("COALESCE(?, ?)", ^meta.os_version, d.os_version),
          app_version: fragment("COALESCE(?, ?)", ^meta.app_version, d.app_version)
        ],
        inc: [bytes_today: ^size]
      ]
    )
  end

  # A brand new device, or one whose last charge was a previous UTC day.
  # Either way today's charge starts the day at zero, so a single batch can
  # only ever fail the quota on its own size -- a plain comparison, not a
  # database condition.
  #
  # Getting the bytes onto the row is then a race between two writes that
  # can't share one guarded statement the way charge_today_query/4 does: a
  # reset (the row exists, dated a previous day) and a fresh insert (the row
  # doesn't exist at all) are different SQL statements, and either one can
  # lose to a concurrent charge for the same device landing in between. When
  # both come back empty, that concurrent charge already moved the row to
  # today, so charge_quota/4 is retried from the top, where the read now
  # sees today and takes the charge_today/4 path instead.
  defp charge_fresh(meta, size, today, now, attempts) do
    if size > @daily_quota_bytes do
      {:error, {:quota_exceeded, seconds_until_midnight(now)}}
    else
      {reset_count, _} = Repo.update_all(reset_query(meta, size, today, now), [])

      cond do
        reset_count == 1 -> :ok
        insert_fresh_device(meta, size, today, now) -> :ok
        true -> charge_quota(meta, size, now, attempts - 1)
      end
    end
  end

  defp reset_query(%Meta{device_id: device_id} = meta, size, today, now) do
    from(d in Device,
      where: d.device_id == ^device_id and (is_nil(d.bytes_day) or d.bytes_day != ^today),
      update: [
        set: [
          last_seen_at: ^now,
          bytes_day: ^today,
          bytes_today: ^size,
          name: fragment("COALESCE(?, ?)", ^meta.device_name, d.name),
          platform: fragment("COALESCE(?, ?)", ^meta.platform, d.platform),
          os_version: fragment("COALESCE(?, ?)", ^meta.os_version, d.os_version),
          app_version: fragment("COALESCE(?, ?)", ^meta.app_version, d.app_version)
        ]
      ]
    )
  end

  defp insert_fresh_device(%Meta{} = meta, size, today, now) do
    fields = %{
      device_id: meta.device_id,
      name: meta.device_name,
      platform: meta.platform,
      os_version: meta.os_version,
      app_version: meta.app_version,
      first_seen_at: now,
      last_seen_at: now,
      bytes_today: size,
      bytes_day: today
    }

    case Repo.insert_all(Device, [fields], on_conflict: :nothing, conflict_target: :device_id) do
      {1, _} -> true
      {0, _} -> false
    end
  end

  # Gives back bytes charge_quota/3 added when the rest of ingest/2 then
  # fails, so a batch that was never actually stored never leaves the device
  # billed for it. Floors at zero and does nothing once the day has rolled
  # over (the charge it is undoing no longer applies to today's row anyway).
  # Mirrors ReportBudget.release/3.
  defp refund_quota(%Meta{device_id: device_id}, size, now) do
    today = DateTime.to_date(now)

    Repo.update_all(
      from(d in Device,
        where: d.device_id == ^device_id and d.bytes_day == ^today,
        update: [set: [bytes_today: fragment("MAX(0, ? - ?)", d.bytes_today, ^size)]]
      ),
      []
    )

    :ok
  end

  @doc false
  @spec seconds_until_midnight(DateTime.t()) :: pos_integer()
  def seconds_until_midnight(now) do
    midnight = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")
    max(DateTime.diff(midnight, now), 1)
  end

  defp resolve_report(%Meta{kind: "stream"}, _now), do: {:ok, nil}
  defp resolve_report(%Meta{kind: "report", report: nil} = meta, _now), do: create_report(meta, 5)

  defp resolve_report(%Meta{kind: "report", report: code, device_id: device_id}, now) do
    case Repo.get(Report, code) do
      %Report{device_id: ^device_id, inserted_at: created} ->
        if DateTime.diff(now, created) <= @report_follow_up_seconds,
          do: {:ok, code},
          else: {:error, :unknown_report}

      _ ->
        {:error, :unknown_report}
    end
  end

  defp create_report(_meta, 0), do: {:error, {:storage, :no_free_report_code}}

  defp create_report(meta, attempts) do
    code = new_report_code()

    if Repo.get(Report, code) do
      create_report(meta, attempts - 1)
    else
      case Repo.insert(%Report{code: code, device_id: meta.device_id, note: meta.note}) do
        {:ok, _report} -> {:ok, code}
        {:error, reason} -> {:error, {:storage, reason}}
      end
    end
  end

  defp store_chunk(%Batch{meta: meta, records: records}, code, now) do
    times = Enum.map(records, & &1.t)
    first_t = Enum.min(times)
    path = Store.meta_path(meta, code, DateTime.to_date(now), first_t)

    with {:ok, bytes} <- Store.write(path, Enum.map(records, &[&1.line, ?\n])) do
      %Chunk{
        device_id: meta.device_id,
        kind: meta.kind,
        path: path,
        first_t: first_t,
        last_t: Enum.max(times),
        line_count: length(records),
        bytes: bytes,
        sessions: Jason.encode!(sessions(records)),
        report_code: code
      }
      |> Repo.insert()
      |> case do
        {:ok, chunk} ->
          {:ok, chunk}

        {:error, reason} ->
          Store.delete(path)
          {:error, {:storage, reason}}
      end
    else
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp sessions(records) do
    records
    |> Enum.group_by(& &1.sid)
    |> Enum.map(fn {sid, group} ->
      times = Enum.map(group, & &1.t)
      %{"sid" => sid, "first" => Enum.min(times), "last" => Enum.max(times), "n" => length(group)}
    end)
  end
end
