defmodule Mydia.RemoteAccess.DirectUrlRefresherTest do
  use Mydia.DataCase, async: false

  alias Mydia.RemoteAccess

  @test_data_dir "test/tmp/refresher_certs"

  setup do
    # Clean up test directory before each test
    File.rm_rf!(@test_data_dir)
    File.mkdir_p!(@test_data_dir)

    # Save original config
    original_direct_urls_config = Application.get_env(:mydia, :direct_urls, [])

    # Set test data directory and external port
    Application.put_env(:mydia, :direct_urls,
      data_dir: @test_data_dir,
      external_port: 4000
    )

    on_exit(fn ->
      # Restore original config
      Application.put_env(:mydia, :direct_urls, original_direct_urls_config)
      # Clean up test directory
      File.rm_rf!(@test_data_dir)
    end)

    :ok
  end

  describe "refresh_direct_urls/0" do
    test "detects URLs and stores them in config" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Simulate refresh by detecting URLs and updating config
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

      {:ok, _cert_path, _key_path, fingerprint} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      {:ok, config} = RemoteAccess.update_direct_urls(direct_urls, fingerprint, false)

      # Verify URLs were detected and stored
      assert is_list(config.direct_urls)
      assert config.direct_urls != []

      # All URLs should be sslip.io URLs (no external URLs configured)
      # HTTP is the default scheme for auto-detected URLs
      Enum.each(config.direct_urls, fn url ->
        assert String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
        assert String.contains?(url, ".sslip.io:")
      end)
    end

    test "generates certificate and stores fingerprint" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Simulate refresh
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

      {:ok, _cert_path, _key_path, fingerprint} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      {:ok, config} = RemoteAccess.update_direct_urls(direct_urls, fingerprint, false)

      # Verify fingerprint was stored
      assert is_binary(config.cert_fingerprint)
      assert String.contains?(config.cert_fingerprint, ":")
      # SHA256 fingerprint format: 32 bytes = 64 hex chars + 31 colons = 95 chars
      assert String.length(config.cert_fingerprint) == 95
    end

    test "creates certificate files in data directory" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Generate certificate
      {:ok, _cert_path, _key_path, _fingerprint} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      # Verify certificate files were created
      cert_path = Path.join(@test_data_dir, "mydia-self-signed.pem")
      key_path = Path.join(@test_data_dir, "mydia-self-signed-key.pem")

      assert File.exists?(cert_path)
      assert File.exists?(key_path)
    end

    test "fingerprint is idempotent on repeated calls" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # First generation
      {:ok, _cert_path1, _key_path1, fingerprint1} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      # Second generation (should reuse existing certificate)
      {:ok, _cert_path2, _key_path2, fingerprint2} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      # Fingerprints should be identical
      assert fingerprint1 == fingerprint2
    end

    test "includes external URL when configured" do
      # Configure external URL
      Application.put_env(:mydia, :direct_urls,
        data_dir: @test_data_dir,
        external_port: 4000,
        external_url: "https://mydia.example.com:443"
      )

      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Detect URLs
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

      # Verify external URL is included
      assert "https://mydia.example.com:443" in direct_urls
    end

    test "includes additional direct URLs when configured" do
      # Configure additional URLs
      Application.put_env(:mydia, :direct_urls,
        data_dir: @test_data_dir,
        external_port: 4000,
        additional_direct_urls: [
          "https://vpn.mydia.local:4000",
          "https://tailscale.mydia.local:4000"
        ]
      )

      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Detect URLs
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

      # Verify additional URLs are included
      assert "https://vpn.mydia.local:4000" in direct_urls
      assert "https://tailscale.mydia.local:4000" in direct_urls
    end

    test "merges all URL sources without duplicates" do
      # Configure overlapping URLs
      Application.put_env(:mydia, :direct_urls,
        data_dir: @test_data_dir,
        external_port: 4000,
        external_url: "https://mydia.example.com:443",
        additional_direct_urls: [
          # Duplicate
          "https://mydia.example.com:443",
          "https://vpn.mydia.local:4000"
        ]
      )

      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Detect URLs
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

      # Count occurrences of the duplicate URL
      duplicate_count =
        direct_urls
        |> Enum.filter(&(&1 == "https://mydia.example.com:443"))
        |> length()

      # Should only appear once
      assert duplicate_count == 1
      assert "https://vpn.mydia.local:4000" in direct_urls
    end

    test "complete refresh flow" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Detect URLs
      direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()
      assert is_list(direct_urls)
      assert direct_urls != []

      # Generate certificate and get fingerprint
      {:ok, _cert_path, _key_path, fingerprint} =
        Mydia.RemoteAccess.Certificates.ensure_certificate()

      assert is_binary(fingerprint)

      # Update config with both
      {:ok, config} = RemoteAccess.update_direct_urls(direct_urls, fingerprint, false)

      # Verify both were stored
      assert config.direct_urls == direct_urls
      assert config.cert_fingerprint == fingerprint
    end
  end

  describe "update_direct_urls/3" do
    test "updates config with URLs and fingerprint" do
      # Initialize remote access config
      {:ok, _config} = RemoteAccess.initialize_keypair()

      direct_urls = [
        "https://192-168-1-100.sslip.io:4000",
        "https://mydia.example.com:443"
      ]

      cert_fingerprint =
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"

      # Update URLs and fingerprint (don't notify relay in test)
      {:ok, config} =
        RemoteAccess.update_direct_urls(direct_urls, cert_fingerprint, false)

      # Verify config was updated
      assert config.direct_urls == direct_urls
      assert config.cert_fingerprint == cert_fingerprint

      # Verify it persists
      persisted_config = RemoteAccess.get_config()
      assert persisted_config.direct_urls == direct_urls
      assert persisted_config.cert_fingerprint == cert_fingerprint
    end

    test "requires list of URLs" do
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Should raise FunctionClauseError for non-list
      assert_raise FunctionClauseError, fn ->
        RemoteAccess.update_direct_urls("not-a-list", "fingerprint", false)
      end
    end

    test "requires binary fingerprint" do
      {:ok, _config} = RemoteAccess.initialize_keypair()

      # Should raise FunctionClauseError for non-binary
      assert_raise FunctionClauseError, fn ->
        RemoteAccess.update_direct_urls([], :not_a_binary, false)
      end
    end
  end
end
