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
    test "re-plans in software so the reported tier stops claiming hardware" do
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

      assert {:retry, retried} = HlsSession.hwaccel_fallback(state, 0)
      assert retried.plan.video.tier == :software
      assert retried.plan.video.action == :encode
    end
  end
end
