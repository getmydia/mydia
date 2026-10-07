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

  test "generators keep :library_path_not_preloaded for an unloaded media file", %{media_file: mf} do
    unloaded = %{mf | library_path: %Ecto.Association.NotLoaded{}}
    assert {:error, :library_path_not_preloaded} = ThumbnailGenerator.generate_cover(unloaded)
  end
end
