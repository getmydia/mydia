defmodule MetadataRelay.PlayerLogs.Ingest do
  @moduledoc """
  Decodes and validates one `POST /player-logs` body.

  The body is gzipped NDJSON: a meta line describing the device and the
  upload, then one log record per line. Everything here is pure, so the
  handler can reject a bad body before it touches the database or the disk.

  Decompression is incremental and stops at the caller's limit, so a small
  hostile body cannot expand without bound. Nothing from the body becomes an
  atom: strings are length-capped before they reach a struct, and each record
  is re-encoded from its validated fields, so what is stored is always well
  formed.
  """

  alias MetadataRelay.PlayerLogs.{Batch, Meta, Record}

  @kinds ~w(stream report)
  @levels ~w(debug info warn error)
  @sources ~w(dart rust)
  @max_msg_chars 8192
  @truncation_marker "...[truncated]"
  # safeInflate hands back output in small slices. This bounds the loop even
  # for a stream that keeps answering :continue with nothing.
  @max_inflate_steps 20_000
  @code_pattern ~r/\ALOG-[0-9A-HJKMNP-TV-Z]{6}\z/

  @spec decode(binary(), pos_integer()) ::
          {:ok, Batch.t()} | {:error, :too_large | :invalid_gzip | :invalid_meta | :no_records}
  def decode(body, max_decompressed) when is_binary(body) do
    with {:ok, text} <- gunzip(body, max_decompressed),
         [meta_line | record_lines] <- non_empty_lines(text),
         {:ok, meta} <- decode_meta(meta_line) do
      {records, dropped} = decode_records(record_lines)

      if records == [] do
        {:error, :no_records}
      else
        {:ok, %Batch{meta: meta, records: records, size: byte_size(text), dropped: dropped}}
      end
    else
      [] -> {:error, :invalid_meta}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Gunzips `data`, refusing to produce more than `limit` bytes.
  """
  @spec gunzip(binary(), pos_integer()) :: {:ok, binary()} | {:error, :too_large | :invalid_gzip}
  def gunzip(data, limit) when is_binary(data) do
    z = :zlib.open()

    try do
      # 31 = 15 window bits + 16: expect a gzip header and trailer.
      :ok = :zlib.inflateInit(z, 31)
      inflate(z, :zlib.safeInflate(z, data), [], 0, limit, 0)
    rescue
      ErlangError -> {:error, :invalid_gzip}
    after
      :zlib.close(z)
    end
  end

  defp inflate(_z, _step, _acc, _size, _limit, steps) when steps > @max_inflate_steps,
    do: {:error, :invalid_gzip}

  defp inflate(_z, {:need_dictionary, _adler, _output}, _acc, _size, _limit, _steps),
    do: {:error, :invalid_gzip}

  defp inflate(z, {status, output}, acc, size, limit, steps) do
    size = size + IO.iodata_length(output)
    acc = [acc | output]

    cond do
      size > limit ->
        {:error, :too_large}

      status == :finished ->
        # Raises data_error, caught above, when the stream stopped short of
        # its end: a truncated body.
        :ok = :zlib.inflateEnd(z)
        {:ok, IO.iodata_to_binary(acc)}

      true ->
        inflate(z, :zlib.safeInflate(z, []), acc, size, limit, steps + 1)
    end
  end

  defp non_empty_lines(text) do
    text
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) == ""))
  end

  defp decode_meta(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "meta"} = map} -> build_meta(map)
      _ -> {:error, :invalid_meta}
    end
  end

  defp build_meta(map) do
    with {:ok, device_id} <- Ecto.UUID.cast(map["device_id"]),
         true <- map["kind"] in @kinds,
         {:ok, report} <- report_code(map["report"]) do
      {:ok,
       %Meta{
         device_id: device_id,
         kind: map["kind"],
         report: report,
         device_name: capped(map["device_name"], 200),
         platform: capped(map["platform"], 32),
         os_version: capped(map["os_version"], 100),
         app_version: capped(map["app_version"], 64),
         build: capped(map["build"], 32),
         note: capped(map["note"], 2000)
       }}
    else
      _ -> {:error, :invalid_meta}
    end
  end

  defp report_code(nil), do: {:ok, nil}

  defp report_code(code) when is_binary(code) do
    if Regex.match?(@code_pattern, code), do: {:ok, code}, else: :error
  end

  defp report_code(_), do: :error

  defp decode_records(lines) do
    {records, dropped} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, dropped} ->
        case decode_record(line) do
          {:ok, record} -> {[record | acc], dropped}
          :error -> {acc, dropped + 1}
        end
      end)

    {Enum.reverse(records), dropped}
  end

  defp decode_record(line) do
    with {:ok, %{"t" => t, "l" => level, "msg" => msg} = map}
         when is_integer(t) and level in @levels and is_binary(msg) <- Jason.decode(line) do
      sid = capped(map["sid"], 32)

      fields = %{
        "t" => t,
        "l" => level,
        "tag" => capped(map["tag"], 64) || "app",
        "msg" => truncate(msg),
        "sid" => sid,
        "src" => if(map["src"] in @sources, do: map["src"], else: "dart")
      }

      {:ok, %Record{t: t, sid: sid, line: Jason.encode!(fields)}}
    else
      _ -> :error
    end
  end

  defp truncate(msg) do
    if String.length(msg) > @max_msg_chars do
      String.slice(msg, 0, @max_msg_chars) <> @truncation_marker
    else
      msg
    end
  end

  defp capped(value, max) when is_binary(value), do: String.slice(value, 0, max)
  defp capped(_value, _max), do: nil
end
