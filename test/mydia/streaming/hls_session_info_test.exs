defmodule Mydia.Streaming.HlsSessionInfoTest do
  @moduledoc """
  Pins `:get_info` reporting the offset the session is actually transcoding
  from.

  `StreamingResolver.start_streaming_session/3` echoes this value back to the
  player, which builds its `StreamTimeline` from it and maps every position it
  persists through that timeline. If the reply ever stops carrying
  `start_position` — or carries something other than the session's own — a
  caller that adopted a session it did not start (see
  `HlsSessionSupervisor.start_new_session/5`, which adopts a concurrent
  registration winner) would persist progress in the wrong coordinate space.

  Driven through `handle_call/3` with a hand-built state rather than a live
  session: `HlsSession.init/1` loads a real media file and spawns a real
  FFmpeg, neither of which this assertion needs. Same convention as
  `hls_session_ready_test.exs` in this directory.
  """

  use ExUnit.Case, async: true

  alias Mydia.Streaming.HlsSession

  defp state(start_position) do
    %HlsSession.State{
      session_id: "sess-#{start_position}",
      media_file_id: 1,
      user_id: 2,
      mode: :transcode,
      start_position: start_position,
      backend: :ffmpeg,
      backend_pid: nil,
      temp_dir: "/tmp/mydia-hls/sess-#{start_position}",
      last_activity: DateTime.utc_now()
    }
  end

  defp get_info(start_position) do
    {:reply, {:ok, info}, _new_state} =
      HlsSession.handle_call(:get_info, {self(), make_ref()}, state(start_position))

    info
  end

  describe "handle_call(:get_info, ...)" do
    test "reports the offset the session was started from" do
      assert get_info(4200).start_position == 4200
    end

    test "reports zero for a session started from the beginning" do
      # Must be 0 rather than nil: the resolver echoes this straight into the
      # `startPosition` field, and the client treats a null as "older server,
      # assume offset zero" — which is right for an old server but would mask
      # a real bug here.
      assert get_info(0).start_position == 0
    end
  end
end
