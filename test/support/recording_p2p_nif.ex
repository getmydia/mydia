defmodule Mydia.Test.RecordingP2pNif do
  @moduledoc """
  Stands in for the HLS chunk NIFs of `Mydia.P2p` in tests. Every call is sent
  to the process registered as `:recording_p2p_nif` as `{:p2p, name, args}`.
  """

  def send_hls_header(resource, stream_id, header),
    do: record(:header, [resource, stream_id, header])

  # A test can make the next chunk calls fail by putting a result under
  # `:recording_p2p_chunk_result` in its process dictionary.
  def send_hls_chunk(resource, stream_id, data) do
    record(:chunk, [resource, stream_id, data])
    Process.get(:recording_p2p_chunk_result, "ok")
  end

  def finish_hls_stream(resource, stream_id), do: record(:finish, [resource, stream_id])

  # A test can make a call raise ArgumentError, as the real NIFs do once the
  # peer has gone, by putting its name (:header, :chunk or :finish) under
  # `:recording_p2p_raise` in its process dictionary.
  defp record(name, args) do
    send(Process.whereis(:recording_p2p_nif), {:p2p, name, args})

    if Process.get(:recording_p2p_raise) == name do
      raise ArgumentError, "stream closed"
    end

    "ok"
  end
end
