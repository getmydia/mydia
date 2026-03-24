defmodule Mydia.SettingsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.{QualityProfile, DefaultMetadataPreferences}

  describe "ensure_default_quality_profiles/0" do
    test "creates default quality profiles when none exist" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Call the function
      assert {:ok, count} = Settings.ensure_default_quality_profiles()
      assert count == 8

      # Verify all profiles were created
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 8

      # Verify specific profiles exist with expected properties
      profile_names = Enum.map(profiles, & &1.name) |> MapSet.new()

      expected_names =
        MapSet.new([
          "Any",
          "SD",
          "HD-720p",
          "HD-1080p",
          "Full HD",
          "4K/UHD",
          "Remux-1080p",
          "Remux-2160p"
        ])

      assert profile_names == expected_names
    end

    test "is idempotent - does not create duplicates" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # First call creates profiles
      assert {:ok, 8} = Settings.ensure_default_quality_profiles()

      # Second call should not create any new profiles
      assert {:ok, 0} = Settings.ensure_default_quality_profiles()

      # Should still have exactly 8 profiles
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 8
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

      # Call the function - should create 7 more profiles
      assert {:ok, 7} = Settings.ensure_default_quality_profiles()

      # Verify we now have 8 profiles
      profiles = Settings.list_quality_profiles()
      assert length(profiles) == 8
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
      assert is_binary(any_profile.description)

      # Check the "HD-1080p" profile
      hd_profile = Settings.get_quality_profile_by_name("HD-1080p")
      assert hd_profile.name == "HD-1080p"
      assert "1080p" in hd_profile.qualities
      assert is_binary(hd_profile.description)

      # Check the "4K/UHD" profile
      uhd_profile = Settings.get_quality_profile_by_name("4K/UHD")
      assert uhd_profile.name == "4K/UHD"
      assert "2160p" in uhd_profile.qualities
      assert is_binary(uhd_profile.description)
    end

    test "profiles have size constraints in quality_standards" do
      # Ensure we start with a clean slate
      Repo.delete_all(QualityProfile)

      # Create default profiles
      {:ok, _count} = Settings.ensure_default_quality_profiles()

      # Check SD profile has max size (converted to quality_standards)
      sd_profile = Settings.get_quality_profile_by_name("SD")
      assert sd_profile.quality_standards[:movie_max_size_mb] == 2048
      assert sd_profile.quality_standards[:episode_max_size_mb] == 1024

      # Check HD-720p profile has size range
      hd720_profile = Settings.get_quality_profile_by_name("HD-720p")
      assert hd720_profile.quality_standards[:movie_min_size_mb] == 1024
      assert hd720_profile.quality_standards[:movie_max_size_mb] == 5120
      assert hd720_profile.quality_standards[:episode_min_size_mb] == 512
      assert hd720_profile.quality_standards[:episode_max_size_mb] == 2560

      # Check 4K/UHD profile has size constraints
      uhd_profile = Settings.get_quality_profile_by_name("4K/UHD")
      assert uhd_profile.quality_standards[:movie_min_size_mb] == 15360
      assert uhd_profile.quality_standards[:movie_max_size_mb] == 81920
      assert uhd_profile.quality_standards[:episode_min_size_mb] == 7680
      assert uhd_profile.quality_standards[:episode_max_size_mb] == 40960
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
      assert length(profiles) == 8

      # Each profile should have required keys
      Enum.each(profiles, fn profile ->
        assert Map.has_key?(profile, :name)
        assert Map.has_key?(profile, :qualities)
        assert Map.has_key?(profile, :upgrades_allowed)
        assert Map.has_key?(profile, :description)
        assert Map.has_key?(profile, :quality_standards)
        assert is_list(profile.qualities)
        assert is_boolean(profile.upgrades_allowed)
        assert is_binary(profile.description)
        assert is_map(profile.quality_standards)
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

      # List should include both database paths and paths synced from runtime
      all_paths = Settings.list_library_paths()

      # Should have at least 3 paths (1 DB + 2 runtime that were synced to DB)
      assert length(all_paths) >= 3

      # Database path should be included
      assert Enum.any?(all_paths, &(&1.id == db_path.id))

      # Runtime paths should be synced to database and included
      # Note: Runtime paths are synced to database on startup, so they have DB IDs
      assert Enum.any?(all_paths, &(&1.path == "/media/movies"))
      assert Enum.any?(all_paths, &(&1.path == "/media/tv"))
    end
  end

  describe "specialized library types" do
    test "can create library path with :music type" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/music_#{System.unique_integer([:positive])}",
          type: :music,
          monitored: true
        })

      assert library_path.type == :music
    end

    test "can create library path with :books type" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/books_#{System.unique_integer([:positive])}",
          type: :books,
          monitored: true
        })

      assert library_path.type == :books
    end

    test "can create library path with :adult type" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/adult_#{System.unique_integer([:positive])}",
          type: :adult,
          monitored: true
        })

      assert library_path.type == :adult
    end

    test "rejects invalid library type" do
      {:error, changeset} =
        Settings.create_library_path(%{
          path: "/media/invalid_#{System.unique_integer([:positive])}",
          type: :invalid_type,
          monitored: true
        })

      assert changeset.errors[:type] != nil
    end

    test "all valid library types are accepted" do
      valid_types = [:movies, :series, :mixed, :music, :books, :adult]

      Enum.each(valid_types, fn type ->
        unique_path = "/media/test_#{type}_#{System.unique_integer([:positive])}"

        {:ok, library_path} =
          Settings.create_library_path(%{
            path: unique_path,
            type: type,
            monitored: true
          })

        assert library_path.type == type
      end)
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

  describe "library path validation on update" do
    setup do
      # Create a library path with a unique test path
      test_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
      test_path = "/media/test_movies_#{test_id}"

      {:ok, library_path} =
        Settings.create_library_path(%{
          path: test_path,
          type: :movies,
          monitored: true
        })

      # Create a media item for file creation (media_item_id is NOT NULL)
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Settings Test Movie #{test_id}",
          year: 2024
        })

      %{library_path: library_path, media_item: media_item}
    end

    test "allows path update when no media files exist", %{library_path: library_path} do
      # Update the path (no files to validate)
      assert {:ok, updated} =
               Settings.update_library_path(library_path, %{path: "/new/media/movies"})

      assert updated.path == "/new/media/movies"
    end

    test "allows path update when all files exist at new location", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create some test files in both old and new locations
      test_files = ["Movie1.mkv", "Movie2.mkv", "Movie3.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
        File.touch!(Path.join(new_path, file))
      end

      # Create media file records with relative paths
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      # Update path should succeed because files exist at new location
      assert {:ok, updated} = Settings.update_library_path(library_path, %{path: new_path})
      assert updated.path == new_path

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end

    test "prevents path update when files don't exist at new location", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create test files only in old location
      test_files = ["Movie1.mkv", "Movie2.mkv", "Movie3.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
      end

      # Create media file records with relative paths
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      # Update path should fail because files don't exist at new location
      assert {:error, changeset} =
               Settings.update_library_path(library_path, %{path: new_path})

      assert changeset.errors[:path] != nil

      {message, _} = changeset.errors[:path]

      assert message =~ "Files not accessible at new location"
      assert message =~ "Checked 3 files, 0 found"

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end

    test "prevents path update when some files missing at new location", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create test files in old location
      test_files = ["Movie1.mkv", "Movie2.mkv", "Movie3.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
      end

      # Only create some files in new location
      File.touch!(Path.join(new_path, "Movie1.mkv"))
      # Movie2.mkv and Movie3.mkv are missing

      # Create media file records with relative paths
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      # Update path should fail because not all files exist at new location
      assert {:error, changeset} =
               Settings.update_library_path(library_path, %{path: new_path})

      assert changeset.errors[:path] != nil

      {message, _} = changeset.errors[:path]

      assert message =~ "Files not accessible at new location"
      assert message =~ "Checked 3 files, 1 found"

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end

    test "allows other field updates without path validation", %{library_path: library_path} do
      # Update monitored status (not the path)
      assert {:ok, updated} =
               Settings.update_library_path(library_path, %{monitored: false})

      assert updated.monitored == false
      assert updated.path == library_path.path
    end

    test "samples up to 10 files for validation", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create 15 test files (more than the sample size)
      test_files = for i <- 1..15, do: "Movie#{i}.mkv"

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
        File.touch!(Path.join(new_path, file))
      end

      # Create media file records for all 15 files
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      # Update path should succeed
      # The validation should only check a sample of 10 files
      assert {:ok, updated} = Settings.update_library_path(library_path, %{path: new_path})
      assert updated.path == new_path

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end
  end

  describe "validate_new_library_path/2" do
    setup do
      # Create a library path with a unique test path
      test_id = :crypto.strong_rand_bytes(8) |> Base.encode16()
      test_path = "/media/test_validate_#{test_id}"

      {:ok, library_path} =
        Settings.create_library_path(%{
          path: test_path,
          type: :movies,
          monitored: true
        })

      # Create a media item for file creation (media_item_id is NOT NULL)
      {:ok, media_item} =
        Mydia.Media.create_media_item(%{
          type: "movie",
          title: "Validate Test Movie #{test_id}",
          year: 2024
        })

      %{library_path: library_path, media_item: media_item}
    end

    test "returns :ok when no media files exist", %{library_path: library_path} do
      assert :ok = Settings.validate_new_library_path(library_path, "/new/path")
    end

    test "returns :ok when all files are accessible", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create test files in both locations
      test_files = ["Movie1.mkv", "Movie2.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
        File.touch!(Path.join(new_path, file))
      end

      # Create media file records
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      assert :ok = Settings.validate_new_library_path(library_path, new_path)

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end

    test "returns error when files are not accessible", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create test files only in old location
      test_files = ["Movie1.mkv", "Movie2.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
      end

      # Create media file records
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      assert {:error, message} = Settings.validate_new_library_path(library_path, new_path)
      assert message =~ "Files not accessible at new location"
      assert message =~ "Checked 2 files, 0 found"

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end

    test "returns error with helpful message when some files are missing", %{
      library_path: library_path,
      media_item: media_item
    } do
      # Create test directory structure
      test_dir = System.tmp_dir!()
      old_path = Path.join(test_dir, "old_movies")
      new_path = Path.join(test_dir, "new_movies")

      File.mkdir_p!(old_path)
      File.mkdir_p!(new_path)

      # Update library path to use test directory
      {:ok, library_path} = Settings.update_library_path(library_path, %{path: old_path})

      # Create test files
      test_files = ["Movie1.mkv", "Movie2.mkv", "Movie3.mkv"]

      for file <- test_files do
        File.touch!(Path.join(old_path, file))
      end

      # Only create one file in new location
      File.touch!(Path.join(new_path, "Movie1.mkv"))

      # Create media file records
      for file <- test_files do
        {:ok, _media_file} =
          %Mydia.Library.MediaFile{}
          |> Mydia.Library.MediaFile.changeset(%{
            library_path_id: library_path.id,
            media_item_id: media_item.id,
            relative_path: file,
            size: 1000
          })
          |> Ecto.Changeset.put_change(:path, Path.join(old_path, file))
          |> Repo.insert()
      end

      assert {:error, message} = Settings.validate_new_library_path(library_path, new_path)
      assert message =~ "Checked 3 files, 1 found"
      assert message =~ "Ensure files have been moved to the new location"

      # Cleanup
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end
  end

  describe "enhanced quality profile operations" do
    setup do
      # Create a test profile with enhanced fields
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test Enhanced Profile",
          qualities: ["1080p", "720p"],
          upgrades_allowed: true,
          upgrade_until_quality: "1080p",
          description: "Test profile with enhanced fields",
          is_system: false,
          version: 1,
          quality_standards: %{
            preferred_video_codecs: ["h264", "h265"],
            preferred_resolutions: ["1080p"],
            movie_min_size_mb: 2048,
            movie_max_size_mb: 15360
          },
          metadata_preferences: %{
            provider_priority: ["tvdb", "tmdb"],
            preferred_language: "en",
            fetch_posters: true
          }
        })

      %{profile: profile}
    end

    test "list_quality_profiles with is_system filter", %{profile: _profile} do
      # List user profiles
      user_profiles = Settings.list_quality_profiles(is_system: false)
      assert length(user_profiles) >= 1
      assert Enum.all?(user_profiles, &(&1.is_system == false))

      # List system profiles (default profiles have is_system: false by default)
      system_profiles = Settings.list_quality_profiles(is_system: true)
      assert Enum.all?(system_profiles, &(&1.is_system == true))
    end

    test "list_quality_profiles with version filter", %{profile: profile} do
      # Create another profile with different version
      {:ok, _profile2} =
        Settings.create_quality_profile(%{
          name: "Version 2 Profile",
          qualities: ["720p"],
          version: 2
        })

      # Filter by version
      v1_profiles = Settings.list_quality_profiles(version: 1)
      assert Enum.any?(v1_profiles, &(&1.id == profile.id))
      assert Enum.all?(v1_profiles, &(&1.version == 1))

      v2_profiles = Settings.list_quality_profiles(version: 2)
      assert length(v2_profiles) >= 1
      assert Enum.all?(v2_profiles, &(&1.version == 2))
    end

    test "list_quality_profiles with source_url filter" do
      # Create profile with source URL
      {:ok, profile_with_url} =
        Settings.create_quality_profile(%{
          name: "Imported Profile",
          qualities: ["1080p"],
          source_url: "https://example.com/profiles/hd.json"
        })

      # Filter by source_url
      imported_profiles =
        Settings.list_quality_profiles(source_url: "https://example.com/profiles/hd.json")

      assert length(imported_profiles) == 1
      assert List.first(imported_profiles).id == profile_with_url.id
    end

    test "clone_quality_profile creates a copy with new name", %{profile: profile} do
      {:ok, cloned} = Settings.clone_quality_profile(profile, "Cloned Profile")

      # Check that it's a different profile
      assert cloned.id != profile.id

      # Check that the name is different
      assert cloned.name == "Cloned Profile"

      # Check that other fields are copied
      assert cloned.qualities == profile.qualities
      assert cloned.upgrades_allowed == profile.upgrades_allowed
      assert cloned.quality_standards == profile.quality_standards
      assert cloned.metadata_preferences == profile.metadata_preferences

      # Check that system fields are reset
      assert cloned.is_system == false
      assert cloned.version == 1
      assert is_nil(cloned.source_url)
      assert is_nil(cloned.customizations)
    end

    test "clone_quality_profile without name adds (Copy) suffix", %{profile: profile} do
      {:ok, cloned} = Settings.clone_quality_profile(profile)

      assert cloned.name == "Test Enhanced Profile (Copy)"
    end

    test "compare_quality_profile_versions detects changes", %{profile: profile1} do
      # Create a modified version
      {:ok, profile2} =
        Settings.create_quality_profile(%{
          name: "Test Enhanced Profile V2",
          qualities: ["2160p", "1080p"],
          upgrades_allowed: false,
          version: 2,
          quality_standards: %{
            preferred_video_codecs: ["h265", "av1"],
            movie_min_size_mb: 5000
          }
        })

      comparison = Settings.compare_quality_profile_versions(profile1, profile2)

      # Check changed fields
      assert Map.has_key?(comparison.changed, :name)
      assert Map.has_key?(comparison.changed, :qualities)
      assert Map.has_key?(comparison.changed, :upgrades_allowed)
      assert Map.has_key?(comparison.changed, :version)
      assert Map.has_key?(comparison.changed, :quality_standards)

      # Verify the actual changes
      {old_name, new_name} = comparison.changed.name
      assert old_name == "Test Enhanced Profile"
      assert new_name == "Test Enhanced Profile V2"

      {old_version, new_version} = comparison.changed.version
      assert old_version == 1
      assert new_version == 2
    end

    test "compare_quality_profile_versions detects added fields", %{profile: profile1} do
      # Create profile without optional fields
      {:ok, profile_basic} =
        Settings.create_quality_profile(%{
          name: "Basic Profile",
          qualities: ["720p"]
        })

      comparison = Settings.compare_quality_profile_versions(profile_basic, profile1)

      # Check added fields
      assert Map.has_key?(comparison.added, :quality_standards)
      assert Map.has_key?(comparison.added, :metadata_preferences)
    end

    test "compare_quality_profile_versions detects removed fields", %{profile: profile1} do
      # Create profile without optional fields
      {:ok, profile_basic} =
        Settings.create_quality_profile(%{
          name: "Basic Profile",
          qualities: ["720p"]
        })

      comparison = Settings.compare_quality_profile_versions(profile1, profile_basic)

      # Check removed fields
      assert Map.has_key?(comparison.removed, :quality_standards)
      assert Map.has_key?(comparison.removed, :metadata_preferences)
    end
  end

  describe "quality_standards validation" do
    test "validates preferred_video_codecs against allowed list" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_video_codecs: ["h264", "h265", "av1"]
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_video_codecs: ["invalid_codec"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates preferred_resolutions against allowed list" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Resolutions",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_resolutions: ["1080p", "720p"]
          }
        })

      # Invalid resolution should fail validation
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Resolutions",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_resolutions: ["8K"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates video bitrate ranges" do
      # Valid bitrate range
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_video_bitrate_mbps: 5.0,
            max_video_bitrate_mbps: 50.0
          }
        })

      # Invalid: min > max
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_video_bitrate_mbps: 50.0,
            max_video_bitrate_mbps: 5.0
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end
  end

  describe "metadata_preferences validation" do
    test "validates provider_priority is a list of valid providers" do
      # Both strings and atoms should be accepted
      {:ok, _profile1} =
        Settings.create_quality_profile(%{
          name: "Valid Provider Priority String",
          qualities: ["1080p"],
          metadata_preferences: %{
            provider_priority: ["metadata_relay", "tvdb", "tmdb"]
          }
        })

      {:ok, _profile2} =
        Settings.create_quality_profile(%{
          name: "Valid Provider Priority Atom",
          qualities: ["1080p"],
          metadata_preferences: %{
            provider_priority: [:metadata_relay, :tvdb]
          }
        })

      # Invalid provider names should be rejected
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Provider Priority",
          qualities: ["1080p"],
          metadata_preferences: %{
            provider_priority: ["invalid_provider"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:metadata_preferences] != nil
    end

    test "validates language codes properly" do
      # Both 2-char and locale codes should be accepted
      {:ok, _profile1} =
        Settings.create_quality_profile(%{
          name: "Valid Language 2char",
          qualities: ["1080p"],
          metadata_preferences: %{
            language: "en"
          }
        })

      {:ok, _profile2} =
        Settings.create_quality_profile(%{
          name: "Valid Language Locale",
          qualities: ["1080p"],
          metadata_preferences: %{
            language: "en-US"
          }
        })

      # Invalid language codes should be rejected
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Language",
          qualities: ["1080p"],
          metadata_preferences: %{
            language: "english"
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:metadata_preferences] != nil
    end

    test "validates boolean preferences" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Booleans",
          qualities: ["1080p"],
          metadata_preferences: %{
            auto_fetch_enabled: true,
            fallback_on_provider_failure: false,
            skip_unavailable_providers: true
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid Booleans",
          qualities: ["1080p"],
          metadata_preferences: %{
            auto_fetch_enabled: "yes"
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:metadata_preferences] != nil
    end
  end

  describe "enhanced quality_standards validation" do
    test "validates preferred_video_codecs" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Video Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264", "av1"]
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid Video Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_video_codecs: ["invalid_codec"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates preferred_audio_codecs" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Audio Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_audio_codecs: ["atmos", "truehd", "dts-hd"]
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid Audio Codecs",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_audio_codecs: ["invalid_audio"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates preferred_audio_channels" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Audio Channels",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_audio_channels: ["7.1", "5.1", "2.0"]
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid Audio Channels",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_audio_channels: ["11.1"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates resolution ranges with min/max" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Resolution Range",
          qualities: ["1080p"],
          quality_standards: %{
            min_resolution: "720p",
            max_resolution: "2160p",
            preferred_resolutions: ["1080p"]
          }
        })

      # Invalid: min > max
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Resolution Range",
          qualities: ["1080p"],
          quality_standards: %{
            min_resolution: "2160p",
            max_resolution: "720p"
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil

      {message, _} = changeset.errors[:quality_standards]
      assert message =~ "min_resolution"
      assert message =~ "cannot be greater than max_resolution"
    end

    test "validates video bitrate ranges with preferred" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Video Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_video_bitrate_mbps: 5.0,
            max_video_bitrate_mbps: 50.0,
            preferred_video_bitrate_mbps: 15.0
          }
        })

      # Invalid: preferred > max
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Video Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_video_bitrate_mbps: 5.0,
            max_video_bitrate_mbps: 50.0,
            preferred_video_bitrate_mbps: 100.0
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates audio bitrate ranges with preferred" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Audio Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_audio_bitrate_kbps: 128,
            max_audio_bitrate_kbps: 768,
            preferred_audio_bitrate_kbps: 320
          }
        })

      # Invalid: preferred < min
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Audio Bitrates",
          qualities: ["1080p"],
          quality_standards: %{
            min_audio_bitrate_kbps: 128,
            max_audio_bitrate_kbps: 768,
            preferred_audio_bitrate_kbps: 64
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates media-type-specific file sizes" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid Media Sizes",
          qualities: ["1080p"],
          quality_standards: %{
            movie_min_size_mb: 2048,
            movie_max_size_mb: 15360,
            episode_min_size_mb: 512,
            episode_max_size_mb: 4096
          }
        })

      # Invalid: movie min > max
      result =
        Settings.create_quality_profile(%{
          name: "Invalid Movie Sizes",
          qualities: ["1080p"],
          quality_standards: %{
            movie_min_size_mb: 15360,
            movie_max_size_mb: 2048
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil

      # Invalid: episode min > max
      result2 =
        Settings.create_quality_profile(%{
          name: "Invalid Episode Sizes",
          qualities: ["1080p"],
          quality_standards: %{
            episode_min_size_mb: 4096,
            episode_max_size_mb: 512
          }
        })

      assert {:error, changeset2} = result2
      assert changeset2.errors[:quality_standards] != nil
    end

    test "validates HDR formats" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid HDR",
          qualities: ["2160p"],
          quality_standards: %{
            hdr_formats: ["dolby_vision", "hdr10+", "hdr10"],
            require_hdr: true
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid HDR",
          qualities: ["2160p"],
          quality_standards: %{
            hdr_formats: ["invalid_hdr"]
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end

    test "validates require_hdr is boolean" do
      {:ok, _profile} =
        Settings.create_quality_profile(%{
          name: "Valid HDR Requirement",
          qualities: ["2160p"],
          quality_standards: %{
            require_hdr: false
          }
        })

      result =
        Settings.create_quality_profile(%{
          name: "Invalid HDR Requirement",
          qualities: ["2160p"],
          quality_standards: %{
            require_hdr: "yes"
          }
        })

      assert {:error, changeset} = result
      assert changeset.errors[:quality_standards] != nil
    end
  end

  describe "quality scoring" do
    setup do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Scoring Test Profile",
          qualities: ["1080p", "2160p"],
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264"],
            preferred_audio_codecs: ["atmos", "truehd", "ac3"],
            preferred_audio_channels: ["7.1", "5.1"],
            min_resolution: "720p",
            max_resolution: "2160p",
            preferred_resolutions: ["1080p"],
            preferred_sources: ["BluRay", "REMUX"],
            min_video_bitrate_mbps: 5.0,
            max_video_bitrate_mbps: 50.0,
            preferred_video_bitrate_mbps: 15.0,
            min_audio_bitrate_kbps: 128,
            max_audio_bitrate_kbps: 768,
            movie_min_size_mb: 2048,
            movie_max_size_mb: 15360,
            episode_min_size_mb: 512,
            episode_max_size_mb: 4096,
            hdr_formats: ["dolby_vision", "hdr10+"],
            require_hdr: false
          }
        })

      %{profile: profile}
    end

    test "scores perfect match as 100", %{profile: profile} do
      media_attrs = %{
        video_codec: "h265",
        audio_codec: "atmos",
        audio_channels: "7.1",
        resolution: "1080p",
        source: "BluRay",
        video_bitrate_mbps: 15.0,
        audio_bitrate_kbps: 320,
        file_size_mb: 8192,
        media_type: :movie,
        hdr_format: "dolby_vision"
      }

      result = QualityProfile.score_media_file(profile, media_attrs)

      assert result.score >= 95.0
      assert result.violations == []
      assert result.breakdown.video_codec == 100.0
      assert result.breakdown.audio_codec == 100.0
      assert result.breakdown.resolution == 100.0
    end

    test "scores second preference lower than first", %{profile: profile} do
      first_pref = %{
        video_codec: "h265",
        resolution: "1080p",
        media_type: :movie
      }

      second_pref = %{
        video_codec: "h264",
        resolution: "1080p",
        media_type: :movie
      }

      result1 = QualityProfile.score_media_file(profile, first_pref)
      result2 = QualityProfile.score_media_file(profile, second_pref)

      assert result1.breakdown.video_codec > result2.breakdown.video_codec
    end

    test "scores within range appropriately", %{profile: profile} do
      within_range = %{
        video_bitrate_mbps: 20.0,
        file_size_mb: 5000,
        media_type: :movie,
        resolution: "1080p"
      }

      result = QualityProfile.score_media_file(profile, within_range)

      assert result.breakdown.video_bitrate >= 75.0
      assert result.breakdown.file_size >= 75.0
    end

    test "penalizes values outside range", %{profile: profile} do
      outside_range = %{
        video_bitrate_mbps: 100.0,
        file_size_mb: 30000,
        media_type: :movie,
        resolution: "1080p"
      }

      result = QualityProfile.score_media_file(profile, outside_range)

      assert result.breakdown.video_bitrate <= 25.0
      assert result.breakdown.file_size <= 25.0
    end

    test "detects resolution violations", %{profile: profile} do
      below_min = %{
        resolution: "480p",
        media_type: :movie
      }

      result = QualityProfile.score_media_file(profile, below_min)

      assert result.score == 0.0
      assert length(result.violations) > 0
      assert Enum.any?(result.violations, &String.contains?(&1, "below minimum"))
    end

    test "detects HDR requirement violations", %{profile: _profile} do
      {:ok, hdr_profile} =
        Settings.create_quality_profile(%{
          name: "HDR Required",
          qualities: ["2160p"],
          quality_standards: %{
            require_hdr: true
          }
        })

      no_hdr = %{
        resolution: "2160p",
        media_type: :movie
      }

      result = QualityProfile.score_media_file(hdr_profile, no_hdr)

      assert result.score == 0.0
      assert length(result.violations) > 0
      assert Enum.any?(result.violations, &String.contains?(&1, "HDR is required"))
    end

    test "differentiates between movie and episode sizes", %{profile: profile} do
      movie_attrs = %{
        file_size_mb: 8192,
        media_type: :movie,
        resolution: "1080p"
      }

      episode_attrs = %{
        file_size_mb: 2048,
        media_type: :episode,
        resolution: "1080p"
      }

      movie_result = QualityProfile.score_media_file(profile, movie_attrs)
      episode_result = QualityProfile.score_media_file(profile, episode_attrs)

      # Both should score well within their respective ranges
      assert movie_result.breakdown.file_size >= 75.0
      assert episode_result.breakdown.file_size >= 75.0
    end

    test "returns 0 score and explanation when no quality_standards defined" do
      {:ok, basic_profile} =
        Settings.create_quality_profile(%{
          name: "Basic No Standards",
          qualities: ["1080p"]
        })

      result = QualityProfile.score_media_file(basic_profile, %{resolution: "1080p"})

      assert result.score == 0.0
      assert result.violations == ["No quality standards defined"]
    end

    test "handles missing media attributes gracefully", %{profile: profile} do
      # Missing most attributes
      minimal_attrs = %{
        resolution: "1080p"
      }

      result = QualityProfile.score_media_file(profile, minimal_attrs)

      # Should still compute a score based on available data
      assert is_float(result.score)
      assert is_map(result.breakdown)
      assert result.breakdown.resolution == 100.0
    end

    test "scores audio bitrate separately from video bitrate", %{profile: profile} do
      with_audio = %{
        video_bitrate_mbps: 15.0,
        audio_bitrate_kbps: 320,
        resolution: "1080p",
        media_type: :movie
      }

      result = QualityProfile.score_media_file(profile, with_audio)

      assert result.breakdown.video_bitrate >= 90.0
      assert result.breakdown.audio_bitrate >= 75.0
    end

    test "scores preferred values within 10% as very high", %{profile: profile} do
      close_to_preferred = %{
        video_bitrate_mbps: 14.5,
        resolution: "1080p",
        media_type: :movie
      }

      result = QualityProfile.score_media_file(profile, close_to_preferred)

      assert result.breakdown.video_bitrate >= 95.0
    end
  end

  describe "enhanced metadata_preferences validation" do
    test "accepts valid metadata preferences with all fields" do
      valid_prefs = %{
        provider_priority: ["metadata_relay", "tvdb", "tmdb"],
        field_providers: %{
          title: "tvdb",
          overview: "tmdb"
        },
        language: "en-US",
        region: "US",
        fallback_languages: ["en", "ja"],
        auto_fetch_enabled: true,
        auto_refresh_interval_hours: 168,
        fallback_on_provider_failure: true,
        skip_unavailable_providers: true,
        conflict_resolution: "prefer_newer",
        merge_strategy: "union"
      }

      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Test Profile with Metadata Prefs",
          qualities: ["1080p"],
          metadata_preferences: valid_prefs
        })

      assert profile.metadata_preferences == valid_prefs
    end

    test "accepts minimal metadata preferences" do
      minimal_prefs = %{
        provider_priority: ["metadata_relay"]
      }

      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Minimal Metadata Profile",
          qualities: ["1080p"],
          metadata_preferences: minimal_prefs
        })

      assert profile.metadata_preferences.provider_priority == ["metadata_relay"]
    end

    test "rejects invalid provider names in priority list" do
      invalid_prefs = %{
        provider_priority: ["invalid_provider", "metadata_relay"]
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Provider Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert Enum.any?(
               errors_on(changeset).metadata_preferences,
               &String.contains?(&1, "provider_priority must be a list of valid provider names")
             )
    end

    test "rejects invalid provider names in field_providers" do
      invalid_prefs = %{
        provider_priority: ["metadata_relay"],
        field_providers: %{
          "title" => "invalid_provider"
        }
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Field Provider Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert Enum.any?(
               errors_on(changeset).metadata_preferences,
               &String.contains?(&1, "field_providers contains invalid provider names")
             )
    end

    test "rejects invalid language codes" do
      invalid_prefs = %{
        provider_priority: ["metadata_relay"],
        language: "invalid"
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Language Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert Enum.any?(
               errors_on(changeset).metadata_preferences,
               &String.contains?(&1, "language must be a valid language code")
             )
    end

    test "accepts valid locale codes" do
      valid_prefs = %{
        provider_priority: ["metadata_relay"],
        language: "ja-JP"
      }

      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Japanese Locale Profile",
          qualities: ["1080p"],
          metadata_preferences: valid_prefs
        })

      assert profile.metadata_preferences.language == "ja-JP"
    end

    test "rejects invalid region codes" do
      invalid_prefs = %{
        provider_priority: ["metadata_relay"],
        region: "USA"
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Region Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert Enum.any?(
               errors_on(changeset).metadata_preferences,
               &String.contains?(&1, "region must be a 2-letter ISO 3166-1 alpha-2 country code")
             )
    end

    test "rejects invalid conflict_resolution values" do
      invalid_prefs = %{
        provider_priority: ["metadata_relay"],
        conflict_resolution: "invalid_strategy"
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Conflict Resolution Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert Enum.any?(
               errors_on(changeset).metadata_preferences,
               &String.contains?(&1, "conflict_resolution must be one of")
             )
    end

    test "rejects non-positive refresh intervals" do
      invalid_prefs = %{
        provider_priority: ["metadata_relay"],
        auto_refresh_interval_hours: 0
      }

      {:error, changeset} =
        Settings.create_quality_profile(%{
          name: "Invalid Interval Profile",
          qualities: ["1080p"],
          metadata_preferences: invalid_prefs
        })

      assert "auto_refresh_interval_hours must be a positive integer" in errors_on(changeset).metadata_preferences
    end

    test "accepts atom provider names" do
      prefs_with_atoms = %{
        provider_priority: [:metadata_relay, :tvdb]
      }

      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Atom Provider Profile",
          qualities: ["1080p"],
          metadata_preferences: prefs_with_atoms
        })

      assert profile.metadata_preferences.provider_priority == [:metadata_relay, :tvdb]
    end
  end

  describe "get_default_metadata_preferences/0" do
    test "returns sensible defaults" do
      defaults = Settings.get_default_metadata_preferences()

      assert is_list(defaults.provider_priority)
      assert "metadata_relay" in defaults.provider_priority
      assert defaults.language == "en-US"
      assert defaults.auto_fetch_enabled == true
      assert defaults.auto_refresh_interval_hours == 168
    end
  end

  describe "get_metadata_preferences_with_defaults/1" do
    test "merges custom preferences with defaults" do
      custom = %{language: "fr-FR", region: "FR"}
      merged = Settings.get_metadata_preferences_with_defaults(custom)

      assert merged.language == "fr-FR"
      assert merged.region == "FR"
      # Default values should still be present
      assert is_list(merged.provider_priority)
      assert merged.auto_fetch_enabled == true
    end

    test "overrides defaults completely for specified keys" do
      custom = %{provider_priority: ["tvdb"]}
      merged = Settings.get_metadata_preferences_with_defaults(custom)

      # Should use custom priority, not merge with default
      assert merged.provider_priority == ["tvdb"]
    end
  end

  describe "get_field_provider/2" do
    test "returns field-specific provider when defined" do
      prefs = %{
        provider_priority: ["metadata_relay", "tvdb"],
        field_providers: %{"title" => "tvdb"}
      }

      assert Settings.get_field_provider(prefs, "title") == "tvdb"
    end

    test "returns first priority provider when no field override exists" do
      prefs = %{
        provider_priority: ["metadata_relay", "tvdb"],
        field_providers: %{"title" => "tvdb"}
      }

      assert Settings.get_field_provider(prefs, "overview") == "metadata_relay"
    end

    test "returns first priority provider when field_providers is empty" do
      prefs = %{
        provider_priority: ["tvdb", "tmdb"],
        field_providers: %{}
      }

      assert Settings.get_field_provider(prefs, "any_field") == "tvdb"
    end

    test "returns nil when no providers are configured" do
      prefs = %{
        provider_priority: [],
        field_providers: %{}
      }

      assert Settings.get_field_provider(prefs, "any_field") == nil
    end
  end

  describe "DefaultMetadataPreferences" do
    test "default/0 returns complete preferences" do
      defaults = DefaultMetadataPreferences.default()

      assert defaults.provider_priority == ["metadata_relay", "tvdb", "tmdb"]
      assert defaults.language == "en-US"
      assert defaults.region == "US"
      assert defaults.fallback_languages == ["en"]
      assert defaults.auto_fetch_enabled == true
      assert defaults.auto_refresh_interval_hours == 168
      assert defaults.fallback_on_provider_failure == true
      assert defaults.skip_unavailable_providers == true
      assert defaults.conflict_resolution == "prefer_newer"
      assert defaults.merge_strategy == "union"
    end

    test "anime_optimized/0 returns Japanese preferences" do
      anime = DefaultMetadataPreferences.anime_optimized()

      assert anime.language == "ja-JP"
      assert anime.region == "JP"
      assert "ja" in anime.fallback_languages
    end

    test "tv_optimized/0 includes TVDB field overrides" do
      tv = DefaultMetadataPreferences.tv_optimized()

      assert tv.field_providers["episode_name"] == "tvdb"
      assert tv.field_providers["season_info"] == "tvdb"
    end

    test "movie_optimized/0 prioritizes TMDB" do
      movie = DefaultMetadataPreferences.movie_optimized()

      assert "tmdb" in movie.provider_priority
      assert movie.field_providers["cast"] == "tmdb"
      assert movie.field_providers["poster"] == "tmdb"
    end

    test "minimal/0 disables auto-fetch" do
      minimal = DefaultMetadataPreferences.minimal()

      assert minimal.auto_fetch_enabled == false
      assert minimal.auto_refresh_interval_hours == 0
      assert minimal.conflict_resolution == "manual"
    end
  end

  describe "export_profile/2" do
    setup do
      {:ok, profile} =
        Settings.create_quality_profile(%{
          name: "Export Test Profile",
          description: "Profile for testing export functionality",
          qualities: ["1080p", "720p"],
          upgrades_allowed: true,
          upgrade_until_quality: "1080p",
          quality_standards: %{
            preferred_video_codecs: ["h265", "h264"],
            min_resolution: "720p",
            max_resolution: "1080p"
          },
          metadata_preferences: %{
            provider_priority: ["metadata_relay", "tvdb"],
            language: "en-US"
          }
        })

      %{profile: profile}
    end

    test "exports to JSON format by default", %{profile: profile} do
      {:ok, exported} = Settings.export_profile(profile)

      # Should be valid JSON
      {:ok, parsed} = Jason.decode(exported)

      assert parsed["schema_version"] == 1
      assert parsed["name"] == "Export Test Profile"
      assert parsed["description"] == "Profile for testing export functionality"
      assert parsed["qualities"] == ["1080p", "720p"]
      assert parsed["upgrades_allowed"] == true
      assert parsed["upgrade_until_quality"] == "1080p"
      assert is_map(parsed["quality_standards"])
      assert is_map(parsed["metadata_preferences"])
      assert is_binary(parsed["exported_at"])
    end

    test "exports to YAML format when specified", %{profile: profile} do
      {:ok, exported} = Settings.export_profile(profile, format: :yaml)

      # Should be valid YAML
      {:ok, parsed} = YamlElixir.read_from_string(exported)

      assert parsed["schema_version"] == 1
      assert parsed["name"] == "Export Test Profile"
      assert parsed["qualities"] == ["1080p", "720p"]
    end

    test "includes all profile fields in export", %{profile: profile} do
      {:ok, exported} = Settings.export_profile(profile, format: :json)
      {:ok, parsed} = Jason.decode(exported)

      # Check essential fields
      assert Map.has_key?(parsed, "schema_version")
      assert Map.has_key?(parsed, "name")
      assert Map.has_key?(parsed, "description")
      assert Map.has_key?(parsed, "qualities")
      assert Map.has_key?(parsed, "upgrades_allowed")
      assert Map.has_key?(parsed, "upgrade_until_quality")
      assert Map.has_key?(parsed, "quality_standards")
      assert Map.has_key?(parsed, "metadata_preferences")
      assert Map.has_key?(parsed, "version")
      assert Map.has_key?(parsed, "exported_at")
    end

    test "pretty prints JSON by default", %{profile: profile} do
      {:ok, exported_pretty} = Settings.export_profile(profile, format: :json, pretty: true)
      {:ok, exported_compact} = Settings.export_profile(profile, format: :json, pretty: false)

      # Pretty version should have more newlines
      assert String.contains?(exported_pretty, "\n")
      assert byte_size(exported_pretty) > byte_size(exported_compact)
    end

    test "returns error for unsupported format", %{profile: profile} do
      assert {:error, message} = Settings.export_profile(profile, format: :xml)
      assert message =~ "Unsupported format"
    end
  end

  describe "import_profile/2" do
    test "imports profile from JSON string" do
      json_data = """
      {
        "schema_version": 1,
        "name": "Imported Profile",
        "description": "Test import",
        "qualities": ["1080p"],
        "upgrades_allowed": false,
        "quality_standards": {
          "preferred_video_codecs": ["h265"]
        }
      }
      """

      {:ok, profile} = Settings.import_profile(json_data)

      assert profile.name == "Imported Profile"
      assert profile.description == "Test import"
      assert profile.qualities == ["1080p"]
      assert profile.upgrades_allowed == false
      assert profile.quality_standards.preferred_video_codecs == ["h265"]
      assert profile.is_system == false
      assert is_nil(profile.source_url)
      refute is_nil(profile.last_synced_at)
    end

    test "imports profile from YAML string" do
      yaml_data = """
      schema_version: 1
      name: YAML Import Profile
      qualities:
        - 720p
        - 1080p
      upgrades_allowed: true
      """

      {:ok, profile} = Settings.import_profile(yaml_data)

      assert profile.name == "YAML Import Profile"
      assert profile.qualities == ["720p", "1080p"]
      assert profile.upgrades_allowed == true
    end

    test "sets source_url for URL imports" do
      # Mock URL import
      json_data = """
      {
        "schema_version": 1,
        "name": "URL Import Profile",
        "qualities": ["1080p"]
      }
      """

      {:ok, profile} =
        Settings.import_profile(json_data, source_url: "https://example.com/profile.json")

      assert profile.source_url == "https://example.com/profile.json"
    end

    test "allows name override on import" do
      json_data = """
      {
        "schema_version": 1,
        "name": "Original Name",
        "qualities": ["1080p"]
      }
      """

      {:ok, profile} = Settings.import_profile(json_data, name: "Custom Name")

      assert profile.name == "Custom Name"
    end

    test "validates required fields" do
      json_data = """
      {
        "schema_version": 1,
        "description": "Missing name and qualities"
      }
      """

      {:error, message} = Settings.import_profile(json_data)

      assert message =~ "Missing required fields"
      assert message =~ "name"
      assert message =~ "qualities"
    end

    test "rejects unsupported schema version" do
      json_data = """
      {
        "schema_version": 999,
        "name": "Future Profile",
        "qualities": ["1080p"]
      }
      """

      {:error, message} = Settings.import_profile(json_data)

      assert message =~ "Unsupported schema version: 999"
      assert message =~ "schema version 1"
    end

    test "rejects legacy format without schema_version" do
      json_data = """
      {
        "name": "Legacy Profile",
        "qualities": ["1080p"]
      }
      """

      {:error, message} = Settings.import_profile(json_data)

      assert message =~ "missing schema_version field"
      assert message =~ "legacy format"
    end

    test "detects conflicts with existing profiles" do
      # Create an existing profile
      {:ok, _existing} =
        Settings.create_quality_profile(%{
          name: "Conflict Profile",
          qualities: ["720p"]
        })

      json_data = """
      {
        "schema_version": 1,
        "name": "Conflict Profile",
        "qualities": ["1080p"]
      }
      """

      {:error, message} = Settings.import_profile(json_data)

      assert message =~ "already exists"
    end

    test "atomizes map keys in quality_standards and metadata_preferences" do
      json_data = """
      {
        "schema_version": 1,
        "name": "Key Test Profile",
        "qualities": ["1080p"],
        "quality_standards": {
          "preferred_video_codecs": ["h265"]
        },
        "metadata_preferences": {
          "provider_priority": ["tvdb"]
        }
      }
      """

      {:ok, profile} = Settings.import_profile(json_data)

      # Keys should be atoms, not strings
      assert is_map(profile.quality_standards)
      assert Map.has_key?(profile.quality_standards, :preferred_video_codecs)

      assert is_map(profile.metadata_preferences)
      assert Map.has_key?(profile.metadata_preferences, :provider_priority)
    end
  end

  describe "import_profile/2 dry run mode" do
    test "returns preview without creating profile" do
      json_data = """
      {
        "schema_version": 1,
        "name": "Dry Run Profile",
        "qualities": ["1080p"]
      }
      """

      {:ok, preview} = Settings.import_profile(json_data, dry_run: true)

      assert preview.dry_run == true
      assert preview.action == :create
      assert preview.profile.name == "Dry Run Profile"
      assert preview.conflicts == []

      # Verify profile was not actually created
      assert Settings.get_quality_profile_by_name("Dry Run Profile") == nil
    end

    test "detects conflicts in dry run mode" do
      # Create an existing profile
      {:ok, existing} =
        Settings.create_quality_profile(%{
          name: "Conflict Test",
          qualities: ["720p"]
        })

      json_data = """
      {
        "schema_version": 1,
        "name": "Conflict Test",
        "qualities": ["1080p"]
      }
      """

      {:ok, preview} = Settings.import_profile(json_data, dry_run: true)

      assert preview.dry_run == true
      assert preview.action == :update
      assert length(preview.conflicts) == 1

      [conflict] = preview.conflicts
      assert conflict.type == :name_conflict
      assert conflict.existing_profile_id == existing.id
      assert conflict.name == "Conflict Test"
    end

    test "validates changeset in dry run mode" do
      json_data = """
      {
        "schema_version": 1,
        "name": "Validation Test",
        "qualities": ["1080p"],
        "quality_standards": {
          "preferred_video_codecs": ["invalid_codec"]
        }
      }
      """

      {:error, message} = Settings.import_profile(json_data, dry_run: true)

      assert message =~ "Validation failed"
      assert message =~ "quality_standards"
    end
  end

  describe "import_profile/2 with remote URLs" do
    setup do
      bypass = Bypass.open()
      %{bypass: bypass}
    end

    test "fetches and imports from remote URL", %{bypass: bypass} do
      json_data = """
      {
        "schema_version": 1,
        "name": "Remote Profile",
        "qualities": ["1080p", "720p"]
      }
      """

      Bypass.expect_once(bypass, "GET", "/profile.json", fn conn ->
        Plug.Conn.resp(conn, 200, json_data)
      end)

      url = "http://localhost:#{bypass.port}/profile.json"
      {:ok, profile} = Settings.import_profile(url)

      assert profile.name == "Remote Profile"
      assert profile.source_url == url
    end

    test "handles HTTP errors gracefully", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/notfound.json", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      url = "http://localhost:#{bypass.port}/notfound.json"
      {:error, message} = Settings.import_profile(url)

      assert message =~ "Failed to fetch from URL"
      assert message =~ "404"
    end

    @tag :skip
    test "handles network errors gracefully" do
      # Use an invalid URL that will cause connection error
      # Note: This test is skipped because it's environment-dependent
      url = "http://localhost:99999/profile.json"
      {:error, message} = Settings.import_profile(url)

      assert message =~ "Failed to fetch from URL"
    end
  end

  describe "round-trip export/import" do
    test "exported profile can be re-imported successfully" do
      # Create original profile
      {:ok, original} =
        Settings.create_quality_profile(%{
          name: "Round Trip Profile",
          description: "Test round-trip export/import",
          qualities: ["2160p", "1080p"],
          upgrades_allowed: true,
          upgrade_until_quality: "2160p",
          quality_standards: %{
            preferred_video_codecs: ["h265", "av1"],
            preferred_audio_codecs: ["atmos", "truehd"],
            min_resolution: "1080p",
            max_resolution: "2160p"
          },
          metadata_preferences: %{
            provider_priority: ["metadata_relay", "tvdb", "tmdb"],
            language: "en-US",
            auto_fetch_enabled: true
          }
        })

      # Export to JSON
      {:ok, exported_json} = Settings.export_profile(original, format: :json)

      # Import with different name to avoid conflict
      {:ok, imported} = Settings.import_profile(exported_json, name: "Round Trip Profile Copy")

      # Verify all settings match
      assert imported.description == original.description
      assert imported.qualities == original.qualities
      assert imported.upgrades_allowed == original.upgrades_allowed
      assert imported.upgrade_until_quality == original.upgrade_until_quality
      assert imported.quality_standards == original.quality_standards
      assert imported.metadata_preferences == original.metadata_preferences
    end

    test "YAML round-trip preserves all data" do
      {:ok, original} =
        Settings.create_quality_profile(%{
          name: "YAML Round Trip",
          qualities: ["1080p"],
          quality_standards: %{
            preferred_video_codecs: ["h264"]
          }
        })

      # Export to YAML
      {:ok, exported_yaml} = Settings.export_profile(original, format: :yaml)

      # Import with different name
      {:ok, imported} = Settings.import_profile(exported_yaml, name: "YAML Round Trip Copy")

      # Verify core settings match
      assert imported.qualities == original.qualities
      assert imported.quality_standards == original.quality_standards
    end
  end

  describe "library path category paths" do
    test "can create library path with category_paths and auto_organize" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true,
          auto_organize: true,
          category_paths: %{
            "anime_movie" => "Anime",
            "cartoon_movie" => "Animated"
          }
        })

      assert library_path.auto_organize == true

      assert library_path.category_paths == %{
               "anime_movie" => "Anime",
               "cartoon_movie" => "Animated"
             }
    end

    test "defaults auto_organize to false" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true
        })

      assert library_path.auto_organize == false
      assert library_path.category_paths == %{}
    end

    test "validates category_paths keys are valid MediaCategory values" do
      {:error, changeset} =
        Settings.create_library_path(%{
          path: "/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true,
          category_paths: %{
            "invalid_category" => "Invalid"
          }
        })

      assert changeset.errors[:category_paths] != nil
      {message, _} = changeset.errors[:category_paths]
      assert message =~ "invalid category keys"
      assert message =~ "invalid_category"
    end

    test "accepts all valid MediaCategory keys in category_paths" do
      valid_categories = %{
        "movie" => "Movies",
        "anime_movie" => "Anime Movies",
        "cartoon_movie" => "Cartoon Movies",
        "tv_show" => "TV Shows",
        "anime_series" => "Anime Series",
        "cartoon_series" => "Cartoon Series"
      }

      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/all_categories_#{System.unique_integer([:positive])}",
          type: :mixed,
          monitored: true,
          category_paths: valid_categories
        })

      assert library_path.category_paths == valid_categories
    end

    test "can update library path with category_paths" do
      {:ok, library_path} =
        Settings.create_library_path(%{
          path: "/media/movies_#{System.unique_integer([:positive])}",
          type: :movies,
          monitored: true
        })

      {:ok, updated} =
        Settings.update_library_path(library_path, %{
          auto_organize: true,
          category_paths: %{"anime_movie" => "Anime"}
        })

      assert updated.auto_organize == true
      assert updated.category_paths == %{"anime_movie" => "Anime"}
    end
  end

  describe "LibraryPath.resolve_category_path/3" do
    alias Mydia.Settings.LibraryPath

    test "returns category-specific path when auto_organize is enabled and category is configured" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: %{"anime_movie" => "Anime"},
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      assert result == "/media/movies/Anime/Spirited Away (2001)"
    end

    test "returns default path when auto_organize is disabled" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: %{"anime_movie" => "Anime"},
        auto_organize: false
      }

      result = LibraryPath.resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      assert result == "/media/movies/Spirited Away (2001)"
    end

    test "returns default path when category is not configured" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: %{"anime_movie" => "Anime"},
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, :movie, "The Matrix (1999)")
      assert result == "/media/movies/The Matrix (1999)"
    end

    test "returns default path when category_paths is empty" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: %{},
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      assert result == "/media/movies/Spirited Away (2001)"
    end

    test "returns default path when category_paths is nil" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: nil,
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, :anime_movie, "Spirited Away (2001)")
      assert result == "/media/movies/Spirited Away (2001)"
    end

    test "accepts string category argument" do
      library = %LibraryPath{
        path: "/media/movies",
        category_paths: %{"anime_movie" => "Anime"},
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, "anime_movie", "Spirited Away (2001)")
      assert result == "/media/movies/Anime/Spirited Away (2001)"
    end

    test "handles nested category subpaths" do
      library = %LibraryPath{
        path: "/media",
        category_paths: %{"anime_series" => "TV/Anime"},
        auto_organize: true
      }

      result = LibraryPath.resolve_category_path(library, :anime_series, "Attack on Titan")
      assert result == "/media/TV/Anime/Attack on Titan"
    end
  end

  describe "default quality profile" do
    setup do
      # Ensure we have some quality profiles to work with
      Repo.delete_all(QualityProfile)
      {:ok, _} = Settings.ensure_default_quality_profiles()
      profiles = Settings.list_quality_profiles()
      %{profiles: profiles}
    end

    test "get_default_quality_profile_id/0 returns nil when not set" do
      # Clear any existing default
      case Settings.get_config_setting_by_key("media.default_quality_profile_id") do
        nil -> :ok
        setting -> Settings.delete_config_setting(setting)
      end

      assert Settings.get_default_quality_profile_id() == nil
    end

    test "set_default_quality_profile/1 persists the profile ID", %{profiles: profiles} do
      profile = hd(profiles)

      assert {:ok, _} = Settings.set_default_quality_profile(profile.id)
      assert Settings.get_default_quality_profile_id() == profile.id
    end

    test "set_default_quality_profile/1 with nil clears the default", %{profiles: profiles} do
      profile = hd(profiles)

      # First set a default
      {:ok, _} = Settings.set_default_quality_profile(profile.id)
      assert Settings.get_default_quality_profile_id() == profile.id

      # Then clear it
      {:ok, _} = Settings.set_default_quality_profile(nil)
      assert Settings.get_default_quality_profile_id() == nil
    end

    test "get_default_quality_profile/0 returns nil when not set" do
      # Clear any existing default
      case Settings.get_config_setting_by_key("media.default_quality_profile_id") do
        nil -> :ok
        setting -> Settings.delete_config_setting(setting)
      end

      assert Settings.get_default_quality_profile() == nil
    end

    test "get_default_quality_profile/0 returns the full struct when set", %{profiles: profiles} do
      profile = hd(profiles)

      {:ok, _} = Settings.set_default_quality_profile(profile.id)
      result = Settings.get_default_quality_profile()

      assert result.id == profile.id
      assert result.name == profile.name
    end

    test "get_default_quality_profile/0 returns nil if profile was deleted", %{profiles: profiles} do
      profile = hd(profiles)

      # Set default
      {:ok, _} = Settings.set_default_quality_profile(profile.id)
      assert Settings.get_default_quality_profile_id() == profile.id

      # Delete the profile
      {:ok, _} = Settings.delete_quality_profile(profile)

      # Should return nil since profile no longer exists
      assert Settings.get_default_quality_profile() == nil
      # But the ID is still stored
      assert Settings.get_default_quality_profile_id() == profile.id
    end

    test "set_default_quality_profile/1 updates existing setting", %{profiles: profiles} do
      [profile1, profile2 | _] = profiles

      # Set first default
      {:ok, _} = Settings.set_default_quality_profile(profile1.id)
      assert Settings.get_default_quality_profile_id() == profile1.id

      # Update to second profile
      {:ok, _} = Settings.set_default_quality_profile(profile2.id)
      assert Settings.get_default_quality_profile_id() == profile2.id

      # Verify only one config setting exists
      settings =
        Settings.list_config_settings()
        |> Enum.filter(&(&1.key == "media.default_quality_profile_id"))

      assert length(settings) == 1
    end
  end
end
