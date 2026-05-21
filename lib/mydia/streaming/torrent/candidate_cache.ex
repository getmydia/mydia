defmodule Mydia.Streaming.Torrent.CandidateCache do
  @moduledoc """
  Per-user, in-process cache of magnet links recently returned by
  `torrentCandidates`.

  This is the interim mitigation for the security issue where the
  `startTorrentSession` mutation trusted any magnet URI from an authenticated
  client. By only accepting magnets we ourselves surfaced via
  `torrentCandidates`, the attack surface shrinks from "any BitTorrent the
  attacker can construct" to "the set of magnets the operator's indexers
  returned in the last few minutes for this user".

  The long-term plan is to return opaque server-issued candidate ids and
  look them up here. Until that lands, this module works on raw magnet
  strings.

  Backed by a single ETS table (`:public`, `:set`) lazily created on first
  use. Entries are tagged with `expires_at`; calls to `member?/2` lazily
  drop expired entries.
  """

  @table __MODULE__
  @ttl_ms :timer.minutes(15)

  @doc """
  Remember a list of magnets as having been returned to a user.

  Existing entries for the user are replaced.
  """
  def remember(user_id, magnets) when is_list(magnets) do
    ensure_table!()
    expires_at = monotonic_now() + @ttl_ms

    hashed = magnets |> Enum.map(&hash_magnet/1) |> MapSet.new()

    :ets.insert(@table, {user_id, hashed, expires_at})
    :ok
  end

  @doc """
  Returns true if `magnet` was recently returned to `user_id` via
  `torrentCandidates`.
  """
  def member?(user_id, magnet) when is_binary(magnet) do
    ensure_table!()

    case :ets.lookup(@table, user_id) do
      [{^user_id, hashes, expires_at}] ->
        if expires_at < monotonic_now() do
          :ets.delete(@table, user_id)
          false
        else
          MapSet.member?(hashes, hash_magnet(magnet))
        end

      _ ->
        false
    end
  end

  def member?(_user_id, _magnet), do: false

  @doc false
  # Test/dev helper to wipe state.
  def clear do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:public, :set, :named_table, read_concurrency: true])
        rescue
          ArgumentError ->
            # Race with another process creating it; that's fine.
            :ok
        end

      _ ->
        :ok
    end
  end

  defp hash_magnet(magnet) when is_binary(magnet) do
    :crypto.hash(:sha256, magnet)
  end

  defp monotonic_now do
    System.monotonic_time(:millisecond)
  end
end
