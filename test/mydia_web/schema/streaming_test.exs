defmodule MydiaWeb.Schema.StreamingTest do
  @moduledoc """
  Regression coverage for the Task 4 cold-file duration fix.

  Before this fix, a never-probed media file (`analyzed_at: nil`) always
  echoed `duration: nil` from `startStreamingSession`, because the old
  fire-and-forget `Candidates.ensure_codec_info_async/1` (since deleted — it
  had no callers left) returned before the probe wrote anything back, and the
  resolver read duration off the struct loaded before the probe was even
  scheduled. The client then had no real runtime to compute a resume
  percentage against.

  This drives a real cold file through the actual `startStreamingSession`
  mutation (real ffprobe, real FFmpeg HLS session, real DB) rather than
  asserting the duration-resolution helpers in isolation, so a future change
  that reorders the resolver's `with` chain or reintroduces the async probe
  on this path fails a test instead of silently returning `nil` again.
  """

  use MydiaWeb.ConnCase

  alias Mydia.AccountsFixtures
  alias Mydia.MediaFixtures
  alias Mydia.SettingsFixtures
  alias MydiaWeb.Schema.Resolvers.StreamingResolver

  @moduletag :requires_ffmpeg

  @start_streaming_session_mutation """
  mutation StartStreamingSession($fileId: ID!, $strategy: StreamingStrategy!) {
    startStreamingSession(fileId: $fileId, strategy: $strategy) {
      sessionId
      duration
      startPosition
    }
  }
  """

  @start_at_offset_mutation """
  mutation StartStreamingSession($fileId: ID!, $strategy: StreamingStrategy!, $startPosition: Int) {
    startStreamingSession(fileId: $fileId, strategy: $strategy, startPosition: $startPosition) {
      sessionId
      duration
      startPosition
    }
  }
  """

  @end_streaming_session_mutation """
  mutation EndStreamingSession($sessionId: String!) {
    endStreamingSession(sessionId: $sessionId)
  }
  """

  @echo_quality_mutation """
  mutation StartStreamingSession($fileId: ID!, $strategy: StreamingStrategy!) {
    startStreamingSession(fileId: $fileId, strategy: $strategy) {
      sessionId
      maxBitrate
      maxHeight
    }
  }
  """

  describe "startStreamingSession mutation" do
    @tag :tmp_dir
    test "a cold file (analyzed_at: nil) returns a non-nil duration", %{tmp_dir: tmp_dir} do
      user = AccountsFixtures.user_fixture()
      media_file = cold_media_file(tmp_dir)

      result =
        Absinthe.run(
          @start_streaming_session_mutation,
          MydiaWeb.Schema,
          variables: %{"fileId" => media_file.id, "strategy" => "TRANSCODE"},
          context: %{current_user: user}
        )

      assert {:ok, %{data: %{"startStreamingSession" => session}}} = result

      try do
        refute is_nil(session["duration"])
        assert_in_delta session["duration"], 2.0, 0.5
      after
        stop_session(session["sessionId"], user)
      end
    end

    @tag :tmp_dir
    test "echoes the offset the running session is transcoding from", %{tmp_dir: tmp_dir} do
      # The echoed value is read off the session itself (HlsSession's
      # `:get_info` reply), not off whatever this request happened to clamp,
      # so that a caller which reused or adopted an already-running session
      # cannot be handed an offset the stream does not actually start at. The
      # player builds its whole StreamTimeline — and therefore every progress
      # row it writes — from this number.
      #
      # Requesting 10s on a 2s file exercises the clamp too: 10 pins to
      # `trunc(2) - 1`, and the session starts (and must report) 1s.
      user = AccountsFixtures.user_fixture()
      media_file = cold_media_file(tmp_dir)

      result =
        Absinthe.run(
          @start_at_offset_mutation,
          MydiaWeb.Schema,
          variables: %{
            "fileId" => media_file.id,
            "strategy" => "TRANSCODE",
            "startPosition" => 10
          },
          context: %{current_user: user}
        )

      assert {:ok, %{data: %{"startStreamingSession" => session}}} = result

      try do
        assert session["startPosition"] == 1
      after
        stop_session(session["sessionId"], user)
      end
    end

    @tag :tmp_dir
    test "echoes the operator's transcode ceiling to a client that asked for nothing",
         %{tmp_dir: tmp_dir} do
      # The echo exists to be honest with clients. Composing the ceiling only
      # inside the transcoder made this reply say "no height cap" while the
      # encode really did scale, so a viewer on a direct connection saw
      # "Original" over a downscaled stream.
      user = AccountsFixtures.user_fixture()
      media_file = cold_media_file(tmp_dir)

      original = Application.get_env(:mydia, :runtime_config)
      on_exit(fn -> restore_runtime_config(original) end)
      put_transcode_ceiling(480)

      result =
        Absinthe.run(
          @echo_quality_mutation,
          MydiaWeb.Schema,
          variables: %{"fileId" => media_file.id, "strategy" => "TRANSCODE"},
          context: %{current_user: user}
        )

      assert {:ok, %{data: %{"startStreamingSession" => session}}} = result

      try do
        assert session["maxHeight"] == 480
        assert session["maxBitrate"] == nil
      after
        stop_session(session["sessionId"], user)
      end
    end
  end

  defp put_transcode_ceiling(height) do
    defaults = Mydia.Config.Schema.defaults()
    streaming = %{defaults.streaming | max_transcode_height: height}
    Application.put_env(:mydia, :runtime_config, %{defaults | streaming: streaming})
  end

  defp restore_runtime_config(nil), do: Application.delete_env(:mydia, :runtime_config)
  defp restore_runtime_config(config), do: Application.put_env(:mydia, :runtime_config, config)

  # A real, tiny (2s) H.264+AAC file so the cold-file path runs an actual
  # ffprobe and an actual FFmpeg HLS transcode, not a stub. Video+audio
  # lavfi sources mirror ffmpeg_remuxer_test.exs in test/mydia/streaming,
  # since the HLS transcoder always emits an audio encode step and a
  # video-only source risks an ffmpeg error on that stream mapping.
  defp cold_media_file(tmp_dir) do
    library_path = SettingsFixtures.library_path_fixture(%{path: tmp_dir, type: "movies"})
    video_path = Path.join(tmp_dir, "tiny.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-f",
          "lavfi",
          "-i",
          "testsrc=duration=2:size=320x240:rate=10",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=1000:duration=2",
          "-c:v",
          "libx264",
          "-c:a",
          "aac",
          "-y",
          video_path
        ],
        stderr_to_stdout: true
      )

    MediaFixtures.media_file_fixture(%{
      library_path_id: library_path.id,
      relative_path: "tiny.mp4",
      size: File.stat!(video_path).size,
      # Never probed yet. media_file_fixture defaults to an already-analyzed
      # row specifically so tests don't accidentally shell out to ffprobe;
      # these tests override that on purpose.
      analyzed_at: nil
    })
  end

  describe "start_streaming_session quality clamping" do
    test "passes a direct connection's requested values through unchanged" do
      assert StreamingResolver.effective_quality(nil, 8000, 1080) == {8000, 1080}
    end

    test "a relay cannot be talked out of its ceiling with a zero height" do
      # Elixir treats 0 as truthy, so `requested || @cap` does not fall back and
      # `min(0, 720)` is 0. The transcoder declines to scale to a non-positive
      # height, so without normalisation a relay client got native resolution
      # over the very infrastructure the ceiling protects.
      assert StreamingResolver.effective_quality("relay", 0, 0) == {2000, 720}
    end

    test "a relay cannot be talked out of its ceiling with a negative height" do
      assert StreamingResolver.effective_quality("relay", -1, -1) == {2000, 720}
    end

    test "a non-positive cap on a direct connection reads as no cap" do
      # Nothing to protect here, but the echo must not report 0 as an applied
      # ceiling — the client labels its quality control from these values.
      assert StreamingResolver.effective_quality(nil, 0, 0) == {nil, nil}
    end

    test "leaves an uncapped direct request uncapped" do
      assert StreamingResolver.effective_quality(nil, nil, nil) == {nil, nil}
    end

    test "clamps a relay connection to the relay ceiling" do
      # A relay carries the stream through Mydia's own infrastructure, so the
      # cap is not negotiable by the client.
      assert StreamingResolver.effective_quality("relay", 8000, 1080) == {2000, 720}
    end

    test "caps an uncapped relay request rather than letting it run free" do
      assert StreamingResolver.effective_quality("relay", nil, nil) == {2000, 720}
    end

    test "honours a relay request already below the ceiling" do
      assert StreamingResolver.effective_quality("relay", 800, 360) == {800, 360}
    end

    test "clamps each half of the pair independently" do
      # The two min/2 calls are separate, so a request that is under the
      # ceiling on one axis and over it on the other must come back mixed
      # rather than clamped or passed through wholesale.
      assert StreamingResolver.effective_quality("relay", 800, 1080) == {800, 720}
      assert StreamingResolver.effective_quality("relay", 8000, 360) == {2000, 360}
    end
  end

  defp stop_session(session_id, user) do
    Absinthe.run(
      @end_streaming_session_mutation,
      MydiaWeb.Schema,
      variables: %{"sessionId" => session_id},
      context: %{current_user: user}
    )
  end
end
