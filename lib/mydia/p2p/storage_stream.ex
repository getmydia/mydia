defmodule Mydia.P2p.StorageStream do
  @moduledoc """
  Streams an object-storage file to a peer. Object storage has no path for
  Rust to open, so the bytes are read in Elixir and pushed through the chunk
  NIFs.
  """

  require Logger

  alias Mydia.P2p
  alias Mydia.P2p.HlsResponse
  alias Mydia.Streaming.SessionFiles

  @p2p_nif Application.compile_env(:mydia, :p2p_nif, Mydia.P2p)

  @doc false
  def stream(resource, stream_id, source, req) do
    case Mydia.Storage.stat(source) do
      {:ok, %{size: file_size}} ->
        push_storage_range(resource, stream_id, source, req, file_size)

      {:error, %Mydia.Storage.Error{kind: :not_found}} ->
        HlsResponse.send_error(resource, stream_id, 404, "Not found")

      {:error, _} ->
        HlsResponse.send_error(resource, stream_id, 502, "Storage unavailable")
    end
  end

  defp push_storage_range(resource, stream_id, source, req, file_size) do
    case HlsResponse.parse_range(req.range_start, req.range_end, file_size) do
      {:full, _} ->
        send_storage_body(resource, stream_id, source, {200, 0, file_size, nil})

      {:partial, range_start, _range_end, _length} when range_start >= file_size ->
        HlsResponse.send_error(resource, stream_id, 416, "Range not satisfiable")

      {:partial, range_start, range_end, content_length} ->
        content_range = "bytes #{range_start}-#{range_end}/#{file_size}"

        send_storage_body(
          resource,
          stream_id,
          source,
          {206, range_start, content_length, content_range}
        )
    end
  end

  defp send_storage_body(resource, stream_id, source, {status, offset, length, content_range}) do
    header = %P2p.HlsResponseHeader{
      status: status,
      content_type: SessionFiles.content_type(source.path),
      content_length: length,
      content_range: content_range,
      cache_control: HlsResponse.cache_control(source.path)
    }

    # The NIFs raise ArgumentError once the peer has gone and the stream is
    # closed, the same as on the local path.
    try do
      case @p2p_nif.send_hls_header(resource, stream_id, header) do
        "ok" ->
          finish_storage_body(resource, stream_id, source, offset, length)

        other ->
          HlsResponse.log_stream_failure(other, "storage")
      end
    rescue
      e in ArgumentError ->
        Logger.debug("Storage stream closed by peer: #{Exception.message(e)}")
        :ok
    catch
      # A backend can also exit (a pool checkout or call timeout) or throw;
      # this clause covers raises too.
      kind, reason ->
        Logger.error(
          "Failed to stream storage: " <> Exception.format(kind, reason, __STACKTRACE__)
        )

        abort_storage_stream(resource, stream_id)
    end
  end

  defp finish_storage_body(resource, stream_id, source, offset, length) do
    case stream_storage_body(resource, stream_id, source, offset, length) do
      {:ok, _} ->
        @p2p_nif.finish_hls_stream(resource, stream_id)

      {:error, reason} ->
        HlsResponse.log_stream_failure(reason, "storage")
        abort_storage_stream(resource, stream_id)
    end
  end

  # Finishing a stream whose read failed would write the terminator and the
  # player would keep a short body as complete, and leaving it alone holds the
  # stream open with the player waiting on bytes that never come. Aborting
  # resets it, which the player reports as a truncated response. After a failed
  # chunk write the stream is already gone, so the abort's own failure, or its
  # ArgumentError, means nothing is left to end.
  defp abort_storage_stream(resource, stream_id) do
    @p2p_nif.abort_hls_stream(resource, stream_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # An empty object has nothing to read, and a ranged read of zero bytes is not
  # a request the storage layer should see.
  defp stream_storage_body(_resource, _stream_id, _source, _offset, 0), do: {:ok, nil}

  defp stream_storage_body(resource, stream_id, source, offset, length) do
    Mydia.Storage.stream_range(source, offset, length, nil, fn data, acc ->
      case @p2p_nif.send_hls_chunk(resource, stream_id, data) do
        "ok" -> {:ok, acc}
        # Unwrapped so `log_stream_failure/2` sees the bare `peer_stopped` reason.
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    end)
  end
end
