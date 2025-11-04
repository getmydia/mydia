defmodule Mydia.SettingsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile

  describe "ensure_default_quality_profiles/0" do
    test "creates default quality profiles when none exist" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Call the function
      assert {:ok, count} = Settings.ensure_default_quality_profiles()
      assert count == 6

      # Verify all profiles were created
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 6

      # Verify specific profiles exist with expected properties
      profile_names = Enum.map(profiles, & &1.name) |> MapSet.new()
      expected_names = MapSet.new(["Any", "SD", "HD-720p", "HD-1080p", "Full HD", "4K/UHD"])
      assert profile_names == expected_names
    end

    test "is idempotent - does not create duplicates" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # First call creates profiles
      assert {:ok, 6} = Settings.ensure_default_quality_profiles()

      # Second call should not create any new profiles
      assert {:ok, 0} = Settings.ensure_default_quality_profiles()

      # Should still have exactly 6 profiles
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 6
    end

    test "only creates missing profiles when some already exist" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Manually create one of the default profiles
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Any",
          qualities: ["360p", "480p", "720p", "1080p"]
        })

      # Call the function - should create 5 more profiles
      assert {:ok, 5} = Settings.ensure_default_quality_profiles()

      # Verify we now have 6 profiles
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 6
    end

    test "profiles have correct structure and required fields" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Create default profiles
      {:ok, _count} = Settings.ensure_default_quality_profiles()

      # Check the "Any" profile
      any_profile = Settings.get_quality_profile_by_name("Any")
      assert any_profile.name == "Any"
      assert is_list(any_profile.qualities)
      assert length(any_profile.qualities) > 0
      assert is_boolean(any_profile.upgrades_allowed)
      assert is_map(any_profile.rules)
      assert Map.has_key?(any_profile.rules, "description")

      # Check the "HD-1080p" profile
      hd_profile = Settings.get_quality_profile_by_name("HD-1080p")
      assert hd_profile.name == "HD-1080p"
      assert "1080p" in hd_profile.qualities
      assert is_map(hd_profile.rules)
      assert Map.has_key?(hd_profile.rules, "max_size_mb")
      assert Map.has_key?(hd_profile.rules, "preferred_sources")

      # Check the "4K/UHD" profile
      uhd_profile = Settings.get_quality_profile_by_name("4K/UHD")
      assert uhd_profile.name == "4K/UHD"
      assert "2160p" in uhd_profile.qualities
      assert is_map(uhd_profile.rules)
    end

    test "profiles have size constraints in rules" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Create default profiles
      {:ok, _count} = Settings.ensure_default_quality_profiles()

      # Check SD profile has max size
      sd_profile = Settings.get_quality_profile_by_name("SD")
      assert sd_profile.rules["max_size_mb"] == 2048

      # Check HD-720p profile has size range
      hd720_profile = Settings.get_quality_profile_by_name("HD-720p")
      assert hd720_profile.rules["min_size_mb"] == 1024
      assert hd720_profile.rules["max_size_mb"] == 5120

      # Check 4K/UHD profile has size constraints
      uhd_profile = Settings.get_quality_profile_by_name("4K/UHD")
      assert uhd_profile.rules["min_size_mb"] == 15360
      assert uhd_profile.rules["max_size_mb"] == 81920
    end

    test "Any profile allows upgrades, others do not" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Create default profiles
      {:ok, _count} = Settings.ensure_default_quality_profiles()

      # Any and SD allow upgrades
      any_profile = Settings.get_quality_profile_by_name("Any")
      assert any_profile.upgrades_allowed == true
      assert any_profile.upgrade_until_quality == "2160p"

      sd_profile = Settings.get_quality_profile_by_name("SD")
      assert sd_profile.upgrades_allowed == true
      assert sd_profile.upgrade_until_quality == "576p"

      # Others don't allow upgrades
      hd_profile = Settings.get_quality_profile_by_name("HD-1080p")
      assert hd_profile.upgrades_allowed == false

      uhd_profile = Settings.get_quality_profile_by_name("4K/UHD")
      assert uhd_profile.upgrades_allowed == false
    end
  end

  describe "default_quality_profiles module" do
    test "returns list of profile definitions" do
      profiles = Settings.DefaultQualityProfiles.defaults()

      assert is_list(profiles)
      assert length(profiles) == 6

      # Each profile should have required keys
      Enum.each(profiles, fn profile ->
        assert Map.has_key?(profile, :name)
        assert Map.has_key?(profile, :qualities)
        assert Map.has_key?(profile, :upgrades_allowed)
        assert Map.has_key?(profile, :rules)
        assert is_list(profile.qualities)
        assert is_boolean(profile.upgrades_allowed)
        assert is_map(profile.rules)
      end)
    end

    test "profile names are unique" do
      profiles = Settings.DefaultQualityProfiles.defaults()
      names = Enum.map(profiles, & &1.name)

      # Check for uniqueness
      assert length(names) == length(Enum.uniq(names))
    end

    test "all profiles have valid qualities arrays" do
      profiles = Settings.DefaultQualityProfiles.defaults()

      Enum.each(profiles, fn profile ->
        assert is_list(profile.qualities)
        assert length(profile.qualities) > 0

        # All quality strings should be valid resolutions
        valid_resolutions = ["360p", "480p", "576p", "720p", "1080p", "2160p"]

        Enum.each(profile.qualities, fn quality ->
          assert quality in valid_resolutions,
                 "Invalid quality #{quality} in profile #{profile.name}"
        end)
      end)
    end
  end

  describe "runtime library paths" do
    setup do
      # Set up runtime config with library paths
      runtime_config = %Mydia.Config.Schema{
        media: %{
          movies_path: "/media/movies",
          tv_path: "/media/tv"
        }
      }

      Application.put_env(:mydia, :runtime_config, runtime_config)

      on_exit(fn ->
        Application.delete_env(:mydia, :runtime_config)
      end)

      :ok
    end

    test "get_runtime_library_paths returns paths with runtime IDs" do
      paths = Settings.get_runtime_library_paths()

      assert length(paths) == 2

      movies_path = Enum.find(paths, &(&1.type == :movies))
      assert movies_path.id == "runtime::library_path::/media/movies"
      assert movies_path.path == "/media/movies"

      tv_path = Enum.find(paths, &(&1.type == :series))
      assert tv_path.id == "runtime::library_path::/media/tv"
      assert tv_path.path == "/media/tv"
    end

    test "get_library_path! can retrieve runtime library paths by runtime ID" do
      runtime_id = "runtime::library_path::/media/movies"
      library_path = Settings.get_library_path!(runtime_id)

      assert library_path.id == runtime_id
      assert library_path.path == "/media/movies"
      assert library_path.type == :movies
    end

    test "get_library_path! raises for non-existent runtime library path" do
      runtime_id = "runtime::library_path::/nonexistent"

      assert_raise RuntimeError, "Runtime library path not found: /nonexistent", fn ->
        Settings.get_library_path!(runtime_id)
      end
    end

    test "list_library_paths merges database and runtime paths" do
      # Create a database library path
      {:ok, db_path} =
        Settings.create_library_path(%{
          path: "/db/path",
          type: :movies,
          monitored: true
        })

      # List should include both database and runtime paths
      all_paths = Settings.list_library_paths()

      # Should have at least 3 paths (1 DB + 2 runtime)
      assert length(all_paths) >= 3

      # Database path should be included
      assert Enum.any?(all_paths, &(&1.id == db_path.id))

      # Runtime paths should be included
      assert Enum.any?(all_paths, &(&1.id == "runtime::library_path::/media/movies"))
      assert Enum.any?(all_paths, &(&1.id == "runtime::library_path::/media/tv"))
    end
  end

  describe "runtime download clients" do
    setup do
      # Set up runtime config with download clients
      runtime_config = %Mydia.Config.Schema{
        download_clients: [
          %{
            name: "qbittorrent",
            type: :qbittorrent,
            enabled: true,
            priority: 10,
            host: "localhost",
            port: 8080
          }
        ]
      }

      Application.put_env(:mydia, :runtime_config, runtime_config)

      on_exit(fn ->
        Application.delete_env(:mydia, :runtime_config)
      end)

      :ok
    end

    test "get_runtime_download_clients returns clients with runtime IDs" do
      clients = Settings.get_runtime_download_clients()

      assert length(clients) == 1

      client = List.first(clients)
      assert client.id == "runtime::download_client::qbittorrent"
      assert client.name == "qbittorrent"
      assert client.type == :qbittorrent
    end

    test "get_download_client_config! can retrieve runtime clients by runtime ID" do
      runtime_id = "runtime::download_client::qbittorrent"
      client = Settings.get_download_client_config!(runtime_id)

      assert client.id == runtime_id
      assert client.name == "qbittorrent"
      assert client.type == :qbittorrent
    end

    test "get_download_client_config! raises for non-existent runtime client" do
      runtime_id = "runtime::download_client::nonexistent"

      assert_raise RuntimeError, "Runtime download client not found: nonexistent", fn ->
        Settings.get_download_client_config!(runtime_id)
      end
    end
  end

  describe "runtime indexers" do
    setup do
      # Set up runtime config with indexers
      runtime_config = %Mydia.Config.Schema{
        indexers: [
          %{
            name: "prowlarr",
            type: :prowlarr,
            enabled: true,
            priority: 10,
            base_url: "http://localhost:9696",
            api_key: "test-key"
          }
        ]
      }

      Application.put_env(:mydia, :runtime_config, runtime_config)

      on_exit(fn ->
        Application.delete_env(:mydia, :runtime_config)
      end)

      :ok
    end

    test "get_runtime_indexers returns indexers with runtime IDs" do
      indexers = Settings.get_runtime_indexers()

      assert length(indexers) == 1

      indexer = List.first(indexers)
      assert indexer.id == "runtime::indexer::prowlarr"
      assert indexer.name == "prowlarr"
      assert indexer.type == :prowlarr
    end

    test "get_indexer_config! can retrieve runtime indexers by runtime ID" do
      runtime_id = "runtime::indexer::prowlarr"
      indexer = Settings.get_indexer_config!(runtime_id)

      assert indexer.id == runtime_id
      assert indexer.name == "prowlarr"
      assert indexer.type == :prowlarr
    end

    test "get_indexer_config! raises for non-existent runtime indexer" do
      runtime_id = "runtime::indexer::nonexistent"

      assert_raise RuntimeError, "Runtime indexer not found: nonexistent", fn ->
        Settings.get_indexer_config!(runtime_id)
      end
    end
  end

  describe "get_*! with string database IDs" do
    test "get_library_path! works with string integer IDs" do
      # Create a database library path
      {:ok, db_path} =
        Settings.create_library_path(%{
          path: "/test/path",
          type: :movies,
          monitored: true
        })

      # Should be able to retrieve with string ID
      library_path = Settings.get_library_path!(to_string(db_path.id))

      assert library_path.id == db_path.id
      assert library_path.path == "/test/path"
    end

    test "get_download_client_config! works with string integer IDs" do
      # Create a database download client config
      {:ok, db_client} =
        Settings.create_download_client_config(%{
          name: "test-client",
          type: :qbittorrent,
          enabled: true,
          priority: 10,
          host: "localhost",
          port: 8080
        })

      # Should be able to retrieve with string ID
      client = Settings.get_download_client_config!(to_string(db_client.id))

      assert client.id == db_client.id
      assert client.name == "test-client"
    end

    test "get_indexer_config! works with string integer IDs" do
      # Create a database indexer config
      {:ok, db_indexer} =
        Settings.create_indexer_config(%{
          name: "test-indexer",
          type: :prowlarr,
          enabled: true,
          priority: 10,
          base_url: "http://localhost:9696",
          api_key: "test-key"
        })

      # Should be able to retrieve with string ID
      indexer = Settings.get_indexer_config!(to_string(db_indexer.id))

      assert indexer.id == db_indexer.id
      assert indexer.name == "test-indexer"
    end
  end
end
