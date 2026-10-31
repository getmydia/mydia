defmodule Mydia.Indexers.TrackerSightings.Row do
  @moduledoc """
  One tracker on the admin Indexers page: what it reported, the effective
  terms once its rule (if any) is applied, and whether that rule is stale.
  """

  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Settings.TrackerRuleConfig

  @type t :: %__MODULE__{
          key: String.t(),
          tracker: String.t(),
          reported: TrackerTerms.t() | nil,
          effective: TrackerTerms.t() | nil,
          rule: TrackerRuleConfig.t() | nil,
          last_seen_at: DateTime.t() | nil,
          stale?: boolean()
        }

  @enforce_keys [:key, :tracker]
  defstruct [:key, :tracker, :reported, :effective, :rule, :last_seen_at, stale?: false]
end
