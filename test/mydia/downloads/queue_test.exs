defmodule Mydia.Downloads.QueueTest do
  @moduledoc """
  Unit tests for `Mydia.Downloads.Queue`'s per-content-type category routing
  and 5-tier priority pass-through. The end-to-end `initiate_download/2`
  pipeline is covered by integration tests elsewhere; this module focuses on
  the two helpers (`resolve_content_type/1` + `resolve_category/3`) because
  they are the unit-of-change for U3 (#124 + #129).
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads.Queue
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Repo
  alias Mydia.Settings.DownloadClientConfig

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  describe "resolve_content_type/1" do
    test "episode_id present -> tv" do
      assert Queue.resolve_content_type(episode_id: "any-uuid") == "tv"
    end

    test "episode_id wins over media_item_id (TV show with explicit episode)" do
      movie = media_item_fixture(%{type: "movie"})
      assert Queue.resolve_content_type(episode_id: "ep-id", media_item_id: movie.id) == "tv"
    end

    test "media_item_id pointing at a movie -> movie" do
      movie = media_item_fixture(%{type: "movie"})
      assert Queue.resolve_content_type(media_item_id: movie.id) == "movie"
    end

    test "media_item_id pointing at a tv_show -> tv" do
      tv = media_item_fixture(%{type: "tv_show"})
      assert Queue.resolve_content_type(media_item_id: tv.id) == "tv"
    end

    test "no episode_id and no media_item_id -> nil" do
      assert Queue.resolve_content_type([]) == nil
      assert Queue.resolve_content_type(download_type: :torrent) == nil
    end

    test "media_item_id pointing at a deleted/unknown record falls back to nil" do
      # Provide a UUID that doesn't exist in the DB
      assert Queue.resolve_content_type(media_item_id: Ecto.UUID.generate()) == nil
    end
  end

  describe "resolve_category/3 — happy path (categories map populated)" do
    test "movie content type picks up the per-type category" do
      client =
        %DownloadClientConfig{
          categories: %{"movie" => "movies", "tv" => "shows"},
          category: nil
        }

      assert Queue.resolve_category(client, "movie", []) == "movies"
    end

    test "tv content type picks up the per-type category" do
      client =
        %DownloadClientConfig{
          categories: %{"movie" => "movies", "tv" => "shows"},
          category: nil
        }

      assert Queue.resolve_category(client, "tv", []) == "shows"
    end
  end

  describe "resolve_category/3 — backwards compatibility (legacy field)" do
    test "empty categories map falls back to the legacy :category field for movies" do
      client = %DownloadClientConfig{categories: %{}, category: "all"}
      assert Queue.resolve_category(client, "movie", []) == "all"
    end

    test "empty categories map falls back to the legacy :category field for tv" do
      client = %DownloadClientConfig{categories: %{}, category: "all"}
      assert Queue.resolve_category(client, "tv", []) == "all"
    end

    test "nil categories map falls back to the legacy :category field" do
      client = %DownloadClientConfig{categories: nil, category: "all"}
      assert Queue.resolve_category(client, "movie", []) == "all"
    end

    test "missing key for the requested content type falls back to the legacy field" do
      client =
        %DownloadClientConfig{
          categories: %{"movie" => "movies"},
          category: "legacy"
        }

      # No "tv" key — fall through to legacy
      assert Queue.resolve_category(client, "tv", []) == "legacy"
    end

    test "empty string value for the requested content type falls back to the legacy field" do
      client =
        %DownloadClientConfig{
          categories: %{"movie" => ""},
          category: "legacy"
        }

      assert Queue.resolve_category(client, "movie", []) == "legacy"
    end

    test "content_type is nil -> use legacy :category field" do
      client = %DownloadClientConfig{categories: %{"movie" => "movies"}, category: "legacy"}
      assert Queue.resolve_category(client, nil, []) == "legacy"
    end

    test "no content_type, no categories, no legacy field -> nil" do
      client = %DownloadClientConfig{categories: %{}, category: nil}
      assert Queue.resolve_category(client, nil, []) == nil
    end
  end

  describe "resolve_category/3 — explicit override" do
    test "opts[:category] takes precedence over categories map" do
      client =
        %DownloadClientConfig{
          categories: %{"movie" => "movies"},
          category: "legacy"
        }

      assert Queue.resolve_category(client, "movie", category: "manual-override") ==
               "manual-override"
    end

    test "opts[:category] nil is still considered an explicit override" do
      # The current contract is that *any* presence of :category in opts wins,
      # even nil. This matches Keyword.has_key? semantics. Documented here so
      # future refactors don't break it accidentally.
      client = %DownloadClientConfig{categories: %{"movie" => "movies"}, category: "legacy"}
      assert Queue.resolve_category(client, "movie", category: nil) == nil
    end
  end

  describe "supports_download_type?/2" do
    # Regression: dispatch used to hardcode the torrent_clients list and
    # left :debrid out, so a debrid-only setup logged
    # "No download clients configured" for every torrent search result.
    # See queue.ex supports_download_type?/2.

    setup do
      # Registry.clear/0 is called by registry_test.exs's setup. When that
      # file runs before this one (test order isn't deterministic across
      # processes), the Registry is empty and Queue.supports_download_type?
      # falls through to `{:error, _} -> false`. Re-register the adapters
      # this describe block exercises so the tests are insulated.
      alias Mydia.Downloads.Client.Registry
      Registry.register(:qbittorrent, Mydia.Downloads.Client.QBittorrent)
      Registry.register(:sabnzbd, Mydia.Downloads.Client.Sabnzbd)
      Registry.register(:debrid, Mydia.Downloads.Client.Debrid)
      :ok
    end

    test "debrid client is eligible for :torrent" do
      client = %DownloadClientConfig{type: :debrid, enabled: true}
      assert Queue.supports_download_type?(client, :torrent)
    end

    test "qbittorrent is eligible for :torrent but not :nzb" do
      client = %DownloadClientConfig{type: :qbittorrent, enabled: true}
      assert Queue.supports_download_type?(client, :torrent)
      refute Queue.supports_download_type?(client, :nzb)
    end

    test "sabnzbd is eligible for :nzb but not :torrent" do
      client = %DownloadClientConfig{type: :sabnzbd, enabled: true}
      assert Queue.supports_download_type?(client, :nzb)
      refute Queue.supports_download_type?(client, :torrent)
    end

    test "unknown download_type lets every adapter through (sniff failed)" do
      client = %DownloadClientConfig{type: :qbittorrent, enabled: true}
      assert Queue.supports_download_type?(client, nil)
    end

    test "every Client-behaviour adapter declares supported_protocols/0" do
      # Guards against the original bug class: if someone adds a new adapter
      # but forgets to declare protocols, the queue would never select it
      # for any priority-based dispatch.
      #
      # We only enforce the contract on modules that implement the
      # Mydia.Downloads.Client behaviour, guarding against any future
      # non-adapter module being registered.
      for {type, adapter} <- Mydia.Downloads.Client.Registry.list_adapters(),
          implements_client_behaviour?(adapter) do
        assert function_exported?(adapter, :supported_protocols, 0),
               "#{inspect(adapter)} (registered as #{inspect(type)}) must implement supported_protocols/0"

        protocols = adapter.supported_protocols()

        assert is_list(protocols) and protocols != [],
               "#{inspect(adapter)}.supported_protocols/0 must return a non-empty list"

        assert Enum.all?(protocols, &(&1 in [:torrent, :nzb])),
               "#{inspect(adapter)}.supported_protocols/0 returned #{inspect(protocols)} — only :torrent and :nzb are valid"
      end
    end

    defp implements_client_behaviour?(module) do
      behaviours =
        :attributes
        |> module.module_info()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      Mydia.Downloads.Client in behaviours
    rescue
      _ -> false
    end
  end

  describe "check_for_active_download/3 — cross-season duplicate blocking" do
    # Regression for the production bug where starting a Season 3 download for a
    # show reported `:duplicate_download` because an unrelated, still-active
    # Season 2 download existed. A TV show legitimately has many concurrent
    # downloads across seasons/episodes, so an active download for the show must
    # not, by itself, make a *different* request a duplicate. This mirrors the
    # tv_show carve-out already present in check_for_existing_media_files/3.
    #
    # download_fixture/1 uses download_client: "test-client", which has no
    # registered client config, so verify_single_download_in_client/1 treats it
    # as :active (assume-active-on-unknown-client). That makes these fixtures a
    # faithful stand-in for a genuinely in-progress download.

    alias Mydia.Indexers.SearchResult
    alias Mydia.Indexers.Structs.SearchResultMetadata

    defp search_result(metadata) do
      %SearchResult{
        download_url: "magnet:?xt=urn:btih:req-#{System.unique_integer([:positive])}",
        title: "Requested Release",
        indexer: "test",
        size: 1_000_000_000,
        seeders: 10,
        leechers: 5,
        metadata: metadata
      }
    end

    defp active_download(media_item_id, attrs) do
      download_fixture(Map.merge(%{media_item_id: media_item_id}, attrs))
    end

    test "an active unscoped TV download does NOT block another unscoped request for the same show" do
      show = media_item_fixture(%{type: "tv_show", title: "The Boys"})

      active_download(show.id, %{title: "The Boys Season 2 S02 1080p", metadata: %{}})

      # Mirrors the season-download UI path before it tagged season metadata:
      # episode_id nil, no season_pack metadata.
      assert Queue.check_for_active_download(search_result(nil), show.id, nil) == :ok
    end

    test "an active unscoped TV download DOES block re-submitting the same release URL" do
      show = media_item_fixture(%{type: "tv_show", title: "The Boys"})
      url = "magnet:?xt=urn:btih:same-release-#{System.unique_integer([:positive])}"

      active_download(show.id, %{title: "The Boys S03 1080p", download_url: url, metadata: %{}})

      # Same release double-clicked: episode_id nil, no season metadata, but the
      # exact download_url already has an active download.
      result = %SearchResult{
        download_url: url,
        title: "The Boys S03 1080p",
        indexer: "test",
        size: 1_000_000_000,
        seeders: 10,
        leechers: 5,
        metadata: nil
      }

      assert Queue.check_for_active_download(result, show.id, nil) ==
               {:error, :duplicate_download}
    end

    test "an active S02 season-pack download does NOT block an S03 season-pack request" do
      show = media_item_fixture(%{type: "tv_show", title: "The Boys"})

      active_download(show.id, %{
        title: "The Boys S02 COMPLETE 1080p",
        metadata: %{season_pack: true, season_number: 2}
      })

      result = search_result(%SearchResultMetadata{season_pack: true, season_number: 3})

      assert Queue.check_for_active_download(result, show.id, nil) == :ok
    end

    test "an active S03 season-pack download DOES block a duplicate S03 season-pack request" do
      show = media_item_fixture(%{type: "tv_show", title: "The Boys"})

      active_download(show.id, %{
        title: "The Boys S03 COMPLETE 1080p",
        metadata: %{season_pack: true, season_number: 3}
      })

      result = search_result(%SearchResultMetadata{season_pack: true, season_number: 3})

      assert Queue.check_for_active_download(result, show.id, nil) ==
               {:error, :duplicate_download}
    end

    test "an active download for one episode does NOT block a different episode" do
      show = media_item_fixture(%{type: "tv_show"})
      ep_a = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 1})
      ep_b = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 2})

      active_download(show.id, %{title: "S03E01", episode_id: ep_a.id})

      assert Queue.check_for_active_download(search_result(nil), show.id, ep_b.id) == :ok
    end

    test "an active download for an episode DOES block a duplicate request for the same episode" do
      show = media_item_fixture(%{type: "tv_show"})
      ep = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 1})

      active_download(show.id, %{title: "S03E01", episode_id: ep.id})

      assert Queue.check_for_active_download(search_result(nil), show.id, ep.id) ==
               {:error, :duplicate_download}
    end

    test "an active movie download DOES block another request for the same movie" do
      movie = media_item_fixture(%{type: "movie"})

      active_download(movie.id, %{title: "The Movie 1080p", metadata: %{}})

      assert Queue.check_for_active_download(search_result(nil), movie.id, nil) ==
               {:error, :duplicate_download}
    end

    test "a completed-but-not-imported download DOES block a new request (still awaiting import)" do
      # The download finished but hasn't been imported yet — it still occupies
      # the movie, so grabbing a second release here is the duplicate bug we fixed.
      movie = media_item_fixture(%{type: "movie"})

      active_download(movie.id, %{
        title: "The Movie 1080p",
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      assert Queue.check_for_active_download(search_result(nil), movie.id, nil) ==
               {:error, :duplicate_download}
    end

    test "an imported download does NOT block a new request" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      movie = media_item_fixture(%{type: "movie"})

      active_download(movie.id, %{
        title: "The Movie 1080p",
        completed_at: now,
        imported_at: now
      })

      assert Queue.check_for_active_download(search_result(nil), movie.id, nil) == :ok
    end

    test "a terminally-failed import does NOT block a new request" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      movie = media_item_fixture(%{type: "movie"})

      active_download(movie.id, %{
        title: "The Movie 1080p",
        completed_at: now,
        import_failed_at: now,
        import_next_retry_at: nil
      })

      assert Queue.check_for_active_download(search_result(nil), movie.id, nil) == :ok
    end
  end

  # Adapter that records the opts passed to remove_torrent/3 so we can prove the
  # delete_files flag reaches the client. The existing MockAdapter in
  # downloads_test.exs discards opts, so we need our own capturing stub here.
  defmodule CaptureAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:ok, %{version: "1.0.0", api_version: "1.0"}}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:ok, "capture-id"}
    @impl true
    def get_status(_config, _client_id), do: {:ok, %{}}
    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok

    @impl true
    def remove_torrent(_config, client_id, opts) do
      if pid = Application.get_env(:mydia, :queue_capture_pid) do
        send(pid, {:remove_torrent_called, client_id, opts})
      end

      :ok
    end
  end

  describe "clear_completed/2 + clear_all_completed/1 delete_files plumbing" do
    setup do
      original =
        case Registry.get_adapter(:qbittorrent) do
          {:ok, adapter} -> adapter
          {:error, _} -> nil
        end

      Registry.register(:qbittorrent, CaptureAdapter)
      Application.put_env(:mydia, :queue_capture_pid, self())

      on_exit(fn ->
        Application.delete_env(:mydia, :queue_capture_pid)
        if original, do: Registry.register(:qbittorrent, original)
      end)

      config =
        download_client_config_fixture(%{
          name: "capture-client",
          type: "qbittorrent",
          enabled: true
        })

      %{config: config}
    end

    defp imported_download(config) do
      download_fixture(%{
        download_client: config.name,
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    end

    test "clear_completed/2 with delete_files: true sets the delete flag on the adapter", %{
      config: config
    } do
      download = imported_download(config)

      assert {:ok, _} = Queue.clear_completed(download, delete_files: true)

      assert_received {:remove_torrent_called, _client_id, opts}
      assert Keyword.get(opts, :delete_files) == true
    end

    test "clear_completed/2 without delete_files does not set the delete flag", %{config: config} do
      download = imported_download(config)

      assert {:ok, _} = Queue.clear_completed(download)

      assert_received {:remove_torrent_called, _client_id, opts}
      refute Keyword.get(opts, :delete_files) == true
    end

    test "clear_completed/2 deletes the DB record even when delete_files is true", %{
      config: config
    } do
      download = imported_download(config)

      assert {:ok, _} = Queue.clear_completed(download, delete_files: true)
      assert Repo.get(Download, download.id) == nil
    end

    test "clear_all_completed/1 forwards delete_files to each imported download", %{
      config: config
    } do
      _d1 = imported_download(config)
      _d2 = imported_download(config)

      assert {:ok, 2} = Queue.clear_all_completed(delete_files: true)

      assert_received {:remove_torrent_called, _id1, opts1}
      assert_received {:remove_torrent_called, _id2, opts2}
      assert Keyword.get(opts1, :delete_files) == true
      assert Keyword.get(opts2, :delete_files) == true
    end

    test "clear_all_completed/1 only targets imported downloads", %{config: config} do
      imported = imported_download(config)
      active = download_fixture(%{download_client: config.name})

      assert {:ok, 1} = Queue.clear_all_completed(delete_files: true)

      assert Repo.get(Download, imported.id) == nil
      assert Repo.get(Download, active.id) != nil
    end
  end

  describe "rematch_imported_download/3" do
    setup do
      library = library_path_fixture(%{type: "movies", monitored: true})
      movie = media_item_fixture(%{type: "movie", title: "Right Movie"})

      download =
        download_fixture(%{
          media_item_id: movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      _media_file =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: library.id,
          metadata: %{"imported_from_download_id" => download.id}
        })

      %{library: library, movie: movie, download: download}
    end

    test "rejects a download that is not imported yet", %{movie: movie} do
      download = download_fixture(%{media_item_id: movie.id, imported_at: nil})
      assert {:error, :not_imported} = Queue.rematch_imported_download(download, movie.id)
    end

    test "rejects a partial-pack / unresolved download", %{movie: movie} do
      download =
        download_fixture(%{
          media_item_id: movie.id,
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
          match_status: "partial_pack"
        })

      assert {:error, :not_single_target} = Queue.rematch_imported_download(download, movie.id)
    end

    test "no-ops when the target is unchanged", %{download: download, movie: movie} do
      assert {:ok, :unchanged} = Queue.rematch_imported_download(download, movie.id)
      refute_enqueued(worker: Mydia.Jobs.MediaRematch)
    end

    test "refuses a pack (provenance resolves to multiple files)", %{
      library: library,
      download: download
    } do
      other_movie = media_item_fixture(%{type: "movie", title: "Other"})

      # A second imported file under the same download id makes this a pack.
      media_file_fixture(%{
        media_item_id: download.media_item_id,
        library_path_id: library.id,
        metadata: %{"imported_from_download_id" => download.id}
      })

      assert {:error, :multiple_files} =
               Queue.rematch_imported_download(download, other_movie.id)

      refute_enqueued(worker: Mydia.Jobs.MediaRematch)
    end

    test "errors when no compatible destination library exists", %{download: download} do
      # Re-match the movie download to a TV episode while only a :movies library
      # is monitored — there is no series destination, so it is rejected pre-move.
      episode = episode_fixture(%{season_number: 1, episode_number: 3})
      show_id = episode.media_item_id

      assert {:error, :no_library_path} =
               Queue.rematch_imported_download(download, show_id, episode.id)

      refute_enqueued(worker: Mydia.Jobs.MediaRematch)
    end

    test "enqueues a re-match job and persists the new target", %{download: download} do
      new_movie = media_item_fixture(%{type: "movie", title: "Corrected Movie"})

      assert {:ok, :enqueued} = Queue.rematch_imported_download(download, new_movie.id)
      assert_enqueued(worker: Mydia.Jobs.MediaRematch, args: %{"download_id" => download.id})

      reloaded = Repo.get(Download, download.id)
      assert reloaded.media_item_id == new_movie.id
    end
  end

  describe "build_download_metadata/1" do
    test "builds the metadata map with indexer and guid" do
      search_result = %Mydia.Indexers.SearchResult{
        title: "Some.Movie.2020.1080p",
        indexer: "test-indexer",
        download_url: "magnet:?xt=urn:btih:" <> String.duplicate("a", 40),
        size: 1_000,
        seeders: 5,
        leechers: 1,
        quality: "1080p"
      }

      metadata = Queue.build_download_metadata(search_result)

      assert metadata[:indexer] == "test-indexer"
      assert is_binary(metadata[:guid])
      assert metadata[:size] == 1_000
    end
  end

  describe "check_for_active_download/4 with :exclude_download_id" do
    test "excludes the given download from the duplicate query" do
      movie = media_item_fixture(%{type: "movie"})

      # An occupying download for this movie. Its download_client is not a
      # configured client, so client verification treats it as :active.
      existing = download_fixture(media_item_id: movie.id)

      search_result = %Mydia.Indexers.SearchResult{
        title: "Some.Movie.2020.1080p",
        indexer: "test-indexer",
        download_url: "magnet:?xt=urn:btih:" <> String.duplicate("b", 40),
        size: 0,
        seeders: 0,
        leechers: 0
      }

      assert {:error, :duplicate_download} =
               Queue.check_for_active_download(search_result, movie.id, nil)

      assert :ok =
               Queue.check_for_active_download(search_result, movie.id, nil,
                 exclude_download_id: existing.id
               )
    end
  end

  describe "reject_release/2 failure_reason" do
    test "defaults to rejected_by_user" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          indexer: "1337x",
          metadata: %{"indexer" => "1337x", "guid" => "guid-default"}
        })

      assert {:ok, :rejected} = Queue.reject_release(download)

      row = Repo.get_by(ReleaseBlacklist, indexer: "1337x", guid: "guid-default")
      assert row.failure_reason == "rejected_by_user"
    end

    test "records the caller's reason when given" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          indexer: "1337x",
          metadata: %{"indexer" => "1337x", "guid" => "guid-custom"}
        })

      assert {:ok, :rejected} =
               Queue.reject_release(download,
                 actor_type: :system,
                 actor_id: "download_monitor",
                 failure_reason: "no_importable_files"
               )

      row = Repo.get_by(ReleaseBlacklist, indexer: "1337x", guid: "guid-custom")
      assert row.failure_reason == "no_importable_files"
    end
  end
end
