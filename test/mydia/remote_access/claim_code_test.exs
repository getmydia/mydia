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
end
