defmodule Mydia.Subtitles.DownloaderOverwriteTest do
  # File.rename/2 (the primitive this module used to move a subtitle into
  # place) silently overwrites an existing destination. Uploader and
  # Sidecars write the exact same naming convention, so a download landing
  # on a path either of them already owns used to clobber that file's bytes
  # while leaving both database rows in place, one now lying about what it
  # points at. These tests exercise the refusal that closes that gap.
  use Mydia.DataCase, async: true

  alias Mydia.MediaFixtures
  alias Mydia.Subtitles.Downloader
  alias Mydia.Subtitles.Uploader

  @original_srt "1\n00:00:01,000 --> 00:00:02,000\noriginal\n"
  @downloaded_srt "1\n00:00:01,000 --> 00:00:02,000\ndownloaded\n"

  defmodule ContentAdapter do
    @behaviour Mydia.Subtitles.Provider

    @impl true
    def search(_config, _params), do: {:ok, []}

    @impl true
    def download(config, _info) do
      {:ok, config.connection_settings["content"]}
    end

    @impl true
    def validate_config(config), do: {:ok, config}

    @impl true
    def quota_info(_config),
      do: {:ok, Mydia.Subtitles.Provider.QuotaInfo.unlimited(:subdl)}

    @impl true
    def capabilities do
      %{
        media_types: [:movie],
        search_keys: [:tmdb_id],
        requires_credentials: false,
        quota: :unlimited
      }
    end
  end

  defp config_for(content) do
    %{type: :subdl, connection_settings: %{"adapter" => ContentAdapter, "content" => content}}
  end

  defp movie_with_media_file(relative_path \\ "Movie.mkv", attrs \\ %{}) do
    dir =
      Path.join(System.tmp_dir!(), "downloader-overwrite-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

    media_file =
      Map.merge(%{library_path_id: library_path.id, relative_path: relative_path}, attrs)
      |> MediaFixtures.media_file_fixture()
      |> Mydia.Repo.preload(:library_path)

    File.write!(Path.join(dir, relative_path), "not really a video")

    {dir, media_file}
  end

  describe "download/3 destination collision" do
    test "refuses to overwrite a subtitle another row owns, and does not create a second row" do
      {dir, media_file} = movie_with_media_file()
      existing_path = Path.join(dir, "Movie.en.srt")

      assert {:ok, existing} = Uploader.upload(media_file, @original_srt, language: "en")
      assert existing.file_path == existing_path

      info = %{
        file_id: "/subtitle/collide.zip",
        language: "en",
        format: "srt",
        subtitle_hash: "a-different-hash-than-the-upload"
      }

      assert {:error, _reason} =
               Downloader.download(info, media_file.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      # The original bytes are untouched...
      assert File.read!(existing_path) == @original_srt
      # ...and there is still exactly one row, the original upload.
      assert [only] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert only.id == existing.id
      assert only.origin == "upload"
    end

    test "refuses to overwrite a sidecar-origin subtitle the same way" do
      {dir, media_file} = movie_with_media_file()
      existing_path = Path.join(dir, "Movie.en.srt")
      File.write!(existing_path, @original_srt)

      {:ok, sidecar} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "sidecar-hash",
          file_path: existing_path,
          format: "srt"
        })
        |> Mydia.Repo.insert()

      info = %{
        file_id: "/subtitle/collide-sidecar.zip",
        language: "en",
        format: "srt",
        subtitle_hash: "yet-another-hash"
      }

      assert {:error, _reason} =
               Downloader.download(info, media_file.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      assert File.read!(existing_path) == @original_srt
      assert [only] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert only.id == sidecar.id
    end

    test "still succeeds for the ordinary case where nothing occupies the destination" do
      {dir, media_file} = movie_with_media_file()

      info = %{
        file_id: "/subtitle/fresh.zip",
        language: "en",
        format: "srt",
        subtitle_hash: "fresh-hash"
      }

      assert {:ok, subtitle} =
               Downloader.download(info, media_file.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      assert subtitle.file_path == Path.join(dir, "Movie.en.srt")
      assert File.read!(subtitle.file_path) == @downloaded_srt
    end
  end

  # Sibling media files that reduce to the exact same basename (one title,
  # two containers) cannot be told apart by name. Mydia.Subtitles.Sidecars
  # attributes their shared sidecar to whichever one
  # Mydia.Library.FileRanking.best/1 ranks higher; downloading against the
  # other one must be refused rather than create a second row a later
  # reconcile pass would disagree with.
  describe "download/3 with an identical-basename sibling" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "downloader-overwrite-identical-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

      low =
        MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mp4",
          resolution: "480p"
        })
        |> Mydia.Repo.preload(:library_path)

      high =
        MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: "Movie.mkv",
          resolution: "1080p"
        })
        |> Mydia.Repo.preload(:library_path)

      File.write!(Path.join(dir, "Movie.mp4"), "not really a video")
      File.write!(Path.join(dir, "Movie.mkv"), "not really a video either")

      %{dir: dir, low: low, high: high}
    end

    test "refuses the download against the non-owning file, writing nothing", %{
      dir: dir,
      low: low,
      high: high
    } do
      info = %{
        file_id: "/subtitle/sibling.zip",
        language: "en",
        format: "srt",
        subtitle_hash: "sibling-hash"
      }

      assert {:error, {:owned_by_other_media_file, owner_id}} =
               Downloader.download(info, low.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      assert owner_id == high.id
      assert File.exists?(Path.join(dir, "Movie.en.srt")) == false
      assert Mydia.Subtitles.list_subtitles(low.id) == []
      assert Mydia.Subtitles.list_subtitles(high.id) == []
    end

    test "accepts the download against the owning file", %{dir: dir, high: high} do
      info = %{
        file_id: "/subtitle/owner.zip",
        language: "en",
        format: "srt",
        subtitle_hash: "owner-hash"
      }

      assert {:ok, subtitle} =
               Downloader.download(info, high.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      assert subtitle.media_file_id == high.id
      assert File.exists?(Path.join(dir, "Movie.en.srt"))
    end
  end

  # `language` reaches here from a provider's search result, external data
  # the provider chain does not sanitize. These tests exercise that boundary
  # directly, mirroring test/mydia/subtitles/uploader_test.exs's own language
  # validation describe block.
  describe "download/3 language validation" do
    test "rejects a language value that attempts path traversal, writing nothing outside the media directory" do
      {dir, media_file} = movie_with_media_file()
      marker = "pwned-#{System.unique_integer([:positive])}"
      escaped_path = Path.join(Path.dirname(dir), "#{marker}.srt")
      on_exit(fn -> File.rm(escaped_path) end)

      refute File.exists?(escaped_path)

      info = %{
        file_id: "/subtitle/traversal.zip",
        language: "../../../#{marker}",
        format: "srt",
        subtitle_hash: "traversal-hash"
      }

      assert {:error, :invalid_language} =
               Downloader.download(info, media_file.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      refute File.exists?(escaped_path)
      refute File.exists?(Path.join(dir, "Movie..."))
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end

    test "rejects a language value containing a path separator" do
      {dir, media_file} = movie_with_media_file()

      info = %{
        file_id: "/subtitle/separator.zip",
        language: "en/evil",
        format: "srt",
        subtitle_hash: "separator-hash"
      }

      assert {:error, :invalid_language} =
               Downloader.download(info, media_file.id,
                 provider_type: :subdl,
                 provider_config: config_for(@downloaded_srt)
               )

      assert File.ls!(dir) == ["Movie.mkv"]
      assert Mydia.Subtitles.list_subtitles(media_file.id) == []
    end
  end
end
