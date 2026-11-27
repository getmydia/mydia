defmodule Mydia.SmartSpace.Inputs.OverrideRule do
  @moduledoc """
  A show's override: `mode` is `"off"` or `"custom"` (an `"inherit"` row is
  never stored, but is tolerated). `unit` and `grace_days` apply to `"custom"`.
  """

  @enforce_keys [:mode]
  defstruct mode: nil, unit: nil, grace_days: nil

  @type t :: %__MODULE__{
          mode: String.t(),
          unit: String.t() | nil,
          grace_days: non_neg_integer() | nil
        }
end
