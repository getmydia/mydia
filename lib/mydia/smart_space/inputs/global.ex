defmodule Mydia.SmartSpace.Inputs.Global do
  @moduledoc "The global Smart Space rule, as read from config."

  @enforce_keys [:enabled, :unit, :grace_days, :watched_by]
  defstruct enabled: false, unit: nil, grace_days: nil, watched_by: nil

  @type t :: %__MODULE__{
          enabled: boolean(),
          unit: String.t(),
          grace_days: non_neg_integer(),
          watched_by: String.t()
        }
end
