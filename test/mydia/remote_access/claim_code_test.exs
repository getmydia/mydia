defmodule Mydia.RemoteAccess.ClaimCodeTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures

  alias Mydia.RemoteAccess

  setup do
    bypass = Bypass.open()
    user = user_fixture()

    {:ok,
     bypass: bypass,
     user: user,
     relay_url: "http://localhost:#{bypass.port}",
     pairing_opts: [
       relay_url: "http://localhost:#{bypass.port}",
       node_addr: ~s({"id":"test-node"}),
       instance_id: "test-instance"
     ]}
  end

  describe "generate_claim_code/2" do
    test "posts only a lookup key and a sealed blob to the relay", %{
      bypass: bypass,
      user: user,
      pairing_opts: pairing_opts
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/pairing/v2/claim", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:relay_body, body})
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)
      assert claim.relay_registered

      assert_receive {:relay_body, body}
      decoded = Jason.decode!(body)

      assert Map.keys(decoded) |> Enum.sort() == ["lookup_key", "sealed"]
      assert decoded["lookup_key"] =~ ~r/\A[0-9a-f]{64}\z/

      # The whole point: neither the code nor the node address leaves the host.
      refute body =~ claim.code
      refute body =~ "node_addr"
    end

    test "returns a usable claim when the relay is unreachable", %{
      bypass: bypass,
      user: user,
      pairing_opts: pairing_opts
    } do
      Bypass.down(bypass)

      assert {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

      refute claim.relay_registered
      assert String.length(claim.code) == 6
      assert claim.lookup_key =~ ~r/\A[0-9a-f]{64}\z/
      assert RemoteAccess.get_claim_by_code(claim.code)
    end

    test "returns a usable claim when the relay rejects the request", %{
      bypass: bypass,
      user: user,
      pairing_opts: pairing_opts
    } do
      Bypass.expect_once(bypass, "POST", "/pairing/v2/claim", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)
      refute claim.relay_registered
    end

    test "stores the code and its lookup key locally", %{
      bypass: bypass,
      user: user,
      pairing_opts: pairing_opts
    } do
      Bypass.expect_once(bypass, "POST", "/pairing/v2/claim", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)

      stored = RemoteAccess.get_claim_by_code(claim.code)
      assert stored.lookup_key == claim.lookup_key
      assert stored.user_id == user.id
    end
  end

  describe "consume_claim_code/3" do
    setup %{bypass: bypass, user: user, pairing_opts: pairing_opts} do
      Bypass.expect_once(bypass, "POST", "/pairing/v2/claim", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      {:ok, claim} = RemoteAccess.generate_claim_code(user.id, pairing_opts)
      {:ok, claim: claim}
    end

    test "deletes the sealed claim from the relay", %{
      bypass: bypass,
      claim: claim,
      relay_url: relay_url
    } do
      test_pid = self()
      device = device_fixture(claim.user_id)

      Bypass.expect_once(bypass, "DELETE", "/pairing/v2/claim/#{claim.lookup_key}", fn conn ->
        send(test_pid, :relay_deleted)
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, consumed} =
               RemoteAccess.consume_claim_code(claim.code, device.id, relay_url: relay_url)

      assert consumed.used_at
      assert_receive :relay_deleted
    end

    test "still consumes the claim when the relay delete fails", %{
      bypass: bypass,
      claim: claim,
      relay_url: relay_url
    } do
      Bypass.down(bypass)
      device = device_fixture(claim.user_id)

      assert {:ok, consumed} =
               RemoteAccess.consume_claim_code(claim.code, device.id, relay_url: relay_url)

      assert consumed.used_at
    end
  end

  defp device_fixture(user_id) do
    {:ok, device} =
      RemoteAccess.create_device(%{
        user_id: user_id,
        device_name: "Pairing test device",
        platform: "test",
        token: Ecto.UUID.generate()
      })

    device
  end
end
