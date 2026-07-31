defmodule Mydia.Jobs.MovieSearchTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Jobs.MovieSearch
  alias Mydia.Library
  alias Mydia.Search
  alias Mydia.Settings
  alias Mydia.IndexerMock
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Registry

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures

  alias Mydia.Repo

  # Mock download client adapter for testing
  defmodule MockDownloadAdapter do
    @behaviour Client

    @impl true
    def supported_protocols, do: [:torrent]

    @impl true
    def test_connection(_config) do
      {:ok, %{version: "1.0.0", api_version: "1.0"}}
    end

    @impl true
    def add_torrent(_config, _torrent, _opts) do
      {:ok, "mock-download-id-#{:rand.uniform(1000)}"}
    end

    @impl true
    def get_status(_config, _client_id) do
      {:ok, %{}}
    end

    @impl true
    def list_torrents(_config, _opts) do
      {:ok, []}
    end

    @impl true
    def remove_torrent(_config, _client_id, _opts) do
      :ok
    end

    @impl true
    def pause_torrent(_config, _client_id) do
      :ok
    end

    @impl true
    def resume_torrent(_config, _client_id) do
      :ok
    end
  end

  setup do
    # Register mock download client adapter
    Registry.register(:transmission, MockDownloadAdapter)

    # Create test user for client configs
    user = user_fixture()

    # Create test download client
    download_client_config_fixture(%{
      name: "test-transmission",
      type: "transmission",
      enabled: true,
      priority: 1,
      host: "localhost",
      port: 9091,
      updated_by_id: user.id
    })

    # Create test library path for media files
    library_path = library_path_fixture(%{path: "/test/library", type: "movies"})

    # Disable all existing DB indexer configs so only our Bypass mock is used
    Settings.list_indexer_configs()
    |> Enum.reject(&Mydia.Settings.runtime_config?/1)
    |> Enum.each(fn config ->
      Settings.update_indexer_config(config, %{enabled: false})
    end)

    # Set up mock Prowlarr server for all tests
    bypass = Bypass.open()

    # Mock with movie results
    IndexerMock.mock_prowlarr_all(bypass,
      results: [
        IndexerMock.movie_result(%{title: "The Matrix", year: 1999, seeders: 100}),
        IndexerMock.movie_result(%{title: "Inception", year: 2010, seeders: 80}),
        IndexerMock.movie_result(%{title: "Movie One", year: 2020, seeders: 50}),
        IndexerMock.movie_result(%{title: "Movie Two", year: 2021, seeders: 45}),
        IndexerMock.movie_result(%{title: "Movie Three", year: 2022, seeders: 40})
      ]
    )

    # Create test indexer configuration pointing to Bypass server
    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Test Movie Indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    %{bypass: bypass, library_path: library_path}
  end

  describe "perform/1 - specific mode" do
    test "returns error when media item does not exist" do
      fake_id = Ecto.UUID.generate()

      assert {:error, :not_found} =
               perform_job(MovieSearch, %{"mode" => "specific", "media_item_id" => fake_id})
    end

    test "returns error when media item is not a movie" do
      tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      assert {:error, :invalid_type} =
               perform_job(MovieSearch, %{
                 "mode" => "specific",
                 "media_item_id" => tv_show.id
               })
    end

    test "processes a valid movie", %{bypass: _bypass} do
      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})

      # Now uses mocked indexer responses
      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id
        })

      # Should succeed with mocked results
      assert result == :ok
    end

    test "uses custom ranking options when provided", %{bypass: _bypass} do
      movie = media_item_fixture(%{type: "movie", title: "Inception", year: 2010})

      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id,
          "min_seeders" => 10,
          "blocked_tags" => ["CAM", "TS"],
          "preferred_tags" => ["REMUX"]
        })

      # Should succeed with mocked results
      assert result == :ok
    end
  end

  describe "perform/1 - all_monitored mode" do
    test "returns ok when no movies need searching" do
      # Create a movie that's not monitored
      _unmonitored_movie = media_item_fixture(%{monitored: false})

      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "skips movies that already have files", %{library_path: library_path} do
      # Create a monitored movie
      movie = media_item_fixture(%{type: "movie", monitored: true})

      # Create a media file for this movie
      {:ok, _media_file} =
        Library.create_media_file(%{
          media_item_id: movie.id,
          path: "/fake/path/movie.mkv",
          relative_path: "movie.mkv",
          library_path_id: library_path.id,
          size: 1_000_000_000,
          quality: %{resolution: "1080p"}
        })

      # The job should complete successfully but not search this movie
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "processes monitored movies without files", %{bypass: _bypass} do
      # Create monitored movies without files
      _movie1 =
        media_item_fixture(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      _movie2 =
        media_item_fixture(%{
          type: "movie",
          title: "Inception",
          year: 2010,
          monitored: true
        })

      # The job should search for these movies using mocked indexer
      result = perform_job(MovieSearch, %{"mode" => "all_monitored"})
      assert result == :ok
    end

    test "skips TV shows in all_monitored mode", %{bypass: _bypass} do
      # Create a monitored TV show
      _tv_show =
        media_item_fixture(%{
          type: "tv_show",
          title: "Breaking Bad",
          monitored: true
        })

      # Also create a monitored movie
      _movie =
        media_item_fixture(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          monitored: true
        })

      # Should only process the movie, not the TV show
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end

    test "continues processing after individual movie failures", %{bypass: _bypass} do
      # Create multiple monitored movies
      _movie1 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie One",
          year: 2020,
          monitored: true
        })

      _movie2 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie Two",
          year: 2021,
          monitored: true
        })

      _movie3 =
        media_item_fixture(%{
          type: "movie",
          title: "Movie Three",
          year: 2022,
          monitored: true
        })

      # Job should process all movies with mocked indexer
      assert :ok = perform_job(MovieSearch, %{"mode" => "all_monitored"})
    end
  end

  describe "load_monitored_movies_without_files/0" do
    test "skips movies with an active download" do
      queued = media_item_fixture(%{type: "movie", title: "Already Queued", monitored: true})
      _ = download_fixture(%{media_item_id: queued.id, title: "Already.Queued.2024.1080p"})

      needs_search = media_item_fixture(%{type: "movie", title: "Needs Search", monitored: true})

      ids = Enum.map(MovieSearch.load_monitored_movies_without_files(), & &1.id)

      refute queued.id in ids
      assert needs_search.id in ids
    end

    test "still selects a movie when its prior download failed" do
      movie = media_item_fixture(%{type: "movie", title: "Failed Once", monitored: true})

      download = download_fixture(%{media_item_id: movie.id, title: "Failed.Once.2024.1080p"})

      {:ok, _} =
        download
        |> Ecto.Changeset.change(error_message: "client reported failure")
        |> Repo.update()

      ids = Enum.map(MovieSearch.load_monitored_movies_without_files(), & &1.id)

      assert movie.id in ids
    end

    test "still selects a movie when its prior download completed" do
      # Edge case: completed_at set but no media_file yet. Search may run again;
      # the queue layer will dedup if appropriate. We mirror queue.ex semantics:
      # only `completed_at IS NULL AND error_message IS NULL` counts as in-flight.
      movie = media_item_fixture(%{type: "movie", title: "Completed", monitored: true})

      download = download_fixture(%{media_item_id: movie.id, title: "Completed.2024.1080p"})

      {:ok, _} =
        download
        |> Ecto.Changeset.change(completed_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()

      ids = Enum.map(MovieSearch.load_monitored_movies_without_files(), & &1.id)

      assert movie.id in ids
    end
  end

  describe "search query construction" do
    test "includes year when available", %{bypass: _bypass} do
      movie = media_item_fixture(%{title: "The Matrix", year: 1999})

      # Job runs with mocked indexer responses
      result =
        perform_job(MovieSearch, %{
          "mode" => "specific",
          "media_item_id" => movie.id
        })

      assert result == :ok
    end
  end

  describe "release blacklist (#123)" do
    test "filters out blacklisted releases before ranking", %{bypass: bypass} do
      # The default `setup` block mocks Prowlarr with a fixed result set —
      # override it here so the only result has a known guid we can blacklist.
      IndexerMock.mock_prowlarr_all(bypass,
        results: [
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            seeders: 100,
            guid: "blacklisted-matrix-guid"
          })
        ]
      )

      # Blacklist that guid before the search runs.
      {:ok, _} =
        Mydia.Downloads.Blacklists.add(
          "Test Indexer",
          "blacklisted-matrix-guid",
          "The Matrix.1999",
          "par2_failed"
        )

      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})

      assert :ok =
               perform_job(MovieSearch, %{
                 "mode" => "specific",
                 "media_item_id" => movie.id
               })

      # No download was initiated for the blacklisted release.
      assert Mydia.Downloads.list_downloads() == []
    end
  end

  describe "default quality profile fallback" do
    test "an unstamped movie ranks with the configured default profile", %{bypass: bypass} do
      default =
        quality_profile_fixture(%{
          name: "Default-1080p",
          quality_standards: %{preferred_resolutions: ["1080p"]}
        })

      {:ok, _} = Settings.set_default_quality_profile(default.id)

      # The 720p release has 50x the seeders. A bare seeders sort picks it;
      # the default profile's preferred resolution picks the 1080p one.
      IndexerMock.mock_prowlarr_all(bypass,
        results: [
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            quality: "720p",
            seeders: 500
          }),
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            quality: "1080p",
            seeders: 10
          })
        ]
      )

      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      assert movie.quality_profile_id == nil

      assert :ok =
               perform_job(MovieSearch, %{
                 "mode" => "specific",
                 "media_item_id" => movie.id
               })

      assert [download] = Mydia.Downloads.list_downloads()
      assert download.title =~ "1080p"
    end

    test "the real seeded \"Any\" default does not grab the lowest resolution", %{bypass: bypass} do
      # Every other test here hand-builds a one-entry preferred_resolutions list,
      # where the ranker's index-first sort happens to give the right answer.
      # The actually seeded default is multi-resolution and stored ascending, so
      # this resolves through it end to end instead.
      Repo.delete_all(Mydia.Settings.QualityProfile)
      assert {:ok, _created} = Settings.ensure_default_quality_profiles()

      default = Settings.get_default_quality_profile()
      assert default.name == "Any"
      assert length(default.quality_standards.preferred_resolutions) > 1

      # Seeders run counter to resolution, so a bare seeders sort picks the 480p
      # and stored-ascending index-first sorting picks it too.
      IndexerMock.mock_prowlarr_all(bypass,
        results: [
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            quality: "480p",
            seeders: 900
          }),
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            quality: "720p",
            seeders: 500
          }),
          IndexerMock.movie_result(%{
            title: "The Matrix",
            year: 1999,
            quality: "1080p",
            seeders: 10
          })
        ]
      )

      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      assert movie.quality_profile_id == nil

      assert :ok =
               perform_job(MovieSearch, %{
                 "mode" => "specific",
                 "media_item_id" => movie.id
               })

      assert [download] = Mydia.Downloads.list_downloads()
      assert download.title =~ "1080p"
      refute download.title =~ "480p"
    end
  end

  describe "Args.parse/1 upgrade mode" do
    test "parses upgrade mode with a target file" do
      args =
        MovieSearch.Args.parse(%{
          "mode" => "upgrade",
          "media_item_id" => "item-uuid",
          "media_file_id" => "file-uuid"
        })

      assert args.mode == "upgrade"
      assert args.media_item_id == "item-uuid"
      assert args.media_file_id == "file-uuid"
    end
  end

  describe "perform/1 - upgrade mode" do
    defp upgrade_target(library_path, opts \\ []) do
      profile_attrs =
        Keyword.get(opts, :profile, %{
          name: "Upgrade profile #{System.unique_integer([:positive])}",
          quality_standards: %{preferred_resolutions: ["1080p", "720p"]},
          min_upgrade_margin: 0
        })

      profile = quality_profile_fixture(profile_attrs)

      movie =
        media_item_fixture(%{
          type: "movie",
          title: "The Matrix",
          year: 1999,
          quality_profile_id: profile.id
        })

      file_attrs =
        Keyword.get(opts, :file_attrs, %{})
        |> Enum.into(%{
          media_item_id: movie.id,
          path: "/test/library/matrix.mkv",
          relative_path: "matrix.mkv",
          library_path_id: library_path.id,
          size: 2_000_000_000,
          resolution: "720p",
          codec: "H.264 (High)",
          analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, media_file} = Library.create_media_file(file_attrs)

      {movie, media_file}
    end

    test "returns {:ok, :skipped} when the media item no longer exists" do
      fake_media_item_id = Ecto.UUID.generate()
      fake_media_file_id = Ecto.UUID.generate()

      assert {:ok, :skipped} =
               perform_job(MovieSearch, %{
                 "mode" => "upgrade",
                 "media_item_id" => fake_media_item_id,
                 "media_file_id" => fake_media_file_id
               })

      assert Mydia.Downloads.list_downloads() == []
    end

    test "returns {:ok, :skipped} when the target media file no longer exists" do
      movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
      fake_media_file_id = Ecto.UUID.generate()

      assert {:ok, :skipped} =
               perform_job(MovieSearch, %{
                 "mode" => "upgrade",
                 "media_item_id" => movie.id,
                 "media_file_id" => fake_media_file_id
               })

      assert Mydia.Downloads.list_downloads() == []
    end

    test "returns {:ok, :skipped} when the target media file has been trashed", %{
      library_path: library_path
    } do
      {movie, media_file} =
        upgrade_target(library_path,
          file_attrs: %{trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)}
        )

      assert {:ok, :skipped} =
               perform_job(MovieSearch, %{
                 "mode" => "upgrade",
                 "media_item_id" => movie.id,
                 "media_file_id" => media_file.id
               })

      assert Mydia.Downloads.list_downloads() == []
    end

    test "grabs a genuine upgrade candidate and tags the download with its target file", %{
      library_path: library_path
    } do
      {movie, media_file} = upgrade_target(library_path)

      assert :ok =
               perform_job(MovieSearch, %{
                 "mode" => "upgrade",
                 "media_item_id" => movie.id,
                 "media_file_id" => media_file.id
               })

      assert [download] = Mydia.Downloads.list_downloads()
      assert download.title =~ "1080p"
      assert download.metadata["upgrade_target_media_file_id"] == media_file.id
      assert download.media_item_id == movie.id
    end

    # Proves the Comparator genuinely gates the grab rather than merely being
    # called for show: same movie, same file, same mocked indexer results as
    # the "grabs a genuine upgrade candidate" test above (proven there to
    # produce a grab) — the *only* difference is min_upgrade_margin raised to
    # a value no real score delta could ever clear. If the filter were
    # removed (or merely a no-op), this would grab exactly like the sibling
    # test does; instead nothing is grabbed and the miss is recorded as a
    # search-backoff failure like the other modes' "no results" paths.
    test "does not grab a candidate that fails the Comparator's margin, even though ReleaseRanker would otherwise pick it",
         %{library_path: library_path} do
      {movie, media_file} =
        upgrade_target(library_path,
          profile: %{
            name: "Unreachable margin",
            quality_standards: %{preferred_resolutions: ["1080p", "720p"]},
            # 100 is the maximum a QualityProfile changeset allows, and a
            # single-dimension (resolution-only) improvement never scores a
            # full 0->100 swing across every weighted quality dimension, so
            # this margin is unreachable without changing anything else about
            # the fixture — see the module doc comment above this test.
            min_upgrade_margin: 100
          }
        )

      assert :ok =
               perform_job(MovieSearch, %{
                 "mode" => "upgrade",
                 "media_item_id" => movie.id,
                 "media_file_id" => media_file.id
               })

      assert Mydia.Downloads.list_downloads() == []

      # Upgrade-mode backoff lives in its own "movie_upgrade" bucket, not the
      # "movie" bucket the missing-file search paths use (see task-7 review
      # finding 1 / Mydia.Upgrades.eligible_movies/1) - a stale "movie"
      # backoff from before this movie had a file must never suppress an
      # upgrade search for it, and vice versa.
      assert Search.get_backoff("movie", movie.id) == nil
      backoff = Search.get_backoff("movie_upgrade", movie.id)
      assert backoff.failure_count == 1
    end
  end
end
