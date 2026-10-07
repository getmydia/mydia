defmodule Mydia.Library.StorageReadSitesTest do
  use Mydia.DataCase, async: false

  @moduletag :s3
  @moduletag :ffmpeg
  @moduletag :tmp_dir

  alias Mydia.Library.{FileAnalyzer, PhashGenerator, SpriteGenerator, ThumbnailGenerator}

  setup %{tmp_dir: tmp_dir} do
    {media_file, loc} = Mydia.S3Helpers.s3_media_file!(tmp_dir: tmp_dir)
    on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)
    %{media_file: media_file}
  end

  test "FileAnalyzer reads codec, duration and size from S3", %{media_file: mf} do
    {:ok, source} = Mydia.Storage.source(mf)
    assert {:ok, %{codec: codec, size: size}} = FileAnalyzer.analyze(source)
    assert is_binary(codec)
    assert size > 0
  end

  test "FileAnalyzer reports a missing object as :file_not_found", %{media_file: mf} do
    {:ok, source} = Mydia.Storage.source(%{mf | relative_path: "nope/missing.mp4"})
    assert {:error, :file_not_found} = FileAnalyzer.analyze(source)
  end

  test "ThumbnailGenerator renders a cover from S3", %{media_file: mf} do
    assert {:ok, checksum} = ThumbnailGenerator.generate_cover(mf)
    assert is_binary(checksum)
  end

  test "SpriteGenerator renders a sprite sheet from S3", %{media_file: mf} do
    assert {:ok, %{}} = SpriteGenerator.generate(mf, frame_count: 4, columns: 2)
  end

  test "PhashGenerator hashes a frame from S3", %{media_file: mf} do
    assert {:ok, hash} = PhashGenerator.generate(mf)
    assert is_binary(hash)
  end

  describe "a failing read of a presigned URL" do
    # The object is deleted after the URL is minted, so ffmpeg and ffprobe get
    # a 404 whose message echoes the URL.
    setup %{media_file: mf} do
      {:ok, url} = Mydia.Storage.media_input(mf)
      assert url =~ "X-Amz-"
      {:ok, source} = Mydia.Storage.source(mf)
      {:ok, loc} = {:ok, source.location}
      Mydia.S3Helpers.delete_prefix!(loc)
      %{url: url}
    end

    test "Ffmpeg errors carry no X-Amz- text", %{url: url} do
      assert {:error, {:ffprobe_error, _, probe_output}} = Mydia.Library.Ffmpeg.probe([url])
      assert {:error, {:ffmpeg_error, _, run_output}} = Mydia.Library.Ffmpeg.run(["-i", url])
      refute probe_output =~ "X-Amz-"
      refute run_output =~ "X-Amz-"
    end

    test "generator results and logs carry no X-Amz- text", %{url: url} do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, reason} = ThumbnailGenerator.get_duration(url)
          refute inspect(reason) =~ "X-Amz-"
          assert {:error, reason} = ThumbnailGenerator.generate_cover_from_path(url)
          refute inspect(reason) =~ "X-Amz-"
        end)

      refute log =~ "X-Amz-"
    end
  end

  test "a missing local file is :file_not_found for MediaFile based generators", %{
    tmp_dir: tmp_dir
  } do
    mf = %Mydia.Library.MediaFile{
      id: Ecto.UUID.generate(),
      relative_path: "nope.mp4",
      library_path: %Mydia.Settings.LibraryPath{path: tmp_dir}
    }

    assert {:error, :file_not_found} = ThumbnailGenerator.generate_cover(mf)
    assert {:error, :file_not_found} = SpriteGenerator.generate(mf)
    assert {:error, :file_not_found} = Mydia.Library.PreviewGenerator.generate(mf)
    assert {:error, :file_not_found} = PhashGenerator.generate(mf)
  end

  test "generators keep :library_path_not_preloaded for an unloaded media file", %{media_file: mf} do
    unloaded = %{mf | library_path: %Ecto.Association.NotLoaded{}}
    assert {:error, :library_path_not_preloaded} = ThumbnailGenerator.generate_cover(unloaded)
  end

  describe "embedded subtitles" do
    alias Mydia.Subtitles.{Delivery, Extractor}

    setup %{tmp_dir: tmp_dir} do
      {media_file, loc} = Mydia.S3Helpers.s3_media_file!(tmp_dir: tmp_dir, subtitles: true)
      on_exit(fn -> Mydia.S3Helpers.delete_prefix!(loc) end)
      %{sub_file: media_file}
    end

    test "embedded subtitle tracks are listed from S3", %{sub_file: mf} do
      assert [%{embedded: true, language: "eng", format: "srt"}] =
               Extractor.list_subtitle_tracks(mf)
    end

    test "an embedded track is extracted from S3", %{sub_file: mf} do
      [%{track_id: track_id}] = Extractor.list_subtitle_tracks(mf)
      assert {:ok, path} = Extractor.extract_subtitle_track(mf, track_id)
      assert File.read!(path) =~ "First invented cue"
      File.rm(path)
    end

    test "Delivery serves embedded track content from S3", %{sub_file: mf} do
      [%{track_id: track_id}] = Extractor.list_subtitle_tracks(mf)
      assert {:ok, content} = Delivery.content(mf, track_id, "srt")
      assert content =~ "Second invented cue"
    end

    test "a failed extraction leaks no presigned URL", %{sub_file: mf} do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:error, reason} = Extractor.extract_subtitle_track(mf, 99)
          refute inspect(reason) =~ "X-Amz-"
          assert {:error, reason} = Delivery.content(mf, 99, "srt")
          refute inspect(reason) =~ "X-Amz-"
        end)

      refute log =~ "X-Amz-"
    end

    test "a missing object is :media_file_not_found", %{sub_file: mf} do
      gone = %{mf | relative_path: "nope/missing.mp4"}
      assert Extractor.list_subtitle_tracks(gone) == []
      assert {:error, :media_file_not_found} = Extractor.extract_subtitle_track(gone, 2)
      assert {:error, :media_file_not_found} = Delivery.content(gone, 2, "srt")
    end
  end
end
