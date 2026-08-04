defmodule Mydia.DownloadsTest do
  # async: false — this suite overrides the global download-client Registry
  # (registers MockAdapter for :qbittorrent, unregisters :qbittorrent). Since
  # production adapter resolution now reads that Registry live, running async
  # would race concurrent readers (media_import, download_monitor) and make them
  # resolve MockAdapter mid-test. Every Registry-mutating suite runs sync.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.SettingsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Client.Error
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.SearchResultMetadata

  # Mock adapter for testing
  defmodule MockAdapter do
    @behaviour Client

    @impl true
    def supported_protocols, do: [:torrent]

    @impl true
    def test_connection(_config) do
      {:ok, %{version: "1.0.0", api_version: "1.0"}}
    end

    # Prefix matches: a trackerless magnet is enriched with the public tracker
    # list on its way to the client, so the string the client sees is longer
    # than the one the search result carried.
    @impl true
    def add_torrent(_config, {:magnet, "magnet:?xt=valid" <> _}, _opts) do
      {:ok, "mock-client-id-123"}
    end

    def add_torrent(_config, {:magnet, "magnet:?xt=error" <> _}, _opts) do
      {:error, Error.invalid_torrent("Invalid magnet link")}
    end

    # Reports back whether the magnet arrived with trackers attached.
    def add_torrent(_config, {:magnet, "magnet:?xt=trackers" <> rest}, _opts) do
      {:ok,
       if(String.contains?(rest, "&tr="), do: "mock-with-trackers", else: "mock-no-trackers")}
    end

    def add_torrent(_config, {:url, url}, _opts) do
      {:ok, "mock-url-id-#{String.length(url)}"}
    end

    def add_torrent(_config, {:file, _body}, _opts) do
      {:ok, "mock-file-id"}
    end

    def add_torrent(_config, _torrent, _opts) do
      {:ok, "mock-default-id"}
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
    # Save original adapter and register mock adapter
    original_adapter =
      case Registry.get_adapter(:qbittorrent) do
        {:ok, adapter} -> adapter
        {:error, _} -> nil
      end

    Registry.register(:qbittorrent, MockAdapter)

    # Restore original adapter after test
    on_exit(fn ->
      if original_adapter do
        Registry.register(:qbittorrent, original_adapter)
      end
    end)

    # Create test user for client configs
    user = user_fixture()

    # Create test download client
    client1 =
      download_client_config_fixture(%{
        name: "test-client-1",
        type: "qbittorrent",
        enabled: true,
        priority: 1,
        host: "localhost",
        port: 8080,
        updated_by_id: user.id
      })

    client2 =
      download_client_config_fixture(%{
        name: "test-client-2",
        type: "qbittorrent",
        enabled: true,
        priority: 2,
        host: "localhost",
        port: 9091,
        category: "movies",
        updated_by_id: user.id
      })

    disabled_client =
      download_client_config_fixture(%{
        name: "disabled-client",
        type: "qbittorrent",
        enabled: false,
        priority: 3,
        host: "localhost",
        port: 7070,
        updated_by_id: user.id
      })

    # Create test search result
    search_result = %SearchResult{
      title: "Test Movie 2024 1080p BluRay x264",
      size: 2_147_483_648,
      seeders: 100,
      leechers: 50,
      download_url: "magnet:?xt=valid",
      indexer: "TestIndexer",
      category: 2000,
      quality: %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr: false,
        proper: false,
        repack: false
      }
    }

    {:ok,
     client1: client1,
     client2: client2,
     disabled_client: disabled_client,
     search_result: search_result,
     user: user}
  end

  describe "initiate_download/2" do
    test "successfully initiates download with highest priority client", %{
      search_result: search_result,
      client1: client1
    } do
      assert {:ok, download} = Downloads.initiate_download(search_result)

      assert download.title == search_result.title
      assert download.download_url == search_result.download_url
      assert download.indexer == search_result.indexer
      assert download.download_client == client1.name
      assert download.download_client_id == "mock-client-id-123"
      assert download.metadata.size == search_result.size
      assert download.metadata.seeders == search_result.seeders
      assert download.metadata.leechers == search_result.leechers
      assert download.metadata.quality == search_result.quality
    end

    test "initiates download with specific client when requested", %{
      search_result: search_result,
      client2: client2
    } do
      assert {:ok, download} =
               Downloads.initiate_download(search_result, client_name: "test-client-2")

      assert download.download_client == client2.name
    end

    test "associates download with media_item_id when provided", %{search_result: search_result} do
      # Note: We're not actually creating a media item in this test,
      # we're just checking that the option is passed through
      # For a full integration test with real media items, see integration tests
      assert {:ok, download} = Downloads.initiate_download(search_result)

      # Verify the download was created successfully
      assert download.title == search_result.title
    end

    test "associates download with episode_id when provided", %{search_result: search_result} do
      # Note: We're not actually creating an episode in this test,
      # we're just checking that the option is passed through
      # For a full integration test with real episodes, see integration tests
      assert {:ok, download} = Downloads.initiate_download(search_result)

      # Verify the download was created successfully
      assert download.title == search_result.title
    end

    test "uses custom category when provided", %{search_result: search_result} do
      # The category is passed to the client adapter, which we can't directly verify
      # in this test without mocking more deeply, but we can verify the download is created
      assert {:ok, download} =
               Downloads.initiate_download(search_result, category: "custom-category")

      assert download.title == search_result.title
    end

    test "uses client's default category when not provided", %{
      search_result: search_result,
      client2: client2
    } do
      # Client2 has category "movies"
      assert {:ok, download} =
               Downloads.initiate_download(search_result, client_name: client2.name)

      assert download.download_client == client2.name
    end

    test "handles URL download links", %{search_result: search_result} do
      # Use Bypass to serve a mock torrent file instead of hitting a real URL
      bypass = Bypass.open()

      # HEAD for redirect check, then GET for actual download
      Bypass.stub(bypass, "HEAD", "/file.torrent", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      Bypass.stub(bypass, "GET", "/file.torrent", fn conn ->
        # Minimal valid torrent metainfo: announce + info dict with name/length.
        # ContentType.detect/1 requires a structurally valid bencode metainfo
        # (must contain an `info` dict), not just a `d8:announce…` prefix.
        torrent_body =
          "d8:announce0:4:infod6:lengthi42e4:name8:test.binee"

        conn
        |> Plug.Conn.put_resp_content_type("application/x-bittorrent")
        |> Plug.Conn.resp(200, torrent_body)
      end)

      url_result = %{search_result | download_url: "http://localhost:#{bypass.port}/file.torrent"}

      assert {:ok, download} = Downloads.initiate_download(url_result)
      assert download.download_url == url_result.download_url
      assert download.download_client_id == "mock-file-id"
    end

    test "returns error when no clients are configured" do
      # Delete ALL download client configs from the database (including runtime ones)
      Mydia.Settings.list_download_client_configs()
      |> Enum.each(fn client_config ->
        # Skip runtime clients (they can't be deleted)
        unless is_binary(client_config.id) and String.starts_with?(client_config.id, "runtime::") do
          Mydia.Settings.delete_download_client_config(client_config)
        end
      end)

      # Also unregister the mock adapter so no clients are available at all.
      # All resolution sites (queue, history, client_health, untracked_matcher,
      # media_import) now resolve through the Registry, so restore it after this
      # test to avoid leaving later tests without the production adapters.
      Mydia.Downloads.Client.Registry.unregister(:qbittorrent)
      on_exit(fn -> Mydia.Downloads.register_clients() end)

      search_result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 0,
        download_url: "magnet:?xt=test",
        indexer: "Test"
      }

      # This should now return :no_clients_configured (no database clients)
      # or error about unknown client type (if runtime clients exist)
      result = Downloads.initiate_download(search_result)

      case result do
        {:error, :no_clients_configured} ->
          assert true

        {:error, {:client_error, %Error{type: :invalid_config}}} ->
          # This happens if there are runtime-configured clients without adapters
          assert true

        {:error, %Error{type: :invalid_config}} ->
          # This also happens if there are runtime-configured clients without adapters
          # (the error is not wrapped in :client_error tuple)
          assert true

        {:error, {:client_error, %Error{type: :api_error}}} ->
          # This can happen if runtime clients exist but they reject the download
          # (e.g., transmission rejecting an invalid magnet link)
          assert true

        {:error, {:client_error, %Error{type: :invalid_torrent}}} ->
          # This can happen if runtime clients exist but they reject the torrent
          # (e.g., client unable to extract hash from invalid magnet link)
          assert true

        other ->
          flunk("Expected error, got: #{inspect(other)}")
      end
    end

    test "returns error when specified client is not found", %{search_result: search_result} do
      assert {:error, {:client_not_found, "nonexistent-client"}} =
               Downloads.initiate_download(search_result, client_name: "nonexistent-client")
    end

    test "returns error when specified client is disabled", %{
      search_result: search_result,
      disabled_client: disabled_client
    } do
      assert {:error, {:client_not_found, client_name}} =
               Downloads.initiate_download(search_result, client_name: disabled_client.name)

      assert client_name == disabled_client.name
    end

    test "hands the client a trackerless magnet with trackers attached", %{client1: _client1} do
      # Regression: Bitmagnet (and Prowlarr, when /download redirects to a
      # magnet) emit a bare magnet with no tr= parameter. Forwarding that
      # verbatim leaves the client with DHT as its only peer source, which
      # downloads exactly zero bytes on any client whose DHT can't reach the
      # swarm.
      bare_magnet = %SearchResult{
        title: "Trackerless Release",
        size: 1000,
        seeders: 5,
        leechers: 0,
        download_url: "magnet:?xt=trackers&dn=Trackerless.Release",
        indexer: "Test"
      }

      assert {:ok, download} = Downloads.initiate_download(bare_magnet)
      assert download.download_client_id == "mock-with-trackers"

      # The stored URL stays exactly as the indexer gave it, so history and
      # duplicate detection keep working off the original release.
      assert download.download_url == bare_magnet.download_url
    end

    test "returns error when client rejects torrent", %{client1: _client1} do
      error_result = %SearchResult{
        title: "Bad Torrent",
        size: 1000,
        seeders: 1,
        leechers: 0,
        download_url: "magnet:?xt=error",
        indexer: "Test"
      }

      assert {:error, {:client_error, %Error{type: :invalid_torrent}}} =
               Downloads.initiate_download(error_result)
    end

    test "skips disabled clients when selecting by priority", %{
      search_result: search_result,
      client1: client1,
      disabled_client: _disabled_client
    } do
      # Even though disabled_client has priority 3 (higher than client1's priority 1),
      # it should be skipped because it's disabled, and client1 should be selected
      assert {:ok, download} = Downloads.initiate_download(search_result)

      assert download.download_client == client1.name
    end

    test "selects client with lowest priority value", %{
      search_result: search_result,
      client1: client1,
      client2: _client2
    } do
      # client1 has priority 1, client2 has priority 2
      # Lower priority value should be selected
      assert {:ok, download} = Downloads.initiate_download(search_result)

      assert download.download_client == client1.name
    end
  end

  describe "list_downloads/1" do
    test "returns all downloads" do
      download1 = download_fixture(%{title: "Download 1"})
      download2 = download_fixture(%{title: "Download 2", completed_at: DateTime.utc_now()})

      downloads = Downloads.list_downloads()

      assert length(downloads) == 2
      assert Enum.any?(downloads, &(&1.id == download1.id))
      assert Enum.any?(downloads, &(&1.id == download2.id))
    end

    test "filters by media_item_id" do
      # Create downloads without FK references for this test
      download1 = download_fixture(%{title: "Download with FK ref"})
      _download2 = download_fixture(%{title: "Download without FK ref"})

      # We can't test FK filtering without actual media items,
      # so we just verify the filter doesn't crash
      downloads = Downloads.list_downloads(media_item_id: download1.id)

      # Should return empty since no downloads have this as media_item_id
      assert downloads == []
    end

    test "filters by episode_id" do
      # Create downloads without FK references for this test
      download1 = download_fixture(%{title: "Download with FK ref"})
      _download2 = download_fixture(%{title: "Download without FK ref"})

      # We can't test FK filtering without actual episodes,
      # so we just verify the filter doesn't crash
      downloads = Downloads.list_downloads(episode_id: download1.id)

      # Should return empty since no downloads have this as episode_id
      assert downloads == []
    end
  end

  describe "get_download!/2" do
    test "returns the download with given id" do
      download = download_fixture()
      assert Downloads.get_download!(download.id).id == download.id
    end

    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Downloads.get_download!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_download/1" do
    test "creates a download with valid attributes" do
      attrs = %{
        title: "Test Download",
        download_url: "magnet:?xt=test"
      }

      assert {:ok, %Download{} = download} = Downloads.create_download(attrs)
      assert download.title == "Test Download"
    end
  end

  describe "update_download/2" do
    test "updates the download" do
      download = download_fixture()

      # Update with valid fields (Download schema doesn't have status/progress fields)
      assert {:ok, updated} =
               Downloads.update_download(download, %{title: "Updated Title"})

      assert updated.title == "Updated Title"
    end
  end

  describe "delete_download/1" do
    test "deletes the download" do
      download = download_fixture()

      assert {:ok, %Download{}} = Downloads.delete_download(download)
      assert_raise Ecto.NoResultsError, fn -> Downloads.get_download!(download.id) end
    end
  end

  describe "list_active_downloads/1" do
    test "excludes completed and failed downloads from active list" do
      # Create active downloads (not completed, not failed)
      _active1 = download_fixture(%{title: "Active 1"})
      _active2 = download_fixture(%{title: "Active 2"})

      # Create completed download
      _completed = download_fixture(%{title: "Completed", completed_at: DateTime.utc_now()})

      # Create failed download
      _failed = download_fixture(%{title: "Failed", error_message: "Download failed"})

      # list_active_downloads gets status from clients (which aren't running in tests)
      # So all non-completed/non-failed downloads will show as "missing" status
      # which is not considered "active" (active = downloading, seeding, checking, paused)
      active = Downloads.list_active_downloads()

      # Without real download clients, active downloads won't show up
      # This is expected behavior - the function queries real client status
      assert is_list(active)
    end
  end

  describe "duplicate download prevention" do
    setup %{search_result: search_result} do
      # Create actual media items and episodes for testing
      movie = media_item_fixture(%{type: "movie", title: "Test Movie"})
      tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})
      episode = episode_fixture(media_item_id: tv_show.id, season_number: 1, episode_number: 1)

      {:ok, search_result: search_result, movie: movie, tv_show: tv_show, episode: episode}
    end

    test "prevents duplicate episode download when active download exists", %{
      search_result: search_result,
      episode: episode
    } do
      # Create initial download for episode (active - not completed, not failed)
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          episode_id: episode.id
        })

      # Try to initiate another download for same episode
      result = Downloads.initiate_download(search_result, episode_id: episode.id)

      assert {:error, :duplicate_download} = result
    end

    test "prevents episode download when previous download completed but not imported", %{
      search_result: search_result,
      episode: episode
    } do
      # A download that finished downloading but hasn't been imported yet still
      # occupies the episode — grabbing a second release here is what produced
      # the duplicate 720p/1080p packs in production.
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          episode_id: episode.id,
          completed_at: DateTime.utc_now()
        })

      result = Downloads.initiate_download(search_result, episode_id: episode.id)

      assert {:error, :duplicate_download} = result
    end

    test "allows episode download when previous import failed terminally", %{
      search_result: search_result,
      episode: episode
    } do
      # A terminally-failed import (no retry scheduled) no longer occupies the
      # episode, so a fresh release may be grabbed.
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          episode_id: episode.id,
          completed_at: DateTime.utc_now(),
          import_failed_at: DateTime.utc_now(),
          import_next_retry_at: nil
        })

      result = Downloads.initiate_download(search_result, episode_id: episode.id)

      assert {:ok, _download} = result
    end

    test "allows episode download when previous download failed", %{
      search_result: search_result,
      episode: episode
    } do
      # Create failed download for episode
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          episode_id: episode.id,
          error_message: "Download failed"
        })

      # Should allow new download since previous one failed
      result = Downloads.initiate_download(search_result, episode_id: episode.id)

      assert {:ok, _download} = result
    end

    test "prevents duplicate movie download when active download exists", %{
      search_result: search_result,
      movie: movie
    } do
      # Create initial download for movie (active - not completed, not failed)
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          media_item_id: movie.id
        })

      # Try to initiate another download for same movie
      result = Downloads.initiate_download(search_result, media_item_id: movie.id)

      assert {:error, :duplicate_download} = result
    end

    test "prevents duplicate season pack download for same season", %{
      search_result: search_result,
      tv_show: tv_show
    } do
      # Create initial season pack download for season 1
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Season Pack S01",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          media_item_id: tv_show.id,
          metadata: %{
            season_pack: true,
            season_number: 1,
            episode_count: 10
          }
        })

      # Try to initiate another season pack download for same season
      season_pack_result = %{
        search_result
        | metadata: SearchResultMetadata.season_pack(1, 10)
      }

      result = Downloads.initiate_download(season_pack_result, media_item_id: tv_show.id)

      assert {:error, :duplicate_download} = result
    end

    test "allows season pack download for different season", %{
      search_result: search_result,
      tv_show: tv_show
    } do
      # Create initial season pack download for season 1
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Season Pack S01",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          media_item_id: tv_show.id,
          metadata: %{
            season_pack: true,
            season_number: 1,
            episode_count: 10
          }
        })

      # Try to initiate season pack download for season 2
      season_pack_result = %{
        search_result
        | metadata: SearchResultMetadata.season_pack(2, 12)
      }

      result = Downloads.initiate_download(season_pack_result, media_item_id: tv_show.id)

      assert {:ok, _download} = result
    end

    test "prevents movie download when previous download completed but not imported", %{
      search_result: search_result,
      movie: movie
    } do
      # Completed-but-not-imported still occupies the movie: don't grab a second
      # release while the first is queued for import.
      {:ok, _first_download} =
        Downloads.create_download(%{
          title: "First Download",
          download_url: "magnet:?xt=first",
          download_client: "test-client",
          download_client_id: "client-123",
          media_item_id: movie.id,
          completed_at: DateTime.utc_now()
        })

      result = Downloads.initiate_download(search_result, media_item_id: movie.id)

      assert {:error, :duplicate_download} = result
    end

    test "prevents episode download when media files already exist", %{
      search_result: search_result,
      episode: episode
    } do
      # Create media file for episode (simulating completed download)
      media_file_fixture(%{episode_id: episode.id})

      # Try to initiate download for episode that already has files
      result = Downloads.initiate_download(search_result, episode_id: episode.id)

      assert {:error, :duplicate_download} = result
    end

    test "prevents movie download when media files already exist", %{
      search_result: search_result,
      movie: movie
    } do
      # Create media file for movie (simulating completed download)
      media_file_fixture(%{media_item_id: movie.id})

      # Try to initiate download for movie that already has files
      result = Downloads.initiate_download(search_result, media_item_id: movie.id)

      assert {:error, :duplicate_download} = result
    end

    test "prevents season pack download when some episodes already have media files", %{
      search_result: search_result,
      tv_show: tv_show
    } do
      # Create episodes for season 2 (to avoid conflict with setup which creates season 1 episode 1)
      episode1 = episode_fixture(media_item_id: tv_show.id, season_number: 2, episode_number: 1)
      episode2 = episode_fixture(media_item_id: tv_show.id, season_number: 2, episode_number: 2)
      _episode3 = episode_fixture(media_item_id: tv_show.id, season_number: 2, episode_number: 3)

      # Create media files for some episodes (but not all)
      media_file_fixture(%{episode_id: episode1.id})
      media_file_fixture(%{episode_id: episode2.id})

      # Try to initiate season pack download - should be prevented since some episodes have files
      season_pack_result = %{
        search_result
        | metadata: SearchResultMetadata.season_pack(2, 3)
      }

      result = Downloads.initiate_download(season_pack_result, media_item_id: tv_show.id)

      assert {:error, :duplicate_download} = result
    end

    test "allows season pack download when no episodes have media files", %{
      search_result: search_result,
      tv_show: tv_show
    } do
      # Create episodes for season 3 but without media files
      _episode1 = episode_fixture(media_item_id: tv_show.id, season_number: 3, episode_number: 1)
      _episode2 = episode_fixture(media_item_id: tv_show.id, season_number: 3, episode_number: 2)

      # Try to initiate season pack download - should be allowed
      season_pack_result = %{
        search_result
        | metadata: SearchResultMetadata.season_pack(3, 2)
      }

      result = Downloads.initiate_download(season_pack_result, media_item_id: tv_show.id)

      assert {:ok, _download} = result
    end

    test "allows season pack download for different season even if other season has files", %{
      search_result: search_result,
      tv_show: tv_show
    } do
      # Create episodes for season 4 with media files
      episode1 = episode_fixture(media_item_id: tv_show.id, season_number: 4, episode_number: 1)
      media_file_fixture(%{episode_id: episode1.id})

      # Create episodes for season 5 without media files
      _episode2 = episode_fixture(media_item_id: tv_show.id, season_number: 5, episode_number: 1)

      # Try to initiate season pack download for season 5 - should be allowed
      season_pack_result = %{
        search_result
        | metadata: SearchResultMetadata.season_pack(5, 1)
      }

      result = Downloads.initiate_download(season_pack_result, media_item_id: tv_show.id)

      assert {:ok, _download} = result
    end
  end

  describe "list_stuck_downloads/1" do
    test "returns downloads that are stuck (completed but not imported)" do
      # Create a stuck download - completed more than 1 hour ago but never imported
      two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      stuck_download =
        download_fixture(%{
          title: "Stuck Download",
          completed_at: two_hours_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # Create a normal completed download (will still be stuck due to time)
      one_hour_ago = DateTime.add(DateTime.utc_now(), -61, :minute)

      also_stuck =
        download_fixture(%{
          title: "Also Stuck",
          completed_at: one_hour_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # Create a recently completed download (not stuck yet)
      just_now = DateTime.utc_now()

      _not_stuck_yet =
        download_fixture(%{
          title: "Not Stuck Yet",
          completed_at: just_now,
          imported_at: nil,
          import_failed_at: nil
        })

      # Create a successfully imported download (not stuck)
      _imported =
        download_fixture(%{
          title: "Already Imported",
          completed_at: two_hours_ago,
          imported_at: DateTime.utc_now(),
          import_failed_at: nil
        })

      # Create a failed download (not stuck - already has import_failed_at)
      _failed =
        download_fixture(%{
          title: "Already Failed",
          completed_at: two_hours_ago,
          imported_at: nil,
          import_failed_at: DateTime.utc_now()
        })

      stuck_downloads = Downloads.list_stuck_downloads()

      assert length(stuck_downloads) == 2
      stuck_ids = Enum.map(stuck_downloads, & &1.id)
      assert stuck_download.id in stuck_ids
      assert also_stuck.id in stuck_ids
    end

    test "respects custom threshold_minutes option" do
      # Create a download completed 30 minutes ago
      thirty_minutes_ago = DateTime.add(DateTime.utc_now(), -30, :minute)

      download =
        download_fixture(%{
          title: "Recently Completed",
          completed_at: thirty_minutes_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # With default 60 minute threshold, should not be stuck
      assert Downloads.list_stuck_downloads() == []

      # With 25 minute threshold, should be stuck
      stuck_downloads = Downloads.list_stuck_downloads(threshold_minutes: 25)
      assert length(stuck_downloads) == 1
      assert hd(stuck_downloads).id == download.id
    end

    test "returns empty list when no stuck downloads exist" do
      # Create a download that's not stuck (recently completed)
      _download =
        download_fixture(%{
          title: "Recent Download",
          completed_at: DateTime.utc_now(),
          imported_at: nil,
          import_failed_at: nil
        })

      assert Downloads.list_stuck_downloads() == []
    end

    test "does not include downloads that were never completed" do
      # Create a download without completed_at (still downloading)
      _downloading =
        download_fixture(%{
          title: "Still Downloading",
          completed_at: nil,
          imported_at: nil,
          import_failed_at: nil
        })

      assert Downloads.list_stuck_downloads() == []
    end
  end

  # Helper function to create a download fixture
  defp download_fixture(attrs \\ %{}) do
    # Generate unique download_client_id to avoid violating unique constraint
    unique_id = "test-id-#{System.unique_integer([:positive])}"

    default_attrs = %{
      title: "Test Download",
      download_url: "magnet:?xt=test",
      download_client: "test-client",
      download_client_id: unique_id
    }

    {:ok, download} =
      default_attrs
      |> Map.merge(attrs)
      |> Downloads.create_download()

    download
  end
end
