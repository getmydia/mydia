defmodule Mydia.RemoteAccess.ClaimCodeTest do
  # async: false — generate_claim_code/2 reads the remote-access enabled flag,
  # which lives in :persistent_term and is not rolled back by the Ecto sandbox.
  # Mydia.RemoteAccessHelpers documents that any test touching it must be
  # serial and must set and reset it, or another file's value decides these.
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.RemoteAccessHelpers

  alias Mydia.RemoteAccess

  setup do
    bypass = Bypass.open()
    user = user_fixture()

    set_remote_access(true)
    on_exit(&reset_remote_access/0)

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
      # Refute the node address VALUE, not just the field name. The field name
      # never appears regardless of whether the seal works, so asserting on it
      # alone would still pass if the address were posted under another key.
      refute body =~ claim.code
      refute body =~ "node_addr"
      refute body =~ "test-node"
      refute body =~ "test-instance"

      # And prove the lookup key is genuinely derived from the claim code
      # rather than an unrelated random value. That derivation is what lets the
      # player find this entry from the code alone.
      assert {:ok, {derived_lookup_key, _sealed}} =
               Mydia.P2p.seal_pairing_claim(
                 claim.code,
                 ~s({"id":"test-node"}),
                 "test-instance"
               )

      assert derived_lookup_key == decoded["lookup_key"]
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

    test "a code can only ever pair one device", %{
      bypass: bypass,
      claim: claim,
      relay_url: relay_url
    } do
      # The winning consume cleans up its relay entry.
      Bypass.stub(bypass, "DELETE", "/pairing/v2/claim/#{claim.lookup_key}", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      first = device_fixture(claim.user_id)
      second = device_fixture(claim.user_id)

      assert {:ok, _} =
               RemoteAccess.consume_claim_code(claim.code, first.id, relay_url: relay_url)

      # Single use is enforced by the UPDATE predicate, not by the prior read,
      # so a second consumer loses even if it validated concurrently.
      assert {:error, :already_used} =
               RemoteAccess.consume_claim_code(claim.code, second.id, relay_url: relay_url)
    end

    test "a pairing that cannot consume its claim creates no device", %{
      bypass: bypass,
      claim: claim,
      relay_url: relay_url
    } do
      Bypass.stub(bypass, "DELETE", "/pairing/v2/claim/#{claim.lookup_key}", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      device = device_fixture(claim.user_id)

      assert {:ok, _} =
               RemoteAccess.consume_claim_code(claim.code, device.id, relay_url: relay_url)

      # A second live claim, so the "no active claim" gate does not short
      # circuit before complete_pairing reaches device creation. Inserted
      # directly to keep the relay out of it.
      {:ok, _live} =
        %Mydia.RemoteAccess.PairingClaim{}
        |> Mydia.RemoteAccess.PairingClaim.changeset_with_code(%{
          user_id: claim.user_id,
          code: "ZZZZZZ",
          lookup_key: String.duplicate("f", 64),
          expires_at:
            DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:second)
        })
        |> Mydia.Repo.insert()

      before = length(RemoteAccess.list_devices(claim.user_id))

      # complete_pairing inserts the device before consuming, so any failure on
      # the consume must take the device with it. This exercises the shared
      # transaction, though it reaches the failure through validation rather
      # than through a genuine concurrent race, which is not reproducible here.
      assert {:error, _} =
               Mydia.RemoteAccess.Pairing.complete_pairing(claim.code, %{
                 device_name: "Loser",
                 platform: "test"
               })

      assert length(RemoteAccess.list_devices(claim.user_id)) == before
    end

    test "an expired claim cannot be consumed even after validation", %{
      claim: claim,
      relay_url: relay_url
    } do
      device = device_fixture(claim.user_id)

      # Simulate the claim lapsing between validation and the write. The UPDATE
      # guards expiry itself, so the window cannot pair a device late.
      past = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.truncate(:second)

      Mydia.Repo.update_all(
        from(c in Mydia.RemoteAccess.PairingClaim, where: c.id == ^claim.id),
        set: [expires_at: past]
      )

      assert {:error, :expired} =
               RemoteAccess.consume_claim_code(claim.code, device.id, relay_url: relay_url)
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
