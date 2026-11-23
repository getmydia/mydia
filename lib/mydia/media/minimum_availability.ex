defmodule Mydia.Media.MinimumAvailability do
  @moduledoc """
  When automatic search may start looking for a movie.

  Releases offered for a movie before it could have been released are fakes,
  usually another film relabelled. The level, global
  (`media.minimum_availability`) or a movie's own override
  (`MediaItem.minimum_availability`), says how long to wait:

    * `"announced"` - never waits.
    * `"in_cinemas"` - until the theatrical `release_date`.
    * `"released"` - until the earlier of the TMDB digital and physical
      release dates, or the theatrical date plus 90 days when TMDB has
      neither (the rule Radarr uses, so long-released films without those
      dates stay searchable).

  A movie with no usable date never waits: missing metadata must not leave it
  silently unsearched forever.

  `Mydia.Jobs.MovieSearch` enforces this for automatic searches; the Search
  button on a movie's page bypasses it.
  """

  alias Mydia.Media.MediaItem

  @fallback_days 90

  @type level :: String.t()
  @type status :: %{level: level(), eligible_on: Date.t() | nil, available?: boolean()}

  @doc "The level that applies to `item`: its override, else `global`."
  @spec effective(MediaItem.t(), level()) :: level()
  def effective(%MediaItem{minimum_availability: level}, _global) when is_binary(level), do: level
  def effective(%MediaItem{}, global), do: global

  @doc "The date `item` becomes eligible under `level`, or nil when it need not wait."
  @spec eligible_on(MediaItem.t(), level()) :: Date.t() | nil
  def eligible_on(%MediaItem{metadata: nil}, _level), do: nil
  def eligible_on(%MediaItem{}, "announced"), do: nil
  def eligible_on(%MediaItem{metadata: metadata}, "in_cinemas"), do: metadata.release_date

  def eligible_on(%MediaItem{metadata: metadata}, "released") do
    case Enum.reject([metadata.digital_release_date, metadata.physical_release_date], &is_nil/1) do
      [] -> metadata.release_date && Date.add(metadata.release_date, @fallback_days)
      dates -> Enum.min(dates, Date)
    end
  end

  def eligible_on(%MediaItem{}, _unknown_level), do: nil

  @doc "Where `item` stands under the configured global level, today."
  @spec status(MediaItem.t()) :: status()
  def status(%MediaItem{} = item), do: status(item, global_level(), Date.utc_today())

  @doc "Where `item` stands under `global` on `today`."
  @spec status(MediaItem.t(), level(), Date.t()) :: status()
  def status(%MediaItem{} = item, global, %Date{} = today) do
    level = effective(item, global)
    eligible_on = eligible_on(item, level)

    %{
      level: level,
      eligible_on: eligible_on,
      available?: is_nil(eligible_on) or Date.compare(eligible_on, today) != :gt
    }
  end

  @doc "Whether automatic search may look for `item` today."
  @spec available?(MediaItem.t()) :: boolean()
  def available?(%MediaItem{} = item), do: status(item).available?

  @doc """
  Records a `search.skipped_unavailable` event: an automatic search for `item`
  waited because of `status` (from `status/1`).
  """
  @spec record_skip(MediaItem.t(), status()) :: :ok
  def record_skip(%MediaItem{} = item, %{level: level, eligible_on: eligible_on}) do
    Mydia.Events.create_event_async(%{
      category: "search",
      type: "search.skipped_unavailable",
      actor_type: :job,
      actor_id: "movie_search",
      resource_type: "media_item",
      resource_id: item.id,
      severity: :info,
      metadata: %{
        "title" => item.title,
        "media_type" => item.type,
        "level" => level,
        "eligible_on" => eligible_on && Date.to_iso8601(eligible_on)
      }
    })
  end

  @doc "The configured `media.minimum_availability`."
  @spec global_level() :: level()
  def global_level do
    case Mydia.Config.get() do
      %{media: %{minimum_availability: level}} when is_binary(level) -> level
      _ -> "released"
    end
  end
end
