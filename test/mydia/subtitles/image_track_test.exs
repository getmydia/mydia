defmodule Mydia.Subtitles.ImageTrackTest do
  @moduledoc """
  `ImageTrack.path/2`'s decisions, without running ffmpeg. The copy itself
  is covered by `image_track_integration_test.exs`, tagged :ffmpeg.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Plugins.SingleFlight
  alias Mydia.Repo
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.ImageTrack

  # A text track at 2 and a PGS track at 3, over a placeholder source file.
  setup do
    media_file =
      MediaFixtures.media_file_fixture(%{
        metadata: %FileMetadata{
          streams: [
            %StreamInfo{index: 0, type: :video, codec: "h264"},
            %StreamInfo{index: 2, type: :subtitle, codec: "subrip", language: "eng"},
            %StreamInfo{index: 3, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "spa"}
          ]
        }
      })
      |> Repo.preload(:library_path)

    source = MediaFile.absolute_path(media_file)
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "placeholder")

    on_exit(fn ->
      File.rm_rf(media_file.library_path.path)
      File.rm_rf(Path.join(Delivery.cache_dir(), media_file.id))
    end)

    {:ok, media_file: media_file, source: source}
  end

  test "serves a cached copy and touches it", %{media_file: media_file} do
    {:ok, cached} = ImageTrack.cache_path(media_file, 3)
    File.mkdir_p!(Path.dirname(cached))
    File.write!(cached, "mks")
    File.touch!(cached, System.os_time(:second) - 3600)

    assert {:ok, ^cached} = ImageTrack.path(media_file, 3)

    {:ok, %File.Stat{mtime: mtime}} = File.stat(cached, time: :posix)
    assert mtime > System.os_time(:second) - 60
  end

  test "answers :pending while a copy holds the lock, and writes nothing", %{
    media_file: media_file
  } do
    {:ok, cached} = ImageTrack.cache_path(media_file, 3)

    :ok =
      SingleFlight.acquire(ImageTrack.lock_slug(cached), :skip, Mydia.Streaming.SubtitleLock)

    assert :pending = ImageTrack.path(media_file, 3)
    assert :pending = ImageTrack.path(media_file, 3)
    refute File.exists?(cached)
    refute File.exists?(ImageTrack.failed_marker(cached))
  end

  test "reports a failed copy without starting another", %{media_file: media_file} do
    {:ok, cached} = ImageTrack.cache_path(media_file, 3)
    File.mkdir_p!(Path.dirname(cached))
    File.write!(ImageTrack.failed_marker(cached), "boom")

    assert {:error, :extraction_failed} = ImageTrack.path(media_file, 3)
  end

  test "refuses a text track", %{media_file: media_file} do
    assert {:error, :not_image_track} = ImageTrack.path(media_file, 2)
  end

  test "refuses a stream the file does not have", %{media_file: media_file} do
    assert {:error, :subtitle_not_found} = ImageTrack.path(media_file, 9)
  end

  test "reports a source missing from disk", %{media_file: media_file, source: source} do
    File.rm!(source)
    assert {:error, :media_file_not_found} = ImageTrack.path(media_file, 3)
  end

  test "a replaced source gets a different cache path", %{
    media_file: media_file,
    source: source
  } do
    {:ok, before} = ImageTrack.cache_path(media_file, 3)
    File.write!(source, "a different, longer placeholder")
    {:ok, after_replace} = ImageTrack.cache_path(media_file, 3)

    refute before == after_replace
  end

  describe "evict_stale/1" do
    test "removes copies, markers and temp files untouched for a week, and keeps the rest" do
      dir = Path.join(Delivery.cache_dir(), "evict-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      now = System.os_time(:second)
      old = now - 8 * 24 * 60 * 60

      stale = Enum.map(["3-1.mks", "3-1.mks.failed", "3-1.mks.tmp-9"], &Path.join(dir, &1))
      text = Path.join(dir, "2-1.vtt")
      fresh = Path.join(dir, "4-1.mks")

      for file <- [text | stale] do
        File.write!(file, "x")
        File.touch!(file, old)
      end

      File.write!(fresh, "x")

      assert :ok = ImageTrack.evict_stale(now)

      for file <- stale, do: refute(File.exists?(file))
      assert File.exists?(fresh)
      # Text bodies belong to Delivery and are left alone.
      assert File.exists?(text)
    end
  end
end
