defmodule Mydia.Media.MinimumAvailability do
  @moduledoc """
  When automatic search may start looking for a movie.

  Releases offered for a movie before it could have been released are fakes,
  usually another film relabelled. The level, global
  (`media.minimum_availability`) or a movie's own override
  (`MediaItem.minimum_availability`), says how long to wait:

    * `"announced"` - never waits.
    * `"in_cinemas"` - until the theatrical `release_date`.
    * `"released"` - until the earliest of the TMDB digital and physical
      release dates and the theatrical date plus 90 days. The 90 days are a
      ceiling as well as a fallback, so an old film whose only typed release
      is a recent reissue stays searchable.

  A movie with no usable date waits only while TMDB says it is unreleased
  (`Rumored`, `Planned`, `In Production`, `Post Production`); otherwise it is
  eligible now, so missing metadata never leaves it silently unsearched.

  `Mydia.Jobs.MovieSearch` enforces this for automatic searches; the Search
  button on a movie's page bypasses it.
  """

  alias Mydia.Media.MediaItem
  alias Mydia.Media.MinimumAvailability.Status

  @fallback_days 90
  @unreleased_statuses ["Rumored", "Planned", "In Production", "Post Production"]

  @type level :: String.t()

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
    theatrical_ceiling = metadata.release_date && Date.add(metadata.release_date, @fallback_days)

    [metadata.digital_release_date, metadata.physical_release_date, theatrical_ceiling]
    |> Enum.reject(&is_nil/1)
    |> Enum.min(Date, fn -> nil end)
  end

  def eligible_on(%MediaItem{}, _unknown_level), do: nil

  @doc "Where `item` stands under the configured global level, today."
  @spec status(MediaItem.t()) :: Status.t()
  def status(%MediaItem{} = item), do: status(item, global_level(), Date.utc_today())

  @doc "Where `item` stands under `global` on `today`."
  @spec status(MediaItem.t(), level(), Date.t()) :: Status.t()
  def status(%MediaItem{} = item, global, %Date{} = today) do
    level = effective(item, global)
    eligible_on = eligible_on(item, level)

    available? =
      if eligible_on,
        do: Date.compare(eligible_on, today) != :gt,
        else: not awaiting_date?(item, level)

    %Status{level: level, eligible_on: eligible_on, available?: available?}
  end

  # No date to wait for, but TMDB says the film is not out yet.
  defp awaiting_date?(_item, "announced"), do: false

  defp awaiting_date?(%MediaItem{metadata: %{status: status}}, _level),
    do: status in @unreleased_statuses

  defp awaiting_date?(_item, _level), do: false

  @doc "Whether automatic search may look for `item` today."
  @spec available?(MediaItem.t()) :: boolean()
  def available?(%MediaItem{} = item), do: status(item).available?

  @doc """
  Records a `search.skipped_unavailable` event: an automatic search for `item`
  waited because of `status` (from `status/1`).
  """
  @spec record_skip(MediaItem.t(), Status.t()) :: :ok
  def record_skip(%MediaItem{} = item, %Status{level: level, eligible_on: eligible_on}) do
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
