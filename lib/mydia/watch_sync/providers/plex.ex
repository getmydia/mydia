defmodule Mydia.WatchSync.Providers.Plex do
  @moduledoc """
  Plex implementation of `Mydia.WatchSync.Provider`.

  `refresh_mappings/2` is the only full-library crawl; it runs on first sync
  and on demand. `list_changes/3` reads watch state and resume position.
  `apply_change/4` scrobbles, unscrobbles, and pushes resume position via
  `/:/progress`.
  """

  @behaviour Mydia.WatchSync.Provider

  alias Mydia.MediaServer.Client.Plex, as: PlexClient

  require Logger

  @page_size 200

  @impl true
  def refresh_mappings(config, _opts) do
    with {:ok, sections} <- PlexClient.list_sections(config) do
      mappings =
        sections
        |> Enum.flat_map(fn section -> mappings_from_section(config, section) end)

      {:ok, mappings}
    end
  end

  @impl true
  def list_changes(config, _user_scope, since) do
    with {:ok, sections} <- PlexClient.list_sections(config) do
      changes =
        sections
        |> Enum.flat_map(fn section -> changes_from_section(config, section, since) end)

      {:ok, changes}
    end
  end

  @impl true
  def apply_change(config, _user_scope, remote_id, change) do
    # Watched flag first, then position: an unscrobble must not clear a resume
    # point we are about to write for an in-progress unwatched item.
    with :ok <- maybe_push_watched(config, remote_id, change) do
      maybe_push_position(config, remote_id, change)
    end
  end

  defp maybe_push_position(config, remote_id, %{position_seconds: position})
       when is_integer(position) do
    PlexClient.update_progress(config, remote_id, position)
  end

  defp maybe_push_position(_config, _remote_id, _change), do: :ok

  defp maybe_push_watched(config, remote_id, %{watched: true}) do
    PlexClient.scrobble(config, remote_id)
  end

  defp maybe_push_watched(config, remote_id, %{watched: false}) do
    PlexClient.unscrobble(config, remote_id)
  end

  defp maybe_push_watched(_config, _remote_id, _change), do: :ok

  # ── Mappings ───────────────────────────────────────────────────────

  defp mappings_from_section(config, %{type: "movie", key: key}) do
    key
    |> page_section_items(config)
    |> Enum.map(fn item ->
      %{
        remote_id: item.rating_key,
        type: :movie,
        external_ids: item.guids,
        season_number: nil,
        episode_number: nil
      }
    end)
  end

  defp mappings_from_section(config, %{type: "show", key: key}) do
    case PlexClient.list_section_items(config, key) do
      {:ok, shows} ->
        Enum.flat_map(shows, fn show ->
          case PlexClient.list_show_episodes(config, show.rating_key) do
            {:ok, episodes} ->
              Enum.map(episodes, fn ep ->
                %{
                  remote_id: ep.rating_key,
                  type: :episode,
                  external_ids: show.guids,
                  season_number: ep.season_number,
                  episode_number: ep.episode_number
                }
              end)

            {:error, reason} ->
              Logger.warning(
                "Failed to list episodes for Plex show #{show.title}: #{inspect(reason)}"
              )

              []
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to list Plex show section #{key}: #{inspect(reason)}")
        []
    end
  end

  defp mappings_from_section(_config, %{type: type, key: key}) do
    Logger.debug("Skipping unsupported Plex section type #{type} (key: #{key})")
    []
  end

  # ── Changes ────────────────────────────────────────────────────────

  defp changes_from_section(config, %{type: "movie", key: key}, since) do
    key
    |> page_section_items(config, since)
    |> Enum.filter(&changed_since?(&1, since))
    |> Enum.map(&to_remote_state/1)
  end

  defp changes_from_section(config, %{type: "show", key: key}, since) do
    case PlexClient.list_section_items(config, key) do
      {:ok, shows} ->
        Enum.flat_map(shows, fn show ->
          case PlexClient.list_show_episodes(config, show.rating_key) do
            {:ok, episodes} ->
              episodes
              |> Enum.filter(&changed_since?(&1, since))
              |> Enum.map(&to_remote_state/1)

            {:error, _} ->
              []
          end
        end)

      {:error, reason} ->
        Logger.warning("Failed to list Plex show section #{key}: #{inspect(reason)}")
        []
    end
  end

  defp changes_from_section(_config, _section, _since), do: []

  defp page_section_items(section_key, config, since \\ nil) do
    page_section_items(section_key, config, since, 0, [])
  end

  defp page_section_items(section_key, config, since, start, acc) do
    opts = [
      start: start,
      size: @page_size,
      since: since
    ]

    case PlexClient.list_section_items(config, section_key, opts) do
      {:ok, items} ->
        # Prepend pages and reverse once at the end. `acc ++ items` copies the
        # whole accumulator per page, which is O(n^2) over a large library and
        # falls hardest on the initial crawl.
        acc = [items | acc]

        if length(items) < @page_size do
          acc |> Enum.reverse() |> List.flatten()
        else
          page_section_items(section_key, config, since, start + @page_size, acc)
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to page Plex section #{section_key} from #{start}: #{inspect(reason)}"
        )

        acc |> Enum.reverse() |> List.flatten()
    end
  end

  defp changed_since?(_item, nil), do: true

  defp changed_since?(item, %DateTime{} = since) do
    case item.last_viewed_at do
      nil ->
        # In-progress items may only have a viewOffset; include them so resume
        # position can move even when Plex has not stamped lastViewedAt.
        (item.view_offset || 0) > 0 or (item.view_count || 0) > 0

      unix when is_integer(unix) ->
        DateTime.from_unix!(unix) |> DateTime.compare(since) != :lt

      _ ->
        true
    end
  end

  defp to_remote_state(item) do
    %{
      remote_id: item.rating_key,
      watched: (item.view_count || 0) > 0,
      position_seconds: position_seconds(item.view_offset),
      at: viewed_at(item.last_viewed_at)
    }
  end

  defp position_seconds(nil), do: nil
  defp position_seconds(ms) when is_integer(ms) and ms > 0, do: div(ms, 1000)
  defp position_seconds(_), do: nil

  defp viewed_at(nil), do: nil

  defp viewed_at(unix) when is_integer(unix) do
    DateTime.from_unix!(unix) |> DateTime.truncate(:second)
  end

  defp viewed_at(_), do: nil
end
