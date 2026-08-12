defmodule Mydia.WatchSync.Providers.Jellyfin do
  @moduledoc """
  Jellyfin implementation of `Mydia.WatchSync.Provider`.

  Jellyfin issues no per-user tokens. One server API key acts for any user, and
  the account is named by the `remote_user_id` GUID on the user scope, so every
  user-scoped call reads that field rather than a token.

  Jellyfin has no "user data changed since" filter, so `list_changes/3`
  enumerates and filters on `LastPlayedDate` client-side, the same shape as the
  Plex crawl.

  ## Known gap: unwatch is invisible to an incremental run

  Jellyfin's `LastPlayedDate` is not a reliable "last touched" timestamp.
  `UpdatePlayState` sets `Played` and `PlaybackPositionTicks` without ever
  stamping it (so a resume position we ourselves pushed via `set_position/4`
  carries no date), and `MarkUnplayed` explicitly nulls it. That means an
  unwatch performed in Jellyfin's own UI produces `watched: false`,
  `position_seconds: nil`, `at: nil`, which is byte-identical to "this item was
  never played" at this layer. `changed_since?/2` cannot tell the two apart,
  and the engine only holds the *previous synced snapshot*, not enough history
  to disambiguate either. So on an incremental run (`since` set), such an
  unwatch is silently skipped. It is not lost forever: the next full
  `refresh_mappings/2` crawl (first sync for a mapping, or an explicit forced
  refresh) re-establishes every item, and any subsequent watch/resume on that
  item stamps a fresh `LastPlayedDate` and is picked up normally.
  """

  @behaviour Mydia.WatchSync.Provider

  alias Mydia.MediaServer.Client.Jellyfin, as: JellyfinClient

  @ticks_per_second 10_000_000

  @impl true
  def refresh_mappings(config, _opts) do
    with {:ok, items} <- JellyfinClient.list_items(config) do
      {:ok, Enum.map(items, &to_mapping/1)}
    end
  end

  @impl true
  def list_changes(config, user_scope, since) do
    with {:ok, user_id} <- remote_user_id(user_scope),
         {:ok, items} <- JellyfinClient.list_items(config, user_id: user_id) do
      changes =
        items
        |> Enum.map(&to_remote_state/1)
        |> Enum.filter(&changed_since?(&1, since))

      {:ok, changes}
    end
  end

  @impl true
  def apply_change(config, user_scope, remote_id, change) do
    with {:ok, user_id} <- remote_user_id(user_scope),
         :ok <- push_watched(config, user_id, remote_id, change) do
      push_position(config, user_id, remote_id, change)
    end
  end

  defp remote_user_id(%{remote_user_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp remote_user_id(_user_scope), do: {:error, :missing_remote_user_id}

  # Watched flag first, then position, matching the Plex provider: an unplayed
  # write must not clear a resume point we are about to set.
  defp push_watched(config, user_id, remote_id, %{watched: true}),
    do: JellyfinClient.mark_played(config, user_id, remote_id)

  defp push_watched(config, user_id, remote_id, %{watched: false}),
    do: JellyfinClient.mark_unplayed(config, user_id, remote_id)

  defp push_watched(_config, _user_id, _remote_id, _change), do: :ok

  defp push_position(config, user_id, remote_id, %{position_seconds: seconds})
       when is_integer(seconds) and seconds > 0,
       do: JellyfinClient.set_position(config, user_id, remote_id, seconds)

  defp push_position(_config, _user_id, _remote_id, _change), do: :ok

  defp to_mapping(item) do
    %{
      remote_id: item["Id"],
      external_ids: external_ids(item["ProviderIds"]),
      season_number: item["ParentIndexNumber"],
      episode_number: item["IndexNumber"],
      type: item_type(item["Type"])
    }
  end

  defp to_remote_state(item) do
    user_data = item["UserData"] || %{}

    %{
      remote_id: item["Id"],
      watched: user_data["Played"] == true,
      position_seconds: position_seconds(user_data["PlaybackPositionTicks"]),
      at: parse_date(user_data["LastPlayedDate"])
    }
  end

  defp item_type("Episode"), do: :episode
  defp item_type(_type), do: :movie

  defp external_ids(nil), do: %{}

  defp external_ids(provider_ids) when is_map(provider_ids) do
    Enum.reduce(provider_ids, %{}, fn {key, value}, acc ->
      case String.downcase(key) do
        "tmdb" -> Map.put(acc, :tmdb, value)
        "tvdb" -> Map.put(acc, :tvdb, value)
        "imdb" -> Map.put(acc, :imdb, value)
        _other -> acc
      end
    end)
  end

  defp external_ids(_provider_ids), do: %{}

  defp position_seconds(ticks) when is_integer(ticks) and ticks > 0,
    do: div(ticks, @ticks_per_second)

  defp position_seconds(_ticks), do: nil

  defp parse_date(nil), do: nil

  defp parse_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp changed_since?(_state, nil), do: true

  # Jellyfin's UpdatePlayState never stamps LastPlayedDate, and MarkUnplayed
  # nulls it, so a nil date does not mean "unchanged". Items carrying real
  # state are included regardless of date, mirroring the Plex provider
  # (providers/plex.ex:199-207). Never-played items (no watched flag, no
  # position) are still excluded here: Jellyfin has no server-side filter
  # like Plex's `lastViewedAt>`, so every untouched item in the library would
  # otherwise flow through the full reconcile path on every run.
  defp changed_since?(%{at: nil} = state, _since),
    do: state.watched or (state.position_seconds || 0) > 0

  defp changed_since?(%{at: at}, %DateTime{} = since),
    do: DateTime.compare(at, since) != :lt
end
