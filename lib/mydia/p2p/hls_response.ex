defmodule Mydia.P2p.HlsResponse do
  @moduledoc """
  The response helpers shared by the HLS stream handlers: error responses,
  cache headers, range parsing and the log line for a failed transfer.
  """

  require Logger

  alias Mydia.P2p

  def parse_range(nil, nil, file_size), do: {:full, file_size}

  def parse_range(range_start, range_end, file_size) do
    # Calculate actual range
    start_byte = range_start || 0
    end_byte = min(range_end || file_size - 1, file_size - 1)
    content_length = end_byte - start_byte + 1

    {:partial, start_byte, end_byte, content_length}
  end

  # A player closes its stream on every seek and when playback stops, and the
  # write that fails then carries the `peer_stopped` prefix. That is the normal
  # end of a transfer nobody wants any more.
  @doc false
  def log_stream_failure("peer_stopped" <> _ = reason, what) do
    Logger.debug("Player stopped reading the #{what}: #{reason}")
  end

  def log_stream_failure(reason, what) do
    Logger.error("Failed to stream #{what}: #{inspect(reason)}")
  end

  def send_error(resource, stream_id, status, message) do
    # Send error as header-only response
    # Wrapped in try/rescue because the P2P stream may already be closed
    # (e.g. peer disconnected), causing NIF calls to raise ArgumentError
    header = %P2p.HlsResponseHeader{
      status: status,
      content_type: "text/plain",
      content_length: byte_size(message),
      content_range: nil,
      cache_control: nil
    }

    try do
      case P2p.send_hls_header(resource, stream_id, header) do
        "ok" ->
          P2p.send_hls_chunk(resource, stream_id, message)
          P2p.finish_hls_stream(resource, stream_id)

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.debug("Failed to send HLS error response: #{inspect(e)}")
        :ok
    end
  end

  def cache_control(path) do
    case Path.extname(path) do
      # Playlists should not be cached (may update)
      ".m3u8" -> "no-cache"
      # Segments can be cached longer
      ".ts" -> "max-age=86400"
      # A subtitle body is stable for the life of the session but not
      # immutable across sessions, and it is small enough that revalidation
      # costs nothing. Matches HlsController's cache_control_for/1.
      ".vtt" -> "no-cache"
      # A bitmap subtitle copy: stable per source, replaced with the source.
      ".mks" -> "no-cache"
      _ -> nil
    end
  end
end
