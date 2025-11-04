defmodule Mydia.Downloads.Client.QbittorrentTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Qbittorrent

  @config %{
    type: :qbittorrent,
    host: "localhost",
    port: 8080,
    username: "admin",
    password: "adminpass",
    use_ssl: false,
    options: %{}
  }

  describe "module behaviour" do
    test "implements all callbacks from Mydia.Downloads.Client behaviour" do
      # Verify the module implements the required behaviour
      behaviours = Qbittorrent.__info__(:attributes)[:behaviour] || []
      assert Mydia.Downloads.Client in behaviours
    end
  end

  describe "configuration validation" do
    test "test_connection requires username and password" do
      config_without_username = Map.delete(@config, :username)

      {:error, error} = Qbittorrent.test_connection(config_without_username)
      assert error.type == :invalid_config
      assert error.message =~ "Username and password are required"
    end

    test "test_connection fails with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.test_connection(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout]
    end
  end

  describe "add_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Qbittorrent.add_torrent(timeout_config, {:magnet, magnet})
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "requires valid credentials" do
      invalid_config = %{@config | username: "wrong", password: "wrong"}

      magnet = "magnet:?xt=urn:btih:ABC123DEF456789012345678901234567890ABCD&dn=test"

      {:error, error} = Qbittorrent.add_torrent(invalid_config, {:magnet, magnet})
      assert error.type in [:authentication_failed, :connection_failed, :network_error]
    end
  end

  describe "get_status/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.get_status(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  describe "list_torrents/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.list_torrents(timeout_config)
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "accepts filter options" do
      # Test that the function accepts the expected options without error
      # Actual filtering would be tested in integration tests
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} = Qbittorrent.list_torrents(timeout_config, filter: :downloading)
      {:error, _error} = Qbittorrent.list_torrents(timeout_config, category: "test")
      {:error, _error} = Qbittorrent.list_torrents(timeout_config, tag: "test")
      assert true
    end
  end

  describe "remove_torrent/3" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.remove_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end

    test "accepts delete_files option" do
      # Test that the function accepts the expected options without error
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, _error} =
        Qbittorrent.remove_torrent(timeout_config, "somehash", delete_files: true)

      {:error, _error} =
        Qbittorrent.remove_torrent(timeout_config, "somehash", delete_files: false)

      assert true
    end
  end

  describe "pause_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.pause_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  describe "resume_torrent/2" do
    test "returns error with unreachable host" do
      unreachable_config = %{@config | host: "nonexistent.invalid", port: 9999}
      timeout_config = put_in(unreachable_config, [:options, :connect_timeout], 100)

      {:error, error} = Qbittorrent.resume_torrent(timeout_config, "somehash")
      assert error.type in [:connection_failed, :network_error, :timeout, :invalid_config]
    end
  end

  # Note: Full integration tests would require either:
  # 1. A real qBittorrent instance (can be configured via environment variables)
  # 2. HTTP mocking library like Bypass or Mox to simulate qBittorrent responses
  #
  # Integration tests should verify:
  # - Authentication flow with valid/invalid credentials
  # - Adding torrents (magnet links, files, URLs) with various options
  # - Retrieving torrent status with all fields parsed correctly
  # - Listing torrents with various filters (state, category, tag)
  # - Removing torrents with/without file deletion
  # - Pausing and resuming torrents
  # - State mapping (downloading, seeding, paused, error, etc.)
  # - Error handling for various failure scenarios
end
