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

  alias MetadataRelay.PlayerLogs.{Batch, Chunk, Device, Meta, Report, Store}
  alias MetadataRelay.Repo

  @daily_quota_bytes 50 * 1024 * 1024
  @report_follow_up_seconds 600
  @code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

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
  never actually stored.
  """
  @spec ingest(Batch.t(), DateTime.t()) :: ingest_result()
  def ingest(%Batch{meta: meta} = batch, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    with {:ok, used} <- check_quota(meta, batch.size, now),
         {:ok, code} <- resolve_report(meta, now),
         {:ok, _chunk} <- store_chunk(batch, code, now),
         :ok <- record_usage(meta, batch.size, used, now) do
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

  @spec new_report_code() :: String.t()
  def new_report_code do
    suffix =
      for <<byte <- :crypto.strong_rand_bytes(6)>>, into: "" do
        <<Enum.at(@code_alphabet, rem(byte, 32))>>
      end

    "LOG-" <> suffix
  end

  @doc "Keeps the logs directory under `player_logs.max_bytes`. See Task 5."
  @spec enforce_cap() :: :ok
  def enforce_cap, do: :ok

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
      {:ok, used}
    end
  end

  defp record_usage(%Meta{} = meta, size, used, now) do
    today = DateTime.to_date(now)

    device =
      Repo.get(Device, meta.device_id) || %Device{device_id: meta.device_id, first_seen_at: now}

    described =
      %{
        name: meta.device_name,
        platform: meta.platform,
        os_version: meta.os_version,
        app_version: meta.app_version
      }
      |> Map.reject(fn {_field, value} -> is_nil(value) end)

    device
    |> Ecto.Changeset.change(
      Map.merge(described, %{last_seen_at: now, bytes_today: used + size, bytes_day: today})
    )
    |> Repo.insert_or_update()
    |> case do
      {:ok, _device} -> :ok
      {:error, changeset} -> {:error, {:storage, changeset}}
    end
  end

  defp seconds_until_midnight(now) do
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
