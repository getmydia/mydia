defmodule Mydia.Settings.TrackerRuleConfigs do
  @moduledoc """
  Storage for per-tracker term overrides: database rows merged with the
  `tracker_rules` declared in YAML or env, a row shadowing a runtime rule whose
  tracker matches case-insensitively.

  Rules are read at grab time straight from here, so a write needs no runtime
  config reload.
  """

  alias Mydia.Repo
  alias Mydia.Settings.RuntimeConfig, as: RC
  alias Mydia.Settings.TrackerRuleConfig

  # Fields a database row leaves to the runtime rule when it has no value.
  @inherited [:seed_ratio, :seed_time, :private, :grab_limit, :query_limit]

  @doc """
  Every rule, sorted by tracker name. A database row shadows the runtime rule
  for its tracker field by field: a field the row leaves empty keeps the
  runtime value, so a YAML `grab_limit` survives a row that only sets terms.
  """
  @spec list() :: [TrackerRuleConfig.t()]
  def list do
    runtime = RC.get_runtime_tracker_rules()
    runtime_by_key = Map.new(runtime, &{&1.tracker_key, &1})

    TrackerRuleConfig
    |> Repo.all()
    |> Enum.map(&inherit(&1, Map.get(runtime_by_key, &1.tracker_key)))
    |> RC.merge_with_runtime_config(fn -> runtime end, :tracker_key)
    |> Enum.sort_by(&(&1.tracker_key || ""))
  end

  defp inherit(row, nil), do: row

  defp inherit(row, runtime_rule) do
    Enum.reduce(@inherited, row, fn field, acc ->
      if is_nil(Map.get(acc, field)),
        do: Map.put(acc, field, Map.get(runtime_rule, field)),
        else: acc
    end)
  end

  @doc "A rule by database UUID or runtime id. Raises when there is none."
  @spec get!(binary()) :: TrackerRuleConfig.t()
  def get!(id) when is_binary(id) do
    if RC.runtime_id?(id) do
      Enum.find(RC.get_runtime_tracker_rules(), &(&1.id == id)) ||
        raise Ecto.NoResultsError, queryable: TrackerRuleConfig
    else
      Repo.get!(TrackerRuleConfig, id)
    end
  end

  @spec create(map()) :: {:ok, TrackerRuleConfig.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %TrackerRuleConfig{}
    |> TrackerRuleConfig.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(TrackerRuleConfig.t(), map()) ::
          {:ok, TrackerRuleConfig.t()} | {:error, Ecto.Changeset.t()}
  def update(%TrackerRuleConfig{} = config, attrs) do
    config
    |> TrackerRuleConfig.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(TrackerRuleConfig.t()) ::
          {:ok, TrackerRuleConfig.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TrackerRuleConfig{} = config), do: Repo.delete(config)
end
