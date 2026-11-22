defmodule Mydia.P2p.FileStream do
  @moduledoc """
  Streams a file from disk to a peer over a p2p HLS stream, honouring range
  requests, and resolves the hosted-artwork sessions served the same way.
  """

  require Logger

  alias Mydia.Media.PosterStore
  alias Mydia.P2p
  alias Mydia.P2p.HlsResponse
  alias Mydia.Streaming.SessionFiles

  @doc """
  Answers an `artwork:<filename>` session with the hosted poster file, or a 404
  when the name does not resolve.
  """
  @spec stream_artwork(term(), term(), String.t(), map()) :: :ok | term()
  def stream_artwork(resource, stream_id, session_id, req) do
    case resolve_artwork(session_id) do
      {:ok, path} -> stream_file(resource, stream_id, path, req)
      {:error, :not_found} -> HlsResponse.send_error(resource, stream_id, 404, "Not found")
    end
  end

  # Public for its test. `PosterStore.path_for/1` owns the filename check, so a
  # traversal or a non-poster name answers exactly as a missing file.
  @doc false
  @spec resolve_artwork(String.t()) :: {:ok, Path.t()} | {:error, :not_found}
  def resolve_artwork("artwork:" <> filename), do: PosterStore.path_for(filename)

  @doc "Streams `file_path` to the peer, logging instead of raising."
  @spec stream_file(term(), term(), Path.t(), map()) :: :ok | term()
  def stream_file(resource, stream_id, file_path, req) do
    try do
      do_stream_file(resource, stream_id, file_path, req)
    rescue
      e ->
        Logger.error(
          "HLS stream failed for #{file_path}: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        :ok
    end
  end

  defp do_stream_file(resource, stream_id, file_path, req) do
    t0 = System.monotonic_time(:millisecond)

    case File.stat(file_path) do
      {:ok, %File.Stat{size: file_size}} ->
        file_stat_ms = System.monotonic_time(:millisecond) - t0

        # Determine content type
        content_type = SessionFiles.content_type(file_path)
        basename = Path.basename(file_path)

        # Handle range requests
        case HlsResponse.parse_range(req.range_start, req.range_end, file_size) do
          {:full, _} ->
            # Full file request
            send_full_file(resource, stream_id, file_path, file_size, content_type)

            stream_ms = System.monotonic_time(:millisecond) - t0

            Logger.info(
              "p2p_metrics_elixir: file_stream file_stat_ms=#{file_stat_ms} stream_ms=#{stream_ms} bytes=#{file_size} path=#{basename} session=#{req.session_id}"
            )

          {:partial, range_start, range_end, content_length} ->
            # Partial content (206)
            send_partial_file(
              resource,
              stream_id,
              file_path,
              file_size,
              range_start,
              range_end,
              content_length,
              content_type
            )

            stream_ms = System.monotonic_time(:millisecond) - t0

            Logger.info(
              "p2p_metrics_elixir: file_stream file_stat_ms=#{file_stat_ms} stream_ms=#{stream_ms} bytes=#{content_length}/#{file_size} range=#{range_start}-#{range_end} path=#{basename} session=#{req.session_id}"
            )
        end

      {:error, :enoent} ->
        Logger.debug("HLS file not found: #{file_path}")
        HlsResponse.send_error(resource, stream_id, 404, "Not found")

      {:error, reason} ->
        Logger.warning("HLS file error: #{inspect(reason)}")
        HlsResponse.send_error(resource, stream_id, 500, "Internal error")
    end
  end

  defp send_full_file(resource, stream_id, file_path, file_size, content_type) do
    t0 = System.monotonic_time(:millisecond)

    # Send header
    header = %P2p.HlsResponseHeader{
      status: 200,
      content_type: content_type,
      content_length: file_size,
      content_range: nil,
      cache_control: HlsResponse.cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        send_header_ms = System.monotonic_time(:millisecond) - t0

        # Stream the file directly from Rust (zero-copy, no per-chunk NIF overhead)
        case P2p.stream_file_range(resource, stream_id, file_path, 0, file_size) do
          "ok" ->
            stream_file_range_ms = System.monotonic_time(:millisecond) - t0 - send_header_ms

            Logger.info(
              "p2p_metrics_elixir: nif_breakdown send_header_ms=#{send_header_ms} stream_file_range_ms=#{stream_file_range_ms} bytes=#{file_size} path=#{Path.basename(file_path)}"
            )

          {:error, reason} ->
            HlsResponse.log_stream_failure(reason, "file")
        end

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end

  defp send_partial_file(
         resource,
         stream_id,
         file_path,
         file_size,
         range_start,
         range_end,
         content_length,
         content_type
       ) do
    t0 = System.monotonic_time(:millisecond)

    # Send header with 206 status
    header = %P2p.HlsResponseHeader{
      status: 206,
      content_type: content_type,
      content_length: content_length,
      content_range: "bytes #{range_start}-#{range_end}/#{file_size}",
      cache_control: HlsResponse.cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        send_header_ms = System.monotonic_time(:millisecond) - t0

        # Stream the file range directly from Rust (zero-copy, no per-chunk NIF overhead)
        case P2p.stream_file_range(resource, stream_id, file_path, range_start, content_length) do
          "ok" ->
            stream_file_range_ms = System.monotonic_time(:millisecond) - t0 - send_header_ms

            Logger.info(
              "p2p_metrics_elixir: nif_breakdown send_header_ms=#{send_header_ms} stream_file_range_ms=#{stream_file_range_ms} bytes=#{content_length} path=#{Path.basename(file_path)}"
            )

          {:error, reason} ->
            HlsResponse.log_stream_failure(reason, "file range")
        end

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end
end
