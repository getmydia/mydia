defmodule Mydia.P2pPairingSealTest do
  use ExUnit.Case, async: true

  alias Mydia.P2p

  @node_addr ~s({"id":"09ecb63dd2","relay_url":"https://relay.mydia.dev"})
  @instance_id "inst-abc-123"

  test "seals a claim and returns a hex lookup key with a base64url blob" do
    assert {:ok, {lookup_key, sealed}} =
             P2p.seal_pairing_claim("K7RPM2", @node_addr, @instance_id)

    assert String.length(lookup_key) == 64
    assert lookup_key =~ ~r/\A[0-9a-f]{64}\z/
    assert byte_size(sealed) > 0
    refute sealed =~ @node_addr
    refute sealed =~ "K7RPM2"
  end

  test "the lookup key is stable across calls but the blob is not" do
    assert {:ok, {key_a, sealed_a}} =
             P2p.seal_pairing_claim("K7RPM2", @node_addr, @instance_id)

    assert {:ok, {key_b, sealed_b}} =
             P2p.seal_pairing_claim("K7RPM2", @node_addr, @instance_id)

    assert key_a == key_b
    refute sealed_a == sealed_b
  end

  test "normalizes case and dashes before deriving" do
    assert {:ok, {key_a, _}} = P2p.seal_pairing_claim("K7RPM2", @node_addr, @instance_id)
    assert {:ok, {key_b, _}} = P2p.seal_pairing_claim("k7r-pm2", @node_addr, @instance_id)

    assert key_a == key_b
  end

  test "rejects an empty code" do
    assert {:error, reason} = P2p.seal_pairing_claim("  -- ", @node_addr, @instance_id)
    assert reason =~ "empty"
  end
end
