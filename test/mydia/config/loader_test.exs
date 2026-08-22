defmodule Mydia.Config.LoaderTest do
  use ExUnit.Case, async: false

  alias Mydia.Config.Loader

  @test_yaml_path "test/fixtures/test_config.yml"

  setup _tags do
    # Set up SQL Sandbox for all tests since Loader now accesses the database
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Mydia.Repo, shared: true)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    # Clean up environment variables before each test
    # First, find and clean all DOWNLOAD_CLIENT_* env vars
    download_client_vars =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "DOWNLOAD_CLIENT_") end)
      |> Enum.map(fn {key, _} -> key end)

    library_path_vars =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "LIBRARY_PATH_") end)
      |> Enum.map(fn {key, _} -> key end)

    env_vars =
      [
        "PORT",
        "HOST",
        "URL_SCHEME",
        "URL_HOST",
        "DATABASE_PATH",
        "POOL_SIZE",
        "LOCAL_AUTH_ENABLED",
        "OIDC_ENABLED",
        "OIDC_ISSUER",
        "OIDC_CLIENT_ID",
        "OIDC_CLIENT_SECRET",
        "MOVIES_PATH",
        "TV_PATH",
        "METADATA_LANGUAGE",
        "LOG_LEVEL",
        "OBAN_POLL_INTERVAL",
        "MAX_TRANSCODE_HEIGHT",
        "AUTO_SEARCH_MIN_SEEDERS"
      ] ++ download_client_vars ++ library_path_vars

    # Store original values
    original_env =
      Enum.map(env_vars, fn var ->
        {var, System.get_env(var)}
      end)

    # Clear all test env vars
    Enum.each(env_vars, &System.delete_env/1)

    # Clean up test YAML file if it exists
    File.rm(@test_yaml_path)

    on_exit(fn ->
      # Delete any DOWNLOAD_CLIENT_* vars the test itself set — they are not in
      # `original_env` (captured at setup), so a plain restore would leak them
      # into the rest of the suite, where any config reload (e.g. the plugin
      # lifecycle) would bake phantom download clients into the global
      # runtime config.
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "DOWNLOAD_CLIENT_") end)
      |> Enum.each(fn {key, _} -> System.delete_env(key) end)

      # Same reasoning for LIBRARY_PATH_* vars the test itself set.
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "LIBRARY_PATH_") end)
      |> Enum.each(fn {key, _} -> System.delete_env(key) end)

      # Restore original environment
      Enum.each(original_env, fn {var, value} ->
        if value do
          System.put_env(var, value)
        else
          System.delete_env(var)
        end
      end)

      # Clean up test file
      File.rm(@test_yaml_path)
    end)

    :ok
  end

  describe "load/1" do
    test "loads defaults when no config file or env vars exist" do
      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.port == 4000
      assert config.server.host == "0.0.0.0"
      assert config.database.pool_size == 5
      assert config.auth.local_enabled == true
      assert config.auth.oidc_enabled == false
    end

    test "loads configuration from YAML file" do
      yaml_content = """
      server:
        port: 8080
        host: "127.0.0.1"
        url_scheme: "https"
        url_host: "mydia.example.com"

      database:
        path: "/custom/path/mydia.db"
        pool_size: 10

      auth:
        local_enabled: false
        oidc_enabled: true
        oidc_issuer: "https://auth.example.com"
        oidc_client_id: "test-client"
        oidc_client_secret: "test-secret"

      media:
        movies_path: "/custom/movies"
        tv_path: "/custom/tv"

      logging:
        level: "debug"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert config.server.port == 8080
      assert config.server.host == "127.0.0.1"
      assert config.server.url_scheme == "https"
      assert config.database.path == "/custom/path/mydia.db"
      assert config.database.pool_size == 10
      assert config.auth.local_enabled == false
      assert config.auth.oidc_enabled == true
      assert config.auth.oidc_issuer == "https://auth.example.com"
      assert config.media.movies_path == "/custom/movies"
      assert config.logging.level == "debug"
    end

    test "loads configuration from environment variables" do
      System.put_env("PORT", "3000")
      System.put_env("HOST", "localhost")
      System.put_env("URL_SCHEME", "https")
      System.put_env("DATABASE_PATH", "/env/mydia.db")
      System.put_env("POOL_SIZE", "20")
      System.put_env("LOCAL_AUTH_ENABLED", "false")
      System.put_env("OIDC_ENABLED", "true")
      System.put_env("OIDC_ISSUER", "https://env.auth.com")
      System.put_env("OIDC_CLIENT_ID", "env-client")
      System.put_env("OIDC_CLIENT_SECRET", "env-secret")
      System.put_env("MOVIES_PATH", "/env/movies")
      System.put_env("LOG_LEVEL", "warning")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.port == 3000
      assert config.server.host == "localhost"
      assert config.server.url_scheme == "https"
      assert config.database.path == "/env/mydia.db"
      assert config.database.pool_size == 20
      assert config.auth.local_enabled == false
      assert config.auth.oidc_enabled == true
      assert config.auth.oidc_issuer == "https://env.auth.com"
      assert config.media.movies_path == "/env/movies"
      assert config.logging.level == "warning"
    end

    test "environment variables override YAML configuration" do
      yaml_content = """
      server:
        port: 8080
        host: "127.0.0.1"

      database:
        pool_size: 10

      logging:
        level: "debug"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      # Set env vars to override
      System.put_env("PORT", "9000")
      System.put_env("LOG_LEVEL", "error")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      # Env vars should override YAML
      assert config.server.port == 9000
      assert config.logging.level == "error"

      # YAML values should be used where no env var exists
      assert config.server.host == "127.0.0.1"
      assert config.database.pool_size == 10
    end

    test "handles boolean environment variables correctly" do
      System.put_env("LOCAL_AUTH_ENABLED", "true")
      System.put_env("OIDC_ENABLED", "false")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.auth.local_enabled == true
      assert config.auth.oidc_enabled == false

      System.put_env("LOCAL_AUTH_ENABLED", "0")
      System.put_env("OIDC_ENABLED", "1")
      System.put_env("OIDC_ISSUER", "https://auth.example.com")
      System.put_env("OIDC_CLIENT_ID", "test-client")
      System.put_env("OIDC_CLIENT_SECRET", "test-secret")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.auth.local_enabled == false
      assert config.auth.oidc_enabled == true
    end

    test "handles integer environment variables correctly" do
      System.put_env("PORT", "5000")
      System.put_env("POOL_SIZE", "15")
      System.put_env("OBAN_POLL_INTERVAL", "2000")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.port == 5000
      assert config.database.pool_size == 15
      assert config.oban.poll_interval == 2000
    end

    test "metadata language defaults to en-US and is overridden by METADATA_LANGUAGE env var" do
      {:ok, config} = Loader.load(config_file: "nonexistent.yml")
      assert config.metadata.language == "en-US"

      System.put_env("METADATA_LANGUAGE", "pt-BR")
      {:ok, config} = Loader.load(config_file: "nonexistent.yml")
      assert config.metadata.language == "pt-BR"
    end

    test "ignores the removed LIBRARY_PATH_<N>_QUALITY_PROFILE_ID variable" do
      # Never worked: profile ids are UUIDs and this parsed as an integer.
      System.put_env("LIBRARY_PATH_1_PATH", "/movies")
      System.put_env("LIBRARY_PATH_1_TYPE", "movies")
      System.put_env("LIBRARY_PATH_1_QUALITY_PROFILE_ID", Ecto.UUID.generate())

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert [path] = config.library_paths
      assert path.path == "/movies"
      refute Map.has_key?(path, :quality_profile_id)
    end

    test "returns error for invalid configuration" do
      yaml_content = """
      server:
        port: -1

      auth:
        local_enabled: false
        oidc_enabled: false
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:error, changeset} = Loader.load(config_file: @test_yaml_path)

      refute changeset.valid?
    end

    test "returns error for malformed YAML" do
      yaml_content = """
      server:
        port: [invalid: yaml: structure
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:error, message} = Loader.load(config_file: @test_yaml_path)

      assert is_binary(message)
      assert message =~ "Failed to parse YAML"
    end

    test "handles empty YAML file" do
      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, "")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      # Should use defaults
      assert config.server.port == 4000
      assert config.database.pool_size == 5
    end

    test "normalizes YAML keys to lowercase atoms" do
      yaml_content = """
      Server:
        Port: 8080
        Host: "example.com"

      Database:
        Pool_Size: 10
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert config.server.port == 8080
      assert config.server.host == "example.com"
      assert config.database.pool_size == 10
    end

    test "supports PHX_HOST as alternative to URL_HOST" do
      System.put_env("PHX_HOST", "phoenix.example.com")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.url_host == "phoenix.example.com"
    end

    test "URL_HOST takes precedence over PHX_HOST" do
      System.put_env("URL_HOST", "url.example.com")
      System.put_env("PHX_HOST", "phoenix.example.com")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.url_host == "url.example.com"
    end

    test "loads download clients from YAML" do
      yaml_content = """
      download_clients:
        - name: "qBittorrent"
          type: "qbittorrent"
          enabled: true
          priority: 1
          host: "localhost"
          port: 8080
          use_ssl: false
          username: "admin"
          password: "pass"
          category: "mydia"
        - name: "Transmission"
          type: "transmission"
          enabled: true
          priority: 2
          host: "localhost"
          port: 9091
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert length(config.download_clients) == 2

      [client1, client2] = config.download_clients

      assert client1.name == "qBittorrent"
      assert client1.type == :qbittorrent
      assert client1.enabled == true
      assert client1.priority == 1
      assert client1.host == "localhost"
      assert client1.port == 8080
      assert client1.use_ssl == false
      assert client1.username == "admin"
      assert client1.password == "pass"
      assert client1.category == "mydia"

      assert client2.name == "Transmission"
      assert client2.type == :transmission
      assert client2.port == 9091
    end

    test "downcases connection_settings keys so adapters find them" do
      yaml_content = """
      download_clients:
        - name: "Blackhole"
          type: "blackhole"
          enabled: true
          priority: 1
          connection_settings:
            Watch_Folder: "/downloads/watch"
            PROVIDER: "real_debrid"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      [client] = config.download_clients

      # Keys must be lowercase strings regardless of YAML casing, matching the
      # lowercase string keys adapters look up.
      assert client.connection_settings["watch_folder"] == "/downloads/watch"
      assert client.connection_settings["provider"] == "real_debrid"
    end

    test "loads download clients from environment variables" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "EnvClient")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "qbittorrent")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "env.host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "8080")
      System.put_env("DOWNLOAD_CLIENT_1_USERNAME", "envuser")
      System.put_env("DOWNLOAD_CLIENT_1_PASSWORD", "envpass")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert length(config.download_clients) == 1

      client = List.first(config.download_clients)

      assert client.name == "EnvClient"
      assert client.type == :qbittorrent
      assert client.host == "env.host"
      assert client.port == 8080
      assert client.username == "envuser"
      assert client.password == "envpass"
    end

    test "defaults external_torrents to :auto when the env var is absent" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "EnvClient")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "qbittorrent")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "env.host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "8080")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert %{external_torrents: :auto} = List.first(config.download_clients)
    end

    test "reads DOWNLOAD_CLIENT_<N>_EXTERNAL_TORRENTS as an atom" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "EnvClient")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "qbittorrent")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "env.host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "8080")
      System.put_env("DOWNLOAD_CLIENT_1_EXTERNAL_TORRENTS", "ignore")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert %{external_torrents: :ignore} = List.first(config.download_clients)
    end

    test "rejects category_only for an rqbit client, which reports no categories" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "EnvRqbit")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "rqbit")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "env.host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "3030")
      System.put_env("DOWNLOAD_CLIENT_1_EXTERNAL_TORRENTS", "category_only")

      assert {:error, _reason} = Loader.load(config_file: "nonexistent.yml")
    end

    test "keeps YAML connection_settings keys as strings for debrid clients" do
      yaml_content = """
      download_clients:
        - name: "Real-Debrid"
          type: "debrid"
          api_key: "rd-key"
          connection_settings:
            provider: "real_debrid"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      client = List.first(config.download_clients)

      assert client.type == :debrid
      # String keys are required — adapters and validation read
      # connection_settings["provider"], not the atomized :provider.
      assert client.connection_settings == %{"provider" => "real_debrid"}
    end

    test "merges download clients from YAML and environment variables" do
      yaml_content = """
      download_clients:
        - name: "YAMLClient"
          type: "qbittorrent"
          host: "yaml.host"
          port: 8080
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      System.put_env("DOWNLOAD_CLIENT_1_NAME", "EnvClient")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "transmission")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "env.host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "9091")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert length(config.download_clients) == 2

      yaml_client = Enum.find(config.download_clients, &(&1.name == "YAMLClient"))
      env_client = Enum.find(config.download_clients, &(&1.name == "EnvClient"))

      assert yaml_client.type == :qbittorrent
      assert yaml_client.port == 8080

      assert env_client.type == :transmission
      assert env_client.port == 9091
    end

    test "loads multiple download clients from environment variables" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "Client1")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "qbittorrent")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "host1")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "8080")

      System.put_env("DOWNLOAD_CLIENT_2_NAME", "Client2")
      System.put_env("DOWNLOAD_CLIENT_2_TYPE", "transmission")
      System.put_env("DOWNLOAD_CLIENT_2_HOST", "host2")
      System.put_env("DOWNLOAD_CLIENT_2_PORT", "9091")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert length(config.download_clients) == 2

      client1 = Enum.find(config.download_clients, &(&1.name == "Client1"))
      client2 = Enum.find(config.download_clients, &(&1.name == "Client2"))

      assert client1.type == :qbittorrent
      assert client1.port == 8080

      assert client2.type == :transmission
      assert client2.port == 9091
    end

    test "loads a debrid client's provider into connection_settings" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "Real-Debrid")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "debrid")
      System.put_env("DOWNLOAD_CLIENT_1_API_KEY", "rd-key")
      System.put_env("DOWNLOAD_CLIENT_1_PROVIDER", "real_debrid")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      client = List.first(config.download_clients)

      assert client.type == :debrid
      assert client.api_key == "rd-key"
      assert client.connection_settings == %{"provider" => "real_debrid"}
    end

    test "loads a blackhole client's watch/completed folders into connection_settings" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "Blackhole")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "blackhole")
      System.put_env("DOWNLOAD_CLIENT_1_WATCH_FOLDER", "/downloads/watch")
      System.put_env("DOWNLOAD_CLIENT_1_COMPLETED_FOLDER", "/downloads/complete")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      client = List.first(config.download_clients)

      assert client.type == :blackhole

      assert client.connection_settings == %{
               "watch_folder" => "/downloads/watch",
               "completed_folder" => "/downloads/complete"
             }
    end

    test "omits connection_settings when no provider or folder vars are set" do
      System.put_env("DOWNLOAD_CLIENT_1_NAME", "Plain")
      System.put_env("DOWNLOAD_CLIENT_1_TYPE", "qbittorrent")
      System.put_env("DOWNLOAD_CLIENT_1_HOST", "host")
      System.put_env("DOWNLOAD_CLIENT_1_PORT", "8080")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      client = List.first(config.download_clients)

      assert client.connection_settings == %{}
    end
  end

  describe "load!/0" do
    test "returns config struct on success" do
      config = Loader.load!()

      assert %Mydia.Config.Schema{} = config
      assert config.server.port == 4000
    end

    test "raises on validation error" do
      yaml_content = """
      auth:
        local_enabled: false
        oidc_enabled: false
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      assert_raise RuntimeError, ~r/Configuration validation failed/, fn ->
        Loader.load!(config_file: @test_yaml_path)
      end
    end
  end

  describe "4-layer precedence" do
    alias Mydia.Repo
    alias Mydia.Settings.ConfigSetting

    setup do
      # Clean up any existing config settings
      Repo.delete_all(ConfigSetting)
      :ok
    end

    test "database settings override YAML configuration" do
      # Create YAML config
      yaml_content = """
      server:
        port: 8080
        host: "yaml.example.com"

      logging:
        level: "debug"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      # Create database config settings that override some YAML values
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "server.port",
          value: "9000",
          category: :server
        })

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      # Database should override YAML for port
      assert config.server.port == 9000

      # YAML values should be used where no database override exists
      assert config.server.host == "yaml.example.com"
      assert config.logging.level == "debug"
    end

    test "the transcode height ceiling is reachable from every layer" do
      # This setting is the stated escape hatch for operators whose hardware
      # cannot encode a 4K file in realtime. It shipped once as a bare key in
      # config/config.exs, which is compile-time and baked into the release,
      # so the only way to set it was to rebuild the image.
      File.mkdir_p!("test/fixtures")

      File.write!(@test_yaml_path, """
      streaming:
        max_transcode_height: 1080
      """)

      {:ok, from_yaml} = Loader.load(config_file: @test_yaml_path)
      assert from_yaml.streaming.max_transcode_height == 1080

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "streaming.max_transcode_height",
          value: "720",
          category: :streaming
        })

      {:ok, from_db} = Loader.load(config_file: @test_yaml_path)
      assert from_db.streaming.max_transcode_height == 720

      System.put_env("MAX_TRANSCODE_HEIGHT", "480")

      {:ok, from_env} = Loader.load(config_file: @test_yaml_path)
      assert from_env.streaming.max_transcode_height == 480
    end

    test "the transcode height ceiling defaults to no ceiling" do
      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.streaming.max_transcode_height == nil
    end

    test "the automatic-search seeder floor is reachable from every layer" do
      # Like the transcode ceiling above, this shipped as a bare compile-time
      # key (config :mydia, :auto_search, min_seeders: ...) that no operator
      # could reach without rebuilding the image, while the docs described it
      # as the one filter you are likely to set.
      File.mkdir_p!("test/fixtures")

      File.write!(@test_yaml_path, """
      downloads:
        min_seeders: 3
      """)

      {:ok, from_yaml} = Loader.load(config_file: @test_yaml_path)
      assert from_yaml.downloads.min_seeders == 3

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "downloads.min_seeders",
          value: "5",
          category: :downloads
        })

      {:ok, from_db} = Loader.load(config_file: @test_yaml_path)
      assert from_db.downloads.min_seeders == 5

      System.put_env("AUTO_SEARCH_MIN_SEEDERS", "10")

      {:ok, from_env} = Loader.load(config_file: @test_yaml_path)
      assert from_env.downloads.min_seeders == 10
    end

    test "the automatic-search seeder floor defaults to 0, filtering nothing" do
      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.downloads.min_seeders == 0
    end

    test "AUTO_SEARCH_MIN_SEEDERS=0 is honoured rather than treated as unset" do
      File.mkdir_p!("test/fixtures")

      File.write!(@test_yaml_path, """
      downloads:
        min_seeders: 7
      """)

      System.put_env("AUTO_SEARCH_MIN_SEEDERS", "0")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert config.downloads.min_seeders == 0
    end

    test "an unparseable AUTO_SEARCH_MIN_SEEDERS is ignored, not applied" do
      File.mkdir_p!("test/fixtures")

      File.write!(@test_yaml_path, """
      downloads:
        min_seeders: 3
      """)

      System.put_env("AUTO_SEARCH_MIN_SEEDERS", "lots")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      # The lower layer stands rather than the whole config failing to load,
      # which would take the app down over one bad variable.
      assert config.downloads.min_seeders == 3
    end

    test "a negative AUTO_SEARCH_MIN_SEEDERS fails validation" do
      System.put_env("AUTO_SEARCH_MIN_SEEDERS", "-1")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Loader.load(config_file: "nonexistent.yml")

      refute changeset.valid?
    end

    test "environment variables override database settings" do
      # Create database config
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "server.port",
          value: "9000",
          category: :server
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "logging.level",
          value: "warning",
          category: :general
        })

      # Set env vars to override database
      System.put_env("PORT", "3000")
      System.put_env("LOG_LEVEL", "error")

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      # Env vars should override database
      assert config.server.port == 3000
      assert config.logging.level == "error"
    end

    test "complete 4-layer precedence: env > db > yaml > defaults" do
      # Layer 1: Defaults (port: 4000, host: "0.0.0.0", level: "info")

      # Layer 2: YAML config
      yaml_content = """
      server:
        port: 8080
        host: "yaml.example.com"

      logging:
        level: "debug"

      media:
        movies_path: "/yaml/movies"
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      # Layer 3: Database config
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "server.port",
          value: "9000",
          category: :server
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "logging.level",
          value: "warning",
          category: :general
        })

      # Layer 4: Environment variables
      System.put_env("PORT", "3000")

      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      # Verify precedence:
      # - port comes from env (highest priority)
      assert config.server.port == 3000

      # - host comes from YAML (no db or env override)
      assert config.server.host == "yaml.example.com"

      # - logging level comes from db (overrides YAML, no env override)
      assert config.logging.level == "warning"

      # - movies_path comes from YAML (no db or env override)
      assert config.media.movies_path == "/yaml/movies"

      # - tv_path is nil (legacy paths have no defaults, no yaml/db/env override)
      assert config.media.tv_path == nil
    end

    test "handles database unavailability gracefully" do
      # This test simulates database being unavailable by not setting up Repo
      # The loader should fall back to 3-layer precedence (env > yaml > defaults)

      yaml_content = """
      server:
        port: 8080
      """

      File.mkdir_p!("test/fixtures")
      File.write!(@test_yaml_path, yaml_content)

      # Even with database potentially unavailable, loading should work
      {:ok, config} = Loader.load(config_file: @test_yaml_path)

      assert config.server.port == 8080
    end

    test "database config supports nested paths" do
      # Test that dot notation works for nested config
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.local_enabled",
          value: "false",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_enabled",
          value: "true",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_issuer",
          value: "https://db.auth.example.com",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_client_id",
          value: "db-client-id",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_client_secret",
          value: "db-client-secret",
          category: :auth
        })

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.auth.local_enabled == false
      assert config.auth.oidc_enabled == true
      assert config.auth.oidc_issuer == "https://db.auth.example.com"
      assert config.auth.oidc_client_id == "db-client-id"
      assert config.auth.oidc_client_secret == "db-client-secret"
    end

    test "database config parses integers correctly" do
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "server.port",
          value: "5555",
          category: :server
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "database.pool_size",
          value: "25",
          category: :server
        })

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.server.port == 5555
      assert config.database.pool_size == 25
    end

    test "database config parses booleans correctly" do
      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.local_enabled",
          value: "false",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_enabled",
          value: "true",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_issuer",
          value: "https://example.com",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_client_id",
          value: "test",
          category: :auth
        })

      {:ok, _} =
        Repo.insert(%ConfigSetting{
          key: "auth.oidc_client_secret",
          value: "test",
          category: :auth
        })

      {:ok, config} = Loader.load(config_file: "nonexistent.yml")

      assert config.auth.local_enabled == false
      assert config.auth.oidc_enabled == true
    end
  end

  describe "reload/0" do
    setup do
      original = Application.get_env(:mydia, :runtime_config)

      on_exit(fn ->
        if original do
          Application.put_env(:mydia, :runtime_config, original)
        else
          Application.delete_env(:mydia, :runtime_config)
        end
      end)

      :ok
    end

    test "stores the merged config in the application environment on success" do
      Application.delete_env(:mydia, :runtime_config)

      assert {:ok, config} = Loader.reload(config_file: "nonexistent.yml")
      assert Application.get_env(:mydia, :runtime_config) == config
    end

    test "leaves the cached config untouched when the merged config is invalid" do
      {:ok, good} = Loader.load(config_file: "nonexistent.yml")
      Application.put_env(:mydia, :runtime_config, good)

      # Persist a value that fails schema validation (url_scheme must be http/https)
      # so the merge validates to an error on reload.
      {:ok, _} =
        Mydia.Settings.upsert_config_setting(%{
          key: "server.url_scheme",
          value: "ftp",
          category: :server
        })

      assert {:error, _reason} = Loader.reload(config_file: "nonexistent.yml")
      # Contract: on error the previously cached config is left untouched.
      assert Application.get_env(:mydia, :runtime_config) == good
    end
  end
end
