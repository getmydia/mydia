defmodule Mydia.Indexers.TrackerSightings do
  @moduledoc """
  Which trackers searches have returned, and what each one reported.

  `Mydia.Indexers.search_all/2` hands every result set to `record/2`. One row
  per tracker (matched case-insensitively) keeps the tracker-level terms it
  last reported and when it was last seen; a later sighting without a value
  never erases an earlier one. Writes go through
  `Mydia.Indexers.TrackerSightings.Recorder`, once a minute, except under the
  SQL sandbox, where they happen in the caller so tests see their own rows.

  `list_trackers/1` backs the admin Indexers page: trackers seen in the last
  30 days plus every override, with effective terms and a stale flag on an
  override that matched nothing in 30 days (the usual cause is a tracker
  renamed in Prowlarr).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Indexers.TrackerRules
  alias Mydia.Indexers.TrackerSightings.{Recorder, Row, Sighting}
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.TrackerRuleConfig

  @window_seconds 30 * 86_400
  @term_fields [:private, :minimum_ratio, :minimum_seed_time]

  @doc "How long a tracker counts as recently seen, and an override as fresh."
  @spec window_days() :: pos_integer()
  def window_days, do: div(@window_seconds, 86_400)

  @doc "Records the trackers behind `results` as seen at `now`."
  @spec record([SearchResult.t()], DateTime.t()) :: :ok
  def record(results, now \\ DateTime.utc_now()) do
    case sightings(results, now) do
      empty when map_size(empty) == 0 ->
        :ok

      sightings ->
        if sandbox_pool?(), do: write(sightings, :debug), else: Recorder.buffer(sightings)
        :ok
    end
  rescue
    # A sighting is a hint for the admin page; it must never fail a search.
    error ->
      Logger.debug("TrackerSightings skipped a batch: #{Exception.message(error)}")
      :ok
  end

  @doc false
  # One merged sighting per tracker key.
  @spec sightings([SearchResult.t()], DateTime.t()) :: %{String.t() => map()}
  def sightings(results, now) do
    seen_at = DateTime.truncate(now, :second)

    results
    |> Enum.filter(&match?(%SearchResult{indexer: indexer} when is_binary(indexer), &1))
    |> Enum.reduce(%{}, fn result, acc ->
      case TrackerRuleConfig.key(result.indexer) do
        "" ->
          acc

        # Within one batch the first spelling of a name is kept; across
        # batches the newest spelling wins (see merge_sightings/2).
        key ->
          new = sighting(key, result, seen_at)
          new = if acc[key], do: %{new | tracker: acc[key].tracker}, else: new
          merge_sightings(acc, %{key => new})
      end
    end)
  end

  defp sighting(key, %SearchResult{indexer: indexer, terms: terms}, seen_at) do
    terms = terms || %TrackerTerms{}

    %{
      tracker: String.trim(indexer),
      tracker_key: key,
      private: terms.private?,
      minimum_ratio: terms.minimum_ratio,
      minimum_seed_time: terms.minimum_seed_time,
      last_seen_at: seen_at
    }
  end

  @doc false
  # Merges `newer` into `older`: a known value in `newer` wins, an unknown one
  # keeps the older value.
  @spec merge_sightings(%{String.t() => map()}, %{String.t() => map()}) :: %{String.t() => map()}
  def merge_sightings(older, newer) do
    Map.merge(older, newer, fn _key, old, new -> merge_one(old, new) end)
  end

  defp merge_one(old, new) do
    Enum.reduce(@term_fields, new, fn field, acc ->
      if is_nil(acc[field]), do: Map.put(acc, field, old[field]), else: acc
    end)
  end

  @doc false
  # Upserts sightings, keeping stored values the new sightings do not know.
  @spec write(%{String.t() => map()}, Logger.level()) :: :ok | :error
  def write(sightings, failure_level) do
    keys = Map.keys(sightings)

    stored =
      from(s in Sighting, where: s.tracker_key in ^keys)
      |> Repo.all()
      |> Map.new(
        &{&1.tracker_key, Map.take(&1, [:tracker, :tracker_key, :last_seen_at | @term_fields])}
      )

    rows =
      stored
      |> merge_sightings(sightings)
      |> Map.take(keys)
      |> Enum.map(fn {_key, row} -> Map.put(row, :id, Ecto.UUID.generate()) end)

    Repo.insert_all(Sighting, rows,
      on_conflict: {:replace, [:tracker, :last_seen_at | @term_fields]},
      conflict_target: [:tracker_key]
    )

    :ok
  rescue
    error ->
      Logger.log(
        failure_level,
        "TrackerSightings dropped #{map_size(sightings)} sighting(s): #{Exception.message(error)}"
      )

      :error
  end

  @doc """
  Trackers for the admin page, sorted by name: every tracker seen in the last
  30 days and every override, each with its reported and effective terms.

  An override is stale when its tracker was neither seen in a search nor
  grabbed from in 30 days, unless it is a database row created within that
  window (a rule added ahead of the first search is not stale yet).
  """
  @spec list_trackers(DateTime.t()) :: [Row.t()]
  def list_trackers(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@window_seconds)
    rules = TrackerRules.list_rules()
    rule_keys = Enum.map(rules, &TrackerRuleConfig.key(&1.tracker))

    sightings =
      from(s in Sighting, where: s.last_seen_at >= ^cutoff or s.tracker_key in ^rule_keys)
      |> Repo.all()
      |> Map.new(&{&1.tracker_key, &1})

    grabbed = recently_grabbed_keys(cutoff)
    rules_by_key = Map.new(rules, &{TrackerRuleConfig.key(&1.tracker), &1})

    sightings
    |> Map.keys()
    |> Enum.filter(&(recent?(sightings[&1], cutoff) or Map.has_key?(rules_by_key, &1)))
    |> Enum.concat(Map.keys(rules_by_key))
    |> Enum.uniq()
    |> Enum.map(&build_row(&1, sightings[&1], rules_by_key[&1], rules, {cutoff, grabbed}))
    |> Enum.sort_by(&String.downcase(&1.tracker))
  end

  defp build_row(key, sighting, rule, rules, {cutoff, grabbed}) do
    tracker = (sighting && sighting.tracker) || rule.tracker
    reported = sighting && reported_terms(sighting)

    %Row{
      key: key,
      tracker: tracker,
      reported: reported,
      effective: TrackerRules.effective(reported, tracker, rules),
      rule: rule,
      last_seen_at: sighting && sighting.last_seen_at,
      stale?:
        rule != nil and not recent?(sighting, cutoff) and not MapSet.member?(grabbed, key) and
          not new_rule?(rule, cutoff)
    }
  end

  defp reported_terms(%Sighting{} = sighting) do
    TrackerTerms.nil_if_empty(%TrackerTerms{
      private?: sighting.private,
      minimum_ratio: sighting.minimum_ratio,
      minimum_seed_time: sighting.minimum_seed_time
    })
  end

  defp recent?(nil, _cutoff), do: false
  defp recent?(%Sighting{last_seen_at: seen}, cutoff), do: DateTime.compare(seen, cutoff) != :lt

  defp new_rule?(rule, cutoff) do
    not Settings.runtime_config?(rule) and match?(%DateTime{}, rule.inserted_at) and
      DateTime.compare(rule.inserted_at, cutoff) != :lt
  end

  defp recently_grabbed_keys(cutoff) do
    from(d in Download,
      where: d.inserted_at >= ^cutoff and not is_nil(d.indexer),
      distinct: true,
      select: d.indexer
    )
    |> Repo.all()
    |> MapSet.new(&TrackerRuleConfig.key/1)
  end

  defp sandbox_pool?, do: Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
end
