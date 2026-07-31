defmodule MetadataRelay.P2pAccessTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.P2pAccess
  alias MetadataRelay.P2pAccess.Store

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})

    Store.init_tables()
    :ets.delete_all_objects(:p2p_sightings)
    :ets.delete_all_objects(:p2p_blocked)
    MetadataRelay.Repo.delete_all(MetadataRelay.P2pAccess.Block)

    original = Application.get_env(:metadata_relay, :p2p_access_bearer_tokens)
    on_exit(fn -> Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, original) end)

    :ok
  end

  defp endpoint_id(n),
    do: String.pad_leading(Integer.to_string(n, 16), 64, "0") |> String.downcase()

  describe "normalize_endpoint_id/1" do
    test "accepts 64 hex characters" do
      assert {:ok, _} = P2pAccess.normalize_endpoint_id(endpoint_id(1))
    end

    test "downcases mixed-case input" do
      upper = String.duplicate("AB", 32)
      assert {:ok, lower} = P2pAccess.normalize_endpoint_id(upper)
      assert lower == String.duplicate("ab", 32)
    end

    test "rejects a short id" do
      assert :error = P2pAccess.normalize_endpoint_id("abc")
    end

    test "rejects 63 hex characters, one short of the boundary" do
      assert :error = P2pAccess.normalize_endpoint_id(String.duplicate("a", 63))
    end

    test "rejects 65 hex characters, one over the boundary" do
      assert :error = P2pAccess.normalize_endpoint_id(String.duplicate("a", 65))
    end

    test "rejects non-hex characters" do
      assert :error = P2pAccess.normalize_endpoint_id(String.duplicate("z", 64))
    end

    test "rejects a nil id" do
      assert :error = P2pAccess.normalize_endpoint_id(nil)
    end
  end

  describe "authorize/1" do
    test "allows an unknown endpoint" do
      assert :allow = P2pAccess.authorize(endpoint_id(2))
    end

    test "records a sighting for an allowed endpoint" do
      id = endpoint_id(3)
      :allow = P2pAccess.authorize(id)

      assert {:ok, {_first, _last, 1}} = Store.lookup_sighting(id)
    end

    test "denies a blocked endpoint" do
      id = endpoint_id(4)
      :ok = P2pAccess.block(id, "bandwidth abuse")

      assert :deny = P2pAccess.authorize(id)
    end

    test "denies a blocked endpoint even when the caller sends a different case" do
      id = endpoint_id(10)
      :ok = P2pAccess.block(id, "bandwidth abuse")

      assert :deny = P2pAccess.authorize(String.upcase(id))
    end

    test "still records a sighting for a blocked endpoint" do
      id = endpoint_id(5)
      :ok = P2pAccess.block(id, "bandwidth abuse")
      :deny = P2pAccess.authorize(id)

      assert {:ok, {_first, _last, 1}} = Store.lookup_sighting(id)
    end

    test "allows again after unblocking" do
      id = endpoint_id(6)
      :ok = P2pAccess.block(id, "mistake")
      :deny = P2pAccess.authorize(id)

      :ok = P2pAccess.unblock(id)

      assert :allow = P2pAccess.authorize(id)
    end
  end

  describe "valid_bearer?/1" do
    test "accepts a configured token" do
      Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, ["secret-one"])
      assert P2pAccess.valid_bearer?("secret-one")
    end

    test "accepts any token in a rotation list" do
      Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, ["old", "new"])
      assert P2pAccess.valid_bearer?("old")
      assert P2pAccess.valid_bearer?("new")
    end

    test "rejects an unconfigured token" do
      Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, ["secret-one"])
      refute P2pAccess.valid_bearer?("wrong")
    end

    test "rejects nil" do
      Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, ["secret-one"])
      refute P2pAccess.valid_bearer?(nil)
    end

    test "rejects everything when no tokens are configured" do
      Application.put_env(:metadata_relay, :p2p_access_bearer_tokens, [])
      refute P2pAccess.valid_bearer?("anything")
      refute P2pAccess.valid_bearer?("")
    end
  end

  describe "block/2 and unblock/1" do
    test "rejects a malformed endpoint id" do
      assert {:error, :invalid_endpoint_id} = P2pAccess.block("nope", "reason")
      assert {:error, :invalid_endpoint_id} = P2pAccess.unblock("nope")
    end
  end

  describe "list_recent/1" do
    test "returns endpoints ordered by most recent activity" do
      old = endpoint_id(7)
      recent = endpoint_id(8)
      now = System.system_time(:second)

      :ets.insert(:p2p_sightings, {old, now - 100, now - 100, 1})
      :ets.insert(:p2p_sightings, {recent, now, now, 5})

      assert [%{endpoint_id: ^recent}, %{endpoint_id: ^old}] = P2pAccess.list_recent(10)
    end

    test "marks blocked endpoints" do
      id = endpoint_id(9)
      :allow = P2pAccess.authorize(id)
      :ok = P2pAccess.block(id, "bandwidth abuse")

      assert [%{endpoint_id: ^id, blocked: true}] = P2pAccess.list_recent(10)
    end

    test "includes endpoints seeded from the database at boot" do
      id = endpoint_id(11)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      MetadataRelay.Repo.delete_all(MetadataRelay.P2pAccess.Sighting)

      MetadataRelay.Repo.insert!(%MetadataRelay.P2pAccess.Sighting{
        endpoint_id: id,
        first_seen: now,
        last_seen: now,
        conn_count: 7
      })

      # Simulate a restart: ETS starts empty, the rows survive on disk.
      # Without the boot seed an operator investigating an incident would
      # only see endpoints seen since the last deploy.
      :ets.delete_all_objects(:p2p_sightings)
      assert :ok = Store.seed_sightings()

      assert [%{endpoint_id: ^id, conn_count: 7}] = P2pAccess.list_recent(10)
    end

    test "honours the limit" do
      now = System.system_time(:second)

      for n <- 100..110 do
        :ets.insert(:p2p_sightings, {endpoint_id(n), now, now, 1})
      end

      assert length(P2pAccess.list_recent(3)) == 3
    end
  end
end
