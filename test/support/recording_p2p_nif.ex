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

  defp record(name, args) do
    send(Process.whereis(:recording_p2p_nif), {:p2p, name, args})
    "ok"
  end
end
