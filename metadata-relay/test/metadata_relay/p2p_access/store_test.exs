defmodule MetadataRelay.P2pAccess.StoreTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias MetadataRelay.P2pAccess.Store

  setup do
    Store.init_tables()
    :ets.delete_all_objects(:p2p_sightings)
    :ets.delete_all_objects(:p2p_blocked)

    original_cap = Application.get_env(:metadata_relay, :p2p_max_sightings)
    on_exit(fn -> Application.put_env(:metadata_relay, :p2p_max_sightings, original_cap) end)

    :ok
  end

  defp endpoint_id(n),
    do: String.pad_leading(Integer.to_string(n, 16), 64, "0") |> String.downcase()

  # The database-failure tests deliberately check the sandbox connection back
  # in mid-test. Restoring it from on_exit rather than from a trailing
  # statement means a failing assertion cannot leave the sandbox checked in
  # and poison every test that runs after it.
  defp restore_sandbox_on_exit do
    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})
    end)
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      result = fun.()
      unless result, do: Process.sleep(10)
      result
    end)
    |> Enum.find(fn result ->
      result or System.monotonic_time(:millisecond) > deadline
    end)
  end

  test "records a first sighting with count 1" do
    id = endpoint_id(1)

    assert :ok = Store.record_sighting(id)
    assert {:ok, {first_seen, last_seen, 1}} = Store.lookup_sighting(id)
    assert first_seen == last_seen
  end

  test "increments the connection count on repeat sightings" do
    id = endpoint_id(2)

    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)

    assert {:ok, {_first, _last, 3}} = Store.lookup_sighting(id)
  end

  test "preserves first_seen across repeat sightings" do
    id = endpoint_id(3)

    :ok = Store.record_sighting(id)
    {:ok, {first_seen, _, _}} = Store.lookup_sighting(id)

    :ok = Store.record_sighting(id)

    assert {:ok, {^first_seen, _, 2}} = Store.lookup_sighting(id)
  end

  test "stops recording new endpoints once the cap is reached" do
    Application.put_env(:metadata_relay, :p2p_max_sightings, 2)

    :ok = Store.record_sighting(endpoint_id(10))
    :ok = Store.record_sighting(endpoint_id(11))
    :ok = Store.record_sighting(endpoint_id(12))

    assert Store.sighting_count() == 2
    assert Store.lookup_sighting(endpoint_id(12)) == :error
  end

  test "keeps updating known endpoints after the cap is reached" do
    Application.put_env(:metadata_relay, :p2p_max_sightings, 1)

    id = endpoint_id(20)
    :ok = Store.record_sighting(id)
    :ok = Store.record_sighting(id)

    assert Store.sighting_count() == 1
    assert {:ok, {_first, _last, 2}} = Store.lookup_sighting(id)
  end

  describe "blocklist" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})
      MetadataRelay.Repo.delete_all(MetadataRelay.P2pAccess.Block)
      :ok
    end

    test "an unknown endpoint is not blocked" do
      refute Store.blocked?(endpoint_id(30))
    end

    test "put_block marks the endpoint blocked in ETS" do
      id = endpoint_id(31)

      assert :ok = Store.put_block(id, "bandwidth abuse")
      assert Store.blocked?(id)
    end

    test "put_block persists the block to the database" do
      id = endpoint_id(32)

      assert :ok = Store.put_block(id, "bandwidth abuse")

      assert %MetadataRelay.P2pAccess.Block{reason: "bandwidth abuse"} =
               MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Block, id)
    end

    test "delete_block clears ETS and the database" do
      id = endpoint_id(33)
      :ok = Store.put_block(id, "mistake")

      assert :ok = Store.delete_block(id)

      refute Store.blocked?(id)
      assert MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Block, id) == nil
    end

    test "reload_blocks repopulates ETS from the database" do
      id = endpoint_id(34)
      :ok = Store.put_block(id, "bandwidth abuse")

      # Simulate a fresh boot where ETS is empty but the row survives.
      :ets.delete_all_objects(:p2p_blocked)
      refute Store.blocked?(id)

      assert :ok = Store.reload_blocks()
      assert Store.blocked?(id)
    end

    test "a failed blocklist load reschedules itself and repopulates ETS when it succeeds" do
      original = Application.get_env(:metadata_relay, :p2p_reload_retry_interval_ms)

      on_exit(fn ->
        Application.put_env(:metadata_relay, :p2p_reload_retry_interval_ms, original)
      end)

      Application.put_env(:metadata_relay, :p2p_reload_retry_interval_ms, 50)
      restore_sandbox_on_exit()

      # Take the sandbox connection away so the Store's Repo.all/1 raises,
      # driving the boot-failure branch rather than the happy path. A Store
      # that gave up here would run with an empty blocklist forever, which
      # silently restores access for every revoked endpoint.
      Ecto.Adapters.SQL.Sandbox.checkin(MetadataRelay.Repo)
      send(Store, :reload_blocks)
      # The GenServer handles messages in order, so this returns only once
      # the failed attempt has been processed and the retry scheduled.
      _ = :sys.get_state(Store)

      # Hand the sandbox back so the scheduled retry finds a usable
      # connection, and add the block the retry is expected to pick up.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})

      id = endpoint_id(36)

      MetadataRelay.Repo.insert!(%MetadataRelay.P2pAccess.Block{
        endpoint_id: id,
        reason: "bandwidth abuse",
        blocked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      refute Store.blocked?(id)
      assert eventually(fn -> Store.blocked?(id) end)
    end

    test "put_block is idempotent and updates the reason" do
      id = endpoint_id(35)

      :ok = Store.put_block(id, "first reason")
      :ok = Store.put_block(id, "second reason")

      assert %MetadataRelay.P2pAccess.Block{reason: "second reason"} =
               MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Block, id)
    end
  end

  describe "flush and prune" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})
      MetadataRelay.Repo.delete_all(MetadataRelay.P2pAccess.Sighting)

      # The Store is a singleton that outlives every test, and a flush only
      # writes sightings touched since the previous one. Reset that window so
      # a test starts from a clean one instead of inheriting whatever the
      # previously run test left behind.
      :sys.replace_state(Store, fn state -> %{state | last_flush_at: 0} end)

      original = Application.get_env(:metadata_relay, :p2p_retention_seconds)
      on_exit(fn -> Application.put_env(:metadata_relay, :p2p_retention_seconds, original) end)

      :ok
    end

    test "flush writes ETS sightings to the database" do
      id = endpoint_id(40)
      :ok = Store.record_sighting(id)
      :ok = Store.record_sighting(id)

      assert {:ok, 1} = Store.flush_now()

      assert %MetadataRelay.P2pAccess.Sighting{conn_count: 2} =
               MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Sighting, id)
    end

    test "flush updates an existing row rather than failing on conflict" do
      id = endpoint_id(41)
      :ok = Store.record_sighting(id)
      {:ok, 1} = Store.flush_now()

      :ok = Store.record_sighting(id)
      assert {:ok, 1} = Store.flush_now()

      assert %MetadataRelay.P2pAccess.Sighting{conn_count: 2} =
               MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Sighting, id)
    end

    test "flush with no sightings writes nothing" do
      assert {:ok, 0} = Store.flush_now()
    end

    test "prune removes sightings older than the retention window" do
      stale = endpoint_id(42)
      fresh = endpoint_id(43)
      now = System.system_time(:second)

      :ets.insert(:p2p_sightings, {stale, now - 100, now - 100, 1})
      :ets.insert(:p2p_sightings, {fresh, now, now, 1})

      Application.put_env(:metadata_relay, :p2p_retention_seconds, 50)

      assert {:ok, 1} = Store.prune_now()
      assert Store.lookup_sighting(stale) == :error
      assert {:ok, _} = Store.lookup_sighting(fresh)
    end

    test "prune also removes the database rows" do
      stale = endpoint_id(44)
      now = System.system_time(:second)

      :ets.insert(:p2p_sightings, {stale, now - 100, now - 100, 1})
      {:ok, 1} = Store.flush_now()

      Application.put_env(:metadata_relay, :p2p_retention_seconds, 50)
      {:ok, 1} = Store.prune_now()

      assert MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Sighting, stale) == nil
    end

    test "flush chunks a batch larger than one chunk and writes every row" do
      now = System.system_time(:second)
      rows = for n <- 1..3_000, do: {endpoint_id(100_000 + n), now, now, 1}
      true = :ets.insert(:p2p_sightings, rows)

      # A single insert_all/3 binds 4 parameters per row against SQLite's
      # 32_766 limit, so this must be split across statements and the counts
      # summed rather than reporting only the last chunk.
      assert {:ok, 3_000} = Store.flush_now()

      assert MetadataRelay.Repo.aggregate(MetadataRelay.P2pAccess.Sighting, :count) == 3_000
    end

    test "a second flush writes only what changed since the first" do
      old = endpoint_id(47)
      now = System.system_time(:second)
      :ets.insert(:p2p_sightings, {old, now - 10, now - 10, 1})

      assert {:ok, 1} = Store.flush_now()

      # Nothing has been touched since, so the delta is empty.
      assert {:ok, 0} = Store.flush_now()

      fresh = endpoint_id(48)
      :ok = Store.record_sighting(fresh)

      assert {:ok, 1} = Store.flush_now()

      assert %MetadataRelay.P2pAccess.Sighting{} =
               MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Sighting, fresh)
    end

    test "seeded sightings resume the persisted conn_count instead of resetting" do
      id = endpoint_id(49)
      :ok = Store.record_sighting(id)
      :ok = Store.record_sighting(id)
      {:ok, 1} = Store.flush_now()

      # Simulate a restart: ETS starts empty, the row survives on disk.
      :ets.delete_all_objects(:p2p_sightings)
      assert :ok = Store.seed_sightings()
      assert {:ok, {_first, _last, 2}} = Store.lookup_sighting(id)

      :ok = Store.record_sighting(id)

      assert {:ok, {_first, _last, 3}} = Store.lookup_sighting(id)
      assert {:ok, 1} = Store.flush_now()
      assert %{conn_count: 3} = MetadataRelay.Repo.get(MetadataRelay.P2pAccess.Sighting, id)
    end

    test "seeding respects the sighting cap" do
      now = System.system_time(:second)

      for n <- 1..5 do
        :ets.insert(:p2p_sightings, {endpoint_id(50 + n), now - n, now - n, 1})
      end

      {:ok, 5} = Store.flush_now()
      :ets.delete_all_objects(:p2p_sightings)

      Application.put_env(:metadata_relay, :p2p_max_sightings, 2)

      assert :ok = Store.seed_sightings()
      assert Store.sighting_count() == 2
      # Most recently seen first, so the two newest rows are the ones kept.
      assert {:ok, _} = Store.lookup_sighting(endpoint_id(51))
      assert {:ok, _} = Store.lookup_sighting(endpoint_id(52))
    end

    test "flush degrades to {:ok, 0} and keeps the Store alive when the database write fails" do
      restore_sandbox_on_exit()

      id = endpoint_id(45)
      :ok = Store.record_sighting(id)

      pid = Process.whereis(Store)
      # Take the sandbox connection away so the Store's Repo.insert_all/3
      # call has no ownership to use and raises DBConnection.OwnershipError,
      # exercising the rescue in do_flush/0 instead of the happy path.
      Ecto.Adapters.SQL.Sandbox.checkin(MetadataRelay.Repo)

      assert {:ok, 0} = Store.flush_now()

      # The point of the rescue: a failed database write must not take the
      # Store down with it, since it owns the ETS tables the request path
      # depends on.
      assert Process.whereis(Store) == pid
      assert Process.alive?(pid)

      # Leave the sandbox usable again for any later use in this test.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})
    end

    test "prune degrades to a rescued {:ok, count} and keeps the Store alive when the database delete fails" do
      stale = endpoint_id(46)
      now = System.system_time(:second)

      :ets.insert(:p2p_sightings, {stale, now - 100, now - 100, 1})
      Application.put_env(:metadata_relay, :p2p_retention_seconds, 50)

      pid = Process.whereis(Store)
      # Take the sandbox connection away so the Store's Repo.delete_all/1
      # call has no ownership to use and raises DBConnection.OwnershipError,
      # exercising the rescue in do_prune/0 instead of the happy path.
      Ecto.Adapters.SQL.Sandbox.checkin(MetadataRelay.Repo)

      assert {:ok, 1} = Store.prune_now()

      # ETS eviction already happened before the database delete was
      # attempted, so the count reflects it regardless of the database
      # outcome.
      assert Store.lookup_sighting(stale) == :error

      # The point of the rescue: a failed database delete must not take the
      # Store down with it, since it owns the ETS tables the request path
      # depends on.
      assert Process.whereis(Store) == pid
      assert Process.alive?(pid)

      # Leave the sandbox usable again for any later use in this test.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MetadataRelay.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(MetadataRelay.Repo, {:shared, self()})
    end
  end
end
