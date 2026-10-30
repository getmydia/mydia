defmodule Mydia.Indexers.TrackerRules do
  @moduledoc """
  Applies operator overrides to the terms a tracker reports.

  Terms belong to the tracker, not to the Mydia indexer that found the
  release: one Prowlarr or Jackett connection fronts many trackers. A rule is
  matched against `SearchResult.indexer` (the tracker's name) after trimming
  and lowercasing both.

  Precedence, field by field: the rule's value, then what the tracker reported
  for that release, then nil (unknown). A rule's `seed_time` is in minutes and
  becomes seconds here. Volume factors are per release and never overridden.

  See `lib/mydia/indexers/README.md`, "Tracker terms".
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Settings
  alias Mydia.Settings.TrackerRuleConfig

  @doc "The case-insensitive key a tracker name is matched under."
  @spec key(String.t() | nil) :: String.t() | nil
  defdelegate key(tracker), to: TrackerRuleConfig

  @doc "Every rule, database rows shadowing YAML/env rules for the same tracker."
  @spec list_rules() :: [TrackerRuleConfig.t()]
  def list_rules, do: Settings.list_tracker_rule_configs()

  @doc "The rule for `tracker`, or nil."
  @spec rule_for(String.t() | nil, [TrackerRuleConfig.t()]) :: TrackerRuleConfig.t() | nil
  def rule_for(tracker, rules \\ list_rules())
  def rule_for(nil, _rules), do: nil

  def rule_for(tracker, rules) do
    wanted = key(tracker)
    Enum.find(rules, &(key(&1.tracker) == wanted))
  end

  @doc """
  The effective terms for a release of `tracker` that reported `terms`.
  Returns nil when neither the tracker nor a rule knows anything.
  """
  @spec effective(TrackerTerms.t() | nil, String.t() | nil, [TrackerRuleConfig.t()]) ::
          TrackerTerms.t() | nil
  def effective(terms, tracker, rules \\ list_rules()) do
    case rule_for(tracker, rules) do
      nil -> terms
      rule -> apply_rule(terms || %TrackerTerms{}, rule) |> TrackerTerms.nil_if_empty()
    end
  end

  @doc "The effective terms for a search result."
  @spec for_result(SearchResult.t(), [TrackerRuleConfig.t()]) :: TrackerTerms.t() | nil
  def for_result(%SearchResult{terms: terms, indexer: indexer}, rules \\ list_rules()),
    do: effective(terms, indexer, rules)

  defp apply_rule(%TrackerTerms{} = terms, %TrackerRuleConfig{} = rule) do
    %TrackerTerms{
      terms
      | minimum_ratio: override(rule.seed_ratio && rule.seed_ratio * 1.0, terms.minimum_ratio),
        minimum_seed_time:
          override(rule.seed_time && rule.seed_time * 60, terms.minimum_seed_time),
        private?: override(rule.private, terms.private?)
    }
  end

  defp override(nil, reported), do: reported
  defp override(value, _reported), do: value
end
