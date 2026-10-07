defmodule Mydia.Storage.WriteGuardTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Library
  alias Mydia.Library.{FileOrganizer, FileRenamer, MediaFile, TrashStore}
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Metadata.Structs.MediaMetadata
  alias Mydia.Media.MediaItem
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage.Error
  alias Mydia.Subtitles

  @lp %LibraryPath{id: Ecto.UUID.generate(), path: "s3://media/movies", type: :movies}
  @mf %MediaFile{id: Ecto.UUID.generate(), relative_path: "A/a.mkv", library_path: @lp}

  # A persisted S3 library and a media file in it, read back without the
  # library_path association, which is how several callers hold it.
  setup do
    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "m",
        endpoint: "http://localhost:1",
        region: "us-east-1",
        bucket: "lib",
        access_key_id: "k",
        secret_access_key: "s"
      })

    {:ok, lp} =
      Settings.create_library_path(%{path: "s3://m/movies", type: "movies", monitored: true})

    file =
      media_file_fixture(%{
        library_path_id: lp.id,
        relative_path: "Invented Film (2031)/film.mkv"
      })

    %{s3_file: Repo.get!(MediaFile, file.id)}
  end

  @tag :tmp_dir
  test "place_file into an unreachable bucket reports the outage", %{tmp_dir: tmp_dir} do
    src = Path.join(tmp_dir, "a.mkv")
    File.write!(src, "x")

    assert {:error, %Error{kind: :unreachable}} =
             FileOrganizer.place_file(src, "s3://m/movies/A/a.mkv", expected_size: 1)

    assert File.exists?(src)
  end

  test "organize, reorganize and rename refuse S3 files" do
    assert {:error, %Error{kind: :read_only}} = FileOrganizer.organize_file(@mf)
    assert {:error, %Error{kind: :read_only}} = FileOrganizer.reorganize_library(@lp)

    assert {:error, %Error{kind: :read_only}} =
             FileRenamer.rename_file(@mf, "s3://media/movies/B/b.mkv")
  end

  test "unpreloaded S3 media files are refused too", %{s3_file: file} do
    assert %Ecto.Association.NotLoaded{} = file.library_path

    assert {:error, %Error{kind: :read_only}} = FileOrganizer.organize_file(file)
    assert {:error, %Error{kind: :read_only}} = FileRenamer.rename_file(file, "/tmp/other.mkv")
    assert {:error, %Error{kind: :read_only}} = Library.delete_media_file_from_disk(file)

    assert {:error, %Error{kind: :read_only}} =
             Library.delete_media_file(file, delete_files: true)

    assert Repo.get(MediaFile, file.id)
  end

  test "trashing an S3 file is refused unless the object is gone", %{s3_file: file} do
    for reason <- [:manual, :pruned, :upgraded, nil] do
      assert {:error, %Error{kind: :read_only}} =
               Library.trash_media_file(file, reason: reason)
    end

    refute Repo.get!(MediaFile, file.id).trashed_at

    assert {:ok, trashed} = Library.trash_media_file(file, reason: :missing, move: false)
    assert trashed.trashed_at
  end

  test "TrashStore.store never moves S3 bytes", %{s3_file: file} do
    assert {:ok, :missing} = TrashStore.store(Repo.preload(file, :library_path))
  end

  test "NFO writer skips S3 libraries without touching the filesystem" do
    metadata = %MediaMetadata{provider_id: "1", provider: :metadata_relay, media_type: :movie}
    item = %MediaItem{type: "movie", metadata: metadata}
    assert {:error, %Error{kind: :read_only}} = NfoWriter.write_for_media_item(item, @lp)
  end

  test "subtitle download is refused for an S3 file", %{s3_file: file} do
    info = %{file_id: 1, language: "en", format: "srt", subtitle_hash: "h"}

    assert {:error, %Error{kind: :read_only}} = Subtitles.download_subtitle(info, file.id)
  end

  test "subtitle upload is refused with a message for an S3 file", %{s3_file: file} do
    assert {:error, message} =
             Subtitles.upload_subtitle(file, "1\n00:00:01,000 --> 00:00:02,000\nHi\n",
               language: "en"
             )

    assert message == "S3 libraries are read-only in this version of Mydia"
  end
end
