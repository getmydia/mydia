defmodule Mydia.Subtitles.ImageTrackIntegrationTest do
  @moduledoc """
  Copies a real PGS track out of a real MKV with the installed ffmpeg.

  Tagged :ffmpeg like the HLS integration tests: it needs the binaries and
  guards ffmpeg behaviour (`-c copy -f matroska` of one subtitle stream)
  that an upgrade could change. Run it with `--include ffmpeg`.
  """
  use Mydia.DataCase, async: false

  @moduletag :ffmpeg

  if is_nil(System.find_executable("ffmpeg")) or is_nil(System.find_executable("ffprobe")) do
    @moduletag skip: "ffmpeg/ffprobe not found on PATH"
  end

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.PgsFixture
  alias Mydia.Repo
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.ImageTrack

  setup do
    media_file =
      MediaFixtures.media_file_fixture(%{
        metadata: %FileMetadata{
          streams: [
            %StreamInfo{index: 0, type: :video, codec: "h264"},
            %StreamInfo{index: 1, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "eng"}
          ]
        }
      })
      |> Repo.preload(:library_path)

    source = MediaFile.absolute_path(media_file)
    File.mkdir_p!(Path.dirname(source))

    on_exit(fn ->
      File.rm_rf(media_file.library_path.path)
      File.rm_rf(Path.join(Delivery.cache_dir(), media_file.id))
    end)

    {:ok, media_file: media_file, source: source}
  end

  test "copies the track into a subtitle-only Matroska file", %{
    media_file: media_file,
    source: source
  } do
    PgsFixture.write_mkv!(source)

    assert :pending = ImageTrack.path(media_file, 1)
    assert {:ok, cached} = await_copy(media_file, 1)

    {out, 0} =
      System.cmd("ffprobe", [
        "-v",
        "error",
        "-show_entries",
        "stream=codec_name,codec_type",
        "-of",
        "csv=p=0",
        cached
      ])

    assert String.trim(out) == "hdmv_pgs_subtitle,subtitle"
  end

  test "a source ffmpeg cannot read leaves a failure marker", %{
    media_file: media_file,
    source: source
  } do
    File.write!(source, "not a media file")

    assert :pending = ImageTrack.path(media_file, 1)
    assert {:error, :extraction_failed} = await_copy(media_file, 1)
  end

  # Polls the way the player does, bounded well past the copy of a 5 s file.
  defp await_copy(media_file, index, attempts \\ 100) do
    case ImageTrack.path(media_file, index) do
      :pending when attempts > 0 ->
        Process.sleep(100)
        await_copy(media_file, index, attempts - 1)

      other ->
        other
    end
  end
end
