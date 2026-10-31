defmodule Mydia.Settings.TrackerRuleConfig do
  @moduledoc """
  A per-tracker override of the terms indexers report: minimum ratio, minimum
  seed time (minutes) and whether the tracker is private, plus optional daily
  grab and query caps.

  Rules layer like the other service configs: `tracker_rules` in YAML or
  `TRACKER_RULE_<N>_*` env vars, or a row here edited from the admin Indexers
  page. A row shadows a runtime rule whose tracker matches case-insensitively,
  field by field: a field the row leaves nil keeps the runtime value (see
  `Mydia.Settings.TrackerRuleConfigs.list/0`).
  Runtime rules are represented with this struct too, with a `runtime::` id
  (see `Mydia.Settings.RuntimeConfig.get_runtime_tracker_rules/0`).

  Validation is `Mydia.Config.Schema.TrackerRule.changeset/2`, shared with the
  config schema so both layers accept the same values.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Config.Schema.TrackerRule

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary() | nil,
          tracker: String.t() | nil,
          tracker_key: String.t() | nil,
          seed_ratio: float() | nil,
          seed_time: non_neg_integer() | nil,
          private: boolean() | nil,
          grab_limit: non_neg_integer() | nil,
          query_limit: non_neg_integer() | nil,
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "tracker_rule_configs" do
    field :tracker, :string
    field :tracker_key, :string
    field :seed_ratio, :float
    field :seed_time, :integer
    field :private, :boolean
    # Per rolling 24 hours; nil is no cap. See Mydia.Indexers.TrackerLimits.
    field :grab_limit, :integer
    field :query_limit, :integer

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The case-insensitive key a tracker name is matched and stored under."
  @spec key(String.t() | nil) :: String.t() | nil
  def key(nil), do: nil
  def key(tracker) when is_binary(tracker), do: tracker |> String.trim() |> String.downcase()

  @doc "Changeset for creating or updating a rule."
  def changeset(config, attrs) do
    config
    |> TrackerRule.changeset(attrs)
    |> cast(attrs, [:updated_by_id])
    |> put_tracker_key()
    |> unique_constraint(:tracker,
      name: :tracker_rule_configs_tracker_key_index,
      message: "already has a rule"
    )
  end

  defp put_tracker_key(changeset) do
    put_change(changeset, :tracker_key, key(get_field(changeset, :tracker)))
  end
end
