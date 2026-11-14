defmodule MetadataRelay.Backup.AuthTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Backup.Auth

  @now 1_800_000_000_000

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp sign(priv, method, path, body, ts) do
    hash = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
    :crypto.sign(:eddsa, :none, "#{method}\n#{path}\n#{hash}\n#{ts}", [priv, :ed25519])
  end

  defp header(pub, sig, ts), do: "MydiaSig signer=#{b64(pub)}, ts=#{ts}, sig=#{b64(sig)}"

  defp parsed(method, path, body, ts) do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    sig = sign(priv, method, path, body, ts)
    {:ok, p} = Auth.parse(header(pub, sig, ts))
    p
  end

  test "valid signature verifies" do
    p = parsed("PUT", "/api/v1/backup/x", "body", @now)
    assert byte_size(p.signer) == 32
    assert byte_size(p.sig) == 64
    assert p.ts == @now
    assert :ok = Auth.verify(p, "PUT", "/api/v1/backup/x", "body", @now)
  end

  test "changed body, path, method or ts fails" do
    p = parsed("PUT", "/p", "body", @now)
    assert {:error, :bad_signature} = Auth.verify(p, "PUT", "/p", "other", @now)
    assert {:error, :bad_signature} = Auth.verify(p, "PUT", "/q", "body", @now)
    assert {:error, :bad_signature} = Auth.verify(p, "GET", "/p", "body", @now)
    assert {:error, :bad_signature} = Auth.verify(%{p | ts: @now + 1}, "PUT", "/p", "body", @now)
  end

  test "skew beyond 5 minutes is rejected, exactly 5 minutes is fine" do
    p = parsed("GET", "/p", "", @now)
    assert :ok = Auth.verify(p, "GET", "/p", "", @now + 300_000)
    assert {:error, :skew} = Auth.verify(p, "GET", "/p", "", @now + 300_001)
    assert {:error, :skew} = Auth.verify(p, "GET", "/p", "", @now - 300_001)
  end

  test "malformed headers" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    sig = sign(priv, "GET", "/p", "", @now)
    assert {:error, :malformed} = Auth.parse(header(binary_part(pub, 0, 31), sig, @now))
    assert {:error, :malformed} = Auth.parse(header(pub, binary_part(sig, 0, 63), @now))
    assert {:error, :malformed} = Auth.parse("Bearer abc")
    assert {:error, :malformed} = Auth.parse("MydiaSig signer=#{b64(pub)}, sig=#{b64(sig)}")

    assert {:error, :malformed} =
             Auth.parse("MydiaSig signer=#{b64(pub)}, ts=abc, sig=#{b64(sig)}")
  end

  test "nil header is missing" do
    assert {:error, :missing} = Auth.parse(nil)
  end

  test "padded base64url is tolerated" do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    sig = sign(priv, "GET", "/p", "", @now)
    h = "MydiaSig signer=#{Base.url_encode64(pub)}, ts=#{@now}, sig=#{Base.url_encode64(sig)}"
    assert {:ok, p} = Auth.parse(h)
    assert :ok = Auth.verify(p, "GET", "/p", "", @now)
  end
end
