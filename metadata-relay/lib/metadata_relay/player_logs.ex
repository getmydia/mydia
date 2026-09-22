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
  Stores one decoded batch: checks the device's daily quota, resolves or
  creates its report, writes the file, indexes it, records the usage against
  the quota, then applies the disk cap.

  The quota check and the quota write are deliberately separate steps. A
  device is only charged once the file is written and indexed, so a storage
  failure never burns part of a device's daily allowance for bytes that were
  never actually stored. The write itself is a single atomic upsert (see
  `record_usage/3`), so two concurrent uploads from the same device both
  count rather than one clobbering the other.
  """
  @spec ingest(Batch.t(), DateTime.t()) :: ingest_result()
  def ingest(%Batch{meta: meta} = batch, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with :ok <- check_quota(meta, batch.size, now),
         {:ok, code} <- resolve_report(meta, now),
         {:ok, _chunk} <- store_chunk(batch, code, now),
         :ok <- record_usage(meta, batch.size, now) do
      enforce_cap()
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

  defp check_quota(%Meta{} = meta, size, now) do
    today = DateTime.to_date(now)

    used =
      case Repo.get(Device, meta.device_id) do
        %Device{bytes_day: ^today, bytes_today: bytes_today} -> bytes_today
        _ -> 0
      end

    if used + size > @daily_quota_bytes do
      {:error, {:quota_exceeded, seconds_until_midnight(now)}}
    else
      :ok
    end
  end

  # Charges `size` bytes to the device's daily usage as one atomic upsert:
  # `bytes_today` becomes `bytes_today + size` when `bytes_day` is already
  # today, or resets to `size` otherwise. Doing the add in SQL (rather than
  # reading `bytes_today` in Elixir and writing `read_value + size` back, as
  # `check_quota/3` does for its cheap pre-check) means two concurrent
  # uploads from the same device both count, instead of the second silently
  # overwriting the first's charge. It also means two concurrent first
  # uploads from a brand new device both land as one insert and one update
  # (`conflict_target: :device_id`) rather than the second raising on the
  # primary key.
  #
  # The description fields (name, platform, os_version, app_version) update
  # as before: a field left blank in this batch's meta does not clobber
  # whatever the device already has on file. `first_seen_at` is only ever
  # set by the initial insert.
  defp record_usage(%Meta{} = meta, size, now) do
    today = DateTime.to_date(now)

    device = %Device{
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

    on_conflict =
      from(d in Device,
        update: [
          set: [
            name: fragment("COALESCE(?, ?)", ^meta.device_name, d.name),
            platform: fragment("COALESCE(?, ?)", ^meta.platform, d.platform),
            os_version: fragment("COALESCE(?, ?)", ^meta.os_version, d.os_version),
            app_version: fragment("COALESCE(?, ?)", ^meta.app_version, d.app_version),
            last_seen_at: ^now,
            bytes_day: ^today,
            bytes_today:
              fragment(
                "CASE WHEN ? = ? THEN ? + ? ELSE ? END",
                d.bytes_day,
                ^today,
                d.bytes_today,
                ^size,
                ^size
              )
          ]
        ]
      )

    device
    |> Repo.insert(on_conflict: on_conflict, conflict_target: :device_id)
    |> case do
      {:ok, _device} -> :ok
      {:error, changeset} -> {:error, {:storage, changeset}}
    end
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
