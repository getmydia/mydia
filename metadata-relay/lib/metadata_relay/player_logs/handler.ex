defmodule MetadataRelay.PlayerLogs.Handler do
  @moduledoc """
  `POST /player-logs`: where Mydia players upload their logs. Unauthenticated,
  like `/crashes/report`, so the checks run cheapest first:

    1. the per-address rate limit, before a byte of the body is read;
    2. the 1 MB compressed cap, while reading;
    3. decompression, bounded at 8 MB, and validation
       (`MetadataRelay.PlayerLogs.Ingest`);
    4. the per-device rate limit, now that the device is known;
    5. for a report batch only, the per-address daily report budget
       (`MetadataRelay.PlayerLogs.ReportBudget`);
    6. the daily per-device quota and storage
       (`MetadataRelay.PlayerLogs.ingest/1`).

  The address rate limit (step 1) is deliberately loose across *all*
  traffic: behind Cloudflare the resolvable client address can be an edge
  shared by many installs (see `RELAY_PROXY_RATE_LIMIT` in
  `metadata-relay/CLAUDE.md`), so a tight all-traffic address budget would
  throttle unrelated installs behind the same edge. `device_id` is
  client-controlled, though, so it alone can't carry the daily-quota half of
  that defense (rotate it and the per-device quota resets with it). Reports
  close that gap without the shared-edge problem: `ReportBudget` charges a
  budget per address, but *only* for `kind: "report"` batches, since a
  report is a deliberate, infrequent "Send logs now" upload of a few MB even
  from a shared edge (see its moduledoc). Stream batches keep only the loose
  step-1 limit; a device-rotating stream flood degrades stream retention
  (streams are evicted first by `MetadataRelay.PlayerLogs.enforce_cap/0`)
  but can't touch the report store.

  The report budget is reserved here, right before storage, as a single
  atomic check-and-increment inside `ReportBudget`'s `GenServer` -- unlike a
  separate check then charge, two concurrent report uploads can't both read
  "room left" and both land. The reservation is released if
  `PlayerLogs.ingest/1` then fails, so a batch that never stored is never
  billed.
  """

  import Plug.Conn

  require Logger

  alias MetadataRelay.{ClientIp, Metrics, PlayerLogs, RateLimiter}
  alias MetadataRelay.PlayerLogs.{Batch, Ingest, Meta, ReportBudget}

  @max_compressed_bytes 1_048_576
  @max_decompressed_bytes 8 * 1_048_576
  @window_ms 60_000
  @ip_limit 120
  @device_limit 30

  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn) do
    address = ClientIp.resolve(conn)
    now = DateTime.utc_now()

    with :ok <- limit("player_logs:ip:#{address}", @ip_limit),
         {:ok, body, conn} <- read_limited(conn),
         {:ok, batch} <- Ingest.decode(body, @max_decompressed_bytes),
         :ok <- limit("player_logs:device:#{batch.meta.device_id}", @device_limit),
         :ok <- reserve_report_budget(batch, address, now),
         {:ok, result} <- ingest(batch, address, now) do
      Metrics.inc("metadata_relay_player_logs_batches_total", kind: batch.meta.kind)
      respond(conn, result)
    else
      {:error, reason} -> reject(conn, reason)
    end
  end

  # PlayerLogs.ingest/1 has its own reserve-then-release for the per-device
  # quota; this releases the per-address report budget the same way when
  # ingest fails, so a batch that never stored is never billed against
  # either.
  defp ingest(batch, address, now) do
    case PlayerLogs.ingest(batch) do
      {:ok, _result} = ok ->
        ok

      {:error, _reason} = error ->
        release_report_budget(batch, address, now)
        error
    end
  end

  defp reserve_report_budget(%Batch{meta: %Meta{kind: "report"}} = batch, address, now) do
    case ReportBudget.reserve(address, batch.size, now) do
      :ok -> :ok
      {:error, seconds} -> {:error, {:report_budget_exceeded, seconds}}
    end
  end

  defp reserve_report_budget(%Batch{}, _address, _now), do: :ok

  defp release_report_budget(%Batch{meta: %Meta{kind: "report"}} = batch, address, now),
    do: ReportBudget.release(address, batch.size, now)

  defp release_report_budget(%Batch{}, _address, _now), do: :ok

  defp limit(key, max) do
    case RateLimiter.check_rate_limit(key, limit: max, window_ms: @window_ms) do
      {:ok, _remaining} -> :ok
      {:error, :rate_limited} -> {:error, :rate_limited}
    end
  end

  defp read_limited(conn) do
    case read_body(conn, length: @max_compressed_bytes) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :too_large}
      {:error, _reason} -> {:error, :invalid_gzip}
    end
  end

  defp respond(conn, :stream), do: send_resp(conn, 204, "")
  defp respond(conn, {:report, code}), do: json(conn, 201, %{code: code})

  defp reject(conn, reason) do
    Metrics.inc("metadata_relay_player_logs_rejected_total", reason: label(reason))

    with {:storage, detail} <- reason do
      Logger.error("[PlayerLogs] Could not store a batch: #{inspect(detail)}")
    end

    {status, message, headers} = describe(reason)

    conn
    |> merge_resp_headers(headers)
    |> json(status, %{error: message})
  end

  defp describe(:rate_limited), do: {429, "Too many requests", [{"retry-after", "60"}]}

  defp describe({:quota_exceeded, seconds}),
    do: {429, "Daily log quota reached", [{"retry-after", Integer.to_string(seconds)}]}

  defp describe({:report_budget_exceeded, seconds}),
    do: {429, "Daily log quota reached", [{"retry-after", Integer.to_string(seconds)}]}

  defp describe(:too_large), do: {413, "Body too large", []}
  defp describe(:invalid_gzip), do: {400, "The body must be gzipped NDJSON", []}
  defp describe(:invalid_meta), do: {400, "The first line must be a valid meta object", []}
  defp describe(:no_records), do: {400, "No valid log records", []}
  defp describe(:unknown_report), do: {400, "Unknown or expired report code", []}
  defp describe({:storage, _detail}), do: {503, "Could not store the logs", []}

  defp label({kind, _detail}), do: Atom.to_string(kind)
  defp label(reason), do: Atom.to_string(reason)

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
