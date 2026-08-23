defmodule MetadataRelay.Cache.InMemoryTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.Cache.InMemory

  setup do
    # Ensure cache is running - it may already be started by the application
    case GenServer.whereis(InMemory) do
      nil ->
        # Not running, start it for tests
        {:ok, _pid} = start_supervised(InMemory)

      _pid ->
        # Already running (started by application), just use it
        :ok
    end

    # Clear cache for a fresh state each test
    InMemory.clear()

    :ok
  end

  describe "get/1 and put/3" do
    test "returns error for missing keys" do
      assert {:error, :not_found} = InMemory.get("nonexistent")
    end

    test "stores and retrieves values" do
      assert :ok = InMemory.put("test_key", "test_value", 60_000)
      assert {:ok, "test_value"} = InMemory.get("test_key")
    end

    test "stores complex data structures" do
      complex_value = %{
        nested: %{data: [1, 2, 3]},
        tuple: {"a", "b"},
        list: [%{id: 1}, %{id: 2}]
      }

      assert :ok = InMemory.put("complex", complex_value, 60_000)
      assert {:ok, ^complex_value} = InMemory.get("complex")
    end

    test "multiple put operations to same key updates value" do
      assert :ok = InMemory.put("key", "value1", 60_000)
      assert {:ok, "value1"} = InMemory.get("key")

      assert :ok = InMemory.put("key", "value2", 60_000)
      assert {:ok, "value2"} = InMemory.get("key")
    end

    test "stores multiple independent keys" do
      assert :ok = InMemory.put("key1", "value1", 60_000)
      assert :ok = InMemory.put("key2", "value2", 60_000)
      assert :ok = InMemory.put("key3", "value3", 60_000)

      assert {:ok, "value1"} = InMemory.get("key1")
      assert {:ok, "value2"} = InMemory.get("key2")
      assert {:ok, "value3"} = InMemory.get("key3")
    end
  end

  describe "TTL expiration" do
    test "expired entries return not found" do
      # Put with 100ms TTL
      assert :ok = InMemory.put("short_lived", "value", 100)

      # Should be available immediately
      assert {:ok, "value"} = InMemory.get("short_lived")

      # Wait for expiration
      Process.sleep(150)

      # Should be expired
      assert {:error, :not_found} = InMemory.get("short_lived")
    end

    test "expired entries are cleaned up on access" do
      assert :ok = InMemory.put("expired", "value", 50)
      Process.sleep(100)

      # First access should detect expiration and delete
      assert {:error, :not_found} = InMemory.get("expired")

      # Stats should reflect a miss
      stats = InMemory.stats()
      assert stats.misses > 0
    end

    test "entries with long TTL remain accessible" do
      # 10 second TTL
      assert :ok = InMemory.put("long_lived", "value", 10_000)

      # Should still be available after 100ms
      Process.sleep(100)
      assert {:ok, "value"} = InMemory.get("long_lived")
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      assert :ok = InMemory.put("key1", "value1", 60_000)
      assert :ok = InMemory.put("key2", "value2", 60_000)
      assert :ok = InMemory.put("key3", "value3", 60_000)

      assert :ok = InMemory.clear()

      assert {:error, :not_found} = InMemory.get("key1")
      assert {:error, :not_found} = InMemory.get("key2")
      assert {:error, :not_found} = InMemory.get("key3")
    end

    test "cache works after clear" do
      assert :ok = InMemory.put("before_clear", "value", 60_000)
      assert :ok = InMemory.clear()

      assert :ok = InMemory.put("after_clear", "new_value", 60_000)
      assert {:ok, "new_value"} = InMemory.get("after_clear")
    end
  end

  describe "stats/0" do
    test "tracks hits and misses" do
      # Start with clean stats
      InMemory.clear()

      # Generate some misses
      InMemory.get("miss1")
      InMemory.get("miss2")

      # Generate some hits
      InMemory.put("hit_key", "value", 60_000)
      InMemory.get("hit_key")
      InMemory.get("hit_key")

      stats = InMemory.stats()

      assert stats.adapter == "in_memory"
      assert stats.misses >= 2
      assert stats.hits >= 2
      assert stats.total_requests >= 4
      assert is_float(stats.hit_rate_pct)
    end

    test "reports cache size and memory usage" do
      InMemory.clear()

      # Add some entries
      for i <- 1..10 do
        InMemory.put("key_#{i}", "value_#{i}", 60_000)
      end

      stats = InMemory.stats()

      assert stats.size == 10
      assert stats.max_entries == 20_000
      assert is_number(stats.memory_mb)
      assert is_number(stats.memory_bytes)
      assert is_float(stats.utilization_pct)
      assert stats.utilization_pct > 0.0
    end

    test "calculates hit rate correctly" do
      InMemory.clear()

      # 1 hit, 1 miss = 50% hit rate
      InMemory.get("miss")
      InMemory.put("hit", "value", 60_000)
      InMemory.get("hit")

      stats = InMemory.stats()
      assert stats.hits >= 1
      assert stats.misses >= 1
      # Hit rate should be around 50%
      assert stats.hit_rate_pct >= 30.0 and stats.hit_rate_pct <= 70.0
    end
  end

  describe "LRU eviction" do
    test "evicts oldest entry when max capacity reached" do
      InMemory.clear()

      # Note: We can't easily test the actual 20k limit without filling it up
      # but we can test the eviction logic by observing behavior
      # This test verifies the mechanism works, not the exact threshold

      # Fill cache with a reasonable number of entries
      for i <- 1..100 do
        InMemory.put("key_#{i}", "value_#{i}", 60_000)
      end

      stats = InMemory.stats()
      assert stats.size == 100

      # All entries should be retrievable since we're under limit
      assert {:ok, "value_1"} = InMemory.get("key_1")
      assert {:ok, "value_100"} = InMemory.get("key_100")
    end

    # Regression guard for T-263: eviction must be genuinely oldest-first,
    # not whatever key a plain `:set`'s `:ets.first/1` happens to hash to
    # first. `@max_entries` is overridden via config so this can exercise
    # real evictions without inserting 20,000 rows.
    test "evicts entries in true insertion order, not ETS hash order" do
      InMemory.clear()
      Application.put_env(:metadata_relay, :cache_max_entries, 5)
      on_exit(fn -> Application.delete_env(:metadata_relay, :cache_max_entries) end)

      for i <- 0..9 do
        InMemory.put("key_#{i}", "value_#{i}", 60_000)
      end

      stats = InMemory.stats()
      assert stats.size == 5

      # Only the five most recently inserted keys should survive.
      for i <- 0..4 do
        assert {:error, :not_found} = InMemory.get("key_#{i}"),
               "expected key_#{i} to have been evicted as the oldest entry"
      end

      for i <- 5..9 do
        expected = "value_#{i}"

        assert {:ok, ^expected} = InMemory.get("key_#{i}"),
               "expected key_#{i} (recently inserted) to survive eviction"
      end
    end

    test "re-inserting an existing key refreshes its position instead of leaking a stale eviction slot" do
      InMemory.clear()
      Application.put_env(:metadata_relay, :cache_max_entries, 3)
      on_exit(fn -> Application.delete_env(:metadata_relay, :cache_max_entries) end)

      InMemory.put("a", 1, 60_000)
      InMemory.put("b", 2, 60_000)
      InMemory.put("c", 3, 60_000)

      # Touch "a" again so it becomes the most recently inserted key.
      InMemory.put("a", "updated", 60_000)

      # Capacity is still 3, so the next insert evicts the true oldest ("b"),
      # not "a" (which would happen if the refreshed insert left its old
      # order-table slot behind).
      InMemory.put("d", 4, 60_000)

      assert {:ok, "updated"} = InMemory.get("a")
      assert {:error, :not_found} = InMemory.get("b")
      assert {:ok, 3} = InMemory.get("c")
      assert {:ok, 4} = InMemory.get("d")
    end
  end

  describe "order-table race safety" do
    # Regression guard: two concurrent `put/3` calls for the same key can
    # each insert their own `{seq, key}` row into the order table (the
    # `drop_order_entry/1` lookup that's supposed to remove the *old* row
    # is not atomic with a sibling call's own insert), while the main
    # table -- a `:set` -- ends up keeping only the last writer's record.
    # That leaves an orphaned order-table row pointing at a `seq` the main
    # table no longer has under that key. This test reproduces that exact
    # end state directly (rather than relying on real scheduler timing to
    # hit a microsecond window) and checks that a subsequent eviction,
    # walking the order table oldest-first, doesn't use the stale row to
    # delete the *current*, live record for the key.
    test "a stale order-table row from a concurrent put does not let eviction delete the current cache record instead of the true oldest" do
      InMemory.clear()
      Application.put_env(:metadata_relay, :cache_max_entries, 2)
      on_exit(fn -> Application.delete_env(:metadata_relay, :cache_max_entries) end)

      # P1: a normal put/3 call establishes "racer"'s first record and its
      # order row (seq_orphan) -- the smallest (oldest) sequence number
      # generated in this test.
      :ok = InMemory.put("racer", "v1", 60_000)
      [{"racer", _value, _expires_at, seq_orphan}] = :ets.lookup(:metadata_relay_cache, "racer")

      # A second, independent key is inserted next, genuinely older than
      # what "racer" is about to become -- this is the entry a correct
      # eviction should pick.
      :ok = InMemory.put("victim", "real-oldest", 60_000)
      [{"victim", _value, _expires_at, seq_victim}] = :ets.lookup(:metadata_relay_cache, "victim")

      # P2: simulate a concurrent put/3 call for "racer" whose own
      # `drop_order_entry/1` ran before P1 had written anything (so it
      # found nothing to drop -- exactly what the real race produces),
      # then wrote its own order row and overwrote the main table's single
      # slot for "racer". seq_orphan's order-table row is never cleaned up,
      # and "racer" is now the *most recently written* live key even
      # though its stale row is the *oldest* entry in the order table.
      seq_racer_current = :erlang.unique_integer([:monotonic, :positive])
      :ets.insert(:metadata_relay_cache_order, {seq_racer_current, "racer"})

      :ets.insert(
        :metadata_relay_cache,
        {"racer", "v-current", DateTime.add(DateTime.utc_now(), 60_000, :millisecond),
         seq_racer_current}
      )

      # Sanity check on the constructed race state: three order-table rows
      # for two live main-table keys, with "racer"'s orphan row the
      # globally oldest.
      assert :ets.first(:metadata_relay_cache_order) == seq_orphan

      assert [{"racer", "v-current", _, ^seq_racer_current}] =
               :ets.lookup(:metadata_relay_cache, "racer")

      assert seq_orphan < seq_victim and seq_victim < seq_racer_current

      # Force an eviction (main table is already at the 2-entry cap). It
      # walks the order table oldest-first, so it reaches the orphaned
      # seq_orphan row before either live row.
      :ok = InMemory.put("new-key", "x", 60_000)

      assert {:ok, "v-current"} = InMemory.get("racer"),
             "the live, most-recently-written entry for \"racer\" must survive " <>
               "an eviction triggered while a stale order-table row for it exists"

      assert {:error, :not_found} = InMemory.get("victim"),
             "the genuinely oldest live entry (\"victim\") must be the one evicted, " <>
               "not skipped in favor of deleting \"racer\" via its stale row"
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes" do
      InMemory.clear()

      # Pre-populate some data
      for i <- 1..10 do
        InMemory.put("concurrent_#{i}", "value_#{i}", 60_000)
      end

      # Spawn multiple processes to read and write concurrently
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            key = "concurrent_#{rem(i, 10) + 1}"
            InMemory.get(key)
            InMemory.put("new_#{i}", "value_#{i}", 60_000)
            InMemory.get("new_#{i}")
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)

      # All tasks should complete successfully
      assert length(results) == 50

      # Cache should still be functional
      assert {:ok, _} = InMemory.get("concurrent_1")
    end
  end

  describe "automatic cleanup" do
    test "expired entries are eventually cleaned up" do
      InMemory.clear()

      # Add entries with very short TTL
      for i <- 1..10 do
        InMemory.put("cleanup_#{i}", "value_#{i}", 100)
      end

      initial_stats = InMemory.stats()
      assert initial_stats.size == 10

      # Wait for expiration
      Process.sleep(200)

      # Cleanup happens every 15 minutes by default, so we can't test automatic
      # cleanup in a unit test. Instead, we verify that accessing expired entries
      # removes them immediately

      # Access one expired entry
      InMemory.get("cleanup_1")

      # That specific entry should be gone, reducing size
      # (other expired entries remain until accessed or cleanup runs)
      new_stats = InMemory.stats()
      assert new_stats.size < initial_stats.size
    end
  end
end
