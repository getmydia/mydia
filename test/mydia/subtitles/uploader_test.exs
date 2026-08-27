defmodule Mydia.Subtitles.UploaderTest do
  use Mydia.DataCase, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Subtitles.Uploader

  @srt """
  1
  00:00:01,000 --> 00:00:02,000
  Hello.
  """

  defp movie_with_media_file(relative_path \\ "Movie.mkv", attrs \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "uploader-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

    media_file =
      Map.merge(%{library_path_id: library_path.id, relative_path: relative_path}, attrs)
      |> Mydia.MediaFixtures.media_file_fixture()
      |> Mydia.Repo.preload(:library_path)

    File.write!(Path.join(dir, relative_path), "not really a video")

    {dir, media_file}
  end

  describe "upload/3" do
    test "stores the file and creates an upload-origin row" do
      {dir, media_file} = movie_with_media_file()

      assert {:ok, subtitle} = Uploader.upload(media_file, @srt, language: "en")

      assert subtitle.origin == "upload"
      assert subtitle.provider == "upload"
      assert subtitle.language == "en"
      assert subtitle.format == "srt"
      assert subtitle.file_path == Path.join(dir, "Movie.en.srt")
      assert File.read!(subtitle.file_path) == @srt
    end

    test "sets forced and hearing_impaired from opts" do
      {_dir, media_file} = movie_with_media_file()

      assert {:ok, subtitle} =
               Uploader.upload(media_file, @srt,
                 language: "en",
                 forced: true,
                 hearing_impaired: true
               )

      assert subtitle.forced
      assert subtitle.hearing_impaired
    end

    test "rejects content that is not a subtitle, without writing anything" do
      {dir, media_file} = movie_with_media_file()

      assert {:error, message} = Uploader.upload(media_file, <<0, 1, 2, 3>>, language: "en")

      assert message =~ "not a subtitle"
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
      assert File.exists?(Path.join(dir, "Movie.en.srt")) == false
    end

    test "rejects a MicroDVD file by name, distinct from an unrecognized one" do
      {_dir, media_file} = movie_with_media_file()

      assert {:error, message} =
               Uploader.upload(media_file, "{0}{100}Hello there", language: "en")

      assert message =~ "sub subtitle"
    end

    test "refuses to overwrite an existing subtitle for that language" do
      {dir, media_file} = movie_with_media_file()
      existing_path = Path.join(dir, "Movie.en.srt")
      File.write!(existing_path, "original content")

      assert {:error, message} = Uploader.upload(media_file, @srt, language: "en")

      assert message =~ "already a subtitle"
      assert File.read!(existing_path) == "original content"
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end

    test "removes the file it wrote when the database insert fails" do
      {dir, media_file} = movie_with_media_file()

      assert {:ok, _first} = Uploader.upload(media_file, @srt, language: "es")

      # Same content, different language: the destination path for "fr" does
      # not exist yet, so the existing-path guard does not fire. The
      # (media_file_id, subtitle_hash) unique index is what actually rejects
      # this, after the file has already been written to disk.
      assert {:error, message} = Uploader.upload(media_file, @srt, language: "fr")

      assert message =~ "identical content"
      assert File.exists?(Path.join(dir, "Movie.fr.srt")) == false
      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert subtitle.language == "es"
    end

    test "reports a plain error when the media file's location cannot be resolved" do
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        relative_path: "Movie.mkv",
        library_path: nil
      }

      assert {:error, message} = Uploader.upload(media_file, @srt, language: "en")
      assert message =~ "Could not resolve"
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end

    # Permission-based tests are unreliable across this project's execution
    # environments (some run as root, where chmod cannot deny writes); see
    # the identically-reasoned @tag :skip in
    # test/mydia/library/scanner_test.exs. Kept here, skipped, so the
    # required behavior stays documented and easy to run by hand.
    @tag :skip
    test "reports a plain error naming the directory on a read-only mount" do
      {dir, media_file} = movie_with_media_file()
      File.chmod!(dir, 0o500)

      result = Uploader.upload(media_file, @srt, language: "en")

      File.chmod!(dir, 0o700)

      assert {:error, message} = result
      assert message =~ dir
      assert message =~ "read-only"
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end
  end

  # Sibling media files that reduce to the exact same basename (one title,
  # two containers) cannot be told apart by name. Mydia.Subtitles.Sidecars
  # attributes their shared sidecar to whichever one
  # Mydia.Library.FileRanking.best/1 ranks higher; uploading against the
  # other one must be refused rather than create a second row a later
  # reconcile pass would disagree with.
  describe "upload/3 with an identical-basename sibling" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "uploader-identical-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

      low =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mp4",
          resolution: "480p"
        })
        |> Mydia.Repo.preload(:library_path)

      high =
        Mydia.MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mkv",
          resolution: "1080p"
        })
        |> Mydia.Repo.preload(:library_path)

      File.write!(Path.join(dir, "Movie.mp4"), "not really a video")
      File.write!(Path.join(dir, "Movie.mkv"), "not really a video either")

      %{dir: dir, low: low, high: high}
    end

    test "refuses the upload against the non-owning file, writing nothing", %{
      dir: dir,
      low: low,
      high: high
    } do
      assert {:error, message} = Uploader.upload(low, @srt, language: "en")

      assert message =~ MediaFile.display_name(high)
      assert File.exists?(Path.join(dir, "Movie.en.srt")) == false
      assert Mydia.Subtitles.list_subtitles(low.id) == []
      assert Mydia.Subtitles.list_subtitles(high.id) == []
    end

    test "accepts the upload against the owning file", %{dir: dir, high: high} do
      assert {:ok, subtitle} = Uploader.upload(high, @srt, language: "en")

      assert subtitle.media_file_id == high.id
      assert File.exists?(Path.join(dir, "Movie.en.srt"))
    end
  end
end
