defmodule Mydia.RemoteAccess.CertificatesTest do
  use ExUnit.Case, async: false
  import Bitwise

  alias Mydia.RemoteAccess.Certificates

  @test_data_dir "test/tmp/certificates"

  setup do
    # Clean up test directory before each test
    File.rm_rf!(@test_data_dir)
    File.mkdir_p!(@test_data_dir)

    # Save original config
    original_config = Application.get_env(:mydia, :direct_urls, [])

    # Set test data directory
    Application.put_env(:mydia, :direct_urls, data_dir: @test_data_dir)

    on_exit(fn ->
      # Restore original config
      Application.put_env(:mydia, :direct_urls, original_config)
      # Clean up test directory
      File.rm_rf!(@test_data_dir)
    end)

    :ok
  end

  describe "ensure_certificate/0" do
    test "generates certificate and key files if they don't exist" do
      {:ok, cert_path, key_path, fingerprint} = Certificates.ensure_certificate()

      # Verify files were created
      assert File.exists?(cert_path)
      assert File.exists?(key_path)

      # Verify paths are correct
      assert cert_path == Path.join(@test_data_dir, "mydia-self-signed.pem")
      assert key_path == Path.join(@test_data_dir, "mydia-self-signed-key.pem")

      # Verify fingerprint is a hex string with colons
      assert is_binary(fingerprint)
      assert String.contains?(fingerprint, ":")
      assert String.match?(fingerprint, ~r/^[0-9A-F:]+$/)
    end

    test "returns existing certificate if it already exists" do
      # Generate certificate first time
      {:ok, cert_path1, key_path1, fingerprint1} = Certificates.ensure_certificate()

      # Call again - should return same paths and fingerprint
      {:ok, cert_path2, key_path2, fingerprint2} = Certificates.ensure_certificate()

      assert cert_path1 == cert_path2
      assert key_path1 == key_path2
      assert fingerprint1 == fingerprint2
    end

    test "generated certificate is valid PEM format" do
      {:ok, cert_path, _key_path, _fingerprint} = Certificates.ensure_certificate()

      # Read and parse certificate
      cert_pem = File.read!(cert_path)
      assert String.contains?(cert_pem, "BEGIN CERTIFICATE")
      assert String.contains?(cert_pem, "END CERTIFICATE")

      # Verify it can be decoded
      [{:Certificate, _der_cert, :not_encrypted}] = :public_key.pem_decode(cert_pem)
    end

    test "generated private key is valid PEM format" do
      {:ok, _cert_path, key_path, _fingerprint} = Certificates.ensure_certificate()

      # Read and parse private key
      key_pem = File.read!(key_path)
      # OpenSSL generates PKCS#8 format by default (BEGIN PRIVATE KEY)
      # Can also be PKCS#1 format (BEGIN RSA PRIVATE KEY)
      assert String.contains?(key_pem, "BEGIN PRIVATE KEY") or
               String.contains?(key_pem, "BEGIN RSA PRIVATE KEY")

      assert String.contains?(key_pem, "END PRIVATE KEY") or
               String.contains?(key_pem, "END RSA PRIVATE KEY")

      # Verify it can be decoded
      decoded = :public_key.pem_decode(key_pem)
      assert is_list(decoded)
      assert decoded != []
    end

    test "private key file has restrictive permissions" do
      {:ok, _cert_path, key_path, _fingerprint} = Certificates.ensure_certificate()

      # Check file permissions (should be 0o600 = owner read/write only)
      stat = File.stat!(key_path)
      # On Unix systems, mode will have the permissions bits
      # We check that it's not world-readable
      refute (stat.mode &&& 0o004) != 0
    end

    test "creates data directory if it doesn't exist" do
      # Remove the test directory
      File.rm_rf!(@test_data_dir)
      refute File.exists?(@test_data_dir)

      # ensure_certificate should create it
      {:ok, _cert_path, _key_path, _fingerprint} = Certificates.ensure_certificate()

      assert File.exists?(@test_data_dir)
    end
  end

  describe "compute_fingerprint/1" do
    test "computes correct SHA256 fingerprint" do
      {:ok, cert_path, _key_path, _fingerprint} = Certificates.ensure_certificate()

      fingerprint = Certificates.compute_fingerprint(cert_path)

      # Verify fingerprint format
      assert is_binary(fingerprint)
      assert String.contains?(fingerprint, ":")

      # SHA256 fingerprint should be 32 bytes = 64 hex chars + 31 colons = 95 chars total
      assert String.length(fingerprint) == 95

      # Each segment should be 2 hex characters
      segments = String.split(fingerprint, ":")
      assert length(segments) == 32

      Enum.each(segments, fn segment ->
        assert String.length(segment) == 2
        assert String.match?(segment, ~r/^[0-9A-F]{2}$/)
      end)
    end

    test "returns same fingerprint for same certificate" do
      {:ok, cert_path, _key_path, _fingerprint} = Certificates.ensure_certificate()

      fingerprint1 = Certificates.compute_fingerprint(cert_path)
      fingerprint2 = Certificates.compute_fingerprint(cert_path)

      assert fingerprint1 == fingerprint2
    end

    test "returns nil for non-existent file" do
      fingerprint = Certificates.compute_fingerprint("/non/existent/path.pem")

      assert is_nil(fingerprint)
    end

    test "fingerprint matches ensure_certificate return value" do
      {:ok, cert_path, _key_path, returned_fingerprint} = Certificates.ensure_certificate()

      computed_fingerprint = Certificates.compute_fingerprint(cert_path)

      assert returned_fingerprint == computed_fingerprint
    end
  end
end
