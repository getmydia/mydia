defmodule Mydia.Config.Schema.TrackerRule do
  @moduledoc """
  One `tracker_rules` entry of `Mydia.Config.Schema`: a per-tracker override
  of the terms indexers report (see `Mydia.Indexers.TrackerRules`).

  `tracker` matches `SearchResult.indexer` case-insensitively; `seed_time` is
  in minutes. A nil field keeps what the tracker reports. Numbers must not be
  negative.

  `changeset/2` is shared with the database rows of
  `Mydia.Settings.TrackerRuleConfig`, so both layers accept exactly the same
  values. Spec 4 of the private-tracker roadmap adds `grab_limit` and
  `query_limit` here.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @fields [:tracker, :seed_ratio, :seed_time, :private]

  @primary_key false
  embedded_schema do
    field :tracker, :string
    field :seed_ratio, :float
    field :seed_time, :integer
    field :private, :boolean
  end

  @type t :: %__MODULE__{}

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
