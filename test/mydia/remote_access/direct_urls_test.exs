defmodule Mydia.RemoteAccess.DirectUrlsTest do
  # Not async due to persistent_term cache and Application.put_env
  use ExUnit.Case, async: false

  alias Mydia.RemoteAccess.DirectUrls

  describe "build_sslip_url/3" do
    test "builds correct sslip.io HTTP URL from IP tuple" do
      assert DirectUrls.build_sslip_url({192, 168, 1, 100}, :http, 4000) ==
               "http://192-168-1-100.sslip.io:4000"
    end

    test "builds correct sslip.io HTTPS URL from IP tuple" do
      assert DirectUrls.build_sslip_url({192, 168, 1, 100}, :https, 4443) ==
               "https://192-168-1-100.sslip.io:4443"
    end

    test "handles different IP addresses" do
      assert DirectUrls.build_sslip_url({10, 0, 0, 1}, :http, 8080) ==
               "http://10-0-0-1.sslip.io:8080"
    end

    test "handles different ports" do
      assert DirectUrls.build_sslip_url({192, 168, 1, 1}, :https, 443) ==
               "https://192-168-1-1.sslip.io:443"
    end
  end

  describe "detect_local_urls/0" do
    test "returns list of URLs" do
      urls = DirectUrls.detect_local_urls()

      assert is_list(urls)
      # URLs should be strings - HTTP by default (HTTPS only when https_port configured)
      Enum.each(urls, fn url ->
        assert is_binary(url)
        assert String.starts_with?(url, "http://") or String.starts_with?(url, "https://")
        assert String.contains?(url, ".sslip.io:")
      end)
    end

    test "filters out loopback addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 127.x.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "127-")
             end)
    end

    test "filters out link-local addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 169.254.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "169-254-")
             end)
    end

    test "filters out docker bridge addresses" do
      urls = DirectUrls.detect_local_urls()

      # Should not contain 172.17.x.x addresses
      refute Enum.any?(urls, fn url ->
               String.contains?(url, "172-17-")
             end)
    end
  end

  describe "detect_all/0" do
    setup do
      # Save original config
      original_config = Application.get_env(:mydia, :direct_urls, [])

      on_exit(fn ->
        # Restore original config
        Application.put_env(:mydia, :direct_urls, original_config)
      end)

      %{original_config: original_config}
    end

    test "includes local URLs" do
      Application.put_env(:mydia, :direct_urls, external_port: 4000)

      urls = DirectUrls.detect_all()

      assert is_list(urls)
      assert urls != []
    end

    test "includes external URL when configured" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: "https://example.com:443"
      )

      urls = DirectUrls.detect_all()

      assert "https://example.com:443" in urls
    end

    test "includes additional direct URLs when configured" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        additional_direct_urls: [
          "https://custom1.example.com:443",
          "https://custom2.example.com:443"
        ]
      )

      urls = DirectUrls.detect_all()

      assert "https://custom1.example.com:443" in urls
      assert "https://custom2.example.com:443" in urls
    end

    test "merges all URL sources without duplicates" do
      # Set up config with overlapping URLs
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: "https://example.com:443",
        additional_direct_urls: [
          # Duplicate of external_url
          "https://example.com:443",
          "https://custom.example.com:443"
        ]
      )

      urls = DirectUrls.detect_all()

      # Count occurrences of the duplicate URL
      duplicate_count =
        urls
        |> Enum.filter(&(&1 == "https://example.com:443"))
        |> length()

      # Should only appear once
      assert duplicate_count == 1
      assert "https://custom.example.com:443" in urls
    end

    test "filters out nil values" do
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: nil,
        additional_direct_urls: []
      )

      urls = DirectUrls.detect_all()

      refute nil in urls
      assert is_list(urls)
    end

    test "returns empty list when no URLs available" do
      # This is hard to test since we can't mock :inet.getifaddrs/0,
      # but we can at least verify it doesn't crash
      Application.put_env(:mydia, :direct_urls,
        external_port: 4000,
        external_url: nil,
        additional_direct_urls: []
      )

      urls = DirectUrls.detect_all()

      assert is_list(urls)
    end
  end

  describe "detect_public_ip/0" do
    setup do
      # Save original config
      original_config = Application.get_env(:mydia, :direct_urls, [])

      # Clear cache before each test
      DirectUrls.clear_public_ip_cache()

      on_exit(fn ->
        # Restore original config and clear cache
        Application.put_env(:mydia, :direct_urls, original_config)
        DirectUrls.clear_public_ip_cache()
      end)

      %{original_config: original_config}
    end

    # Genuinely reaches the public internet (ifconfig.me/icanhazip.com/
    # api.ipify.org) rather than a stub, so it stays out of the default run
    # like every other :external test — Mydia.RelayGuard refuses it
    # otherwise (#530).
    @tag :external
    test "returns {:ok, ip} when successful" do
      # Enable public IP detection
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: true)

      # This is an integration test - it makes real HTTP calls
      # Skip in CI environments or when network is unavailable
      case DirectUrls.detect_public_ip() do
        {:ok, ip} ->
          assert is_binary(ip)
          # Validate IP format (should be parseable)
          assert {:ok, _} = ip |> String.to_charlist() |> :inet.parse_address()

        {:error, :all_services_failed} ->
          # Network unavailable, skip assertion
          :ok
      end
    end

    test "returns {:error, :disabled} when public IP detection is disabled" do
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: false)

      assert {:error, :disabled} = DirectUrls.detect_public_ip()
    end

    test "caches successful results" do
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: true)

      # First call
      result1 = DirectUrls.detect_public_ip()

      # Second call should return the same result (cached)
      result2 = DirectUrls.detect_public_ip()

      assert result1 == result2
    end
  end

  describe "detect_public_url/0" do
    setup do
      original_config = Application.get_env(:mydia, :direct_urls, [])
      DirectUrls.clear_public_ip_cache()

      on_exit(fn ->
        Application.put_env(:mydia, :direct_urls, original_config)
        DirectUrls.clear_public_ip_cache()
      end)

      %{original_config: original_config}
    end

    test "returns sslip.io URL on success" do
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: true, http_port: 4443)

      case DirectUrls.detect_public_url() do
        {:ok, url} ->
          assert is_binary(url)
          # HTTP URLs are primary (HTTPS only when https_port configured)
          assert String.starts_with?(url, "http://")
          assert String.contains?(url, ".sslip.io:")
          assert String.ends_with?(url, ":4443")

        {:error, :detection_failed} ->
          # Network unavailable or public IP detection failed
          :ok
      end
    end

    test "uses http_port from config" do
      Application.put_env(:mydia, :direct_urls,
        public_ip_enabled: true,
        http_port: 8443
      )

      case DirectUrls.detect_public_url() do
        {:ok, url} ->
          # Should use http_port (8443)
          assert String.ends_with?(url, ":8443")

        {:error, :detection_failed} ->
          # Network unavailable or public IP detection failed
          :ok
      end
    end

    test "returns error when disabled" do
      Application.put_env(:mydia, :direct_urls, public_ip_enabled: false)

      # detect_public_url returns :detection_failed when no public URLs are available
      # The :disabled error is returned by detect_public_ip, but detect_public_url
      # returns :detection_failed when detect_public_urls returns an empty list
      assert {:error, :detection_failed} = DirectUrls.detect_public_url()
    end
  end

  describe "clear_public_ip_cache/0" do
    test "clears the cache successfully" do
      # Just ensure it doesn't crash
      assert :ok = DirectUrls.clear_public_ip_cache()
    end

    test "can be called multiple times" do
      assert :ok = DirectUrls.clear_public_ip_cache()
      assert :ok = DirectUrls.clear_public_ip_cache()
    end
  end
end
