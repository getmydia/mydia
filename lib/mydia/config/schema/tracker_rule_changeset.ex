defmodule Mydia.Config.Schema.TrackerRuleChangeset do
  @moduledoc """
  Validation for one tracker rule, shared by the `tracker_rules` entries of
  `Mydia.Config.Schema` (YAML and env) and the database rows of
  `Mydia.Settings.TrackerRuleConfig`, so both layers accept exactly the same
  values.

  A rule names its tracker and overrides any of `seed_ratio`, `seed_time`
  (minutes) and `private`. Numbers must not be negative. Spec 4 of the
  private-tracker roadmap adds `grab_limit` and `query_limit` here.
  """

  import Ecto.Changeset

  @fields [:tracker, :seed_ratio, :seed_time, :private]

  @doc "The fields a rule carries."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @fields)
    |> update_change(:tracker, &(&1 && String.trim(&1)))
    |> validate_required([:tracker])
    |> validate_length(:tracker, max: 200)
    |> validate_number(:seed_ratio, greater_than_or_equal_to: 0)
    |> validate_number(:seed_time, greater_than_or_equal_to: 0)
  end
end
