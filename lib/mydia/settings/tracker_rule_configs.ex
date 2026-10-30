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

  @doc "Every rule, database rows first, sorted by tracker name."
  @spec list() :: [TrackerRuleConfig.t()]
  def list do
    TrackerRuleConfig
    |> Repo.all()
    |> RC.merge_with_runtime_config(&RC.get_runtime_tracker_rules/0, :tracker_key)
    |> Enum.sort_by(&(&1.tracker_key || ""))
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
