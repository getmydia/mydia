defmodule Mydia.Media.Monitoring do
  @moduledoc """
  Owns season and episode monitoring: presets, bulk monitored-flag rewrites and
  the rules for whether newly discovered episodes arrive monitored.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Episode, Episodes, Items, MediaItem}
  alias Mydia.Events
  alias Mydia.Library.MediaFile

  @doc """
  Updates the monitored status for all episodes in a season.

  Returns `{:ok, count}` where count is the number of updated episodes,
  or `{:error, reason}` if the transaction fails.

  ## Examples

      iex> update_season_monitoring(media_item_id, 1, true)
      {:ok, 12}

      iex> update_season_monitoring(media_item_id, 2, false)
      {:ok, 8}
  """
  @spec update_season_monitoring(binary(), integer(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_season_monitoring(media_item_id, season_number, monitored)
      when is_boolean(monitored) do
    Repo.transaction(fn ->
      Episode
      |> where([e], e.media_item_id == ^media_item_id)
      |> where([e], e.season_number == ^season_number)
      |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])
      |> elem(0)
    end)
  end

  # :existing is not redundant with the Upgrades sweep, it is what enables it:
  # `Mydia.Upgrades` only considers episodes with `monitored == true`, so this
  # is the one way to say "upgrade the files I have, stop chasing the ones I
  # never found". :first_season and :latest_season are gone because the season
  # header toggle does each in one click.
  @monitoring_presets [:all, :missing, :existing, :future, :none]

  @doc """
  Returns the list of valid monitoring presets.
  """
  @spec monitoring_presets() :: [atom()]
  def monitoring_presets, do: @monitoring_presets

  @doc """
  Reads the current episode rows back as whichever preset describes them, or
  `:custom` when none does.

  Derived rather than stored on purpose. Storing the last preset applied is
  what made the old label go stale the moment someone toggled a season by
  hand, since nothing wrote it back. Computing it from the rows means the
  label is either true or says `:custom`.

  Episodes must have `media_files` preloaded, which the show page already does.
  """
  @spec derive_monitoring_preset([Episode.t()]) :: atom()
  def derive_monitoring_preset([]), do: :none

  def derive_monitoring_preset(episodes) do
    monitored = MapSet.new(Enum.filter(episodes, & &1.monitored), & &1.id)

    # Nothing monitored is :none, decided before the search rather than during
    # it. Several partitions can produce the empty set (:future on a show whose
    # episodes have all aired, :existing on a show with no files), so a
    # first-match walk would answer "Future Episodes" for a show the user just
    # set to "No Episodes".
    if MapSet.size(monitored) == 0 do
      :none
    else
      Enum.find(@monitoring_presets, :custom, fn preset ->
        {to_monitor, _} = partition_episodes_by_preset(episodes, preset)
        MapSet.new(to_monitor, & &1.id) == monitored
      end)
    end
  end

  @doc """
  Counts how many episodes each preset would monitor if it were applied now.

  Runs the same partition `apply_episode_monitoring/2` uses, so the preview
  and the write cannot disagree. The menu uses it to disable a preset that
  would monitor nothing, such as `:future` on a show with no unaired episodes,
  which otherwise reads back as `:none` and looks like the click was ignored.

  Pure: takes episodes with `media_files` preloaded, issues no query.
  """
  @spec monitoring_preview([Episode.t()]) :: %{atom() => non_neg_integer()}
  def monitoring_preview(episodes) do
    Map.new(@monitoring_presets, fn preset ->
      {to_monitor, _} = partition_episodes_by_preset(episodes, preset)
      {preset, length(to_monitor)}
    end)
  end

  @doc """
  Applies a monitoring preset to the episodes of a TV show.

  A one-shot bulk rewrite of `episodes.monitored`, and nothing else. The show
  row is untouched, because the preset describes an action taken once rather
  than a standing rule. What happens to episodes discovered later is decided by
  `should_monitor_new_episode?/2`, reading the season they land in and, for a
  season that does not exist yet, `monitor_new_seasons`.

  ## Presets

  All of them exclude season 0; specials are opt-in.

  - `:all` - Every episode
  - `:missing` - Episodes without files, or not yet aired
  - `:existing` - Only episodes that have files, which is what leaves the
    Upgrades sweep something to work on without searching for what is absent
  - `:future` - Only episodes that have not aired
  - `:none` - Nothing

  ## Returns

  - `{:ok, count}` - Number of episodes whose monitored flag was written
  - `{:error, reason}`

  ## Examples

      iex> apply_episode_monitoring(media_item, :all)
      {:ok, 24}
  """
  @spec apply_episode_monitoring(MediaItem.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def apply_episode_monitoring(%MediaItem{type: "tv_show"} = media_item, preset)
      when preset in @monitoring_presets do
    Repo.transaction(fn ->
      # Untrashed files only, extras included: the same set the show page
      # preloads for the menu preview, so a trashed file can neither make an
      # episode count as "existing" here nor disagree with the preview count.
      episodes =
        Episodes.list_episodes(Scope.system(), media_item.id,
          preload: [media_files: MediaFile.active()]
        )

      {to_monitor, to_unmonitor} = partition_episodes_by_preset(episodes, preset)

      written =
        set_episodes_monitored(to_monitor, true) + set_episodes_monitored(to_unmonitor, false)

      Events.media_item_updated(
        media_item,
        :user,
        "media_context",
        "Applied '#{preset}' monitoring to episodes"
      )

      written
    end)
  end

  def apply_episode_monitoring(%MediaItem{type: type}, preset)
      when preset in @monitoring_presets do
    {:error, {:invalid_type, "apply_episode_monitoring only works for TV shows, got #{type}"}}
  end

  def apply_episode_monitoring(_media_item, preset) when preset not in @monitoring_presets do
    {:error, {:invalid_preset, "Unknown preset: #{preset}"}}
  end

  # Both branches of the bulk apply wrote the same update_all with a different
  # boolean, so it lives in one place.
  @doc false
  def set_episodes_monitored([], _monitored), do: 0

  def set_episodes_monitored(episodes, monitored) do
    ids = Enum.map(episodes, & &1.id)

    Episode
    |> where([e], e.id in ^ids)
    |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])
    |> elem(0)
  end

  @doc """
  Sets whether seasons that do not exist yet arrive monitored.

  Deliberately independent of the presets. Inferring it from the preset made
  two states unreachable: "monitor everything I have but do not chase new
  seasons", and setting the flag at all without a bulk rewrite that destroys
  hand-curated per-season monitoring. It also let a preset contradict itself,
  since :future unmonitors every aired episode while implying new seasons are
  wanted.
  """
  @spec set_monitor_new_seasons(MediaItem.t(), :all | :none) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_monitor_new_seasons(%MediaItem{} = media_item, mode) when mode in [:all, :none] do
    # update_all rather than a changeset: the caller's struct may be stale, and
    # a changeset whose value matches the stale struct produces no change, so
    # the write would silently skip while the row still held the old value.
    MediaItem
    |> where([m], m.id == ^media_item.id)
    |> Repo.update_all(set: [monitor_new_seasons: mode, updated_at: DateTime.utc_now()])

    updated = Items.get_media_item!(Scope.system(), media_item.id)

    Events.media_item_updated(
      updated,
      :user,
      "media_context",
      "New season monitoring set to #{mode}"
    )

    {:ok, updated}
  end

  # Partition episodes into those to monitor and those to unmonitor based on preset
  defp partition_episodes_by_preset(episodes, :all) do
    # Monitor all episodes (except season 0 specials)
    {to_monitor, to_unmonitor} =
      Enum.split_with(episodes, fn ep -> ep.season_number > 0 end)

    {to_monitor, to_unmonitor}
  end

  defp partition_episodes_by_preset(episodes, :none) do
    # Unmonitor all episodes
    {[], episodes}
  end

  # Every preset below excludes season 0. Specials are opt-in through the
  # season header or the per-episode toggle, never swept in by a bulk action.
  # Without this guard :missing monitored fileless specials, which then left
  # `should_monitor_new_episode?/2` admitting every future special forever,
  # because its season-0 guard only covers the empty-season branch.
  defp partition_episodes_by_preset(episodes, :future) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      ep.season_number > 0 && ep.air_date && Date.compare(ep.air_date, today) == :gt
    end)
  end

  defp partition_episodes_by_preset(episodes, :missing) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      has_no_files = Enum.empty?(ep.media_files)
      is_future = ep.air_date && Date.compare(ep.air_date, today) == :gt
      ep.season_number > 0 && (has_no_files || is_future)
    end)
  end

  defp partition_episodes_by_preset(episodes, :existing) do
    Enum.split_with(episodes, fn ep ->
      ep.season_number > 0 && not Enum.empty?(ep.media_files)
    end)
  end

  @doc """
  Classifies a season's monitoring state from its already-loaded episodes.

  Pure, so the UI can call it on episodes it already has in memory rather than
  issuing another query.
  """
  @spec season_monitoring_state([Episode.t()]) :: :none | :partial | :all
  def season_monitoring_state([]), do: :none

  def season_monitoring_state(episodes) do
    cond do
      Enum.all?(episodes, & &1.monitored) -> :all
      Enum.any?(episodes, & &1.monitored) -> :partial
      true -> :none
    end
  end

  @doc """
  Decides whether an episode discovered by a refresh, scan, or provider switch
  should arrive monitored.

  A new episode inherits the season it lands in, so unmonitoring a season also
  stops that season's future episodes. A season that does not exist yet has
  nothing to inherit, so it falls back to the show's `monitor_new_seasons`
  setting. Specials are opt-in: a brand-new season 0 is never admitted, but an
  existing season 0 that the user has monitored is.
  """
  @spec should_monitor_new_episode?(MediaItem.t(), integer()) :: boolean()
  def should_monitor_new_episode?(%MediaItem{monitored: false}, _season_number), do: false

  def should_monitor_new_episode?(%MediaItem{} = media_item, season_number) do
    monitored_flags =
      Episode
      |> where([e], e.media_item_id == ^media_item.id)
      |> where([e], e.season_number == ^season_number)
      |> select([e], e.monitored)
      |> Repo.all()

    case monitored_flags do
      [] -> season_number > 0 and media_item.monitor_new_seasons == :all
      flags -> Enum.any?(flags)
    end
  end
end
