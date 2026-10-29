defmodule MydiaWeb.MediaLive.Show.DownloadSummary do
  @moduledoc """
  What the detail page says about downloads that are still in the client.

  Built from the page's `downloads_with_status` and the item's episodes, it
  answers the two questions the old banner could not: *which* episodes are
  downloading, and how far along they are. The banner reads `items`,
  `progress` and `state`; the episode rows read `by_episode`.

  "Active" means still transferring toward a file: downloading, checking,
  paused or queued. Seeding and completed torrents are finished from the
  viewer's side, so they are left out.

  A season pack (`episode_id` nil, `metadata.season_pack` with a
  `season_number`) covers the episodes listed in its `metadata.episode_ids`,
  or the season's aired episodes when it lists none. An episode's own
  download wins over a pack that also covers it.
  """

  alias MydiaWeb.MediaLive.Show.DownloadSummaryItem, as: Item

  @active_statuses ["downloading", "checking", "paused", "queued"]

  defstruct items: [], progress: 0.0, state: nil, by_episode: %{}, eta: nil

  @type t :: %__MODULE__{
          items: [Item.t()],
          progress: float(),
          state: String.t() | nil,
          by_episode: %{optional(binary()) => map()},
          eta: integer() | nil
        }

  @doc "The statuses that count as still downloading."
  def active_statuses, do: @active_statuses

  @doc """
  Summarises the active downloads among `downloads` against `episodes`.

  Returns `nil` when nothing is active, so a template can guard on it.
  """
  @spec build([map()], [map()] | term()) :: t() | nil
  def build(downloads, episodes) do
    active = Enum.filter(downloads, &(&1.status in @active_statuses))

    if active == [] do
      nil
    else
      episodes = if is_list(episodes), do: episodes, else: []
      items = active |> Enum.map(&item(&1, episodes)) |> Enum.sort_by(& &1.sort_key)

      %__MODULE__{
        items: items,
        progress: progress(active),
        state: shared_state(active),
        by_episode: by_episode(items, episodes),
        eta: eta(active)
      }
    end
  end

  @doc """
  The active download for one episode, from a summary that may be `nil`.
  """
  @spec for_episode(t() | nil, binary()) :: map() | nil
  def for_episode(nil, _episode_id), do: nil
  def for_episode(%__MODULE__{by_episode: map}, episode_id), do: Map.get(map, episode_id)

  defp item(download, episodes) do
    cond do
      download.episode_id ->
        episode = episode_for(download, episodes)
        season = episode && episode.season_number
        number = episode && episode.episode_number

        %Item{
          download: download,
          kind: :episode,
          season_number: season,
          episode_number: number,
          sort_key: {0, season || 0, number || 0}
        }

      season = pack_season(download) ->
        %Item{
          download: download,
          kind: :season_pack,
          season_number: season,
          sort_key: {0, season, -1}
        }

      true ->
        %Item{download: download, kind: :other, sort_key: {1, download.title || "", 0}}
    end
  end

  defp episode_for(%{episode: %{season_number: _} = episode}, _episodes), do: episode

  defp episode_for(%{episode_id: id}, episodes), do: Enum.find(episodes, &(&1.id == id))

  defp pack_season(%{metadata: metadata}) when is_map(metadata) do
    pack? = metadata["season_pack"] || metadata[:season_pack]
    season = metadata["season_number"] || metadata[:season_number]

    if pack? == true and is_integer(season), do: season
  end

  defp pack_season(_download), do: nil

  # Direct downloads are written last so they win over a pack for the same
  # episode. File state is deliberately not consulted: many handlers reload
  # the media item without rebuilding this summary, so readers check an
  # episode's files themselves.
  defp by_episode(items, episodes) do
    {direct, packs} = Enum.split_with(items, &(&1.kind == :episode))

    pack_entries =
      for %Item{kind: :season_pack} = pack <- packs,
          episode <- episodes,
          episode.season_number == pack.season_number,
          pack_covers?(pack.download, episode),
          do: {episode.id, pack.download}

    direct_entries =
      for %Item{download: download} <- direct, do: {download.episode_id, download}

    Map.new(pack_entries ++ direct_entries)
  end

  # The grab records the episodes a pack was taken for in `episode_ids`
  # (see Mydia.Downloads.Queue.Duplicates). Manual grabs and older rows carry
  # none; for those the pack covers the season's aired episodes, since an
  # unaired one cannot be in it.
  defp pack_covers?(%{metadata: metadata}, episode) do
    case metadata["episode_ids"] || metadata[:episode_ids] do
      [_ | _] = ids -> episode.id in ids
      _ -> aired?(episode)
    end
  end

  defp aired?(%{air_date: %Date{} = date}), do: Date.compare(date, Date.utc_today()) != :gt
  defp aired?(_episode), do: false

  # Weighted by size when every download reports one, so a 40 GB pack at 10%
  # is not averaged up by a 1 GB episode at 100%. Otherwise a plain mean.
  defp progress(active) do
    sizes = Enum.map(active, &(&1.size || 0))

    if Enum.all?(sizes, &(&1 > 0)) do
      done = active |> Enum.map(&((&1.progress || 0) * (&1.size || 0))) |> Enum.sum()
      clamp(done / Enum.sum(sizes))
    else
      active |> Enum.map(&(&1.progress || 0)) |> Enum.sum() |> Kernel./(length(active)) |> clamp()
    end
  end

  defp clamp(value), do: value |> max(0.0) |> min(100.0) |> Kernel.*(1.0)

  # A state worth naming only when it holds for everything: one paused torrent
  # among four running ones is not "paused".
  defp shared_state(active) do
    case active |> Enum.map(& &1.status) |> Enum.uniq() do
      [status] when status != "downloading" -> status
      _ -> nil
    end
  end

  # The slowest download decides when the batch is done, so one download
  # without an estimate leaves the batch without one.
  defp eta(active) do
    etas = Enum.map(active, & &1.eta)
    if Enum.all?(etas, &(is_integer(&1) and &1 > 0)), do: Enum.max(etas)
  end
end
