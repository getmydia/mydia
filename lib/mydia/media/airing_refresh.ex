defmodule Mydia.Media.AiringRefresh do
  @moduledoc """
  Decides which seasons of airing shows are worth re-reading between weekly
  metadata passes.

  Providers publish upcoming episodes with placeholder titles and fill in the
  real title, overview and screencap in the days around the air date (see
  `Mydia.Media.EpisodePlaceholder`). The weekly pass alone left those
  placeholders visible for up to a week.

  An episode needs a refresh while its title is a placeholder, or once it has
  aired while its overview is a placeholder or its screencap is missing. Only
  episodes from 14 days after air to 7 days before are considered, which also
  stops the job chasing screencaps TVDB never publishes.
  """

  import Ecto.Query, warn: false

  alias Mydia.Media.{Episode, EpisodePlaceholder, MediaItem}
  alias Mydia.Metadata.Structs.EpisodeData
  alias Mydia.Repo

  @days_after_air 14
  @days_before_air 7
  # A provider's air date is its local broadcast date, which can be a day
  # either side of the UTC date this job runs on.
  @hot_margin_days 1

  @type scope :: :hot | :all

  @doc """
  Returns the monitored TV shows with seasons due for a refresh on `today`.

  `:hot` keeps only seasons holding a due episode that airs within a day of
  `today`. `:all` keeps every season holding a due episode in the window.
  """
  @spec due_seasons(Date.t(), scope()) :: [{MediaItem.t(), [non_neg_integer()]}]
  def due_seasons(%Date{} = today, scope) when scope in [:hot, :all] do
    from_date = Date.add(today, -@days_after_air)
    to_date = Date.add(today, @days_before_air)

    Episode
    |> join(:inner, [e], m in MediaItem, on: m.id == e.media_item_id)
    |> where([_e, m], m.type == "tv_show" and m.monitored == true)
    |> where([e], not is_nil(e.air_date) and e.air_date >= ^from_date and e.air_date <= ^to_date)
    |> select([e, m], {e, m})
    |> Repo.all()
    |> Enum.filter(fn {episode, _item} ->
      needs_refresh?(episode, today) and in_scope?(episode, today, scope)
    end)
    |> Enum.group_by(fn {_episode, item} -> item.id end)
    |> Enum.map(fn {_id, [{_episode, item} | _] = pairs} ->
      seasons =
        pairs
        |> Enum.map(fn {episode, _item} -> episode.season_number end)
        |> Enum.uniq()
        |> Enum.sort()

      {item, seasons}
    end)
    |> Enum.sort_by(fn {item, _seasons} -> {item.title, item.id} end)
  end

  defp needs_refresh?(%Episode{} = episode, today) do
    EpisodePlaceholder.title?(episode.title) or
      (Date.compare(episode.air_date, today) != :gt and missing_aired_details?(episode.metadata))
  end

  defp missing_aired_details?(%EpisodeData{} = data) do
    EpisodePlaceholder.overview?(data.overview) or EpisodePlaceholder.still?(data.still_path)
  end

  defp missing_aired_details?(_metadata), do: true

  defp in_scope?(_episode, _today, :all), do: true

  defp in_scope?(%Episode{air_date: air_date}, today, :hot) do
    abs(Date.diff(air_date, today)) <= @hot_margin_days
  end
end
