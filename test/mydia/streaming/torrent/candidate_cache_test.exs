defmodule Mydia.Streaming.Torrent.CandidateCacheTest do
  @moduledoc """
  Unit tests for the per-user magnet allow-list used by `startTorrentSession`.

  This cache is the interim guard against the "any-magnet" attack: a client
  may only start a torrent session with a magnet that was previously surfaced
  by `torrentCandidates` for that user. Regression tests here keep that
  property honest.
  """

  # The cache is a single named ETS table — running async would race other
  # tests that clear() before exercising it.
  use ExUnit.Case, async: false

  alias Mydia.Streaming.Torrent.CandidateCache

  setup do
    CandidateCache.clear()
    :ok
  end

  describe "remember/2 + member?/2" do
    test "a remembered magnet is reported as a member" do
      user_id = Ecto.UUID.generate()
      magnet = "magnet:?xt=urn:btih:aabbccdd"

      :ok = CandidateCache.remember(user_id, [magnet])

      assert CandidateCache.member?(user_id, magnet)
    end

    test "an unknown magnet is not a member" do
      user_id = Ecto.UUID.generate()

      :ok = CandidateCache.remember(user_id, ["magnet:?xt=urn:btih:known"])

      refute CandidateCache.member?(user_id, "magnet:?xt=urn:btih:unknown")
    end

    test "an empty cache reports no members" do
      refute CandidateCache.member?(Ecto.UUID.generate(), "magnet:?xt=urn:btih:any")
    end

    test "remember/2 replaces the previous entry for the same user" do
      user_id = Ecto.UUID.generate()
      old = "magnet:?xt=urn:btih:old"
      fresh = "magnet:?xt=urn:btih:fresh"

      :ok = CandidateCache.remember(user_id, [old])
      :ok = CandidateCache.remember(user_id, [fresh])

      refute CandidateCache.member?(user_id, old)
      assert CandidateCache.member?(user_id, fresh)
    end
  end

  describe "user isolation" do
    test "a magnet remembered for user A is not accessible to user B" do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      magnet = "magnet:?xt=urn:btih:shared"

      :ok = CandidateCache.remember(user_a, [magnet])

      assert CandidateCache.member?(user_a, magnet)
      refute CandidateCache.member?(user_b, magnet)
    end
  end

  describe "clear/0" do
    test "wipes all entries across users" do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      magnet = "magnet:?xt=urn:btih:wipe"

      :ok = CandidateCache.remember(user_a, [magnet])
      :ok = CandidateCache.remember(user_b, [magnet])

      :ok = CandidateCache.clear()

      refute CandidateCache.member?(user_a, magnet)
      refute CandidateCache.member?(user_b, magnet)
    end

    test "is a no-op when the table has never been initialized" do
      # clear/0 is also called in test setup; this just asserts the contract
      # holds even when the ETS table has nothing in it.
      assert :ok = CandidateCache.clear()
    end
  end

  describe "input handling" do
    test "non-binary magnets are reported as non-members" do
      user_id = Ecto.UUID.generate()

      :ok = CandidateCache.remember(user_id, ["magnet:?xt=urn:btih:real"])

      # The resolver coerces inputs, but defensive: the cache must not raise
      # if a non-string slips through.
      refute CandidateCache.member?(user_id, nil)
      refute CandidateCache.member?(user_id, 42)
    end

    test "remember/2 accepts an empty list (no-op semantics)" do
      user_id = Ecto.UUID.generate()

      :ok = CandidateCache.remember(user_id, [])

      refute CandidateCache.member?(user_id, "magnet:?xt=urn:btih:anything")
    end
  end
end
