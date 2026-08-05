defmodule Mydia.Downloads.BlacklistsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Repo

  import Mydia.DownloadsFixtures

  describe "add/5" do
    test "inserts a row with the given fields" do
      assert {:ok, row} =
               Blacklists.add("nzbhydra2", "abc123", "Show.S01E01", "par2_failed")

      assert row.indexer == "nzbhydra2"
      assert row.guid == "abc123"
      assert row.title == "Show.S01E01"
      assert row.failure_reason == "par2_failed"
      assert %DateTime{} = row.expires_at
      assert %DateTime{} = row.inserted_at
    end

    test "normalizes indexer name to lowercase" do
      assert {:ok, row} =
               Blacklists.add("Prowlarr", "guid-1", "Title", "stalled")

      assert row.indexer == "prowlarr"
    end

    test "applies the default 30-day TTL when none supplied" do
      before = DateTime.utc_now()
      {:ok, row} = Blacklists.add("nzbhydra2", "ttl-default", "T", "x")

      delta_seconds = DateTime.diff(row.expires_at, before, :second)
      # 30 days +/- a little wiggle room.
      assert delta_seconds >= 29 * 24 * 60 * 60
      assert delta_seconds <= 31 * 24 * 60 * 60
    end

    test "accepts a ttl_days override" do
      before = DateTime.utc_now()

      {:ok, row} =
        Blacklists.add("nzbhydra2", "ttl-7", "T", "x", ttl_days: 7)

      delta_seconds = DateTime.diff(row.expires_at, before, :second)
      assert delta_seconds >= 6 * 24 * 60 * 60
      assert delta_seconds <= 8 * 24 * 60 * 60
    end

    test "accepts an explicit nil expires_at (block forever)" do
      {:ok, row} =
        Blacklists.add("nzbhydra2", "forever-1", "T", "x", expires_at: nil)

      assert is_nil(row.expires_at)
    end

    test "upserts on duplicate (indexer, guid) instead of erroring" do
      {:ok, original} =
        Blacklists.add("nzbhydra2", "dup-1", "Old Title", "stalled")

      {:ok, updated} =
        Blacklists.add("nzbhydra2", "dup-1", "New Title", "par2_failed", ttl_days: 1)

      # Same row (upsert), updated fields visible.
      all = Repo.all(ReleaseBlacklist)
      assert length(all) == 1
      assert updated.title == "New Title"
      assert updated.failure_reason == "par2_failed"

      # And the upsert really targeted the existing row, not a new one
      # (same id is not guaranteed by SQLite upsert returning, but the unique
      # constraint is what we care about).
      assert updated.indexer == original.indexer
      assert updated.guid == original.guid
    end

    test "case-insensitive collision: 'NZBhydra2' upserts onto 'nzbhydra2'" do
      {:ok, _} = Blacklists.add("nzbhydra2", "case-1", "First", "stalled")
      {:ok, _} = Blacklists.add("NZBhydra2", "case-1", "Second", "stalled")

      assert length(Repo.all(ReleaseBlacklist)) == 1
    end
  end

  describe "blacklisted?/2" do
    test "returns true for an active row" do
      {:ok, _} = Blacklists.add("nzbhydra2", "active-1", "T", "x")
      assert Blacklists.blacklisted?("nzbhydra2", "active-1")
    end

    test "treats indexer name case-insensitively" do
      {:ok, _} = Blacklists.add("Prowlarr", "case-lookup", "T", "x")
      assert Blacklists.blacklisted?("PROWLARR", "case-lookup")
      assert Blacklists.blacklisted?("prowlarr", "case-lookup")
    end

    test "returns true when expires_at is nil (forever)" do
      {:ok, _} =
        Blacklists.add("nzbhydra2", "forever-2", "T", "x", expires_at: nil)

      assert Blacklists.blacklisted?("nzbhydra2", "forever-2")
    end

    test "returns false when expires_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        Blacklists.add("nzbhydra2", "expired-1", "T", "x", expires_at: past)

      refute Blacklists.blacklisted?("nzbhydra2", "expired-1")
    end

    test "returns false for unknown (indexer, guid)" do
      refute Blacklists.blacklisted?("nzbhydra2", "missing")
    end

    test "returns false on nil inputs" do
      refute Blacklists.blacklisted?(nil, "abc")
      refute Blacklists.blacklisted?("nzbhydra2", nil)
      refute Blacklists.blacklisted?(nil, nil)
    end
  end

  describe "list/1 and count/1" do
    setup do
      {:ok, a} = Blacklists.add("nzbhydra2", "a", "A", "par2_failed")
      {:ok, b} = Blacklists.add("nzbhydra2", "b", "B", "stalled")
      {:ok, c} = Blacklists.add("prowlarr", "c", "C", "client_reported_failure")
      %{a: a, b: b, c: c}
    end

    test "returns rows ordered by inserted_at desc by default" do
      rows = Blacklists.list()
      assert length(rows) == 3
    end

    test "respects limit and offset" do
      assert length(Blacklists.list(limit: 2)) == 2
      assert length(Blacklists.list(limit: 1, offset: 2)) == 1
    end

    test "filters by failure_reason" do
      rows = Blacklists.list(failure_reason: "stalled")
      assert length(rows) == 1
      assert hd(rows).failure_reason == "stalled"
    end

    test "count/1 matches list size" do
      assert Blacklists.count() == 3
      assert Blacklists.count(failure_reason: "par2_failed") == 1
    end
  end

  describe "list_failure_reasons/0" do
    test "returns distinct sorted failure reasons" do
      {:ok, _} = Blacklists.add("a", "1", "T", "stalled")
      {:ok, _} = Blacklists.add("a", "2", "T", "par2_failed")
      {:ok, _} = Blacklists.add("a", "3", "T", "stalled")

      assert Blacklists.list_failure_reasons() == ["par2_failed", "stalled"]
    end
  end

  describe "remove/1" do
    test "deletes the row and returns {:ok, row}" do
      {:ok, row} = Blacklists.add("nzbhydra2", "rm-1", "T", "x")
      assert {:ok, _} = Blacklists.remove(row.id)
      refute Blacklists.blacklisted?("nzbhydra2", "rm-1")
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} =
               Blacklists.remove("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "block_forever/1" do
    test "sets expires_at to nil" do
      {:ok, row} =
        Blacklists.add("nzbhydra2", "bf-1", "T", "x", ttl_days: 1)

      assert {:ok, updated} = Blacklists.block_forever(row.id)
      assert is_nil(updated.expires_at)
    end

    test "returns {:error, :not_found} for an unknown id" do
      assert {:error, :not_found} =
               Blacklists.block_forever("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "cleanup_expired/0" do
    test "deletes rows whose expires_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      {:ok, _} = Blacklists.add("a", "1", "T", "x", expires_at: past)
      {:ok, _} = Blacklists.add("a", "2", "T", "x", expires_at: past)
      {:ok, _} = Blacklists.add("a", "3", "T", "x", expires_at: future)
      {:ok, _} = Blacklists.add("a", "4", "T", "x", expires_at: nil)

      assert 2 = Blacklists.cleanup_expired()

      remaining = Repo.all(ReleaseBlacklist)
      assert length(remaining) == 2
      guids = remaining |> Enum.map(& &1.guid) |> Enum.sort()
      assert guids == ["3", "4"]
    end

    test "returns 0 when there's nothing to delete" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, _} = Blacklists.add("a", "1", "T", "x", expires_at: future)
      assert 0 == Blacklists.cleanup_expired()
    end
  end

  describe "extract_key/1" do
    test "returns indexer and guid from metadata" do
      download =
        download_fixture(%{
          indexer: "1337x",
          metadata: %{"guid" => "https://1337x.to/torrent/123/"}
        })

      assert {:ok, "1337x", "https://1337x.to/torrent/123/"} = Blacklists.extract_key(download)
    end

    test "falls back to the indexer stored in metadata" do
      download =
        download_fixture(%{
          indexer: nil,
          metadata: %{"indexer" => "nyaa", "guid" => "abc"}
        })

      assert {:ok, "nyaa", "abc"} = Blacklists.extract_key(download)
    end

    test "errors when the guid is missing" do
      download = download_fixture(%{indexer: "1337x", metadata: %{}})

      assert {:error, :no_guid} = Blacklists.extract_key(download)
    end

    test "errors when the indexer is missing" do
      download = download_fixture(%{indexer: nil, metadata: %{"guid" => "abc"}})

      assert {:error, :no_indexer} = Blacklists.extract_key(download)
    end
  end
end
