defmodule Mydia.WatchSync.Reconciler do
  @moduledoc """
  Three-way merge between local state, remote state, and the last-agreed
  snapshot.

  Two-way comparison cannot express unwatch: "watched remotely, not watched
  locally" means either "newly watched there" or "just unwatched here", and
  those demand opposite actions. The snapshot is what disambiguates them.

  Pure functions only. All I/O lives in `Mydia.WatchSync.Engine`.
  """

  @position_noise_threshold_seconds 10

  @type side :: %{
          watched: boolean(),
          position_seconds: integer() | nil,
          at: DateTime.t() | nil
        }

  @type change :: %{watched: boolean(), position_seconds: integer() | nil}

  @type decision ::
          {:push, change()} | {:pull, change()} | {:record_only, change()} | :noop

  @doc """
  Resolves one item.

  `:push` applies the change remotely, `:pull` applies it locally,
  `:record_only` updates the snapshot when both sides already agree, and
  `:noop` means nothing at all changed.
  """
  @spec resolve(side(), side(), side() | nil) :: decision()
  def resolve(local, remote, nil) do
    # First sync for this item: there is no basis for detecting an unwatch, so
    # union rather than risk deleting history that predates the snapshot.
    cond do
      local.watched and not remote.watched -> {:push, change(true, local.position_seconds)}
      remote.watched and not local.watched -> {:pull, change(true, remote.position_seconds)}
      true -> {:record_only, change(local.watched, newest_position(local, remote))}
    end
  end

  def resolve(local, remote, snapshot) do
    local_changed? = local.watched != snapshot.watched
    remote_changed? = remote.watched != snapshot.watched

    cond do
      # Both sides moved off the snapshot. For a boolean that means both moved
      # to the same value, so there is nothing to propagate: they already agree
      # and only the snapshot is stale. A "both changed in opposite directions"
      # case cannot arise, because differing from the same boolean forces both
      # sides to the same value. Position differences are picked up on the next
      # sync, which reaches resolve_position/3 once the flag is settled.
      local_changed? and remote_changed? ->
        {:record_only, change(local.watched, newest_position(local, remote))}

      local_changed? ->
        {:push, change(local.watched, local.position_seconds)}

      remote_changed? ->
        {:pull, change(remote.watched, remote.position_seconds)}

      true ->
        resolve_position(local, remote, snapshot)
    end
  end

  @doc """
  Folds several remote copies of one local item into a single remote side.

  A server can hold one movie or episode as several items, for instance a
  1080p library and a 4K library, each with its own played flag. The item is
  watched if any copy is. Position and time come from the most recently played
  copy; when no copy carries a date (Jellyfin's `UpdatePlayState` never stamps
  one), the furthest position wins.
  """
  @spec merge_remotes([side(), ...]) :: side()
  def merge_remotes([_ | _] = sides) do
    source = Enum.max_by(sides, &recency_key/1)

    %{
      watched: Enum.any?(sides, & &1.watched),
      position_seconds: source.position_seconds,
      at: source.at
    }
  end

  defp recency_key(%{at: nil} = side), do: {0, 0, side.position_seconds || 0}

  defp recency_key(%{at: at} = side),
    do: {1, DateTime.to_unix(at, :microsecond), side.position_seconds || 0}

  defp resolve_position(local, remote, snapshot) do
    local_delta = position_delta(local.position_seconds, snapshot.position_seconds)
    remote_delta = position_delta(remote.position_seconds, snapshot.position_seconds)

    cond do
      local_delta >= @position_noise_threshold_seconds and local_delta >= remote_delta ->
        {:push, change(local.watched, local.position_seconds)}

      remote_delta >= @position_noise_threshold_seconds ->
        {:pull, change(remote.watched, remote.position_seconds)}

      true ->
        :noop
    end
  end

  defp position_delta(nil, _), do: 0
  defp position_delta(_, nil), do: 0
  defp position_delta(a, b), do: abs(a - b)

  defp newest_position(local, remote) do
    case compare_times(local.at, remote.at) do
      :lt -> remote.position_seconds
      _ -> local.position_seconds
    end
  end

  defp compare_times(nil, nil), do: :eq
  defp compare_times(nil, _), do: :lt
  defp compare_times(_, nil), do: :gt
  defp compare_times(a, b), do: DateTime.compare(a, b)

  defp change(watched, position), do: %{watched: watched, position_seconds: position}
end
