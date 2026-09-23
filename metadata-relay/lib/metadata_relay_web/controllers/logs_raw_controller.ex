defmodule MetadataRelayWeb.LogsRawController do
  @moduledoc """
  `GET /logs/raw`: a device's or a report's logs as plain text, for curl,
  grep and agents, behind the dashboard basic auth. `./dev relay logs` wraps
  it. See `MetadataRelay.PlayerLogs.Query` for the parameters.

  The response is chunked and built one stored file at a time, so memory stays
  flat whatever the window: the pod has a 512 Mi limit.
  """

  # `use Phoenix.Controller` also imports Plug.Conn (chunk/2, send_chunked/2).
  use Phoenix.Controller, formats: [:text]

  alias MetadataRelay.PlayerLogs
  alias MetadataRelay.PlayerLogs.{Device, Query, Store}

  @batch_lines 500

  def show(conn, params) do
    with {:ok, query} <- Query.parse(params, System.system_time(:millisecond)),
         {:ok, header, chunks} <- source(query) do
      conn = conn |> put_resp_content_type("text/plain") |> send_chunked(200)

      case emit(conn, header) do
        {:ok, conn} -> stream_chunks(conn, chunks, query)
        :closed -> conn
      end
    else
      {:error, :not_found} -> plain(conn, 404, "No logs for that device or code\n")
      {:error, {:ambiguous, devices}} -> plain(conn, 409, ambiguous(devices))
      {:error, message} when is_binary(message) -> plain(conn, 400, message <> "\n")
    end
  end

  defp source(%Query{code: code}) when is_binary(code) do
    case PlayerLogs.get_report(code) do
      nil ->
        {:error, :not_found}

      report ->
        header =
          "# report #{code} from #{describe(PlayerLogs.get_device(report.device_id), report.device_id)}" <>
            " at #{DateTime.to_iso8601(report.inserted_at)}" <>
            if(report.note, do: " note: #{report.note}", else: "") <> "\n"

        {:ok, header, PlayerLogs.chunks_for_report(code)}
    end
  end

  defp source(%Query{device: value} = query) do
    with {:ok, device} <- PlayerLogs.resolve_device(value) do
      chunks = PlayerLogs.chunks_for_device(device.device_id, query.since_ms, query.until_ms)
      {:ok, "# device #{describe(device, device.device_id)}\n", chunks}
    end
  end

  defp describe(%Device{} = device, id) do
    details = [device.platform, device.app_version] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    "#{device.name || "Unnamed device"} (#{id}) #{details}" |> String.trim_trailing()
  end

  defp describe(nil, id), do: "an unknown device (#{id})"

  defp ambiguous(devices) do
    lines =
      Enum.map(devices, fn device ->
        "  #{device.device_id}  last seen #{DateTime.to_iso8601(device.last_seen_at)}\n"
      end)

    IO.iodata_to_binary(["Several devices have that name; pass one of these IDs:\n" | lines])
  end

  defp stream_chunks(conn, chunks, query) do
    result =
      Enum.reduce_while(chunks, {:cont, conn, 0}, fn chunk, {:cont, conn, count} ->
        case send_chunk(conn, chunk, query, count) do
          {:cont, _conn, _count} = more -> {:cont, more}
          stop -> {:halt, stop}
        end
      end)

    case result do
      {:truncated, conn} ->
        case emit(conn, "-- truncated --\n") do
          {:ok, conn} -> conn
          :closed -> conn
        end

      {_status, conn} ->
        conn

      {:cont, conn, _count} ->
        conn
    end
  end

  defp send_chunk(conn, chunk, query, count) do
    chunk.path
    |> Store.stream_lines()
    |> Stream.map(&decode/1)
    |> Stream.filter(&Query.matches?(&1, query))
    |> Stream.chunk_every(@batch_lines)
    |> Enum.reduce_while({:cont, conn, count}, fn records, {:cont, conn, count} ->
      room = query.max_lines - count

      {taken, truncated?} =
        if length(records) > room, do: {Enum.take(records, room), true}, else: {records, false}

      case emit(conn, Enum.map(taken, &Query.format_line/1)) do
        {:ok, conn} when truncated? -> {:halt, {:truncated, conn}}
        {:ok, conn} -> {:cont, {:cont, conn, count + length(taken)}}
        :closed -> {:halt, {:closed, conn}}
      end
    end)
  rescue
    # An index row whose file is gone: skip it rather than fail the response.
    File.Error -> {:cont, conn, count}
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, record} -> record
      {:error, _reason} -> nil
    end
  end

  defp emit(conn, []), do: {:ok, conn}

  defp emit(conn, data) do
    case chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, _reason} -> :closed
    end
  end

  defp plain(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
  end
end
