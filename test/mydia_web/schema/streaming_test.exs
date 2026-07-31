defmodule MydiaWeb.Schema.StreamingTest do
  @moduledoc """
  Regression coverage for the Task 4 cold-file duration fix.

  Before this fix, a never-probed media file (`analyzed_at: nil`) always
  echoed `duration: nil` from `startStreamingSession`, because the old
  fire-and-forget `Candidates.ensure_codec_info_async/1` returned before the
  probe wrote anything back, and the resolver read duration off the struct
  loaded before the probe was even scheduled. The client then had no real
  runtime to compute a resume percentage against.

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

  @end_streaming_session_mutation """
  mutation EndStreamingSession($sessionId: String!) {
    endStreamingSession(sessionId: $sessionId)
  }
  """

  describe "startStreamingSession mutation" do
    @tag :tmp_dir
    test "a cold file (analyzed_at: nil) returns a non-nil duration", %{tmp_dir: tmp_dir} do
      user = AccountsFixtures.user_fixture()
      library_path = SettingsFixtures.library_path_fixture(%{path: tmp_dir, type: "movies"})

      video_path = Path.join(tmp_dir, "tiny.mp4")

      # A real, tiny (2s) H.264+AAC file so the cold-file path runs an actual
      # ffprobe and an actual FFmpeg HLS transcode, not a stub. Video+audio
      # lavfi sources mirror ffmpeg_remuxer_test.exs in this same directory,
      # since the HLS transcoder always emits an audio encode step and a
      # video-only source risks an ffmpeg error on that stream mapping.
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

      media_file =
        MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "tiny.mp4",
          size: File.stat!(video_path).size,
          # The whole point: never probed yet. media_file_fixture defaults to
          # an already-analyzed row specifically so tests don't accidentally
          # shell out to ffprobe; this test overrides that on purpose.
          analyzed_at: nil
        })

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
