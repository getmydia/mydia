defmodule Mydia.Streaming.HlsSessionSeekAlignmentTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.SegmentPlan
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Settings.LibraryPath

  describe "encoder_start_position/3" do
    setup do
      {:ok, plan} = SegmentPlan.build(3600.0)
      %{plan: plan}
    end

    test "a :full session's first encoder starts on the segment grid", %{plan: plan} do
      first_index = SegmentPlan.index_for_time(plan, 1234)

      assert first_index == 308
      assert HlsSession.encoder_start_position(plan, first_index, 1234) == 1232
    end

    test "agrees with where a relocation to the same segment starts", %{plan: plan} do
      # relocate/2 starts at trunc(SegmentPlan.start_time(plan, target)). If the
      # first encoder disagreed, its segment 308 and a relocated one would
      # begin at different times.
      assert HlsSession.encoder_start_position(plan, 308, 1234) ==
               trunc(SegmentPlan.start_time(plan, 308))
    end

    test "a resume already on the grid starts where it was asked to", %{plan: plan} do
      assert HlsSession.encoder_start_position(plan, 7, 28) == 28
    end

    test "a :window session starts where it was asked to" do
      assert HlsSession.encoder_start_position(nil, 0, 1234) == 1234
    end
  end

  defp media_file(codec, opts \\ []) do
    %MediaFile{
      id: Ecto.UUID.generate(),
      codec: codec,
      audio_codec: "aac",
      relative_path: "resume.mkv",
      library_path: %LibraryPath{path: "/lib"},
      metadata: %FileMetadata{
        duration: Keyword.get(opts, :duration, 3600.0),
        container: Keyword.get(opts, :container, "mkv"),
        streams: []
      }
    }
  end

  defp locate_to(answer) do
    test_pid = self()

    fn path, seconds ->
      send(test_pid, {:located, path, seconds})
      answer
    end
  end

  defp never_locate do
    fn _path, _seconds -> flunk("the keyframe lookup should not have run") end
  end

  describe "effective_playlist_mode/2" do
    test "a :full request with a known duration runs :full" do
      assert HlsSession.effective_playlist_mode(media_file("h264"), :full) == :full
    end

    test "a :full request without a duration degrades to :window" do
      assert HlsSession.effective_playlist_mode(media_file("h264", duration: nil), :full) ==
               :window
    end

    test "a :window request runs :window" do
      assert HlsSession.effective_playlist_mode(media_file("h264"), :window) == :window
    end
  end

  describe "seek_opts/3" do
    test "pins a copied :window resume to the keyframe the lookup found" do
      opts =
        HlsSession.seek_opts(media_file("h264"), [start_position: 27], locate_to({:ok, 20.0}))

      assert opts[:seek_keyframe] == 20.0
      # The requested offset is left alone: the supervisor matches on it.
      assert opts[:start_position] == 27
      assert_received {:located, "/lib/resume.mkv", 27}
    end

    test "pins an MP4 too" do
      file = media_file("h264", container: "mp4")

      assert HlsSession.seek_opts(file, [start_position: 27], locate_to({:ok, 20.0}))[
               :seek_keyframe
             ] == 20.0
    end

    test "looks one up for a :full request that degrades to :window" do
      opts =
        HlsSession.seek_opts(
          media_file("h264", duration: nil),
          [start_position: 27, playlist_mode: :full],
          locate_to({:ok, 20.0})
        )

      assert opts[:seek_keyframe] == 20.0
    end

    test "leaves opts alone when the lookup has no answer" do
      opts = [start_position: 27]

      assert HlsSession.seek_opts(media_file("h264"), opts, locate_to(:none)) == opts
    end

    test "never looks up re-encoded video" do
      # Accurate seek, plus -copypriorss:a 0 for copied audio, already starts
      # it on the second it was asked for.
      opts = [start_position: 27]

      assert HlsSession.seek_opts(media_file("hevc"), opts, never_locate()) == opts
    end

    test "never looks up a capped session, which always re-encodes" do
      opts = [start_position: 27, max_bitrate: 4000]

      assert HlsSession.seek_opts(media_file("h264"), opts, never_locate()) == opts
    end

    test "never looks up a :full session" do
      opts = [start_position: 27, playlist_mode: :full]

      assert HlsSession.seek_opts(media_file("h264"), opts, never_locate()) == opts
    end

    test "never looks up an MPEG-TS source" do
      # A TS copy seek lands after its target, so a pin would start the stream
      # a GOP later than the echo claims.
      opts = [start_position: 27]

      assert HlsSession.seek_opts(media_file("h264", container: "ts"), opts, never_locate()) ==
               opts
    end

    test "never looks up a start from zero" do
      opts = [start_position: 0]

      assert HlsSession.seek_opts(media_file("h264"), opts, never_locate()) == opts
    end
  end

  describe "transcoder_base_opts/4" do
    test "forwards a pinned keyframe to the transcoder" do
      opts =
        HlsSession.transcoder_base_opts(media_file("h264"), "/lib/resume.mkv", "/tmp/s",
          seek_keyframe: 20.0,
          start_position: 27
        )

      assert opts[:seek_keyframe] == 20.0
      assert opts[:start_position] == 27
      assert opts[:input_path] == "/lib/resume.mkv"
    end

    test "forwards no keyframe when none was pinned" do
      opts =
        HlsSession.transcoder_base_opts(media_file("h264"), "/lib/resume.mkv", "/tmp/s",
          start_position: 27
        )

      assert Keyword.get(opts, :seek_keyframe) == nil
    end
  end
end
