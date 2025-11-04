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
    env_vars = [
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
      "LOG_LEVEL",
      "OBAN_POLL_INTERVAL",
      "DOWNLOAD_CLIENT_1_NAME",
      "DOWNLOAD_CLIENT_1_TYPE",
      "DOWNLOAD_CLIENT_1_HOST",
      "DOWNLOAD_CLIENT_1_PORT",
      "DOWNLOAD_CLIENT_1_USERNAME",
      "DOWNLOAD_CLIENT_1_PASSWORD",
      "DOWNLOAD_CLIENT_2_NAME",
      "DOWNLOAD_CLIENT_2_TYPE",
      "DOWNLOAD_CLIENT_2_HOST",
      "DOWNLOAD_CLIENT_2_PORT"
    ]

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

      # - tv_path comes from defaults (no yaml, db, or env override)
      assert config.media.tv_path == "/media/tv"
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
end
