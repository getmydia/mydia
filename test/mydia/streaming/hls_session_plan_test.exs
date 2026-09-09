defmodule Mydia.Streaming.HlsSessionPlanTest do
  @moduledoc """
  The session carries its plan so consumers do not re-derive it. A fallback to
  software mid-session changes the plan, and a dashboard that never hears about
  it keeps advertising hardware encoding that stopped happening.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.StreamPlan

  @media_file %MediaFile{
    codec: "hevc",
    audio_codec: "eac3",
    relative_path: "film.mkv",
    library_path: %LibraryPath{path: "/tmp"},
    metadata: %FileMetadata{width: 1920, height: 1080}
  }

  describe "hwaccel_fallback/2" do
    test "re-plans in software so the reported tier stops claiming hardware, and announces it" do
      backend_opts = [
        max_bitrate: 1500,
        max_height: 480,
        media_file: @media_file,
        capabilities: Capabilities.software("test")
      ]

      state = %HlsSession.State{
        session_id: "session-1",
        media_file: @media_file,
        max_bitrate: 1500,
        max_height: 480,
        backend_opts: backend_opts,
        accel_fallbacks: 0,
        hwaccel_lease: nil,
        plan: StreamPlan.for_hls(@media_file, backend_opts)
      }

      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")

      assert {:retry, retried} = HlsSession.hwaccel_fallback(state, 0)
      assert retried.plan.video.tier == :software
      assert retried.plan.video.action == :encode

      # The dashboard's Now Playing reload hangs off this exact message; a
      # plan that changed silently is the smaller copy of the bug this whole
      # feature exists to fix.
      assert_receive {:session_updated, "session-1"}
    end

    test "the terminal path (fallback already used) broadcasts nothing" do
      # Only the session_id matters to the guard clause -- it returns :stop
      # before touching backend_opts, media_file, or the plan.
      state = %HlsSession.State{session_id: "session-2", accel_fallbacks: 1}

      Phoenix.PubSub.subscribe(Mydia.PubSub, "hls_sessions")

      assert :stop = HlsSession.hwaccel_fallback(state, 0)

      refute_receive {:session_updated, _}, 50
    end
  end

  describe "get_info/1" do
    test "reports the session's plan" do
      backend_opts = [
        max_bitrate: 1500,
        max_height: 480,
        capabilities: Capabilities.software("test")
      ]

      plan = StreamPlan.for_hls(@media_file, backend_opts)

      state = %HlsSession.State{
        session_id: "session-3",
        media_file: @media_file,
        backend_opts: backend_opts,
        plan: plan
      }

      {:reply, {:ok, info}, _state} =
        HlsSession.handle_call(:get_info, {self(), make_ref()}, state)

      # Full-struct equality, not merely "the key is present": a plan that
      # got rebuilt, truncated, or swapped for another session's would fail
      # this the same way a missing key would.
      assert info.plan == plan
      assert info.plan.video.tier == :software
    end
  end
end
